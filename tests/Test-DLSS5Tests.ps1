# Loaded by the release suite after the line-ending cases: the mission test and Arm gate cases added in v55.
if ($null -eq (Get-Command Get-Dlss5ArmGate -ErrorAction SilentlyContinue)) {
    $script:Failures.Add('FAIL mission test cases: the updater under test has no Arm gate')
    return
}

$script:GateTarget = '{"all":[{"present":"game.exe","except":[],"depth":0}]}'

function New-Dlss5TestedPackageBytes {
    param([Parameter(Mandatory=$true)][object[]]$Tests, [hashtable]$Scripts = @{}, [switch]$Target, [AllowNull()][string[]]$State = $null)

    # A plain package declaring the given tests, each with its script (exit 0 unless given); with -Target, its target asks for game.exe in the package folder.
    $declarations = [string]::Join(',', @($Tests | ForEach-Object { '{"name":"' + $_.Name + '","required":' + $(if ($_.Required) { 'true' } else { 'false' }) + ',"role":"' + $_.Role + '","here_only":' + $(if ($_.HereOnly) { 'true' } else { 'false' }) + '}' }))
    $project = '{"mission_id":"hello-world","rerun":false' + $(if ($Target) { ',"target":' + $script:GateTarget } else { '' }) + ',"tests":[' + $declarations + ']}'
    $files = [ordered]@{ 'PROJECT.json' = $script:PackageUtf8.GetBytes($project + $script:PackageNewline) }
    foreach ($test in $Tests) { $files['TEST.' + $test.Name + '.ps1'] = $script:PackageUtf8.GetBytes($(if ($Scripts.ContainsKey($test.Name)) { $Scripts[$test.Name] } else { 'exit 0' }) + $script:PackageNewline) }

    return ,(New-Dlss5PackageVariant -Bytes (New-Dlss5PlainPackageBytes) -Files $files -State $State)
}

function New-Dlss5TestDeclaration {
    param([Parameter(Mandatory=$true)][string]$Name, [bool]$Required = $true, [string]$Role = 'dev', [bool]$HereOnly = $false)

    return [pscustomobject]@{ Name = $Name; Required = $Required; Role = $Role; HereOnly = $HereOnly }
}

function New-Dlss5TestRecordFixture {
    param([Parameter(Mandatory=$true)][string]$Name, [string]$Verdict = 'pass', [string]$Role = 'dev', [Parameter(Mandatory=$true)][string]$Mission, [string]$Time = '20261107T100000Z', [string]$Machine = '00000000-0000-0000-0000-000000000001', [string]$Location = '0123456789abcdef', [string]$Label = 'HOST|C:\Somewhere')

    return [pscustomobject]@{ Name = $Name; Verdict = $Verdict; Role = $Role; Mission = $Mission; Time = $Time; Machine = $Machine; Location = $Location; Label = $Label }
}

function New-Dlss5RecordStateLines {
    param([Parameter(Mandatory=$true)][AllowEmptyCollection()][object[]]$Records, [bool]$Armed = $false, $Update = $null)

    return ConvertTo-Dlss5StateBody ([pscustomobject]@{ Empty = $false; Armed = $Armed; MissionEdited = $false; ReplacedMissionHash = $null; Update = $Update; Records = $Records })
}

function Get-Dlss5PackageIdentityAt {
    param([Parameter(Mandatory=$true)][string]$PackagePath)

    return Get-Dlss5BootstrapIdentity -Bytes ([IO.File]::ReadAllBytes($PackagePath)) -Strict
}

function Get-Dlss5ConsoleText {
    return ($script:Dlss5Console.Output -join "`n")
}

$script:PlainMission = (Get-Dlss5BootstrapIdentity -Bytes (New-Dlss5TestedPackageBytes -Tests @((New-Dlss5TestDeclaration 'unit'))) -Strict).MissionSha256

Invoke-Dlss5Case 'mission tests declarations parse, refuse every illegal form and survive the project writer' {
    $parse = { param($Tests) ConvertFrom-Dlss5ProjectConfig -Bytes $script:PackageUtf8.GetBytes('{"mission_id":"m","rerun":false,"tests":' + $Tests + '}') -Strict }
    $project = & $parse '[{"name":"unit","required":true,"role":"dev","here_only":false},{"name":"live","required":false,"role":"target","here_only":true}]'
    Assert-Dlss5Equal $project.Tests.Count 2 'The declarations were not read.'
    Assert-Dlss5True ($project.Tests[1].HereOnly -and $project.Tests[1].Role -ceq 'target' -and -not $project.Tests[1].Required) 'The second declaration was misread.'
    Assert-Dlss5Equal (& $parse '[]').Tests.Count 0 'An empty array did not mean no tests.'
    $illegal = @(
        '{}', '[{"name":"unit","required":true,"role":"dev"}]', '[{"name":"unit","required":true,"role":"dev","here_only":false,"extra":1}]',
        '[{"name":"unit","required":true,"role":"dev","here_only":false},{"name":"unit","required":false,"role":"dev","here_only":false}]',
        '[{"name":"unit","required":true,"role":"dev","here_only":true}]', '[{"name":"Unit","required":true,"role":"dev","here_only":false}]',
        '[{"name":"unit","required":"yes","role":"dev","here_only":false}]', '[{"name":"unit","required":true,"role":"lab","here_only":false}]'
    )
    foreach ($tests in $illegal) { Assert-Dlss5Throws { $null = & $parse $tests } ([FormatException]) "An illegal declaration was accepted: $tests" }
    $many = '[' + [string]::Join(',', @(1..33 | ForEach-Object { '{"name":"t' + $_ + '","required":false,"role":"dev","here_only":false}' })) + ']'
    Assert-Dlss5Throws { $null = & $parse $many } ([FormatException]) 'More than 32 declarations were accepted.'
    # The writer keeps the declarations, so Configure's project edits keep them.
    $project.ApprovalMode = 'manual'
    $written = ConvertFrom-Dlss5ProjectConfig -Bytes (ConvertTo-Dlss5ProjectConfigBytes $project) -Strict
    Assert-Dlss5True ($written.Tests.Count -eq 2 -and $written.Tests[0].Name -ceq 'unit' -and $written.Tests[1].HereOnly) 'The project writer dropped or changed the declarations.'
    # The framing reading ignores the field.
    Assert-Dlss5Equal (ConvertFrom-Dlss5ProjectConfig -Bytes $script:PackageUtf8.GetBytes('{"mission_id":"m","rerun":false,"tests":"anything"}')).Tests.Count 0 'The framing reading read the tests field.'
}

Invoke-Dlss5Case 'mission tests a package whose test files and declarations disagree is refused at load' {
    $bytes = New-Dlss5TestedPackageBytes -Tests @((New-Dlss5TestDeclaration 'unit'))
    $undeclared = New-Dlss5PackageVariant -Bytes $bytes -Files ([ordered]@{ 'TEST.extra.ps1' = $script:PackageUtf8.GetBytes('exit 0') })
    Assert-Dlss5Throws { $null = Get-Dlss5BootstrapIdentity -Bytes $undeclared -Strict } ([FormatException]) 'An undeclared test file was accepted.'
    $missing = New-Dlss5PackageVariant -Bytes $bytes -Files ([ordered]@{ 'TEST.unit.ps1' = $null })
    Assert-Dlss5Throws { $null = Get-Dlss5BootstrapIdentity -Bytes $missing -Strict } ([FormatException]) 'A declaration without its file was accepted.'
    Assert-Dlss5True (Test-Dlss5MissionFileRole 'TEST.unit.ps1') 'A test file is not a mission file.'
    Assert-Dlss5True (-not (Test-Dlss5MissionFileRole 'TEST.Unit.ps1') -and -not (Test-Dlss5MissionFileRole 'TEST.unit.txt')) 'A misnamed test file was taken as a mission file.'
}

Invoke-Dlss5Case 'mission tests STATE carries records under schema 2 and refuses every malformed record layout' {
    $records = @((New-Dlss5TestRecordFixture -Name 'b' -Mission $script:PlainMission), (New-Dlss5TestRecordFixture -Name 'a' -Mission $script:PlainMission -Label ('HOST|C:\' + [char]0x00e5 + 'ngest')))
    $lines = New-Dlss5RecordStateLines -Records $records
    Assert-Dlss5Equal $lines[0] 'state_schema: 2' 'A STATE with records did not use schema 2.'
    Assert-Dlss5True ($lines[-2].StartsWith('test_record: a ', [StringComparison]::Ordinal) -and $lines[-1].StartsWith('test_record: b ', [StringComparison]::Ordinal)) 'The records were not sorted.'
    $read = ConvertFrom-Dlss5StateBody $lines
    Assert-Dlss5Equal $read.Records.Count 2 'The records did not round-trip.'
    Assert-Dlss5Equal $read.Records[0].Label ('HOST|C:\' + [char]0x00e5 + 'ngest') 'A non-ASCII label did not round-trip.'
    Assert-Dlss5Equal (New-Dlss5RecordStateLines -Records @())[0] 'state_schema: 1' 'A STATE without records did not keep schema 1.'
    # A state built without a Records property, as callers before v55 built it, still renders.
    Assert-Dlss5Equal (New-Dlss5StateLines -Armed $true)[0] 'state_schema: 1' 'A state without the records property did not render.'
    $record = $lines[-1]
    $malformed = @(
        @('state_schema: 1', 'armed: false', 'mission_edited: false', $record),
        @('state_schema: 2', 'armed: false', 'mission_edited: false'),
        @('state_schema: 2', 'armed: false', 'mission_edited: false', $lines[-1], $lines[-2]),
        @('state_schema: 2', 'armed: false', 'mission_edited: false', $record, $record),
        @('state_schema: 2', 'armed: false', $record, 'mission_edited: false'),
        @('state_schema: 2', 'armed: false', 'mission_edited: false', $record.Replace(' pass ', ' maybe '))
    )
    foreach ($body in $malformed) { Assert-Dlss5Throws { $null = ConvertFrom-Dlss5StateBody ([string[]]$body) } ([FormatException]) ('A malformed record layout was accepted: ' + ($body -join ' / ')) }
    $tooMany = @(1..257 | ForEach-Object { New-Dlss5TestRecordFixture -Name ('t' + $_) -Mission $script:PlainMission })
    Assert-Dlss5Throws { $null = New-Dlss5RecordStateLines -Records $tooMany } ([FormatException]) 'More than 256 records were accepted.'
    Assert-Dlss5Throws { $null = ConvertFrom-Dlss5StateBody @('state_schema: 3', 'armed: false', 'mission_edited: false') } ([NotSupportedException]) 'An unknown schema was not refused as unsupported.'
}

Invoke-Dlss5Case 'mission tests a headless run records pass and fail with their fields and no output, and removes its folder' {
    $tests = @((New-Dlss5TestDeclaration 'good' -Role 'target'), (New-Dlss5TestDeclaration 'bad' -Required $false -Role 'target'), (New-Dlss5TestDeclaration 'empty' -Required $false -Role 'target'))
    $bytes = New-Dlss5TestedPackageBytes -Tests $tests -Scripts @{ 'good' = 'Write-Output "secret-output"; exit 0'; 'bad' = 'exit 3' }
    $bytes = New-Dlss5PackageVariant -Bytes $bytes -Files ([ordered]@{ 'TEST.empty.ps1' = [byte[]]@() })
    Invoke-Dlss5PackageInteraction -Name 'tests-headless-run' -Bytes $bytes -Action {
        param($PackagePath)
        $script:Dlss5Console = New-Dlss5SubstitutedConsole @()
        Assert-Dlss5Equal (Invoke-Dlss5TestRun -Path $PackagePath -Names @('good')) 0 "A passing test did not return 0: $(Get-Dlss5ConsoleText)"
        Assert-Dlss5Equal (Invoke-Dlss5TestRun -Path $PackagePath -Names @('bad')) 1 "A failing test did not return 1: $(Get-Dlss5ConsoleText)"
        $identity = Get-Dlss5PackageIdentityAt $PackagePath
        $location = Get-Dlss5LocationIdentity -PackagePath $PackagePath
        $good = @($identity.State.Records | Where-Object { $_.Name -ceq 'good' })
        $bad = @($identity.State.Records | Where-Object { $_.Name -ceq 'bad' })
        Assert-Dlss5True ($good.Count -eq 1 -and $good[0].Verdict -ceq 'pass' -and $bad.Count -eq 1 -and $bad[0].Verdict -ceq 'fail') 'The verdicts were not recorded.'
        Assert-Dlss5True ($good[0].Role -ceq 'target' -and $good[0].Mission -ceq $identity.MissionSha256 -and $good[0].Location -ceq $location.Hash -and $good[0].Machine -ceq (Get-Dlss5MachineId)) 'The record fields are wrong.'
        Assert-Dlss5Equal $good[0].Label ($env:COMPUTERNAME + '|' + $location.Path) 'The record label is wrong.'
        Assert-Dlss5True (-not ([IO.File]::ReadAllText($PackagePath)).Contains('secret-output')) 'Test output reached the package.'
        $folder = Get-Dlss5StorePath 'mission-tests'
        Assert-Dlss5True (-not (Test-Path -LiteralPath $folder) -or @(Get-ChildItem -LiteralPath $folder -Force).Count -eq 0) 'A test run folder was left behind.'
        # An empty test script is a valid mission file, and it passes.
        Assert-Dlss5Equal (Invoke-Dlss5TestRun -Path $PackagePath -Names @('empty')) 0 "An empty test did not run and pass: $(Get-Dlss5ConsoleText)"
        Assert-Dlss5True (@((Get-Dlss5PackageIdentityAt $PackagePath).State.Records | Where-Object { $_.Name -ceq 'empty' -and $_.Verdict -ceq 'pass' }).Count -eq 1) 'The empty test was not recorded as a pass.'
        # A rerun replaces the record for the same test, machine and location.
        $null = Invoke-Dlss5TestRun -Path $PackagePath -Names @('good')
        Assert-Dlss5Equal @((Get-Dlss5PackageIdentityAt $PackagePath).State.Records | Where-Object { $_.Name -ceq 'good' }).Count 1 'A rerun added a second record for the same location.'
    }
}

Invoke-Dlss5Case 'mission tests a run is refused for a role mismatch, an undeclared test, a pending update and an unreadable machine id' {
    $bytes = New-Dlss5TestedPackageBytes -Tests @((New-Dlss5TestDeclaration 'unit' -Role 'target')) -Target
    Invoke-Dlss5PackageInteraction -Name 'tests-run-refusals' -Bytes $bytes -Action {
        param($PackagePath, $Game)
        $script:Dlss5Console = New-Dlss5SubstitutedConsole @()
        # Without game.exe the folder is a dev location, so the target test is refused.
        Assert-Dlss5Equal (Invoke-Dlss5TestRun -Path $PackagePath -Names @('unit')) $script:Dlss5RefusedExitCode 'A target test ran at a dev location.'
        Assert-Dlss5True (Get-Dlss5ConsoleText).Contains('runs at a target location, and this location is dev') 'The role refusal did not say why.'
        [IO.File]::WriteAllBytes((Join-Path $Game 'game.exe'), [byte[]](1))
        Assert-Dlss5Equal (Invoke-Dlss5TestRun -Path $PackagePath -Names @('other')) $script:Dlss5RefusedExitCode 'An undeclared test ran.'
        $saved = $script:Dlss5ReadMachineGuid
        try {
            $script:Dlss5ReadMachineGuid = { $null }
            Assert-Dlss5Equal (Invoke-Dlss5TestRun -Path $PackagePath -Names @('unit')) $script:Dlss5RefusedExitCode 'A run without a machine id was not refused.'
            Assert-Dlss5True (Get-Dlss5ConsoleText).Contains('MachineGuid') 'The machine id refusal did not name the MachineGuid.'
        }
        finally { $script:Dlss5ReadMachineGuid = $saved }
        Assert-Dlss5Equal (Get-Dlss5StateRecords (Get-Dlss5PackageIdentityAt $PackagePath).State).Count 0 'A refused run wrote a record.'
    }
    $update = [pscustomobject]@{ FromVersion = 54; FromMissionHash = $null; FromSha256 = ('a' * 64); ReplacedEdit = $false; BackupSha256 = $null }
    $pending = New-Dlss5TestedPackageBytes -Tests @((New-Dlss5TestDeclaration 'unit' -Role 'target')) -State (New-Dlss5RecordStateLines -Records @() -Update $update)
    Invoke-Dlss5PackageInteraction -Name 'tests-run-pending' -Bytes $pending -Action {
        param($PackagePath)
        $script:Dlss5Console = New-Dlss5SubstitutedConsole @()
        $before = [IO.File]::ReadAllBytes($PackagePath)
        Assert-Dlss5Equal (Invoke-Dlss5TestRun -Path $PackagePath -Names @('unit')) $script:Dlss5RefusedExitCode 'A run was not refused while an update awaited acknowledgement.'
        Assert-Dlss5True (Test-Dlss5ByteEquality -Left ([IO.File]::ReadAllBytes($PackagePath)) -Right $before) 'A run refused for a pending update changed the package.'
    }
}

Invoke-Dlss5Case 'mission tests a test that runs too long is stopped and recorded as a fail' {
    $bytes = New-Dlss5TestedPackageBytes -Tests @((New-Dlss5TestDeclaration 'slow' -Role 'target')) -Scripts @{ 'slow' = 'Start-Sleep -Seconds 60; exit 0' }
    Invoke-Dlss5PackageInteraction -Name 'tests-timeout' -Bytes $bytes -Action {
        param($PackagePath)
        $script:Dlss5Console = New-Dlss5SubstitutedConsole @()
        $saved = $script:Dlss5TestTimeout
        try {
            $script:Dlss5TestTimeout = [TimeSpan]::FromSeconds(3)
            Assert-Dlss5Equal (Invoke-Dlss5TestRun -Path $PackagePath -Names @('slow')) 1 "The timed-out test did not count as a fail: $(Get-Dlss5ConsoleText)"
        }
        finally { $script:Dlss5TestTimeout = $saved }
        Assert-Dlss5True (Get-Dlss5ConsoleText).Contains('was stopped') 'The timeout was not reported.'
        Assert-Dlss5Equal @((Get-Dlss5PackageIdentityAt $PackagePath).State.Records)[0].Verdict 'fail' 'The timed-out test was not recorded as a fail.'
    }
}

Invoke-Dlss5Case 'mission tests a test that cannot start records nothing and says why' {
    $bytes = New-Dlss5TestedPackageBytes -Tests @((New-Dlss5TestDeclaration 'unit' -Role 'target'))
    Invoke-Dlss5PackageInteraction -Name 'tests-cannot-start' -Bytes $bytes -Action {
        param($PackagePath)
        $script:Dlss5Console = New-Dlss5SubstitutedConsole @()
        $saved = $script:Dlss5TestShell
        try {
            $script:Dlss5TestShell = 'dlss5-no-such-shell.exe'
            Assert-Dlss5Equal (Invoke-Dlss5TestRun -Path $PackagePath -Names @('unit')) $script:Dlss5RefusedExitCode 'A test that could not start was not refused.'
        }
        finally { $script:Dlss5TestShell = $saved }
        Assert-Dlss5True (Get-Dlss5ConsoleText).Contains('Not recorded: the test unit could not be started') "The start failure was not reported: $(Get-Dlss5ConsoleText)"
        $folder = Get-Dlss5StorePath 'mission-tests'
        Assert-Dlss5True (-not (Test-Path -LiteralPath $folder) -or @(Get-ChildItem -LiteralPath $folder -Force).Count -eq 0) 'A test that could not start left its folder behind.'
        # A run folder that cannot be created is reported the same way: a file stands where the scratch folder belongs.
        if (Test-Path -LiteralPath $folder) { Remove-Item -LiteralPath $folder -Recurse -Force }
        [IO.File]::WriteAllText($folder, 'occupied')
        try { Assert-Dlss5Equal (Invoke-Dlss5TestRun -Path $PackagePath -Names @('unit')) $script:Dlss5RefusedExitCode 'A test without its folder was not refused.' }
        finally { Remove-Item -LiteralPath $folder -Force }
        Assert-Dlss5True (Get-Dlss5ConsoleText).Contains('since its folder could not be created') "The folder failure was not reported: $(Get-Dlss5ConsoleText)"
        Assert-Dlss5Equal (Get-Dlss5StateRecords (Get-Dlss5PackageIdentityAt $PackagePath).State).Count 0 'A test that could not start was recorded.'
    }
}

Invoke-Dlss5Case 'mission tests a record beyond the limit drops the oldest, ties broken by line order' {
    # 256 records at distinct locations; the two oldest share a time, and the one earlier in line order goes.
    $records = @(1..256 | ForEach-Object {
        $time = if ($_ -le 2) { '20200101T000000Z' } else { [DateTime]::new(2026, 1, 1).AddDays($_).ToString('yyyyMMddTHHmmssZ', [Globalization.CultureInfo]::InvariantCulture) }
        New-Dlss5TestRecordFixture -Name 'unit' -Role 'target' -Mission $script:PlainMission -Time $time -Location ('{0:x16}' -f $_)
    })
    $bytes = New-Dlss5TestedPackageBytes -Tests @((New-Dlss5TestDeclaration 'unit' -Role 'target')) -State (New-Dlss5RecordStateLines -Records $records)
    Invoke-Dlss5PackageInteraction -Name 'tests-record-limit' -Bytes $bytes -Action {
        param($PackagePath)
        $script:Dlss5Console = New-Dlss5SubstitutedConsole @()
        Assert-Dlss5Equal (Invoke-Dlss5TestRun -Path $PackagePath -Names @('unit')) 0 "The run beyond the limit failed: $(Get-Dlss5ConsoleText)"
        $kept = Get-Dlss5StateRecords (Get-Dlss5PackageIdentityAt $PackagePath).State
        $locations = @($kept | ForEach-Object { $_.Location })
        $here = (Get-Dlss5LocationIdentity -PackagePath $PackagePath).Hash
        Assert-Dlss5Equal $kept.Count 256 'The record limit was not kept.'
        Assert-Dlss5True ((('{0:x16}' -f 1) -cnotin $locations) -and (('{0:x16}' -f 2) -cin $locations) -and ($here -cin $locations)) 'The wrong record was dropped.'
    }
}

Invoke-Dlss5Case 'mission tests a new record is kept at the limit even when a skewed clock makes it the oldest' {
    $records = @(1..256 | ForEach-Object { New-Dlss5TestRecordFixture -Name 'unit' -Role 'target' -Mission $script:PlainMission -Time ([DateTime]::new(2026, 1, 1).AddDays($_).ToString('yyyyMMddTHHmmssZ', [Globalization.CultureInfo]::InvariantCulture)) -Location ('{0:x16}' -f $_) })
    $bytes = New-Dlss5TestedPackageBytes -Tests @((New-Dlss5TestDeclaration 'unit' -Role 'target')) -State (New-Dlss5RecordStateLines -Records $records)
    Invoke-Dlss5PackageInteraction -Name 'tests-record-limit-skew' -Bytes $bytes -Action {
        param($PackagePath)
        $script:Dlss5Console = New-Dlss5SubstitutedConsole @()
        $skewed = New-Dlss5TestRecordFixture -Name 'unit' -Role 'target' -Mission (Get-Dlss5PackageIdentityAt $PackagePath).MissionSha256 -Time '20200101T000000Z' -Location 'ffffffffffffffff'
        $location = [pscustomobject]@{ Machine = $skewed.Machine; Location = $skewed.Location; Path = 'C:\Here'; Error = '' }
        $null = Add-Dlss5TestRecord -Path $PackagePath -Record $skewed -Location $location
        $kept = Get-Dlss5StateRecords (Get-Dlss5PackageIdentityAt $PackagePath).State
        $locations = @($kept | ForEach-Object { $_.Location })
        Assert-Dlss5Equal $kept.Count 256 'The record limit was not kept.'
        Assert-Dlss5True (('ffffffffffffffff' -cin $locations) -and (('{0:x16}' -f 1) -cnotin $locations)) 'The new record was dropped, or the oldest other record was kept.'
    }
}

Invoke-Dlss5Case 'mission tests the headless run item refuses a stale expectation and runs on the current one' {
    $bytes = New-Dlss5TestedPackageBytes -Tests @((New-Dlss5TestDeclaration 'unit' -Role 'target'))
    Invoke-Dlss5PackageInteraction -Name 'tests-run-item' -Bytes $bytes -Action {
        param($PackagePath)
        $script:Dlss5Console = New-Dlss5SubstitutedConsole @()
        $identity = $script:Dlss5ExecutingIdentity
        $request = { param($MissionSha256, $Name) [pscustomobject]@{ Item = '--internal-run-test'; Expect = [pscustomobject]@{ Version = $identity.Version; EngineSha256 = $identity.EngineSha256; MissionSha256 = $MissionSha256 }; Folder = $Name } }
        $before = [IO.File]::ReadAllBytes($PackagePath)
        Assert-Dlss5Equal (Invoke-Dlss5PackageItem -Path $PackagePath -Request (& $request ('0' * 64) 'unit')) $script:Dlss5RefusedExitCode 'A stale expectation ran the test.'
        Assert-Dlss5True (Get-Dlss5ConsoleText).Contains('not the one this command expected') 'The stale expectation was not reported.'
        Assert-Dlss5Equal (Invoke-Dlss5PackageItem -Path $PackagePath -Request (& $request $identity.MissionSha256 'other')) $script:Dlss5RefusedExitCode 'An undeclared test ran headless.'
        Assert-Dlss5True (Test-Dlss5ByteEquality -Left ([IO.File]::ReadAllBytes($PackagePath)) -Right $before) 'A refused run item changed the package.'
        Assert-Dlss5Equal (Invoke-Dlss5PackageItem -Path $PackagePath -Request (& $request $identity.MissionSha256 'unit')) 0 "The run item did not run on the current expectation: $(Get-Dlss5ConsoleText)"
        Assert-Dlss5Equal (Get-Dlss5StateRecords (Get-Dlss5PackageIdentityAt $PackagePath).State).Count 1 'The run item did not record.'
    }
}

Invoke-Dlss5Case 'mission tests a test that cannot be stopped records nothing and stops the run' {
    $tests = @((New-Dlss5TestDeclaration 'stuck' -Role 'target'), (New-Dlss5TestDeclaration 'after' -Required $false -Role 'target'))
    $bytes = New-Dlss5TestedPackageBytes -Tests $tests -Scripts @{ 'stuck' = 'Start-Sleep -Seconds 6; exit 0' }
    Invoke-Dlss5PackageInteraction -Name 'tests-cannot-stop' -Bytes $bytes -Action {
        param($PackagePath)
        $script:Dlss5Console = New-Dlss5SubstitutedConsole @()
        $saved = @{ Timeout = $script:Dlss5TestTimeout; Stop = $script:Dlss5StopTestProcess }
        try {
            $script:Dlss5TestTimeout = [TimeSpan]::FromSeconds(2)
            $script:Dlss5StopTestProcess = { param($Process) throw [ComponentModel.Win32Exception]::new(5) }
            Assert-Dlss5Equal (Invoke-Dlss5TestRun -Path $PackagePath -Names @('stuck', 'after')) $script:Dlss5RefusedExitCode 'A test that could not be stopped was not refused.'
        }
        finally { $script:Dlss5TestTimeout = $saved.Timeout; $script:Dlss5StopTestProcess = $saved.Stop }
        $text = Get-Dlss5ConsoleText
        Assert-Dlss5True ($text.Contains('Not recorded: the test stuck ran longer than 2 seconds and could not be stopped') -and -not $text.Contains('and was stopped')) "The failed stop was not reported: $text"
        Assert-Dlss5True ($text.Contains('The remaining 1 test was not run.') -and -not $text.Contains('Running test after')) "The run went on after a test that could not be stopped: $text"
        Assert-Dlss5Equal (Get-Dlss5StateRecords (Get-Dlss5PackageIdentityAt $PackagePath).State).Count 0 'A test that could not be stopped was recorded.'
    }
}

Invoke-Dlss5Case 'mission tests a window opened before the package changed runs nothing' {
    # The test leaves a marker, so a run that started it would show.
    $marker = 'New-Item -ItemType File -Force -Path (Join-Path $env:DLSS5_TEST_PACKAGE_DIR "ran.txt") | Out-Null; exit 0'
    $bytes = New-Dlss5TestedPackageBytes -Tests @((New-Dlss5TestDeclaration 'unit' -Role 'target')) -Scripts @{ 'unit' = $marker }
    $changed = New-Dlss5PackageVariant -Bytes $bytes -Files ([ordered]@{ 'TEST.unit.ps1' = $script:PackageUtf8.GetBytes('exit 1' + $script:PackageNewline) })
    $update = [pscustomobject]@{ FromVersion = 54; FromMissionHash = $null; FromSha256 = ('a' * 64); ReplacedEdit = $false; BackupSha256 = $null }
    $pending = New-Dlss5PackageVariant -Bytes $bytes -State (New-Dlss5RecordStateLines -Records @() -Update $update)
    foreach ($later in @(@{ Name = 'mission'; Bytes = $changed; Text = 'the mission changed in another window' }, @{ Name = 'update'; Bytes = $pending; Text = 'acknowledge the what''s-changed box first' })) {
        Invoke-Dlss5PackageInteraction -Name ('tests-stale-window-' + $later.Name) -Bytes $bytes -Action {
            param($PackagePath, $Game)
            $script:Dlss5Console = New-Dlss5SubstitutedConsole @()
            [IO.File]::WriteAllBytes($PackagePath, $later.Bytes)
            Assert-Dlss5Equal (Invoke-Dlss5TestRun -Path $PackagePath -Names @('unit')) $script:Dlss5RefusedExitCode "A stale window ran its test after the $($later.Name) changed."
            Assert-Dlss5True ((Get-Dlss5ConsoleText).Contains($later.Text) -and (Get-Dlss5ConsoleText).Contains('Nothing was run.')) "The stale window did not say why: $(Get-Dlss5ConsoleText)"
            Assert-Dlss5True (-not (Test-Path -LiteralPath (Join-Path $Game 'ran.txt'))) "A stale window started its test after the $($later.Name) changed."
            Assert-Dlss5True (Test-Dlss5ByteEquality -Left ([IO.File]::ReadAllBytes($PackagePath)) -Right $later.Bytes) 'A refused stale run changed the package.'
        }
    }
}

Invoke-Dlss5Case 'mission tests a record that cannot be written stops the run' {
    # The test makes the package read-only, so the record write fails below the package write's own refusals.
    $tests = @((New-Dlss5TestDeclaration 'lock' -Role 'target'), (New-Dlss5TestDeclaration 'after' -Required $false -Role 'target'))
    $bytes = New-Dlss5TestedPackageBytes -Tests $tests -Scripts @{ 'lock' = '(Get-Item -LiteralPath $env:DLSS5_TEST_PACKAGE_PATH).IsReadOnly = $true; exit 0' }
    Invoke-Dlss5PackageInteraction -Name 'tests-record-unwritable' -Bytes $bytes -Action {
        param($PackagePath)
        $script:Dlss5Console = New-Dlss5SubstitutedConsole @()
        try { Assert-Dlss5Equal (Invoke-Dlss5TestRun -Path $PackagePath -Names @('lock', 'after')) $script:Dlss5RefusedExitCode "An unwritable record did not refuse the run: $(Get-Dlss5ConsoleText)" }
        finally { (Get-Item -LiteralPath $PackagePath).IsReadOnly = $false }
        $text = Get-Dlss5ConsoleText
        Assert-Dlss5True ($text.Contains('The test lock gave pass, but its record was refused') -and $text.Contains('The remaining 1 test was not run.') -and -not $text.Contains('Running test after')) "The unwritable record was not reported, or the run went on: $text"
        Assert-Dlss5Equal (Get-Dlss5StateRecords (Get-Dlss5PackageIdentityAt $PackagePath).State).Count 0 'An unwritable record was written.'
    }
}

Invoke-Dlss5Case 'mission tests a mission changed during the run refuses the record' {
    $bytes = New-Dlss5TestedPackageBytes -Tests @((New-Dlss5TestDeclaration 'swap' -Role 'target'), (New-Dlss5TestDeclaration 'after' -Required $false -Role 'target')) -Scripts @{ 'swap' = '[IO.File]::WriteAllBytes($env:DLSS5_TEST_PACKAGE_PATH, [IO.File]::ReadAllBytes($env:DLSS5_TEST_SWAP_SOURCE)); exit 0' }
    $changed = New-Dlss5PackageVariant -Bytes $bytes -Files ([ordered]@{ 'MISSION.md' = $script:PackageUtf8.GetBytes(('@@template', 'Changed {{package_dir}}.', '{{part:task_instructions}}', '{{part:startup_instructions}}{{part:request}}', '@@mode default', '@@part task_instructions', 'Greet.', '@@part startup_instructions', 'Start.', '@@mode task', '@@part task_instructions', 'Do the task.', '@@part startup_instructions', 'Start.', '@@part request', '', 'USER REQUEST', '{{task_text}}', '') -join $script:PackageNewline) })
    Invoke-Dlss5PackageInteraction -Name 'tests-mission-changed' -Bytes $bytes -Action {
        param($PackagePath, $Game)
        $source = Join-Path (Split-Path -Parent $Game) 'changed.cmd'
        [IO.File]::WriteAllBytes($source, $changed)
        $script:Dlss5Console = New-Dlss5SubstitutedConsole @()
        $prior = $env:DLSS5_TEST_SWAP_SOURCE
        try {
            $env:DLSS5_TEST_SWAP_SOURCE = $source
            Assert-Dlss5Equal (Invoke-Dlss5TestRun -Path $PackagePath -Names @('swap')) $script:Dlss5RefusedExitCode 'A record for a replaced mission was not refused.'
        }
        finally { $env:DLSS5_TEST_SWAP_SOURCE = $prior }
        Assert-Dlss5True (Get-Dlss5ConsoleText).Contains('its record was refused') "The refusal was not reported: $(Get-Dlss5ConsoleText)"
        Assert-Dlss5Equal (Get-Dlss5StateRecords (Get-Dlss5PackageIdentityAt $PackagePath).State).Count 0 'The record reached the changed mission.'
        # Once a record is refused, the rest of the run is not run, since it could not be recorded either.
        [IO.File]::WriteAllBytes($PackagePath, $bytes)
        $script:Dlss5ExecutingIdentity = Get-Dlss5PackageIdentityAt $PackagePath
        $script:Dlss5Console = New-Dlss5SubstitutedConsole @()
        try {
            $env:DLSS5_TEST_SWAP_SOURCE = $source
            Assert-Dlss5Equal (Invoke-Dlss5TestRun -Path $PackagePath -Names @('swap', 'after')) $script:Dlss5RefusedExitCode "A run with a refused record did not report the refusal: $(Get-Dlss5ConsoleText)"
        }
        finally { $env:DLSS5_TEST_SWAP_SOURCE = $prior }
        Assert-Dlss5True ((Get-Dlss5ConsoleText).Contains('The remaining 1 test was not run.') -and -not (Get-Dlss5ConsoleText).Contains('Running test after')) "The run went on after a refused record: $(Get-Dlss5ConsoleText)"
    }
}

Invoke-Dlss5Case 'mission tests the Arm gate consults the newest matching record for each declaration' {
    $identity = Get-Dlss5BootstrapIdentity -Bytes (New-Dlss5TestedPackageBytes -Tests @((New-Dlss5TestDeclaration 'unit'), (New-Dlss5TestDeclaration 'live' -Role 'target'), (New-Dlss5TestDeclaration 'here' -Role 'target' -HereOnly $true), (New-Dlss5TestDeclaration 'extra' -Required $false))) -Strict
    $mission = $identity.MissionSha256
    $here = [pscustomobject]@{ Machine = '00000000-0000-0000-0000-000000000001'; Location = 'aaaaaaaaaaaaaaaa'; Path = 'C:\Here'; Error = '' }
    $gate = { param($Records) $state = [pscustomobject]@{ Empty = $false; Armed = $false; MissionEdited = $false; ReplacedMissionHash = $null; Update = $null; Records = [object[]]$Records }; Get-Dlss5ArmGate -Identity $identity -Location $here -State $state }
    $passes = @((New-Dlss5TestRecordFixture -Name 'unit' -Mission $mission), (New-Dlss5TestRecordFixture -Name 'live' -Role 'target' -Mission $mission -Location 'bbbbbbbbbbbbbbbb'), (New-Dlss5TestRecordFixture -Name 'here' -Role 'target' -Mission $mission -Location 'aaaaaaaaaaaaaaaa'))
    Assert-Dlss5Equal (& $gate $passes).Kind 'satisfied' 'Matching passes did not satisfy the gate.'
    Assert-Dlss5Equal (& $gate @()).Kind 'not-satisfied' 'No records satisfied the gate.'
    $statuses = { param($Result) [string]::Join(',', @($Result.Tests | ForEach-Object { $_.Test.Name + '=' + $_.Status })) }
    Assert-Dlss5Equal (& $statuses (& $gate @())) 'unit=no-record,live=no-record,here=no-record' 'The optional test was consulted, or a status is wrong.'
    # A dev pass does not count for a target test, a target-only pass from another location does not count, and a stale record is reported.
    $wrong = @((New-Dlss5TestRecordFixture -Name 'unit' -Mission ('f' * 64)), (New-Dlss5TestRecordFixture -Name 'live' -Mission $mission), (New-Dlss5TestRecordFixture -Name 'here' -Role 'target' -Mission $mission -Location 'bbbbbbbbbbbbbbbb'))
    Assert-Dlss5Equal (& $statuses (& $gate $wrong)) 'unit=stale,live=no-record,here=no-record' 'Non-matching records were consulted.'
    # A fail newer than a pass from another location decides a test that is not target-only.
    $newer = $passes + @(New-Dlss5TestRecordFixture -Name 'unit' -Verdict 'fail' -Mission $mission -Time '20261107T110000Z' -Location 'cccccccccccccccc')
    Assert-Dlss5Equal (& $statuses (& $gate $newer)) 'unit=fail,live=pass,here=pass' 'The newest record did not decide.'
    # The newest record decides even when it comes first in line order.
    $earlier = @((New-Dlss5TestRecordFixture -Name 'unit' -Verdict 'fail' -Mission $mission -Time '20261107T110000Z' -Location '0000000000000000'), (New-Dlss5TestRecordFixture -Name 'unit' -Mission $mission -Location 'ffffffffffffffff')) + @($passes[1], $passes[2])
    Assert-Dlss5Equal (& $statuses (& $gate $earlier)) 'unit=fail,live=pass,here=pass' 'The last line decided instead of the newest record.'
    $unknown = [pscustomobject]@{ Machine = ''; Location = ''; Path = ''; Error = 'cannot identify' }
    $state = [pscustomobject]@{ Empty = $false; Armed = $false; MissionEdited = $false; ReplacedMissionHash = $null; Update = $null; Records = [object[]]$passes }
    Assert-Dlss5Equal (& $statuses (Get-Dlss5ArmGate -Identity $identity -Location $unknown -State $state)) 'unit=pass,live=pass,here=location-unknown' 'An unknown location satisfied a target-only test.'
    $none = Get-Dlss5BootstrapIdentity -Bytes (New-Dlss5TestedPackageBytes -Tests @((New-Dlss5TestDeclaration 'extra' -Required $false))) -Strict
    Assert-Dlss5Equal (Get-Dlss5ArmGate -Identity $none -Location $here).Kind 'none-required' 'Optional tests alone made the gate require tests.'
}

Invoke-Dlss5Case 'mission tests Arm, the internal arm, the box and Execute honor the Arm gate' {
    $bytes = New-Dlss5TestedPackageBytes -Tests @((New-Dlss5TestDeclaration 'unit' -Role 'target')) -Scripts @{ 'unit' = 'exit 0' }
    Invoke-Dlss5PackageInteraction -Name 'tests-gate-arm' -Bytes $bytes -Action {
        param($PackagePath)
        $script:Dlss5Console = New-Dlss5SubstitutedConsole @()
        Assert-Dlss5Throws { $null = Set-Dlss5GatedArm -Path $PackagePath } ([InvalidOperationException]) 'The package armed without its required test.'
        Assert-Dlss5True ($null -eq (Get-Command Set-Dlss5ArmState -ErrorAction SilentlyContinue)) 'A writer that can arm past the Arm gate remains.'
        Assert-Dlss5True (-not (Get-Dlss5PackageIdentityAt $PackagePath).State.Armed) 'A refused arm armed the package.'
        # Execute refuses an armed package whose gate does not hold at this location, before any session work.
        $armed = Set-Dlss5PackageSections -Bytes ([IO.File]::ReadAllBytes($PackagePath)) -Bodies ([ordered]@{ STATE = (New-Dlss5RecordStateLines -Records @() -Armed $true) })
        [IO.File]::WriteAllBytes($PackagePath, $armed)
        $script:Dlss5ExecutingIdentity = Get-Dlss5PackageIdentityAt $PackagePath
        $savedMission = Get-Variable -Name Dlss5StartupMissionId -Scope Script -ValueOnly -ErrorAction SilentlyContinue
        try {
            $script:Dlss5StartupMissionId = 'hello-world'
            Assert-Dlss5Equal (Invoke-Dlss5Execute -Path $PackagePath) $script:Dlss5RefusedExitCode 'Execute ran without its required test.'
        }
        finally { $script:Dlss5StartupMissionId = $savedMission }
        Assert-Dlss5True (Get-Dlss5ConsoleText).Contains('the Arm gate is not satisfied at this location') "Execute did not say why it refused: $(Get-Dlss5ConsoleText)"
        Assert-Dlss5True (Get-Dlss5PackageIdentityAt $PackagePath).State.Armed 'A refused Execute disarmed the package.'
        $null = Set-Dlss5Disarmed -Path $PackagePath
        Assert-Dlss5Equal (Invoke-Dlss5TestRun -Path $PackagePath -Names @('unit')) 0 "The required test did not pass: $(Get-Dlss5ConsoleText)"
        $null = Set-Dlss5GatedArm -Path $PackagePath
        Assert-Dlss5True (Get-Dlss5PackageIdentityAt $PackagePath).State.Armed 'A satisfied gate did not arm the package.'
        # Arm and disarm keep the records.
        $null = Set-Dlss5Disarmed -Path $PackagePath
        Assert-Dlss5Equal (Get-Dlss5StateRecords (Get-Dlss5PackageIdentityAt $PackagePath).State).Count 1 'Arming or disarming dropped the record.'
    }
    $update = [pscustomobject]@{ FromVersion = 54; FromMissionHash = $null; FromSha256 = ('a' * 64); ReplacedEdit = $false; BackupSha256 = $null }
    $pending = New-Dlss5TestedPackageBytes -Tests @((New-Dlss5TestDeclaration 'unit' -Role 'target')) -State (New-Dlss5RecordStateLines -Records @() -Update $update)
    Invoke-Dlss5PackageInteraction -Name 'tests-gate-box' -Bytes $pending -Action {
        param($PackagePath)
        $script:Dlss5Console = New-Dlss5SubstitutedConsole @()
        Assert-Dlss5Throws { Invoke-Dlss5BoxChoice -Path $PackagePath -Accept $true } ([InvalidOperationException]) 'The box re-armed without the required test.'
        Assert-Dlss5True ($null -ne (Get-Dlss5PackageIdentityAt $PackagePath).State.Update) 'A refused re-arm acknowledged the update.'
        Invoke-Dlss5BoxChoice -Path $PackagePath -Accept $false
        $identity = Get-Dlss5PackageIdentityAt $PackagePath
        Assert-Dlss5True ($null -eq $identity.State.Update -and -not $identity.State.Armed) 'Keep disarmed did not acknowledge the update.'
    }
    # The box offers re-arming only when the gate holds, and says why otherwise.
    Invoke-Dlss5PackageInteraction -Name 'tests-gate-box-menu' -Bytes $pending -Action {
        param($PackagePath)
        $script:Dlss5Console = New-Dlss5SubstitutedConsole @('Escape')
        $null = Invoke-Dlss5Menu -Path $PackagePath
        $text = Get-Dlss5ConsoleText
        Assert-Dlss5True ($text.Contains('Re-arming is not offered: the Arm gate is not satisfied') -and -not $text.Contains('[a] Accept and re-arm')) "The box offered re-arming without the required test: $text"
    }
    # On a satisfied gate the box offers re-arming, and Keep disarmed keeps the records.
    $pendingMission = (Get-Dlss5BootstrapIdentity -Bytes $pending -Strict).MissionSha256
    $satisfied = New-Dlss5PackageVariant -Bytes $pending -State (New-Dlss5RecordStateLines -Records @((New-Dlss5TestRecordFixture -Name 'unit' -Role 'target' -Mission $pendingMission)) -Update $update)
    Invoke-Dlss5PackageInteraction -Name 'tests-gate-box-satisfied' -Bytes $satisfied -Action {
        param($PackagePath)
        $script:Dlss5Console = New-Dlss5SubstitutedConsole @('k', 'Enter', 'Escape')
        $null = Invoke-Dlss5Menu -Path $PackagePath
        $text = Get-Dlss5ConsoleText
        Assert-Dlss5True ($text.Contains('Accept and re-arm: the Arm gate is satisfied.') -and $text.Contains('[a] Accept and re-arm')) "The box did not offer re-arming on a satisfied gate: $text"
        $identity = Get-Dlss5PackageIdentityAt $PackagePath
        Assert-Dlss5True ($null -eq $identity.State.Update -and -not $identity.State.Armed) "Keep disarmed did not acknowledge the update, or armed: $text"
        Assert-Dlss5Equal (Get-Dlss5StateRecords $identity.State).Count 1 'Keep disarmed dropped the records.'
    }
}

Invoke-Dlss5Case 'mission tests a failing consulted required record disarms, and other records do not' {
    $tests = @((New-Dlss5TestDeclaration 'unit' -Role 'target'), (New-Dlss5TestDeclaration 'extra' -Required $false -Role 'target'))
    $bytes = New-Dlss5TestedPackageBytes -Tests $tests -Scripts @{ 'unit' = 'if ($env:DLSS5_TEST_FAIL -ceq "1") { exit 1 }; exit 0'; 'extra' = 'exit 1' }
    Invoke-Dlss5PackageInteraction -Name 'tests-disarm' -Bytes $bytes -Action {
        param($PackagePath)
        $script:Dlss5Console = New-Dlss5SubstitutedConsole @()
        $null = Invoke-Dlss5TestRun -Path $PackagePath -Names @('unit')
        $null = Set-Dlss5GatedArm -Path $PackagePath
        Assert-Dlss5Equal (Invoke-Dlss5TestRun -Path $PackagePath -Names @('extra')) 1 'The optional test did not fail.'
        Assert-Dlss5True (Get-Dlss5PackageIdentityAt $PackagePath).State.Armed 'A failing optional test disarmed the package.'
        # A newer pass from another location stays the consulted record, so a required fail here does not disarm.
        $current = Get-Dlss5PackageIdentityAt $PackagePath
        $newer = (Get-Dlss5StateRecords $current.State) + @(New-Dlss5TestRecordFixture -Name 'unit' -Role 'target' -Mission $current.MissionSha256 -Time '20991231T000000Z' -Location 'ffffffffffffffff')
        [IO.File]::WriteAllBytes($PackagePath, (Set-Dlss5PackageSections -Bytes ([IO.File]::ReadAllBytes($PackagePath)) -Bodies ([ordered]@{ STATE = (New-Dlss5RecordStateLines -Records $newer -Armed $true) })))
        $prior = $env:DLSS5_TEST_FAIL
        try {
            $env:DLSS5_TEST_FAIL = '1'
            Assert-Dlss5Equal (Invoke-Dlss5TestRun -Path $PackagePath -Names @('unit')) 1 'The required test did not fail.'
        }
        finally { $env:DLSS5_TEST_FAIL = $prior }
        Assert-Dlss5True (Get-Dlss5PackageIdentityAt $PackagePath).State.Armed 'A required fail the gate does not consult disarmed the package.'
        [IO.File]::WriteAllBytes($PackagePath, (Set-Dlss5PackageSections -Bytes ([IO.File]::ReadAllBytes($PackagePath)) -Bodies ([ordered]@{ STATE = (New-Dlss5RecordStateLines -Records (Get-Dlss5StateRecords $current.State) -Armed $true) })))
        $prior = $env:DLSS5_TEST_FAIL
        try {
            $env:DLSS5_TEST_FAIL = '1'
            Assert-Dlss5Equal (Invoke-Dlss5TestRun -Path $PackagePath -Names @('unit')) 1 'The required test did not fail.'
        }
        finally { $env:DLSS5_TEST_FAIL = $prior }
        Assert-Dlss5True (-not (Get-Dlss5PackageIdentityAt $PackagePath).State.Armed) 'A failing required test did not disarm the package.'
        Assert-Dlss5True (Get-Dlss5ConsoleText).Contains('the package is disarmed') 'The disarm was not reported.'
    }
}

Invoke-Dlss5Case 'mission tests the disarm decision reads the records in their written order when times tie' {
    $bytes = New-Dlss5TestedPackageBytes -Tests @((New-Dlss5TestDeclaration 'unit' -Role 'target'))
    $mission = (Get-Dlss5BootstrapIdentity -Bytes $bytes -Strict).MissionSha256
    $low = @{ Machine = '00000000-0000-0000-0000-000000000001'; Location = '0000000000000001' }
    $high = @{ Machine = 'ffffffff-ffff-ffff-ffff-ffffffffffff'; Location = 'ffffffffffffffff' }
    # Within one time the later line is consulted, so a fail that sorts before the pass leaves the package armed, and one that sorts after it disarms.
    foreach ($order in @(@{ Name = 'fail-first'; Pass = $high; Fail = $low; Disarms = $false }, @{ Name = 'fail-last'; Pass = $low; Fail = $high; Disarms = $true })) {
        $pass = New-Dlss5TestRecordFixture -Name 'unit' -Role 'target' -Mission $mission -Machine $order.Pass.Machine -Location $order.Pass.Location
        $state = New-Dlss5RecordStateLines -Records @($pass) -Armed $true
        Invoke-Dlss5PackageInteraction -Name ('tests-tie-' + $order.Name) -Bytes (New-Dlss5PackageVariant -Bytes $bytes -State $state) -Action {
            param($PackagePath)
            $script:Dlss5Console = New-Dlss5SubstitutedConsole @()
            $fail = New-Dlss5TestRecordFixture -Name 'unit' -Verdict 'fail' -Role 'target' -Mission $mission -Machine $order.Fail.Machine -Location $order.Fail.Location
            $location = [pscustomobject]@{ Machine = $order.Fail.Machine; Location = $order.Fail.Location; Path = 'C:\Here'; Error = '' }
            Assert-Dlss5Equal (Add-Dlss5TestRecord -Path $PackagePath -Record $fail -Location $location) $order.Disarms "The disarm decision is wrong for $($order.Name)."
            Assert-Dlss5Equal (Get-Dlss5PackageIdentityAt $PackagePath).State.Armed (-not $order.Disarms) "The written arm state is wrong for $($order.Name)."
        }
    }
}

Invoke-Dlss5Case 'mission tests menu Arm, the internal arm and the internal accept honor required tests' {
    $bytes = New-Dlss5TestedPackageBytes -Tests @((New-Dlss5TestDeclaration 'unit' -Role 'target')) -State (New-Dlss5RecordStateLines -Records @())
    Invoke-Dlss5PackageInteraction -Name 'tests-gate-items' -Bytes $bytes -Action {
        param($PackagePath)
        $request = { param($Item) $current = $script:Dlss5ExecutingIdentity; [pscustomobject]@{ Item = $Item; Expect = [pscustomobject]@{ Version = $current.Version; EngineSha256 = $current.EngineSha256; MissionSha256 = $current.MissionSha256 }; Folder = $null } }
        $script:Dlss5Console = New-Dlss5SubstitutedConsole @()
        Assert-Dlss5Equal (Invoke-Dlss5PackageItem -Path $PackagePath -Request (& $request '--internal-arm')) $script:Dlss5RefusedExitCode 'The internal arm armed without the required test.'
        # With required tests, menu Arm asks nothing: it shows the gate when it does not hold, and arms when it does.
        $script:Dlss5Console = New-Dlss5SubstitutedConsole @('a', 'Enter', 'Escape')
        $null = Invoke-Dlss5Menu -Path $PackagePath
        $text = Get-Dlss5ConsoleText
        Assert-Dlss5True ($text.Contains('Arm gate: not satisfied') -and -not $text.Contains('Arm it?') -and -not (Get-Dlss5PackageIdentityAt $PackagePath).State.Armed) "Menu Arm did not refuse with the gate status: $text"
        $script:Dlss5Console = New-Dlss5SubstitutedConsole @()
        $null = Invoke-Dlss5TestRun -Path $PackagePath -Names @('unit')
        $script:Dlss5Console = New-Dlss5SubstitutedConsole @('a', 'Enter', 'Escape')
        $null = Invoke-Dlss5Menu -Path $PackagePath
        Assert-Dlss5True ((-not (Get-Dlss5ConsoleText).Contains('Arm it?')) -and (Get-Dlss5PackageIdentityAt $PackagePath).State.Armed) "Menu Arm did not arm on a satisfied gate without asking: $(Get-Dlss5ConsoleText)"
        $null = Set-Dlss5Disarmed -Path $PackagePath
        $script:Dlss5Console = New-Dlss5SubstitutedConsole @()
        Assert-Dlss5Equal (Invoke-Dlss5PackageItem -Path $PackagePath -Request (& $request '--internal-arm')) 0 "The internal arm refused a satisfied gate: $(Get-Dlss5ConsoleText)"
        Assert-Dlss5True (Get-Dlss5PackageIdentityAt $PackagePath).State.Armed 'The internal arm did not arm on a satisfied gate.'
    }
    $mission = (Get-Dlss5BootstrapIdentity -Bytes $bytes -Strict).MissionSha256
    $update = [pscustomobject]@{ FromVersion = 54; FromMissionHash = $null; FromSha256 = ('a' * 64); ReplacedEdit = $false; BackupSha256 = $null }
    $pass = New-Dlss5TestRecordFixture -Name 'unit' -Role 'target' -Mission $mission
    foreach ($variant in @(@{ Name = 'unsatisfied'; Records = @(); Code = $script:Dlss5RefusedExitCode }, @{ Name = 'satisfied'; Records = @($pass); Code = 0 })) {
        $pending = New-Dlss5PackageVariant -Bytes $bytes -State (New-Dlss5RecordStateLines -Records $variant.Records -Update $update)
        Invoke-Dlss5PackageInteraction -Name ('tests-gate-accept-' + $variant.Name) -Bytes $pending -Action {
            param($PackagePath)
            $script:Dlss5Console = New-Dlss5SubstitutedConsole @()
            $current = $script:Dlss5ExecutingIdentity
            $accept = [pscustomobject]@{ Item = '--internal-accept'; Expect = [pscustomobject]@{ Version = $current.Version; EngineSha256 = $current.EngineSha256; MissionSha256 = $current.MissionSha256 }; Folder = $null }
            Assert-Dlss5Equal (Invoke-Dlss5PackageItem -Path $PackagePath -Request $accept) $variant.Code "The internal accept returned the wrong code for the $($variant.Name) gate: $(Get-Dlss5ConsoleText)"
            $after = Get-Dlss5PackageIdentityAt $PackagePath
            Assert-Dlss5Equal $after.State.Armed ($variant.Code -eq 0) "The internal accept left the wrong arm state for the $($variant.Name) gate."
            Assert-Dlss5Equal ($null -eq $after.State.Update) ($variant.Code -eq 0) "The internal accept left the wrong update record for the $($variant.Name) gate."
            Assert-Dlss5Equal (Get-Dlss5StateRecords $after.State).Count $variant.Records.Count "The internal accept changed the records for the $($variant.Name) gate."
        }
    }
}

Invoke-Dlss5Case 'mission tests every mission content write removes the records, and absorb refuses an undeclared test file' {
    $bytes = New-Dlss5TestedPackageBytes -Tests @((New-Dlss5TestDeclaration 'unit' -Role 'target'))
    Invoke-Dlss5PackageInteraction -Name 'tests-mission-writes' -Bytes $bytes -Action {
        param($PackagePath, $Game)
        $script:Dlss5Console = New-Dlss5SubstitutedConsole @()
        $null = Invoke-Dlss5TestRun -Path $PackagePath -Names @('unit')
        $script:Dlss5ExecutingIdentity = Get-Dlss5PackageIdentityAt $PackagePath
        Set-Dlss5ProjectConfig -Path $PackagePath -Change { param($Project) $Project.ApprovalMode = 'manual' }
        $identity = Get-Dlss5PackageIdentityAt $PackagePath
        Assert-Dlss5True ($identity.Project.ApprovalMode -ceq 'manual' -and $identity.Project.Tests.Count -eq 1) 'Configure dropped the declarations.'
        Assert-Dlss5Equal (Get-Dlss5StateRecords $identity.State).Count 0 'A project edit kept the records.'
        $null = Invoke-Dlss5TestRun -Path $PackagePath -Names @('unit')
        $script:Dlss5ExecutingIdentity = Get-Dlss5PackageIdentityAt $PackagePath
        $folder = Join-Path $Game 'edited'
        New-Item -ItemType Directory -Force $folder | Out-Null
        $stray = Join-Path $folder 'TEST.stray.ps1'
        [IO.File]::WriteAllText($stray, 'exit 0')
        $before = [IO.File]::ReadAllBytes($PackagePath)
        Assert-Dlss5Equal (Invoke-Dlss5Absorb -Path $PackagePath -Files @($stray) -Headless) $script:Dlss5RefusedExitCode 'Absorb took an undeclared test file.'
        Assert-Dlss5True (Get-Dlss5ConsoleText).Contains('Drop each test file together with the PROJECT.json that declares it') 'Absorb did not say how to add a test.'
        Assert-Dlss5True (Test-Dlss5ByteEquality -Left ([IO.File]::ReadAllBytes($PackagePath)) -Right $before) 'A refused absorb changed the package.'
        $project = Join-Path $folder 'PROJECT.json'
        [IO.File]::WriteAllText($project, '{"mission_id":"hello-world","rerun":false,"tests":[{"name":"unit","required":true,"role":"target","here_only":false},{"name":"stray","required":false,"role":"target","here_only":false}]}')
        Assert-Dlss5Equal (Invoke-Dlss5Absorb -Path $PackagePath -Files @($stray, $project) -Headless) 0 "Absorb refused a test file dropped with its declaration: $(Get-Dlss5ConsoleText)"
        $identity = Get-Dlss5PackageIdentityAt $PackagePath
        Assert-Dlss5True ($identity.MissionFiles.Contains('TEST.stray.ps1') -and (Get-Dlss5StateRecords $identity.State).Count -eq 0) 'Absorb did not add the test or kept the records.'
        $script:Dlss5ExecutingIdentity = $identity
        $ghost = Join-Path $folder 'ghost'
        New-Item -ItemType Directory -Force $ghost | Out-Null
        $declaresGhost = Join-Path $ghost 'PROJECT.json'
        [IO.File]::WriteAllText($declaresGhost, '{"mission_id":"hello-world","rerun":false,"tests":[{"name":"unit","required":true,"role":"target","here_only":false},{"name":"stray","required":false,"role":"target","here_only":false},{"name":"ghost","required":false,"role":"target","here_only":false}]}')
        $before = [IO.File]::ReadAllBytes($PackagePath)
        Assert-Dlss5Equal (Invoke-Dlss5Absorb -Path $PackagePath -Files @($declaresGhost) -Headless) $script:Dlss5RefusedExitCode 'Absorb took a declaration without its test file.'
        Assert-Dlss5True (Test-Dlss5ByteEquality -Left ([IO.File]::ReadAllBytes($PackagePath)) -Right $before) 'A refused absorb changed the package.'
    }
    # Removing a seed is a mission content write too.
    $seed = $script:PackageUtf8.GetBytes('{"schema_version":1,"host":"claude"}' + $script:PackageNewline)
    $seeded = New-Dlss5PackageVariant -Bytes $bytes -Files ([ordered]@{ 'SEED.json' = $seed })
    Invoke-Dlss5PackageInteraction -Name 'tests-seed-write' -Bytes $seeded -Action {
        param($PackagePath)
        $script:Dlss5Console = New-Dlss5SubstitutedConsole @()
        $null = Invoke-Dlss5TestRun -Path $PackagePath -Names @('unit')
        Assert-Dlss5Equal (Get-Dlss5StateRecords (Get-Dlss5PackageIdentityAt $PackagePath).State).Count 1 'The seeded package did not record its test.'
        $script:Dlss5ExecutingIdentity = Get-Dlss5PackageIdentityAt $PackagePath
        Set-Dlss5Seed -Path $PackagePath -Remove
        $identity = Get-Dlss5PackageIdentityAt $PackagePath
        Assert-Dlss5True ((-not $identity.MissionFiles.Contains('SEED.json')) -and (Get-Dlss5StateRecords $identity.State).Count -eq 0) 'Removing the seed kept the records.'
    }
    # Baking a seed is one as well.
    Invoke-Dlss5PackageInteraction -Name 'tests-seed-bake' -Bytes $bytes -Action {
        param($PackagePath)
        $script:Dlss5Console = New-Dlss5SubstitutedConsole @()
        $null = Invoke-Dlss5TestRun -Path $PackagePath -Names @('unit')
        Assert-Dlss5Equal (Get-Dlss5StateRecords (Get-Dlss5PackageIdentityAt $PackagePath).State).Count 1 'The package did not record its test before the seed.'
        $script:Dlss5ExecutingIdentity = Get-Dlss5PackageIdentityAt $PackagePath
        $null = Set-Dlss5MachineField -Field 'host' -Value 'claude'
        Set-Dlss5Seed -Path $PackagePath -Fields @('host')
        $identity = Get-Dlss5PackageIdentityAt $PackagePath
        Assert-Dlss5True ($identity.MissionFiles.Contains('SEED.json') -and (Get-Dlss5StateRecords $identity.State).Count -eq 0) 'Baking a seed did not bake it, or kept the records.'
    }
}

Invoke-Dlss5Case 'mission tests a whole-file update carries the records into the new file' {
    $mission = (Get-Dlss5BootstrapIdentity -Bytes $script:CandidateBytes).MissionSha256
    $records = @((New-Dlss5TestRecordFixture -Name 'unit' -Mission $mission))
    $local = Get-Dlss5BootstrapIdentity -Bytes (New-Dlss5PackageVariant -Bytes $script:CandidateBytes -State (New-Dlss5RecordStateLines -Records $records -Armed $true)) -Strict
    $trust = (New-Dlss5TrustFixture -Whole @{ $script:CandidateVersion = $script:CandidateIdentity.Sha256 }).Trust
    $updated = Get-Dlss5BootstrapIdentity -Bytes (New-Dlss5UpdatedCopyBytes -Local $local -Chosen $script:CandidateIdentity -Trust $trust) -Strict
    Assert-Dlss5True (-not $updated.State.Armed -and $null -ne $updated.State.Update) 'The update did not arrive disarmed with its record.'
    Assert-Dlss5Equal (Get-Dlss5StateRecords $updated.State).Count 1 'The update dropped the test records.'
    Assert-Dlss5Equal (Get-Dlss5StateRecords $updated.State)[0].Mission $mission 'The carried record changed.'
}

Invoke-Dlss5Case 'mission tests the header shows the gate and the identifying-data notice' {
    $seed = $script:PackageUtf8.GetBytes('{"schema_version":1,"host":"claude"}' + $script:PackageNewline)
    $declared = @((New-Dlss5TestDeclaration 'unit' -Role 'target'))
    # The record is for this mission, so the gate it shows is satisfied.
    $declaredMission = (Get-Dlss5BootstrapIdentity -Bytes (New-Dlss5TestedPackageBytes -Tests $declared) -Strict).MissionSha256
    $recorded = New-Dlss5RecordStateLines -Records @((New-Dlss5TestRecordFixture -Name 'unit' -Role 'target' -Mission $declaredMission -Label 'BOX|C:\Games\Here'))
    $withRecords = New-Dlss5TestedPackageBytes -Tests $declared -State $recorded
    $variants = [ordered]@{
        'neither' = (New-Dlss5PlainPackageBytes)
        'seed' = (New-Dlss5PackageVariant -Bytes (New-Dlss5PlainPackageBytes) -Files ([ordered]@{ 'SEED.json' = $seed }))
        'records' = $withRecords
        'both' = (New-Dlss5PackageVariant -Bytes $withRecords -Files ([ordered]@{ 'SEED.json' = $seed }))
    }
    # The loop variable must not be called name: Invoke-Dlss5PackageInteraction's Name parameter would shadow it inside the action.
    foreach ($variant in $variants.Keys) {
        Invoke-Dlss5PackageInteraction -Name ('tests-header-' + $variant) -Bytes $variants[$variant] -Action {
            param($PackagePath)
            $script:Dlss5Console = New-Dlss5SubstitutedConsole @()
            Write-Dlss5Header -Identity $script:Dlss5ExecutingIdentity -Path $PackagePath
            $text = Get-Dlss5ConsoleText
            $seedShown = $text.Contains('a seed of machine settings')
            $recordsShown = $text.Contains('test records (computer name, machine id and folder)')
            Assert-Dlss5Equal $seedShown ($variant -cin @('seed', 'both')) "The seed notice is wrong for $variant."
            Assert-Dlss5Equal $recordsShown ($variant -cin @('records', 'both')) "The records notice is wrong for $variant."
            Assert-Dlss5Equal $text.Contains('identifying data') ($variant -cne 'neither') "The identifying-data notice is wrong for $variant."
            Assert-Dlss5Equal $text.Contains('Arm gate') ($variant -cin @('records', 'both')) "The gate status is wrong for $variant."
            if ($variant -ceq 'records') { Assert-Dlss5True ($text.Contains('Arm gate: satisfied') -and $text.Contains('Required test unit (target): pass, run ') -and $text.Contains('on BOX in C:\Games\Here')) "The gate lines do not show the passing record: $text" }
        }
    }
}

Invoke-Dlss5Case 'mission tests the header shows the stale record, no record and location unknown lines' {
    $declared = @((New-Dlss5TestDeclaration 'unit' -Role 'target'), (New-Dlss5TestDeclaration 'here' -Role 'target' -HereOnly $true))
    $stale = New-Dlss5RecordStateLines -Records @((New-Dlss5TestRecordFixture -Name 'unit' -Role 'target' -Mission ('f' * 64)))
    Invoke-Dlss5PackageInteraction -Name 'tests-header-statuses' -Bytes (New-Dlss5TestedPackageBytes -Tests $declared -State $stale) -Action {
        param($PackagePath)
        $script:Dlss5Console = New-Dlss5SubstitutedConsole @()
        Write-Dlss5Header -Identity $script:Dlss5ExecutingIdentity -Path $PackagePath
        $text = Get-Dlss5ConsoleText
        Assert-Dlss5True ($text.Contains('Arm gate: not satisfied') -and $text.Contains('Required test unit (target): stale record, for another mission, run ') -and $text.Contains('Required test here (target, here only): no record')) "The stale record and no record lines are wrong: $text"
        $saved = $script:Dlss5ReadMachineGuid
        try {
            $script:Dlss5ReadMachineGuid = { $null }
            $script:Dlss5Console = New-Dlss5SubstitutedConsole @()
            Write-Dlss5Header -Identity $script:Dlss5ExecutingIdentity -Path $PackagePath
        }
        finally { $script:Dlss5ReadMachineGuid = $saved }
        $text = Get-Dlss5ConsoleText
        Assert-Dlss5True $text.Contains('Required test here (target, here only): location unknown: this machine''s id (MachineGuid) is missing or is not a GUID.') "The location unknown line is wrong: $text"
    }
}

Invoke-Dlss5Case 'mission tests the Run tests menu runs the runnable tests and says which are hidden' {
    $tests = @((New-Dlss5TestDeclaration 'unit' -Role 'dev'), (New-Dlss5TestDeclaration 'live' -Required $false -Role 'target'))
    # A state that is not empty, so no new-package box comes first.
    $bytes = New-Dlss5TestedPackageBytes -Tests $tests -Target -State (New-Dlss5RecordStateLines -Records @())
    Invoke-Dlss5PackageInteraction -Name 'tests-menu' -Bytes $bytes -Action {
        param($PackagePath)
        # Run tests, then All of these, then leave the menu.
        $script:Dlss5Console = New-Dlss5SubstitutedConsole @('t', 'Enter', 'Enter', 'Escape')
        $null = Invoke-Dlss5Menu -Path $PackagePath
        $text = Get-Dlss5ConsoleText
        Assert-Dlss5True $text.Contains('1 declared test runs only at a target location, so it is not offered at this dev location.') "The hidden test was not explained: $text"
        $records = Get-Dlss5StateRecords (Get-Dlss5PackageIdentityAt $PackagePath).State
        Assert-Dlss5True ($records.Count -eq 1 -and $records[0].Name -ceq 'unit' -and $records[0].Role -ceq 'dev') 'The menu did not run exactly the dev test.'
    }
    # A test whose name is a lone hyphen can be chosen on its own.
    $hyphen = New-Dlss5TestedPackageBytes -Tests @((New-Dlss5TestDeclaration '-' -Required $false -Role 'dev')) -Target -State (New-Dlss5RecordStateLines -Records @())
    Invoke-Dlss5PackageInteraction -Name 'tests-menu-hyphen' -Bytes $hyphen -Action {
        param($PackagePath)
        # Run tests, then the first test, then leave the menu.
        $script:Dlss5Console = New-Dlss5SubstitutedConsole @('t', 'Enter', '1', 'Enter', 'Escape')
        $null = Invoke-Dlss5Menu -Path $PackagePath
        $records = Get-Dlss5StateRecords (Get-Dlss5PackageIdentityAt $PackagePath).State
        Assert-Dlss5True ($records.Count -eq 1 -and $records[0].Name -ceq '-') "The test named - could not be chosen: $(Get-Dlss5ConsoleText)"
    }
    # Past the ninth test the entries have no shortcut, so a typed space moves nothing.
    $ten = @(1..10 | ForEach-Object { New-Dlss5TestDeclaration ('t' + $_) -Required $false -Role 'dev' })
    $many = New-Dlss5TestedPackageBytes -Tests $ten -Target -State (New-Dlss5RecordStateLines -Records @())
    Invoke-Dlss5PackageInteraction -Name 'tests-menu-ten' -Bytes $many -Action {
        param($PackagePath)
        # Run tests, a space, then Enter on the still highlighted All of these, then leave the menu.
        $script:Dlss5Console = New-Dlss5SubstitutedConsole @('t', 'Enter', ' ', 'Enter', 'Escape')
        $null = Invoke-Dlss5Menu -Path $PackagePath
        $text = Get-Dlss5ConsoleText
        Assert-Dlss5True (-not $text.Contains('[ ]')) "An entry showed a blank shortcut: $text"
        Assert-Dlss5Equal (Get-Dlss5StateRecords (Get-Dlss5PackageIdentityAt $PackagePath).State).Count 10 "A typed space chose a test past the ninth: $text"
    }
    # A location where no declared test runs is explained, not failed.
    $other = New-Dlss5TestedPackageBytes -Tests @((New-Dlss5TestDeclaration 'live' -Required $false -Role 'target')) -Target -State (New-Dlss5RecordStateLines -Records @())
    Invoke-Dlss5PackageInteraction -Name 'tests-menu-none' -Bytes $other -Action {
        param($PackagePath)
        $script:Dlss5Console = New-Dlss5SubstitutedConsole @('t', 'Enter', 'Escape')
        $null = Invoke-Dlss5Menu -Path $PackagePath
        $text = Get-Dlss5ConsoleText
        Assert-Dlss5True ($text.Contains('1 declared test runs only at a target location') -and $text.Contains('No test runs at this location.')) "The empty runnable set was not explained: $text"
    }
}

Invoke-Dlss5Case 'mission tests status reports the gate and the record count' {
    $fixture = New-Dlss5IsolatedLaunchFixture -Name 'tests-status'
    $status = Get-Dlss5LaunchStatus $fixture
    Assert-Dlss5True ($status.gate -ceq 'none-required' -and $status.test_records -eq 0) "The DLSS package's gate status is wrong: $($status | ConvertTo-Json -Compress)"
}
