# Loaded by the release suite after the package cases: the Configuration cases added in v51 (machine config, project config, approval modes, target and seed).
if ($null -eq (Get-Command Read-Dlss5MachineConfig -ErrorAction SilentlyContinue)) {
    $script:Failures.Add('FAIL configure cases: the updater under test has no machine config support')
    return
}
$script:ConfigureUtf8 = [Text.UTF8Encoding]::new($false, $true)

function ConvertTo-Dlss5TestJsonBytes {
    param([Parameter(Mandatory=$true)][string]$Text)

    return ,$script:ConfigureUtf8.GetBytes($Text + [char]13 + [char]10)
}

function New-Dlss5ProjectVariantBytes {
    param([Parameter(Mandatory=$true)][string]$ProjectJson, [Collections.IDictionary]$Extra = $null)

    $files = [ordered]@{ 'PROJECT.json' = (ConvertTo-Dlss5TestJsonBytes $ProjectJson) }
    if ($null -ne $Extra) { foreach ($name in $Extra.Keys) { $files[$name] = $Extra[$name] } }

    return ,(New-Dlss5PackageVariant -Bytes $script:CandidateBytes -Files $files -State (New-Dlss5StateLines))
}

function New-Dlss5ClaudeAuthStub {
    param([Parameter(Mandatory=$true)][string]$Directory, [Parameter(Mandatory=$true)][string[]]$Body)

    New-Item -ItemType Directory -Force $Directory | Out-Null
    $stub = Join-Path $Directory 'claude.cmd'
    [IO.File]::WriteAllText($stub, ((@('@echo off') + $Body) -join "`r`n") + "`r`n", [Text.ASCIIEncoding]::new())

    return $stub
}

function Get-Dlss5TestRefusal {
    param([Parameter(Mandatory=$true)][scriptblock]$Action)

    try { $null = & $Action; return '' }
    catch { return $_.Exception.Message }
}

Invoke-Dlss5Case 'configure release missions declare their approval mode and target' {
    $project = $script:CandidateIdentity.Project
    Assert-Dlss5Equal $project.ApprovalMode 'default' 'The DLSS mission does not ship approval mode default.'
    Assert-Dlss5Equal @($project.Target).Count 1 'The DLSS mission does not declare one target check.'
    Assert-Dlss5Equal $project.Target[0].Present '*.exe' 'The DLSS target does not look for an executable.'
    Assert-Dlss5Equal $project.Target[0].Depth 2 'The DLSS target does not search two folder levels.'
    Assert-Dlss5Equal ([string]::Join(',', $project.Target[0].Except)) 'unins*,crash*,report*,setup*,install*,launcher*,vc_redist*,dxsetup*' 'The DLSS target exclusions differ from the fingerprint''s.'
    Assert-Dlss5Equal $script:CandidateIdentity.Seed $null 'The DLSS mission ships a seed.'
}

Invoke-Dlss5Case 'configure project config grammar' {
    $read = { param($Json) ConvertFrom-Dlss5ProjectConfig -Bytes (ConvertTo-Dlss5TestJsonBytes $Json) -Strict }
    $v50 = & $read '{"mission_id":"x","rerun":false}'
    Assert-Dlss5True ($v50.ApprovalMode -ceq 'default' -and $null -eq $v50.Target) 'A v50 project config did not read as default with no target.'
    foreach ($bad in @(
        '{"mission_id":"x","rerun":false,"extra":1}',
        '{"mission_id":"x","rerun":false,"approval_mode":"Manual"}',
        '{"mission_id":"x","rerun":false,"approval_mode":"allowlist"}',
        '{"mission_id":"x","rerun":false,"allowed_tools":["Read"]}',
        '{"mission_id":"x","rerun":false,"approval_mode":"manual","allowed_tools":["Read"]}',
        '{"mission_id":"x","rerun":false,"approval_mode":1}',
        '{"mission_id":"x","rerun":false,"target":null}',
        '{"mission_id":"x","rerun":false,"target":{"all":[]}}',
        '{"mission_id":"x","rerun":false,"target":{"all":[{"present":"*.exe"}],"any":[]}}',
        '{"mission_id":"x","rerun":false,"target":{"all":[{"present":"*.exe","Depth":1}]}}',
        '{"mission_id":"x","rerun":false,"target":{"all":[{"except":["a"]}]}}',
        '{"mission_id":"x","rerun":false,"target":{"all":[{"present":"*.exe","depth":4}]}}',
        '{"mission_id":"x","rerun":false,"target":{"all":[{"present":"*.exe","depth":-1}]}}',
        '{"mission_id":"x","rerun":false,"target":{"all":[{"present":"*.exe","depth":1.5}]}}',
        '{"mission_id":"x","rerun":false,"target":{"all":[{"present":"bin/*.exe"}]}}',
        '{"mission_id":"x","rerun":false,"target":{"all":[{"present":"a:b"}]}}',
        '{"mission_id":"x","rerun":false,"target":{"all":[{"present":""}]}}')) {
        Assert-Dlss5Throws { $null = & $read $bad } ([FormatException]) "A project config was accepted: $bad"
    }
    $glob = '"' + ('a' * 65) + '"'
    Assert-Dlss5Throws { $null = & $read ('{"mission_id":"x","rerun":false,"target":{"all":[{"present":' + $glob + '}]}}') } ([FormatException]) 'A 65-character glob was accepted.'
    $excepts = '[' + [string]::Join(',', @(1..17 | ForEach-Object { '"e' + $_ + '"' })) + ']'
    Assert-Dlss5Throws { $null = & $read ('{"mission_id":"x","rerun":false,"target":{"all":[{"present":"*","except":' + $excepts + '}]}}') } ([FormatException]) 'Seventeen except globs were accepted.'
    $checks = '[' + [string]::Join(',', @(1..17 | ForEach-Object { '{"present":"c' + $_ + '"}' })) + ']'
    Assert-Dlss5Throws { $null = & $read ('{"mission_id":"x","rerun":false,"target":{"all":' + $checks + '}}') } ([FormatException]) 'Seventeen target checks were accepted.'
    foreach ($mode in @('default', 'manual', 'auto')) { Assert-Dlss5Equal (& $read ('{"mission_id":"x","rerun":false,"approval_mode":"' + $mode + '"}')).ApprovalMode $mode "Approval mode $mode did not read." }
    $bare = & $read '{"mission_id":"x","rerun":false,"target":{"all":[{"present":"*.exe"}]}}'
    Assert-Dlss5True ($bare.Target[0].Except.Count -eq 0 -and $bare.Target[0].Depth -eq 0) 'A check without except or depth did not take the defaults.'
    # The framing reading reads only the mission id and rerun, so a later version's project stays stageable.
    $later = ConvertFrom-Dlss5ProjectConfig -Bytes (ConvertTo-Dlss5TestJsonBytes '{"mission_id":"x","rerun":true,"approval_mode":"future","later":1}')
    Assert-Dlss5True ($later.MissionId -ceq 'x' -and $later.Rerun) 'The framing reading refused a later version''s project keys.'
    # The largest project the bounds allow fits the 65,536-byte limit.
    $globs = @(1..16 | ForEach-Object { '"' + ('g' * 62) + $_.ToString('x2') + '"' })
    $big = '{"mission_id":"x","rerun":false,"target":{"all":[' + [string]::Join(',', @(1..16 | ForEach-Object { '{"present":"' + ('p' * 62) + $_.ToString('x2') + '","except":[' + [string]::Join(',', $globs) + '],"depth":3}' })) + ']}}'
    Assert-Dlss5Equal @((& $read $big).Target).Count 16 'The largest allowed target was refused.'
}

Invoke-Dlss5Case 'configure project config writes read back as the same project' {
    $project = $script:CandidateIdentity.Project
    $bytes = ConvertTo-Dlss5ProjectConfigBytes $project
    Assert-Dlss5Equal $script:ConfigureUtf8.GetString($bytes) $script:ConfigureUtf8.GetString([byte[]]$script:CandidateIdentity.MissionFiles['PROJECT.json']) 'The DLSS project config did not serialize to its shipped bytes.'
    $changed = ConvertFrom-Dlss5ProjectConfig -Bytes $bytes -Strict
    $changed.ApprovalMode = 'auto'
    $changed.Target = $null
    $again = ConvertFrom-Dlss5ProjectConfig -Bytes (ConvertTo-Dlss5ProjectConfigBytes $changed) -Strict
    Assert-Dlss5True ($again.ApprovalMode -ceq 'auto' -and $null -eq $again.Target) 'A changed project did not round-trip.'
    $changed.ApprovalMode = 'allowlist'
    Assert-Dlss5Throws { $null = ConvertTo-Dlss5ProjectConfigBytes $changed } ([FormatException]) 'An approval mode outside the grammar was written.'
}

Invoke-Dlss5Case 'configure target assertion branches' {
    $root = Join-Path $script:ScratchRoot 'configure-target'
    $game = Join-Path $root 'game'
    New-Item -ItemType Directory -Force (Join-Path $game 'a/b/c') | Out-Null
    $check = { param([string]$Present, [string[]]$Except = @(), [int]$Depth = 0) ,@(New-Dlss5TargetCheck -Present $Present -Except $Except -Depth $Depth) }
    $holds = { param($Target) (Test-Dlss5TargetAssertion -Directory $game -Target $Target).Holds }
    Assert-Dlss5True (& $holds $null) 'No declared target did not hold.'
    Assert-Dlss5Equal (Test-Dlss5TargetAssertion -Directory $game -Target $null).Role 'target' 'No declared target did not make the location a target.'
    [IO.File]::WriteAllBytes((Join-Path $game 'unins000.exe'), [byte[]](1))
    Assert-Dlss5True (-not (& $holds (& $check '*.exe' @('unins*')))) 'An excluded file satisfied the check.'
    Assert-Dlss5Equal (Test-Dlss5TargetAssertion -Directory $game -Target (& $check '*.exe' @('unins*'))).Role 'dev' 'A failing target did not make the location dev.'
    [IO.File]::WriteAllBytes((Join-Path $game 'a/b/Game.EXE'), [byte[]](1))
    Assert-Dlss5True (& $holds (& $check '*.exe' @('unins*') 2)) 'A matching file at depth 2 did not satisfy a depth 2 check, or case mattered.'
    Assert-Dlss5True (-not (& $holds (& $check '*.exe' @('unins*') 1))) 'A file at depth 2 satisfied a depth 1 check.'
    [IO.File]::WriteAllBytes((Join-Path $game 'a/b/c/deep.dat'), [byte[]](1))
    Assert-Dlss5True (-not (& $holds (& $check '*.dat' @() 2))) 'A file at depth 3 satisfied a depth 2 check.'
    Assert-Dlss5True (& $holds (& $check 'deep.da?' @() 3)) 'The ? wildcard did not match.'
    New-Item -ItemType Directory -Force (Join-Path $game 'folder.exe') | Out-Null
    Assert-Dlss5True (-not (& $holds (& $check 'folder.exe'))) 'A directory satisfied a check.'
    $both = @((New-Dlss5TargetCheck -Present '*.exe' -Except @('unins*') -Depth 2), (New-Dlss5TargetCheck -Present 'missing.txt'))
    $result = Test-Dlss5TargetAssertion -Directory $game -Target $both
    Assert-Dlss5True (-not $result.Holds -and $result.Reason.Contains('missing.txt')) "A failing second check did not fail the target, naming it: $($result.Reason)"
    $result = Test-Dlss5TargetAssertion -Directory (Join-Path $root 'absent') -Target (& $check '*')
    Assert-Dlss5True (-not $result.Holds -and $result.Reason.Contains('package folder cannot be read')) "An unreadable package folder did not fail every check: $($result.Reason)"
    # The search reads at most 50,000 entries; a check that reaches the bound without a match does not hold.
    $wide = Join-Path $root 'wide'
    New-Item -ItemType Directory -Force $wide | Out-Null
    for ($index = 0; $index -lt 50001; $index++) { [IO.File]::WriteAllBytes((Join-Path $wide ('f' + $index + '.txt')), [byte[]]::new(0)) }
    $result = Test-Dlss5TargetAssertion -Directory $wide -Target (& $check '*.exe')
    Assert-Dlss5True (-not $result.Holds -and $result.Reason.Contains('stopped after reading 50000 entries')) "The entry budget did not end the search: $($result.Reason)"
    Remove-Item -Recurse -Force $wide
    # Reparse points are never followed or matched.
    $linked = Join-Path $root 'linked'
    $outside = Join-Path $root 'outside'
    New-Item -ItemType Directory -Force $linked, $outside | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $outside 'game.exe'), [byte[]](1))
    $junction = Join-Path $linked 'bin'
    $made = cmd.exe /d /c mklink /J "$junction" "$outside" 2>&1
    Assert-Dlss5True (Test-Path -LiteralPath (Join-Path $junction 'game.exe')) "The junction fixture was not created: $made"
    Assert-Dlss5True (-not (Test-Dlss5TargetAssertion -Directory $linked -Target (& $check '*.exe' @() 2)).Holds) 'A check followed a junction.'
    $hardDir = Join-Path $root 'filelink'
    New-Item -ItemType Directory -Force $hardDir | Out-Null
    $fileLink = Join-Path $hardDir 'game.exe'
    $linkResult = cmd.exe /d /c mklink "$fileLink" (Join-Path $outside 'game.exe') 2>&1
    if (Test-Path -LiteralPath $fileLink) { Assert-Dlss5True (-not (Test-Dlss5TargetAssertion -Directory $hardDir -Target (& $check '*.exe')).Holds) 'A file symbolic link satisfied a check.' }
    else { Write-Host "NOTE configure target: file symbolic links unavailable here ($linkResult); the reparse-file branch was not exercised." }
}

Invoke-Dlss5Case 'configure an unreadable subdirectory contributes no matches' {
    $root = Join-Path $script:ScratchRoot 'configure-target-acl'
    $locked = Join-Path $root 'locked'
    New-Item -ItemType Directory -Force (Join-Path $root 'open') , $locked | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $locked 'game.exe'), [byte[]](1))
    $acl = Get-Acl -LiteralPath $locked
    $rule = [Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.WindowsIdentity]::GetCurrent().User, 'ListDirectory', 'Deny')
    $acl.AddAccessRule($rule)
    Set-Acl -LiteralPath $locked -AclObject $acl
    try {
        $result = Test-Dlss5TargetAssertion -Directory $root -Target @(New-Dlss5TargetCheck -Present '*.exe' -Depth 1)
        Assert-Dlss5True (-not $result.Holds -and $result.Reason.Contains($locked)) "An unreadable subdirectory was not named in the refusal: $($result.Reason)"
        [IO.File]::WriteAllBytes((Join-Path $root 'open/game.exe'), [byte[]](1))
        Assert-Dlss5True (Test-Dlss5TargetAssertion -Directory $root -Target @(New-Dlss5TargetCheck -Present '*.exe' -Depth 1)).Holds 'An unreadable subdirectory failed a check that held elsewhere.'
    }
    finally {
        $null = $acl.RemoveAccessRule($rule)
        Set-Acl -LiteralPath $locked -AclObject $acl
    }
}

Invoke-Dlss5Case 'configure machine config grammar' {
    $read = { param($Json, [switch]$Seed) ConvertFrom-Dlss5MachineConfig -Bytes (ConvertTo-Dlss5TestJsonBytes $Json) -Seed:$Seed }
    $config = & $read '{"schema_version":1,"host":"claude","host_path":"C:\\Tools\\claude.exe","claude":{"model":"opus","effort":"high","account":"Person@Example.com"},"codex":{"model":"gpt-6-sol","effort":"ultra"}}'
    Assert-Dlss5True ($config.HostKind -ceq 'claude' -and $config.HostPath -ceq 'C:\Tools\claude.exe' -and $config.Hosts['claude'].Account -ceq 'Person@Example.com' -and $config.Hosts['codex'].Effort -ceq 'ultra') 'A full machine config did not read.'
    Assert-Dlss5Equal $script:ConfigureUtf8.GetString((ConvertTo-Dlss5MachineConfigBytes $config)).Trim() '{"schema_version":1,"host":"claude","host_path":"C:\\Tools\\claude.exe","claude":{"model":"opus","effort":"high","account":"Person@Example.com"},"codex":{"model":"gpt-6-sol","effort":"ultra"}}' 'A machine config did not serialize as read.'
    foreach ($bad in @(
        '{"host":"claude"}',
        '{"schema_version":2}',
        '{"schema_version":1,"extra":1}',
        '{"schema_version":1,"host":"Claude"}',
        '{"schema_version":1,"host":"gemini"}',
        '{"schema_version":1,"host_path":"C:\\Tools\\claude.exe"}',
        '{"schema_version":1,"host":"claude","host_path":"C:\\Tools\\codex.exe"}',
        '{"schema_version":1,"host":"claude","host_path":"claude.exe"}',
        '{"schema_version":1,"host":"claude","host_path":"C:\\Tools\\claude.exe:stream"}',
        '{"schema_version":1,"claude":{"effort":"ultra"}}',
        '{"schema_version":1,"claude":{"model":"-x"}}',
        '{"schema_version":1,"claude":{"account":"no-at"}}',
        '{"schema_version":1,"claude":{"account":"a@@b"}}',
        '{"schema_version":1,"claude":{"account":"@b"}}',
        '{"schema_version":1,"claude":{"account":"a b@c"}}',
        '{"schema_version":1,"claude":{"other":"x"}}',
        '{"schema_version":1,"claude":{"model":1}}',
        '{"schema_version":1,"codex":{"account":"a@b"}}',
        '{"schema_version":1,"claude":"opus"}')) {
        Assert-Dlss5Throws { $null = & $read $bad } ([FormatException]) "A machine config was accepted: $bad"
    }
    Assert-Dlss5Throws { $null = & $read '{"schema_version":1,"host":"claude","host_path":"C:\\Tools\\claude.exe"}' -Seed } ([FormatException]) 'A seed carrying host_path was accepted.'
    Assert-Dlss5Equal (& $read '{"schema_version":1,"host":"codex","claude":{"account":"a@b"}}' -Seed).HostKind 'codex' 'A valid seed did not read.'
}

Invoke-Dlss5Case 'configure machine config read, write, concurrent change and reset' {
    Invoke-Dlss5WithLocalAppData -Path (Join-Path $script:ScratchRoot 'configure-machine') -Action {
        New-Item -ItemType Directory -Force (Get-Dlss5StorePath) | Out-Null
        $path = Get-Dlss5StorePath 'machine-config.json'
        Assert-Dlss5Equal (Read-Dlss5MachineConfig).Status 'absent' 'A missing machine config did not read as absent.'
        $null = Set-Dlss5MachineField -Field 'claude.model' -Value 'opus'
        $null = Set-Dlss5MachineField -Field 'codex.effort' -Value 'high'
        $read = Read-Dlss5MachineConfig
        Assert-Dlss5True ($read.Status -ceq 'valid' -and $read.Config.Hosts['claude'].Model -ceq 'opus' -and $read.Config.Hosts['codex'].Effort -ceq 'high') 'Two writes of different fields did not both survive.'
        # A change written between this window's read and its write is kept, since every write re-reads inside the lock.
        [IO.File]::WriteAllText($path, '{"schema_version":1,"claude":{"model":"opus","effort":"low"},"codex":{"effort":"high"}}' + "`r`n")
        $null = Set-Dlss5MachineField -Field 'claude.account' -Value 'a@b.c'
        $read = Read-Dlss5MachineConfig
        Assert-Dlss5True ($read.Config.Hosts['claude'].Effort -ceq 'low' -and $read.Config.Hosts['claude'].Account -ceq 'a@b.c') 'A concurrent change to another field was lost.'
        Assert-Dlss5Throws { $null = Set-Dlss5MachineField -Field 'claude.effort' -Value 'ultra' } ([FormatException]) 'An invalid effort was written.'
        Assert-Dlss5Throws { $null = Set-Dlss5MachineField -Field 'claude.account' -Value 'bad' } ([FormatException]) 'An invalid account was written.'
        Assert-Dlss5Throws { $null = Set-Dlss5MachineField -Field 'codex.account' -Value 'a@b.c' } ([FormatException]) 'A Codex account was written.'
        Assert-Dlss5Throws { $null = Set-Dlss5MachineField -Field 'host_path' -Value 'C:\x\claude.exe' } ([InvalidOperationException]) 'A host path was written without a host.'
        $tools = Join-Path $script:ScratchRoot 'configure-machine/tools'
        $stub = New-Dlss5ClaudeAuthStub -Directory $tools -Body @('exit /b 0')
        $null = Set-Dlss5MachineField -Field 'host' -Value 'claude'
        $null = Set-Dlss5MachineField -Field 'host_path' -Value $stub
        Assert-Dlss5Equal (Read-Dlss5MachineConfig).Config.HostPath $stub 'An existing host path was not written.'
        Assert-Dlss5Throws { $null = Set-Dlss5MachineField -Field 'host_path' -Value (Join-Path $tools 'missing/claude.exe') } ([FormatException]) 'A host path to a missing executable was written.'
        Assert-Dlss5Throws { $null = Set-Dlss5MachineField -Field 'host_path' -Value $tools } ([FormatException]) 'A folder was written as the host path.'
        # The host and its path are one unit.
        $null = Set-Dlss5MachineField -Field 'host' -Value 'codex'
        $read = Read-Dlss5MachineConfig
        Assert-Dlss5True ($read.Config.HostKind -ceq 'codex' -and $null -eq $read.Config.HostPath) 'Changing the host kept the other host''s path.'
        $null = Set-Dlss5MachineField -Field 'host' -Value 'claude'
        $null = Set-Dlss5MachineField -Field 'host_path' -Value $stub
        $null = Set-Dlss5MachineField -Field 'host' -Value ''
        $read = Read-Dlss5MachineConfig
        Assert-Dlss5True ($null -eq $read.Config.HostKind -and $null -eq $read.Config.HostPath -and $read.Config.Hosts['claude'].Model -ceq 'opus') 'Clearing the host did not clear its path, or cleared other fields.'
        # An invalid file refuses writes and launches, and is kept as a backup when reset; a second reset replaces the earlier backup.
        [IO.File]::WriteAllText($path, '{"schema_version":1,"bogus":1}')
        Assert-Dlss5Equal (Read-Dlss5MachineConfig).Status 'invalid' 'An invalid machine config did not read as invalid.'
        Assert-Dlss5Throws { $null = Set-Dlss5MachineField -Field 'claude.model' -Value 'x' } ([InvalidOperationException]) 'A write to an invalid machine config was accepted.'
        Assert-Dlss5Throws { $null = Resolve-Dlss5LaunchConfiguration } ([IO.InvalidDataException]) 'A launch with an invalid machine config was not refused.'
        Assert-Dlss5Equal (Reset-Dlss5MachineConfig) 'reset' 'The reset did not replace an invalid file.'
        Assert-Dlss5Equal ([IO.File]::ReadAllText($path + '.bkp')) '{"schema_version":1,"bogus":1}' 'The reset did not keep the invalid file as its backup.'
        Assert-Dlss5Equal ([IO.File]::ReadAllText($path).Trim()) '{"schema_version":1}' 'The reset did not write a file holding only schema_version 1.'
        [IO.File]::WriteAllText($path, '{"schema_version":1,"second":1}')
        $null = Reset-Dlss5MachineConfig
        Assert-Dlss5Equal ([IO.File]::ReadAllText($path + '.bkp')) '{"schema_version":1,"second":1}' 'A second reset did not replace the earlier backup.'
        Assert-Dlss5Equal (Reset-Dlss5MachineConfig) 'not-needed' 'A reset of a valid file changed it.'
        Remove-Item -LiteralPath $path
        Assert-Dlss5Equal (Reset-Dlss5MachineConfig) 'written' 'A reset of an absent file did not write one.'
        [IO.File]::WriteAllText($path, '{"schema_version":1,"x":"' + ('a' * 70000) + '"}')
        Assert-Dlss5Equal (Read-Dlss5MachineConfig).Status 'invalid' 'An oversized machine config did not read as invalid.'
        $null = Reset-Dlss5MachineConfig
        # A file that cannot be read for the backup is never replaced.
        Remove-Item -LiteralPath $path
        New-Item -ItemType Directory -Force $path | Out-Null
        Assert-Dlss5Equal (Read-Dlss5MachineConfig).Status 'unreadable' 'A folder in place of the machine config did not read as unreadable.'
        Assert-Dlss5Throws { $null = Reset-Dlss5MachineConfig } ([InvalidOperationException]) 'A reset replaced a file it could not read.'
        Assert-Dlss5True (Test-Path -LiteralPath $path -PathType Container) 'A refused reset changed the unreadable path.'
        Remove-Item -LiteralPath $path
    }
}

Invoke-Dlss5Case 'configure effective config precedence' {
    Invoke-Dlss5WithLocalAppData -Path (Join-Path $script:ScratchRoot 'configure-precedence') -Action {
        $machine = ConvertFrom-Dlss5MachineConfig -Bytes (ConvertTo-Dlss5TestJsonBytes '{"schema_version":1,"claude":{"model":"machine-model","account":"m@x.y"}}')
        $seed = ConvertFrom-Dlss5MachineConfig -Seed -Bytes (ConvertTo-Dlss5TestJsonBytes '{"schema_version":1,"claude":{"model":"seed-model","effort":"high","account":"s@x.y"},"codex":{"effort":"low"}}')
        $saved = @{ Model = $env:DLSS5_CLAUDE_MODEL; Effort = $env:DLSS5_CLAUDE_EFFORT }
        try {
            $env:DLSS5_CLAUDE_MODEL = $null
            $env:DLSS5_CLAUDE_EFFORT = $null
            $result = Get-Dlss5ModelConfiguration -Kind 'claude' -Machine $machine -Seed $seed
            Assert-Dlss5True ($result.Model -ceq 'machine-model' -and $result.Effort -ceq 'high' -and $result.Account -ceq 'm@x.y' -and $result.AccountSource -ceq 'machine config') 'Machine config did not win over the seed field by field.'
            $result = Get-Dlss5ModelConfiguration -Kind 'claude' -Machine $null -Seed $seed
            Assert-Dlss5True ($result.Model -ceq 'seed-model' -and $result.AccountSource -ceq 'seed') 'The seed did not supply unset fields.'
            $env:DLSS5_CLAUDE_MODEL = 'env-model'
            $env:DLSS5_CLAUDE_EFFORT = 'LOW'
            $result = Get-Dlss5ModelConfiguration -Kind 'claude' -Machine $machine -Seed $seed
            Assert-Dlss5True ($result.Model -ceq 'env-model' -and $result.Effort -ceq 'low') 'The environment did not win over machine config.'
            # An invalid environment value is warned about and then counts as unset.
            $env:DLSS5_CLAUDE_MODEL = '-bad'
            $env:DLSS5_CLAUDE_EFFORT = 'huge'
            $result = Get-Dlss5ModelConfiguration -Kind 'claude' -Machine $machine -Seed $seed
            Assert-Dlss5True ($result.Model -ceq 'machine-model' -and $result.Effort -ceq 'high') 'An invalid environment value did not fall through to machine config and the seed.'
            $env:DLSS5_CLAUDE_MODEL = $null
            $env:DLSS5_CLAUDE_EFFORT = $null
            $result = Get-Dlss5ModelConfiguration -Kind 'codex' -Machine $machine -Seed $seed
            Assert-Dlss5True ($result.Effort -ceq 'low' -and $null -eq $result.Account) 'The other host''s settings leaked into a Codex launch.'
            $result = Get-Dlss5ModelConfiguration -Kind 'claude'
            Assert-Dlss5True ($result.Model -ceq '' -and $result.Effort -ceq 'medium') 'The defaults changed.'
        }
        finally { $env:DLSS5_CLAUDE_MODEL = $saved.Model; $env:DLSS5_CLAUDE_EFFORT = $saved.Effort }
    }
}

Invoke-Dlss5Case 'configure host resolution by source' {
    Invoke-Dlss5WithLocalAppData -Path (Join-Path $script:ScratchRoot 'configure-host') -Action {
        New-Item -ItemType Directory -Force (Get-Dlss5StorePath) | Out-Null
        $path = Get-Dlss5StorePath 'machine-config.json'
        $tools = Join-Path $script:ScratchRoot 'configure-host/tools'
        $stub = New-Dlss5ClaudeAuthStub -Directory $tools -Body @('exit /b 0')
        $saved = $env:DLSS5_AGENT_HOST
        try {
            $env:DLSS5_AGENT_HOST = $null
            [IO.File]::WriteAllText($path, '{"schema_version":1,"host":"claude","host_path":"' + $stub.Replace('\', '\\') + '"}')
            $launch = Resolve-Dlss5LaunchConfiguration
            Assert-Dlss5True ($launch.Agent.Kind -ceq 'claude' -and $launch.Agent.Command -ceq $stub) 'A machine config host path was not used.'
            # An explicit environment host is never redirected by machine config.
            $other = New-Dlss5ClaudeAuthStub -Directory (Join-Path $tools 'other') -Body @('exit /b 0')
            $env:DLSS5_AGENT_HOST = $other
            Assert-Dlss5Equal (Resolve-Dlss5LaunchConfiguration).Agent.Command $other 'The environment host was redirected.'
            $env:DLSS5_AGENT_HOST = 'not-a-host'
            Assert-Dlss5Throws { $null = Resolve-Dlss5LaunchConfiguration } ([IO.InvalidDataException]) 'An invalid DLSS5_AGENT_HOST did not refuse.'
            $env:DLSS5_AGENT_HOST = $null
            Remove-Item -LiteralPath $stub
            $message = Get-Dlss5TestRefusal { Resolve-Dlss5LaunchConfiguration }
            Assert-Dlss5True ($message.Contains('no longer names an existing executable') -and $message.Contains('machine config')) "A removed host path did not refuse naming machine config: $message"
            [IO.File]::WriteAllText($path, '{"schema_version":1,"host":"codex"}')
            $savedPath = $env:PATH
            try {
                $env:PATH = [Environment]::GetFolderPath('System')
                $message = Get-Dlss5TestRefusal { Resolve-Dlss5LaunchConfiguration }
                Assert-Dlss5True ($message.Contains('not installed') -and $message.Contains('machine config')) "A configured host that is not installed did not refuse: $message"
            }
            finally { $env:PATH = $savedPath }
            # A machine config host that is not the effective one is not checked.
            $env:DLSS5_AGENT_HOST = $other
            Assert-Dlss5Equal (Resolve-Dlss5LaunchConfiguration).Agent.Command $other 'A configured host was checked though the environment chose another.'
        }
        finally { $env:DLSS5_AGENT_HOST = $saved; Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue }
    }
}

Invoke-Dlss5Case 'configure account check branches' {
    $root = Join-Path $script:ScratchRoot 'configure-account'
    $check = { param($Body) Get-Dlss5TestRefusal { Assert-Dlss5ClaudeAccount -Command (New-Dlss5ClaudeAuthStub -Directory $root -Body $Body) -Account 'person@example.com' -Source 'machine config' } }
    Assert-Dlss5Equal (& $check @('echo {"loggedIn":true,"email":"Person@Example.COM"}')) '' 'A matching account ignoring case was refused.'
    foreach ($case in @(
        @(@('echo {"loggedIn":true,"email":"other@example.com"}'), 'signed in as other@example.com'),
        @(@('echo {"loggedIn":false}'), 'not signed in'),
        @(@('echo {"loggedIn":true}'), 'reported no email'),
        @(@('echo not json'), 'could not be read as JSON'),
        @(@('echo {"loggedIn":true,"email":"person@example.com"}', 'exit /b 3'), 'exit code 3'))) {
        $message = & $check $case[0]
        Assert-Dlss5True $message.Contains($case[1]) "The account check did not refuse with '$($case[1])': $message"
    }
    # A host that never exits, and one that exits while a descendant keeps its output open, are stopped at the bound with their
    # process trees and refuse. Each tree is a ping to its own address, so a survivor is found by its command line.
    $survivors = { param($Address) @(Get-CimInstance -ClassName Win32_Process -Filter "Name = 'PING.EXE'" | Where-Object { $null -ne $_.CommandLine -and $_.CommandLine.Contains($Address) }).Count }
    foreach ($case in @(
        @('127.0.0.71', @('start /b ping -n 120 127.0.0.71', 'ping -n 120 127.0.0.71 >nul'), 'that never exits'),
        @('127.0.0.72', @('start /b ping -n 120 127.0.0.72', 'exit /b 0'), 'that exits while a descendant holds its output'))) {
        $timer = [Diagnostics.Stopwatch]::StartNew()
        $message = & $check $case[1]
        Assert-Dlss5True ($message.Contains('did not finish within 30 seconds') -and $timer.Elapsed.TotalSeconds -lt 60) "An account check $($case[2]) did not refuse within the bound: $message"
        Start-Sleep -Seconds 2
        Assert-Dlss5Equal (& $survivors $case[0]) 0 "An account check $($case[2]) left its process tree running."
    }
}

Invoke-Dlss5Case 'configure approval mode arguments on both hosts and both session kinds' {
    $saved = @{ Agent = (Get-Variable -Name Dlss5SelectedAgent -Scope Script -ValueOnly -ErrorAction SilentlyContinue); Identity = (Get-Variable -Name Dlss5ExecutingIdentity -Scope Script -ValueOnly -ErrorAction SilentlyContinue) }
    try {
        foreach ($case in @(
            @('default', 'claude', '--add-dir M --effort medium --'),
            @('manual', 'claude', '--add-dir M --permission-mode manual --effort medium --'),
            @('auto', 'claude', '--add-dir M --permission-mode auto --effort medium --'),
            @('default', 'codex', '--config model_reasoning_effort="medium" -C G --add-dir M'),
            @('auto', 'codex', '--approve-for-me --config model_reasoning_effort="medium" -C G --add-dir M'))) {
            $json = '{"mission_id":"x","rerun":false,"approval_mode":"' + $case[0] + '"}'
            $script:Dlss5ExecutingIdentity = [pscustomobject]@{ Project = (ConvertFrom-Dlss5ProjectConfig -Bytes (ConvertTo-Dlss5TestJsonBytes $json) -Strict); Seed = $null; State = $null }
            $script:Dlss5SelectedAgent = [pscustomobject]@{ Kind = $case[1]; Command = $case[1]; Model = ''; Effort = 'medium' }
            # A game session and a plain session build their arguments the same way, with their own directories.
            Assert-Dlss5Equal ([string]::Join(' ', @(Get-Dlss5AgentPrefixArguments -Agent $case[1] -GameDirectory 'G' -MachineDirectory 'M'))) $case[2] "The $($case[0]) arguments on $($case[1]) differ."
        }
        $message = Get-Dlss5TestRefusal { Assert-Dlss5ApprovalModeSupported -Kind 'codex' -Mode 'manual' }
        Assert-Dlss5True ($message.Contains('Codex cannot enforce') -and $message.Contains('nothing was launched')) "Codex manual was not refused: $message"
        foreach ($mode in @('default', 'auto')) { Assert-Dlss5Equal (Get-Dlss5TestRefusal { Assert-Dlss5ApprovalModeSupported -Kind 'codex' -Mode $mode }) '' "Codex $mode was refused." }
        foreach ($mode in $script:Dlss5ApprovalModes) { Assert-Dlss5Equal (Get-Dlss5TestRefusal { Assert-Dlss5ApprovalModeSupported -Kind 'claude' -Mode $mode }) '' "Claude Code $mode was refused." }
        foreach ($flag in @('bypassPermissions', '--dangerously-skip-permissions', '--allow-dangerously-skip-permissions', '--dangerously-bypass-approvals-and-sandbox')) {
            Assert-Dlss5True (-not (Get-Dlss5UpdaterInstructionText).Contains($flag)) "The engine passes $flag."
        }
    }
    finally { $script:Dlss5SelectedAgent = $saved.Agent; $script:Dlss5ExecutingIdentity = $saved.Identity }
}

Invoke-Dlss5Case 'configure codex refusal remedies follow the copy' {
    $saved = @{ Identity = (Get-Variable -Name Dlss5ExecutingIdentity -Scope Script -ValueOnly -ErrorAction SilentlyContinue); Path = $script:Dlss5PackagePath; Startup = (Get-Variable -Name Dlss5Startup -Scope Script -ValueOnly -ErrorAction SilentlyContinue); PathVar = $env:PATH }
    try {
        $script:Dlss5ExecutingIdentity = $script:CandidateIdentity
        $script:Dlss5PackagePath = $null
        $script:Dlss5Startup = [pscustomobject]@{ Diagnosis = [pscustomobject]@{ Reason = 'git-unavailable'; Evidence = 'fixture' } }
        $tools = Join-Path $script:ScratchRoot 'configure-remedies/tools'
        $null = New-Dlss5ClaudeAuthStub -Directory $tools -Body @('exit /b 0')
        $env:PATH = $tools + ';' + [Environment]::GetFolderPath('System')
        $message = Get-Dlss5TestRefusal { Assert-Dlss5ApprovalModeSupported -Kind 'codex' -Mode 'manual' }
        Assert-Dlss5True ($message.Contains('--host claude') -and -not $message.Contains('change the mission''s approval mode')) "Under a refused package write the remedies were wrong: $message"
        $env:PATH = [Environment]::GetFolderPath('System')
        $message = Get-Dlss5TestRefusal { Assert-Dlss5ApprovalModeSupported -Kind 'codex' -Mode 'manual' }
        Assert-Dlss5True ($message.Contains('Claude Code is not installed') -and -not $message.Contains('--host claude')) "Without Claude Code the refusal named its remedies: $message"
    }
    finally { $script:Dlss5ExecutingIdentity = $saved.Identity; $script:Dlss5PackagePath = $saved.Path; $script:Dlss5Startup = $saved.Startup; $env:PATH = $saved.PathVar }
}

Invoke-Dlss5Case 'configure seed grammar follows the strict and framing readings' {
    $seeded = New-Dlss5ProjectVariantBytes -ProjectJson '{"mission_id":"dlss5","rerun":true,"approval_mode":"default"}' -Extra ([ordered]@{ 'SEED.json' = (ConvertTo-Dlss5TestJsonBytes '{"schema_version":1,"host":"claude","claude":{"account":"a@b.c"}}') })
    $identity = Get-Dlss5BootstrapIdentity -Bytes $seeded -Strict
    Assert-Dlss5True ($null -ne $identity.Seed -and $identity.Seed.Hosts['claude'].Account -ceq 'a@b.c') 'A seed was not read by the strict reading.'
    $malformed = New-Dlss5PackageVariant -Bytes $script:CandidateBytes -Files ([ordered]@{ 'SEED.json' = (ConvertTo-Dlss5TestJsonBytes '{"schema_version":1,"host":"claude","host_path":"C:\\x\\claude.exe"}') })
    Assert-Dlss5Throws { $null = Get-Dlss5BootstrapIdentity -Bytes $malformed -Strict } ([FormatException]) 'The strict reading accepted a seed carrying host_path.'
    $framing = Get-Dlss5BootstrapIdentity -Bytes $malformed
    Assert-Dlss5True ($framing.MissionFiles.Contains('SEED.json') -and $null -eq $framing.Seed) 'The framing reading read the seed''s content.'
    Assert-Dlss5True (Test-Dlss5MissionFileRole 'SEED.json') 'SEED.json is not a mission file.'
    # --dump-payload still extracts a seed the strict reading refuses.
    $fixture = New-Dlss5IsolatedLaunchFixture -Name 'configure-seed-dump'
    [IO.File]::WriteAllBytes($fixture.Updater, $malformed)
    $folder = Join-Path $fixture.Root 'dump'
    $process = Invoke-Dlss5IsolatedLaunch -Fixture $fixture -Arguments @('--dump-payload', $folder)
    Assert-Dlss5Equal $process.ExitCode 0 "Dumping a package with a malformed seed failed: $($process.StandardOutput) $($process.StandardError)"
    Assert-Dlss5True ([Linq.Enumerable]::SequenceEqual[byte]([IO.File]::ReadAllBytes((Join-Path $folder 'SEED.json')), [byte[]]$framing.MissionFiles['SEED.json'])) 'The dump did not extract the malformed seed as embedded.'
}

Invoke-Dlss5Case 'configure seed validation at launch' {
    Invoke-Dlss5WithLocalAppData -Path (Join-Path $script:ScratchRoot 'configure-seed-launch') -Action {
        New-Item -ItemType Directory -Force (Get-Dlss5StorePath) | Out-Null
        $saved = @{ Identity = (Get-Variable -Name Dlss5ExecutingIdentity -Scope Script -ValueOnly -ErrorAction SilentlyContinue); Launch = $script:Dlss5LaunchConfiguration; Host = $env:DLSS5_AGENT_HOST; PathVar = $env:PATH; Path = $script:Dlss5PackagePath }
        try {
            $tools = Join-Path $script:ScratchRoot 'configure-seed-launch/tools'
            $stub = New-Dlss5ClaudeAuthStub -Directory $tools -Body @('echo {"loggedIn":true,"email":"seed@x.y"}')
            $env:PATH = $tools + ';' + [Environment]::GetFolderPath('System')
            $env:DLSS5_AGENT_HOST = $null
            $script:Dlss5PackagePath = $null
            $seed = { param($Json) Get-Dlss5BootstrapIdentity -Strict -Bytes (New-Dlss5ProjectVariantBytes -ProjectJson '{"mission_id":"dlss5","rerun":false}' -Extra ([ordered]@{ 'SEED.json' = (ConvertTo-Dlss5TestJsonBytes $Json) })) }
            $script:Dlss5ExecutingIdentity = & $seed '{"schema_version":1,"host":"claude","claude":{"account":"seed@x.y"}}'
            $null = Resolve-Dlss5LaunchConfiguration
            Assert-Dlss5Equal (Select-Dlss5Agent).Command $stub 'A valid seeded host and account were not used.'
            $script:Dlss5ExecutingIdentity = & $seed '{"schema_version":1,"host":"claude","claude":{"account":"other@x.y"}}'
            $message = Get-Dlss5TestRefusal { Select-Dlss5Agent }
            Assert-Dlss5True ($message.Contains('The seed expects') -and $message.Contains('other@x.y')) "A failing seeded account did not refuse naming the seed: $message"
            $script:Dlss5ExecutingIdentity = & $seed '{"schema_version":1,"host":"codex"}'
            $message = Get-Dlss5TestRefusal { Select-Dlss5Agent }
            Assert-Dlss5True ($message.Contains('seed names the codex host') -and $message.Contains('Override the host in machine config')) "A seeded host that is not installed did not refuse naming the seed: $message"
            Assert-Dlss5True (-not $message.Contains('rebake')) "The seed refusal offered a package write the copy does not allow: $message"
            # Overriding by a higher source skips the seed field: the environment here, machine config below.
            $env:DLSS5_AGENT_HOST = $stub
            $null = Resolve-Dlss5LaunchConfiguration
            Assert-Dlss5Equal (Select-Dlss5Agent).Command $stub 'An environment host did not skip the seeded host.'
            $env:DLSS5_AGENT_HOST = $null
            $null = Set-Dlss5MachineField -Field 'host' -Value 'claude'
            $null = Resolve-Dlss5LaunchConfiguration
            Assert-Dlss5Equal (Select-Dlss5Agent).Command $stub 'A machine config host did not skip the seeded host.'
            # The other host's seed fields are not checked.
            $script:Dlss5ExecutingIdentity = & $seed '{"schema_version":1,"codex":{"model":"gpt-6-sol"},"claude":{"account":"seed@x.y"}}'
            $null = Resolve-Dlss5LaunchConfiguration
            $selected = Select-Dlss5Agent
            Assert-Dlss5True ($selected.Kind -ceq 'claude' -and $selected.Model -ceq '') 'The other host''s seed fields were used or checked.'
        }
        finally { $script:Dlss5ExecutingIdentity = $saved.Identity; $script:Dlss5LaunchConfiguration = $saved.Launch; $env:DLSS5_AGENT_HOST = $saved.Host; $env:PATH = $saved.PathVar; $script:Dlss5PackagePath = $saved.Path }
    }
}

Invoke-Dlss5Case 'configure seed refusal names package remedies only where package writes are allowed' {
    Invoke-Dlss5PackageInteraction -Name 'configure-seed-remedy' -Bytes (New-Dlss5ProjectVariantBytes -ProjectJson '{"mission_id":"dlss5","rerun":true}' -Extra ([ordered]@{ 'SEED.json' = (ConvertTo-Dlss5TestJsonBytes '{"schema_version":1,"host":"codex"}') })) -Action {
        param($packagePath, $game)
        $saved = @{ Host = $env:DLSS5_AGENT_HOST; PathVar = $env:PATH; Path = $script:Dlss5PackagePath; Launch = $script:Dlss5LaunchConfiguration }
        try {
            $env:DLSS5_AGENT_HOST = $null
            $env:PATH = [Environment]::GetFolderPath('System')
            $script:Dlss5PackagePath = $packagePath
            $null = Resolve-Dlss5LaunchConfiguration
            $message = Get-Dlss5TestRefusal { Select-Dlss5Agent }
            Assert-Dlss5True $message.Contains('remove or rebake the seed') "An editable copy's seed refusal did not offer the seed remedy: $message"
            $script:Dlss5Startup = [pscustomobject]@{ Diagnosis = [pscustomobject]@{ Reason = 'git-unavailable'; Evidence = 'fixture' } }
            $message = Get-Dlss5TestRefusal { Select-Dlss5Agent }
            Assert-Dlss5True (-not $message.Contains('rebake') -and $message.Contains('machine config')) "Under the diagnosis condition the seed refusal offered a package write: $message"
            $script:Dlss5Startup = [pscustomobject]@{ Diagnosis = $null }
            $script:Dlss5ExecutingIdentity = Get-Dlss5BootstrapIdentity -Strict -Bytes (New-Dlss5PackageVariant -Bytes ([IO.File]::ReadAllBytes($packagePath)) -State (New-Dlss5StateLines -Update ([pscustomobject]@{ FromVersion = 50; FromMissionHash = $null; FromSha256 = ('d' * 64); ReplacedEdit = $false; BackupSha256 = $null })))
            $message = Get-Dlss5TestRefusal { Select-Dlss5Agent }
            Assert-Dlss5True (-not $message.Contains('rebake')) "With an update record pending the seed refusal offered a package write: $message"
            # The shared copy is never edited, so its seed refusal names only the machine config remedy.
            $slot = Get-Dlss5StorePath 'DLSS5-ADDER.cmd'
            [IO.File]::WriteAllBytes($slot, [IO.File]::ReadAllBytes($packagePath))
            $script:Dlss5ExecutingIdentity = Get-Dlss5BootstrapIdentity -Strict -Bytes ([IO.File]::ReadAllBytes($slot))
            $script:Dlss5PackagePath = $slot
            $message = Get-Dlss5TestRefusal { Select-Dlss5Agent }
            Assert-Dlss5True ($message.Contains('seed names the codex host') -and -not $message.Contains('rebake')) "On the shared copy the seed refusal offered a package write: $message"
        }
        finally { $env:DLSS5_AGENT_HOST = $saved.Host; $env:PATH = $saved.PathVar; $script:Dlss5PackagePath = $saved.Path; $script:Dlss5LaunchConfiguration = $saved.Launch }
    }
}

Invoke-Dlss5Case 'configure seed remedy and package writes refuse while the Git gate refuses' {
    $fixture = New-Dlss5GitFixture 'configure-gate'
    $seeded = New-Dlss5ProjectVariantBytes -ProjectJson '{"mission_id":"dlss5","rerun":true}' -Extra ([ordered]@{ 'SEED.json' = (ConvertTo-Dlss5TestJsonBytes '{"schema_version":1,"host":"codex"}') })
    [IO.File]::WriteAllBytes($fixture.Updater, $seeded)
    [void](Invoke-Dlss5Git -Repository $fixture.Root add -- 'Game/DLSS5-ADDER.cmd')
    [void](Invoke-Dlss5Git -Repository $fixture.Root commit -m 'test: track package')
    # An uncommitted mission edit of the tracked package makes the Git gate refuse.
    [IO.File]::WriteAllBytes($fixture.Updater, (New-Dlss5PackageVariant -Bytes $seeded -Files ([ordered]@{ 'INSTRUCTIONS.cleanup-boundary.md' = [byte[]](65) }) -State (New-Dlss5StateLines -MissionEdited $true)))
    $git = Split-Path -Parent (Get-Command git -CommandType Application | Select-Object -First 1).Source
    Invoke-Dlss5WithLocalAppData -Path (Join-Path $fixture.Root 'LocalAppData') -Action {
        $saved = @{ Startup = (Get-Variable -Name Dlss5Startup -Scope Script -ValueOnly -ErrorAction SilentlyContinue); Identity = (Get-Variable -Name Dlss5ExecutingIdentity -Scope Script -ValueOnly -ErrorAction SilentlyContinue); Host = $env:DLSS5_AGENT_HOST; PathVar = $env:PATH; Path = $script:Dlss5PackagePath; Launch = $script:Dlss5LaunchConfiguration }
        try {
            $script:Dlss5Startup = [pscustomobject]@{ Diagnosis = $null }
            Write-Dlss5MachineTrustFixture -MachineDirectory (Get-Dlss5StorePath) -Whole @{ $script:CandidateVersion = $script:CandidateIdentity.Sha256 }
            $env:DLSS5_AGENT_HOST = $null
            # Git stays reachable so the gate refuses for the edit, not for a missing git; Codex is not installed.
            $env:PATH = $git + ';' + [Environment]::GetFolderPath('System')
            $script:Dlss5PackagePath = $fixture.Updater
            $script:Dlss5ExecutingIdentity = Get-Dlss5BootstrapIdentity -Strict -Bytes ([IO.File]::ReadAllBytes($fixture.Updater))
            $block = Get-Dlss5SectionWriteBlock $fixture.Updater
            Assert-Dlss5True $block.StartsWith('The Git check refuses changes to this package', [StringComparison]::Ordinal) "The Git gate did not refuse the fixture: [$block]"
            $null = Resolve-Dlss5LaunchConfiguration
            $message = Get-Dlss5TestRefusal { Select-Dlss5Agent }
            Assert-Dlss5True ($message.Contains('seed names the codex host') -and -not $message.Contains('rebake')) "Under a refusing Git gate the seed refusal offered a package write: $message"
            Assert-Dlss5Throws { Set-Dlss5ProjectConfig -Path $fixture.Updater -Change { param($Project) $Project.Rerun = $false } } ([InvalidOperationException]) 'A project write under a refusing Git gate was accepted.'
            Assert-Dlss5Throws { Set-Dlss5Seed -Path $fixture.Updater -Remove } ([InvalidOperationException]) 'A seed removal under a refusing Git gate was accepted.'
        }
        finally { $script:Dlss5Startup = $saved.Startup; $script:Dlss5ExecutingIdentity = $saved.Identity; $env:DLSS5_AGENT_HOST = $saved.Host; $env:PATH = $saved.PathVar; $script:Dlss5PackagePath = $saved.Path; $script:Dlss5LaunchConfiguration = $saved.Launch }
    }
}

Invoke-Dlss5Case 'configure project and seed writes are mission edits under the section-write rules' {
    Invoke-Dlss5PackageInteraction -Name 'configure-package-writes' -Bytes (New-Dlss5PackageVariant -Bytes $script:CandidateBytes -State (New-Dlss5StateLines -Armed $true)) -Action {
        param($packagePath, $game)
        $before = $script:Dlss5ExecutingIdentity.MissionSha256
        Set-Dlss5ProjectConfig -Path $packagePath -ExpectMission $before -Change { param($Project) $Project.ApprovalMode = 'auto' }
        $identity = Get-Dlss5BootstrapIdentity -Bytes ([IO.File]::ReadAllBytes($packagePath)) -Strict
        Assert-Dlss5True ($identity.Project.ApprovalMode -ceq 'auto' -and -not $identity.State.Armed -and $identity.State.MissionEdited -and $identity.MissionSha256 -cne $before) 'A project config change was not a disarming mission edit.'
        $same = $identity.MissionSha256
        Set-Dlss5ProjectConfig -Path $packagePath -ExpectMission $same -Change { param($Project) $Project.ApprovalMode = 'auto' }
        Assert-Dlss5Equal (Get-Dlss5BootstrapIdentity -Bytes ([IO.File]::ReadAllBytes($packagePath)) -Strict).MissionSha256 $same 'An unchanged project write changed the mission hash.'
        Assert-Dlss5Throws { Set-Dlss5ProjectConfig -Path $packagePath -ExpectMission $before -Change { param($Project) $Project.Rerun = $false } } ([InvalidOperationException]) 'A project write on a stale mission was accepted.'
        # Seeds are baked from chosen machine config fields, never the host path, and removed again.
        $tools = Join-Path $game 'tools'
        $stub = New-Dlss5ClaudeAuthStub -Directory $tools -Body @('exit /b 0')
        $null = Set-Dlss5MachineField -Field 'host' -Value 'claude'
        $null = Set-Dlss5MachineField -Field 'host_path' -Value $stub
        $null = Set-Dlss5MachineField -Field 'claude.account' -Value 'a@b.c'
        Assert-Dlss5Throws { Set-Dlss5Seed -Path $packagePath -Fields @('host_path') } ([FormatException]) 'host_path was baked into a seed.'
        Assert-Dlss5Throws { Set-Dlss5Seed -Path $packagePath -Fields @('codex.model') } ([InvalidOperationException]) 'An unset field was baked into a seed.'
        Set-Dlss5Seed -Path $packagePath -Fields @('host', 'claude.account')
        $identity = Get-Dlss5BootstrapIdentity -Bytes ([IO.File]::ReadAllBytes($packagePath)) -Strict
        Assert-Dlss5Equal $script:ConfigureUtf8.GetString([byte[]]$identity.MissionFiles['SEED.json']).Trim() '{"schema_version":1,"host":"claude","claude":{"account":"a@b.c"}}' 'The baked seed holds the wrong fields.'
        Set-Dlss5Seed -Path $packagePath -Remove
        Assert-Dlss5True (-not (Get-Dlss5BootstrapIdentity -Bytes ([IO.File]::ReadAllBytes($packagePath)) -Strict).MissionFiles.Contains('SEED.json')) 'The seed was not removed.'
        Assert-Dlss5Throws { Set-Dlss5Seed -Path $packagePath -Remove } ([InvalidOperationException]) 'Removing an absent seed was accepted.'
        # Under the diagnosis condition, with an update record pending, or on the shared copy, package writes refuse; machine writes still work.
        $script:Dlss5Startup = [pscustomobject]@{ Diagnosis = [pscustomobject]@{ Reason = 'git-unavailable'; Evidence = 'fixture' } }
        Assert-Dlss5Throws { Set-Dlss5ProjectConfig -Path $packagePath -Change { param($Project) $Project.Rerun = $false } } ([InvalidOperationException]) 'A project write under the diagnosis condition was accepted.'
        $null = Set-Dlss5MachineField -Field 'claude.model' -Value 'opus'
        $script:Dlss5Startup = [pscustomobject]@{ Diagnosis = $null }
        [IO.File]::WriteAllBytes($packagePath, (New-Dlss5PackageVariant -Bytes ([IO.File]::ReadAllBytes($packagePath)) -State (New-Dlss5StateLines -Update ([pscustomobject]@{ FromVersion = 50; FromMissionHash = $null; FromSha256 = ('d' * 64); ReplacedEdit = $false; BackupSha256 = $null }))))
        $script:Dlss5ExecutingIdentity = Get-Dlss5BootstrapIdentity -Bytes ([IO.File]::ReadAllBytes($packagePath)) -Strict
        Assert-Dlss5Throws { Set-Dlss5ProjectConfig -Path $packagePath -Change { param($Project) $Project.Rerun = $false } } ([InvalidOperationException]) 'A project write with an update pending was accepted.'
        $slot = Get-Dlss5StorePath 'DLSS5-ADDER.cmd'
        [IO.File]::WriteAllBytes($slot, $script:CandidateBytes)
        $script:Dlss5ExecutingIdentity = $script:CandidateIdentity
        Assert-Dlss5Throws { Set-Dlss5ProjectConfig -Path $slot -Change { param($Project) $Project.Rerun = $false } } ([InvalidOperationException]) 'A project write on the shared copy was accepted.'
    }
}

Invoke-Dlss5Case 'configure explode and absorb carry SEED.json' {
    $seedBytes = ConvertTo-Dlss5TestJsonBytes '{"schema_version":1,"host":"codex"}'
    Invoke-Dlss5PackageInteraction -Name 'configure-seed-explode' -Bytes (New-Dlss5PackageVariant -Bytes $script:CandidateBytes -Files ([ordered]@{ 'SEED.json' = $seedBytes }) -State (New-Dlss5StateLines)) -Action {
        param($packagePath, $game)
        $script:Dlss5Console = New-Dlss5SubstitutedConsole @()
        Assert-Dlss5Equal (Invoke-Dlss5Explode -Path $packagePath -Headless) 0 'Explode failed.'
        Assert-Dlss5True ([Linq.Enumerable]::SequenceEqual[byte]([IO.File]::ReadAllBytes((Join-Path $game 'SEED.json')), [byte[]]$seedBytes)) 'Explode did not write SEED.json.'
        $folder = Join-Path $game 'drop'
        New-Item -ItemType Directory -Force $folder | Out-Null
        [IO.File]::WriteAllText((Join-Path $folder 'SEED.json'), '{"schema_version":1,"host":"claude"}' + "`r`n")
        $identity = $script:Dlss5ExecutingIdentity
        Assert-Dlss5Equal (Invoke-Dlss5Absorb -Path $packagePath -Files @((Join-Path $folder 'SEED.json')) -Headless -Expect $identity) 0 'Absorb refused a seed.'
        Assert-Dlss5Equal (Get-Dlss5BootstrapIdentity -Bytes ([IO.File]::ReadAllBytes($packagePath)) -Strict).Seed.HostKind 'claude' 'Absorb did not embed SEED.json.'
        [IO.File]::WriteAllText((Join-Path $folder 'SEED.json'), '{"schema_version":1,"host":"claude","host_path":"C:\\x\\claude.exe"}' + "`r`n")
        $identity = $script:Dlss5ExecutingIdentity
        Assert-Dlss5Equal (Invoke-Dlss5Absorb -Path $packagePath -Files @((Join-Path $folder 'SEED.json')) -Headless -Expect $identity) 8 'Absorb accepted a seed carrying host_path.'
    }
}

Invoke-Dlss5Case 'configure header shows the role, target, approval mode and seed notice' {
    Invoke-Dlss5PackageInteraction -Name 'configure-header' -Bytes (New-Dlss5PackageVariant -Bytes $script:CandidateBytes -Files ([ordered]@{ 'SEED.json' = (ConvertTo-Dlss5TestJsonBytes '{"schema_version":1,"host":"codex"}') }) -State (New-Dlss5StateLines)) -Action {
        param($packagePath, $game)
        $script:Dlss5Console = New-Dlss5SubstitutedConsole @()
        Write-Dlss5Header -Identity $script:Dlss5ExecutingIdentity -Path $packagePath
        $text = $script:Dlss5Console.Output -join "`n"
        Assert-Dlss5True ($text.Contains('Location: dev') -and $text.Contains('within 2 folder levels')) "The header did not show the dev role and target: $text"
        Assert-Dlss5True $text.Contains('Approval mode: default') 'The header did not show the approval mode.'
        Assert-Dlss5True $text.Contains('identifying data') 'The header did not show the seed notice.'
        New-Dlss5TargetExecutable $game
        $script:Dlss5Console = New-Dlss5SubstitutedConsole @()
        Write-Dlss5Header -Identity $script:Dlss5ExecutingIdentity -Path $packagePath
        Assert-Dlss5True ($script:Dlss5Console.Output -join "`n").Contains('Location: target') 'The header did not re-evaluate the role.'
    }
}

Invoke-Dlss5Case 'configure execute refuses outside a target and diagnose is not gated' {
    $fixture = New-Dlss5IsolatedLaunchFixture -Name 'configure-execute-target' -StubBody @('echo started>"%DLSS5_TEST_STARTED_PATH%"')
    $started = Join-Path $fixture.StubRoot 'started.txt'
    $environment = @{ DLSS5_TEST_STARTED_PATH = $started }
    # A first launch inside the target records trust for the copy, which the later diagnosis-only launch requires. A launch whose
    # stub agent only records its start ends with its notification channel retained and a nonzero exit, so these cases judge
    # only whether the agent started.
    $process = Invoke-Dlss5IsolatedLaunch -Fixture $fixture -Environment $environment
    Assert-Dlss5True (Test-Path -LiteralPath $started) "Execute inside the target did not start the agent (exit $($process.ExitCode)): $($process.StandardOutput) $($process.StandardError)"
    Remove-Item -LiteralPath $started
    Remove-Item -Recurse -Force (Join-Path $fixture.Game 'bin')
    $process = Invoke-Dlss5IsolatedLaunch -Fixture $fixture -Environment $environment
    Assert-Dlss5Equal $process.ExitCode 8 "Execute outside a target did not refuse: $($process.StandardOutput) $($process.StandardError)"
    Assert-Dlss5True $process.StandardOutput.Contains('not a target of the mission') 'The refusal did not name the target.'
    Assert-Dlss5True (-not (Test-Path -LiteralPath $started)) 'An agent started outside a target.'
    $null = Set-Dlss5FixtureArmed $fixture
    $task = Invoke-Dlss5IsolatedLaunch -Fixture $fixture -Arguments @('a task') -Environment $environment
    Assert-Dlss5Equal $task.ExitCode 8 "A command-line task outside a target did not refuse: $($task.StandardOutput)"
    Assert-Dlss5True (-not (Test-Path -LiteralPath $started)) 'A task agent started outside a target.'
    # An empty .git directory is Git metadata git cannot inspect, so the launch becomes diagnosis-only, which the target does not gate.
    New-Item -ItemType Directory -Force (Join-Path $fixture.Game '.git') | Out-Null
    $diagnose = Invoke-Dlss5IsolatedLaunch -Fixture $fixture -Arguments (Get-Dlss5DiagnoseArguments $fixture) -Environment $environment
    Assert-Dlss5True (Test-Path -LiteralPath $started) "Diagnose outside a target did not start the agent (exit $($diagnose.ExitCode)): $($diagnose.StandardOutput) $($diagnose.StandardError)"
}

Invoke-Dlss5Case 'configure launches apply the approval mode and the account check on execute, a task and diagnose' {
    # The stub answers the account check, and otherwise records the permission arguments, which follow --add-dir and --model.
    $fixture = New-Dlss5IsolatedLaunchFixture -Name 'configure-launch-approval' -StubBody @(
        'if "%~1"=="auth" (',
        'echo {"loggedIn":true,"email":"%DLSS5_TEST_EMAIL%"}',
        'exit /b 0',
        ')',
        'echo %5 %6>>"%DLSS5_TEST_ARGS_PATH%"'
    )
    [IO.File]::WriteAllBytes($fixture.Updater, (New-Dlss5ProjectVariantBytes -ProjectJson '{"mission_id":"dlss5","rerun":true,"approval_mode":"manual"}'))
    New-Item -ItemType Directory -Force $fixture.MachineDirectory | Out-Null
    [IO.File]::WriteAllText((Join-Path $fixture.MachineDirectory 'machine-config.json'), '{"schema_version":1,"claude":{"account":"person@example.com"}}')
    $argsPath = Join-Path $fixture.StubRoot 'args.txt'
    $match = @{ DLSS5_TEST_EMAIL = 'Person@Example.com'; DLSS5_TEST_ARGS_PATH = $argsPath }
    $other = @{ DLSS5_TEST_EMAIL = 'other@example.com'; DLSS5_TEST_ARGS_PATH = $argsPath }
    $recorded = { if (Test-Path -LiteralPath $argsPath) { @([IO.File]::ReadAllLines($argsPath) | Where-Object { $_.Trim().Length -gt 0 }) } else { @() } }
    $launches = @(
        @{ Name = 'Execute'; Arguments = $null },
        @{ Name = 'a command-line task'; Arguments = @('a task') },
        @{ Name = 'Diagnose'; Arguments = 'diagnose' })
    $count = 0
    foreach ($launch in $launches) {
        if ($launch.Arguments -ceq 'diagnose') { New-Item -ItemType Directory -Force (Join-Path $fixture.Game '.git') | Out-Null }
        foreach ($case in @(@($match, $true), @($other, $false))) {
            if ($null -eq $launch.Arguments) { $process = Invoke-Dlss5IsolatedLaunch -Fixture $fixture -Environment $case[0] }
            else {
                $arguments = if ($launch.Arguments -ceq 'diagnose') { Get-Dlss5DiagnoseArguments $fixture } else { $null = Set-Dlss5FixtureArmed $fixture; $launch.Arguments }
                $process = Invoke-Dlss5IsolatedLaunch -Fixture $fixture -Arguments $arguments -Environment $case[0]
            }
            if ($case[1]) {
                # The launch ends with its notification channel retained and a nonzero exit; only the start and its arguments are judged.
                $count++
                $lines = @(& $recorded)
                Assert-Dlss5True ($lines.Count -eq $count -and $lines[-1].Trim() -ceq '--permission-mode manual') "$($launch.Name) did not start the agent with the manual approval mode (exit $($process.ExitCode)): $($lines -join ' | ') $($process.StandardOutput) $($process.StandardError)"
            }
            else {
                Assert-Dlss5True ($process.ExitCode -ne 0 -and $process.StandardOutput.Contains('signed in as other@example.com')) "$($launch.Name) with another account was not refused: $($process.StandardOutput)"
                Assert-Dlss5Equal @(& $recorded).Count $count "$($launch.Name) started the agent though the account differed."
            }
        }
    }
}

Invoke-Dlss5Case 'configure default host prompt appears only after the earlier launch checks pass' {
    $fixture = New-Dlss5IsolatedLaunchFixture -Name 'configure-default-host' -StubBody @('echo started>"%DLSS5_TEST_STARTED_PATH%"')
    $started = Join-Path $fixture.StubRoot 'started.txt'
    # No launch argument, environment variable, machine config or seed names a host; only the stub Claude Code is on PATH.
    $pwsh = Split-Path -Parent (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source
    $environment = @{ DLSS5_AGENT_HOST = $null; DLSS5_AGENT = $null; PATH = ($fixture.StubRoot + ';' + $pwsh + ';' + [Environment]::GetFolderPath('System')); DLSS5_TEST_STARTED_PATH = $started }
    $prompt = 'DLSS5_AGENT_HOST is unset'
    $bin = Join-Path $fixture.Game 'bin'
    $saved = Join-Path $fixture.Root 'bin-saved'
    Move-Item -LiteralPath $bin -Destination $saved
    $process = Invoke-Dlss5IsolatedLaunch -Fixture $fixture -Environment $environment
    Assert-Dlss5True ($process.ExitCode -ne 0 -and $process.StandardOutput.Contains('not a target of the mission') -and -not $process.StandardOutput.Contains($prompt)) "A failing target did not end the launch before the host prompt: $($process.StandardOutput)"
    Move-Item -LiteralPath $saved -Destination $bin
    New-Item -ItemType Directory -Force $fixture.MachineDirectory | Out-Null
    $config = Join-Path $fixture.MachineDirectory 'machine-config.json'
    [IO.File]::WriteAllText($config, '{"schema_version":1,"bogus":1}')
    $process = Invoke-Dlss5IsolatedLaunch -Fixture $fixture -Environment $environment
    Assert-Dlss5True ($process.ExitCode -ne 0 -and $process.StandardOutput.Contains('machine config') -and -not $process.StandardOutput.Contains($prompt)) "An invalid machine config did not end the launch before the host prompt: $($process.StandardOutput)"
    Assert-Dlss5True (-not (Test-Path -LiteralPath $started)) 'An agent started after an earlier launch check refused.'
    Remove-Item -LiteralPath $config
    $process = Invoke-Dlss5IsolatedLaunch -Fixture $fixture -Environment $environment
    # The launch ends with its notification channel retained and a nonzero exit; only the prompt and the start are judged.
    Assert-Dlss5True ($process.StandardOutput.Contains($prompt) -and (Test-Path -LiteralPath $started)) "With no source naming a host, the default host choice did not run (exit $($process.ExitCode), started $(Test-Path -LiteralPath $started)): $($process.StandardOutput) $($process.StandardError)"
}

Invoke-Dlss5Case 'configure headless requests' {
    Invoke-Dlss5PackageInteraction -Name 'configure-headless' -Bytes (New-Dlss5PackageVariant -Bytes $script:CandidateBytes -State (New-Dlss5StateLines)) -Action {
        param($packagePath, $game)
        $script:Dlss5Console = New-Dlss5SubstitutedConsole @()
        $request = Join-Path $game 'request.json'
        $send = {
            param([string]$Json, $Expect = $script:Dlss5ExecutingIdentity)
            [IO.File]::WriteAllText($request, $Json)

            return Invoke-Dlss5PackageItem -Path $packagePath -Request ([pscustomobject]@{ Item = '--internal-configure'; Expect = (ConvertFrom-Dlss5ExpectationToken (Get-Dlss5ExpectationToken $Expect)); Folder = $request })
        }
        Assert-Dlss5Equal (& $send '{"action":"set-machine","field":"claude.model","value":"opus"}') 0 'A headless machine write failed.'
        Assert-Dlss5Equal (Read-Dlss5MachineConfig).Config.Hosts['claude'].Model 'opus' 'The headless machine write did not land.'
        Assert-Dlss5Equal (& $send '{"action":"set-machine","field":"claude.model","value":null}') 0 'A headless clear failed.'
        Assert-Dlss5Equal (& $send '{"action":"set-machine","field":"claude.effort","value":"ultra"}') 8 'An invalid headless value was accepted.'
        Assert-Dlss5Equal (& $send '{"action":"set-project","approval_mode":"auto","target":null}') 0 'A headless project write failed.'
        $identity = $script:Dlss5ExecutingIdentity
        Assert-Dlss5True ($identity.Project.ApprovalMode -ceq 'auto' -and $null -eq $identity.Project.Target) 'The headless project write did not land.'
        Assert-Dlss5Equal (& $send '{"action":"set-project","approval_mode":"allowlist"}') 8 'A headless approval mode outside the grammar was accepted.'
        Assert-Dlss5Equal (& $send '{"action":"set-project","allowed_tools":["Read"]}') 8 'A headless allowed_tools field was accepted.'
        Assert-Dlss5Equal (& $send '{"action":"set-project","approval_mode":"manual"}') 0 'A headless approval mode change failed.'
        Assert-Dlss5Equal (& $send '{"action":"set-project","extra":1}') 8 'An unknown request field was accepted.'
        Assert-Dlss5Equal (& $send '{"action":"bake-seed","fields":["claude.model"]}') 8 'A seed was baked from an unset field.'
        # A stale mission refuses package writes, but not machine writes, which depend only on the version and engine.
        $stale = [pscustomobject]@{ Version = $identity.Version; EngineSha256 = $identity.EngineSha256; MissionSha256 = ('0' * 64) }
        Assert-Dlss5Equal (& $send '{"action":"set-project","rerun":false}' $stale) 8 'A package write with a stale mission was accepted.'
        Assert-Dlss5Equal (& $send '{"action":"set-machine","field":"codex.effort","value":"low"}' $stale) 0 'A machine write was refused for a stale mission.'
        $wrongEngine = [pscustomobject]@{ Version = $identity.Version; EngineSha256 = ('0' * 64); MissionSha256 = $identity.MissionSha256 }
        Assert-Dlss5Equal (& $send '{"action":"set-machine","field":"codex.effort","value":"low"}' $wrongEngine) 8 'A machine write for another engine was accepted.'
        Assert-Dlss5Equal (& $send 'not json') 8 'An unparseable request was accepted.'
        Assert-Dlss5Equal (& $send ('{"action":"reset-machine","pad":"' + ('a' * 70000) + '"}')) 8 'An oversized request was accepted.'
        # With an update record pending, machine actions are accepted and package actions refuse.
        [IO.File]::WriteAllBytes($packagePath, (New-Dlss5PackageVariant -Bytes ([IO.File]::ReadAllBytes($packagePath)) -State (New-Dlss5StateLines -Update ([pscustomobject]@{ FromVersion = 50; FromMissionHash = $null; FromSha256 = ('d' * 64); ReplacedEdit = $false; BackupSha256 = $null }))))
        $script:Dlss5ExecutingIdentity = Get-Dlss5BootstrapIdentity -Bytes ([IO.File]::ReadAllBytes($packagePath)) -Strict
        Assert-Dlss5Equal (& $send '{"action":"set-machine","field":"codex.effort","value":"high"}') 0 'A machine write was refused while an update was pending.'
        Assert-Dlss5Equal (& $send '{"action":"set-project","rerun":false}') 8 'A package write was accepted while an update was pending.'
        Assert-Dlss5Equal (& $send '{"action":"remove-seed"}') 8 'A seed removal was accepted while an update was pending.'
    }
}

Invoke-Dlss5Case 'configure interactive flows' {
    Invoke-Dlss5PackageInteraction -Name 'configure-interactive' -Bytes (New-Dlss5PackageVariant -Bytes $script:CandidateBytes -State (New-Dlss5StateLines)) -Action {
        param($packagePath, $game)
        # Set the Claude model by typing, then leave.
        $keys = @('m', 'Enter') + @('o', 'p', 'u', 's') + @('Enter', 'b', 'Enter')
        $script:Dlss5Console = New-Dlss5SubstitutedConsole $keys
        Invoke-Dlss5Configure -Path $packagePath
        Assert-Dlss5Equal (Read-Dlss5MachineConfig).Config.Hosts['claude'].Model 'opus' 'The typed model was not saved.'
        # Esc cancels a text entry without changing anything.
        $script:Dlss5Console = New-Dlss5SubstitutedConsole @('a', 'Enter', 'x', 'Escape', 'b', 'Enter')
        Invoke-Dlss5Configure -Path $packagePath
        Assert-Dlss5Equal (Read-Dlss5MachineConfig).Config.Hosts['claude'].Account $null 'A cancelled entry was saved.'
        # Pasted text counts as text in an entry.
        $script:Dlss5Console = New-Dlss5SubstitutedConsole (@('a', 'Enter') + (Add-Dlss5PastedText -Keys @() -Text 'me@x.y') + @('Enter', 'b', 'Enter'))
        Invoke-Dlss5Configure -Path $packagePath
        Assert-Dlss5Equal (Read-Dlss5MachineConfig).Config.Hosts['claude'].Account 'me@x.y' 'A pasted account was not saved.'
        # Choosing the approval mode is a disarming mission edit after its confirmation-free choice.
        $script:Dlss5Console = New-Dlss5SubstitutedConsole @('r', 'Enter', 'u', 'Enter', 'b', 'Enter')
        Invoke-Dlss5Configure -Path $packagePath
        Assert-Dlss5Equal $script:Dlss5ExecutingIdentity.Project.ApprovalMode 'auto' 'The approval mode was not changed.'
        # Baking and removing the seed each ask first, and a declined confirmation changes nothing.
        foreach ($answer in @('n', 'y')) {
            $script:Dlss5Console = New-Dlss5SubstitutedConsole @('s', 'Enter', '1', 'Enter', 'k', 'Enter', $answer, 'Enter', 'b', 'Enter')
            Invoke-Dlss5Configure -Path $packagePath
            Assert-Dlss5True ($script:Dlss5Console.Output -join "`n").Contains('Bake these fields') 'The seed bake did not ask first.'
            Assert-Dlss5Equal (Get-Dlss5BootstrapIdentity -Bytes ([IO.File]::ReadAllBytes($packagePath)) -Strict).MissionFiles.Contains('SEED.json') ($answer -ceq 'y') "The seed bake answered $answer left the wrong seed state."
        }
        foreach ($answer in @('n', 'y')) {
            $script:Dlss5Console = New-Dlss5SubstitutedConsole @('d', 'Enter', $answer, 'Enter', 'b', 'Enter')
            Invoke-Dlss5Configure -Path $packagePath
            Assert-Dlss5True ($script:Dlss5Console.Output -join "`n").Contains('Remove the seed from this package?') 'The seed removal did not ask first.'
            Assert-Dlss5Equal (Get-Dlss5BootstrapIdentity -Bytes ([IO.File]::ReadAllBytes($packagePath)) -Strict).MissionFiles.Contains('SEED.json') ($answer -ceq 'n') "The seed removal answered $answer left the wrong seed state."
        }
        # An invalid machine config offers only the reset among machine items; the reset asks first.
        [IO.File]::WriteAllText((Get-Dlss5StorePath 'machine-config.json'), '{"schema_version":1,"bogus":1}')
        $script:Dlss5Console = New-Dlss5SubstitutedConsole @('x', 'Enter', 'y', 'Enter', 'b', 'Enter')
        Invoke-Dlss5Configure -Path $packagePath
        $text = $script:Dlss5Console.Output -join "`n"
        # Only the menu shown before the reset counts; after it the machine config is valid again and its fields return.
        $beforeReset = $text.Substring(0, [Math]::Max(0, $text.IndexOf('Replace ', [StringComparison]::Ordinal)))
        Assert-Dlss5True (-not $beforeReset.Contains('Set claude.model') -and $beforeReset.Contains('Reset the machine config')) 'An invalid machine config still offered its fields.'
        Assert-Dlss5Equal (Read-Dlss5MachineConfig).Status 'valid' 'The confirmed reset did not run.'
        # On the shared copy, only machine items are offered.
        $slot = Get-Dlss5StorePath 'DLSS5-ADDER.cmd'
        [IO.File]::WriteAllBytes($slot, $script:CandidateBytes)
        $script:Dlss5ExecutingIdentity = $script:CandidateIdentity
        $script:Dlss5Console = New-Dlss5SubstitutedConsole @('b', 'Enter')
        Invoke-Dlss5Configure -Path $slot
        $text = $script:Dlss5Console.Output -join "`n"
        Assert-Dlss5True ($text.Contains('never edited') -and -not $text.Contains('Set the approval mode') -and $text.Contains('Set claude.model')) 'The shared copy offered project items or hid machine items.'
        # Under the diagnosis condition, Configure is in the menu with its machine items.
        $script:Dlss5ExecutingIdentity = Get-Dlss5BootstrapIdentity -Bytes ([IO.File]::ReadAllBytes($packagePath)) -Strict
        $script:Dlss5Startup = [pscustomobject]@{ Diagnosis = [pscustomobject]@{ Reason = 'git-unavailable'; Evidence = 'fixture' } }
        $script:Dlss5Console = New-Dlss5SubstitutedConsole @('c', 'Enter', 'b', 'Enter', 'Escape')
        $null = Invoke-Dlss5Menu -Path $packagePath
        $text = $script:Dlss5Console.Output -join "`n"
        Assert-Dlss5True ($text.Contains('[c] Configure') -and $text.Contains('Set claude.model') -and $text.Contains('unavailable: A startup check failed')) 'Configure under the diagnosis condition did not offer machine items only.'
    }
}
