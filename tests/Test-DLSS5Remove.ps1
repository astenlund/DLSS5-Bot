# Loaded by the release suite after the mission test cases: the mission file removal cases added in v56.
if ($null -eq (Get-Command Invoke-Dlss5RemoveMissionFiles -ErrorAction SilentlyContinue)) {
    $script:Failures.Add('FAIL mission file removal cases: the updater under test has no mission file removal')
    return
}

function New-Dlss5RemovablePackageBytes {
    param([Collections.IDictionary]$Files = $null, [switch]$Seed, [switch]$NamedInstruction, [AllowNull()][string[]]$State = $null)

    # A plain package with a required test unit, an optional test other and an instruction file extra; -NamedInstruction makes MISSION.md
    # name a second instruction file, guide, and -Seed adds a seed. The state is not empty unless given, so no new-package box comes first.
    $tests = @((New-Dlss5TestDeclaration 'unit' -Role 'dev'), (New-Dlss5TestDeclaration 'other' -Required $false -Role 'dev'))
    $bytes = New-Dlss5TestedPackageBytes -Tests $tests -State $(if ($null -ne $State) { $State } else { New-Dlss5RecordStateLines -Records @() })
    $added = [ordered]@{ 'INSTRUCTIONS.extra.md' = $script:PackageUtf8.GetBytes('Extra.' + $script:PackageNewline) }
    if ($Seed) { $added['SEED.json'] = $script:PackageUtf8.GetBytes('{"schema_version":1,"host":"claude"}' + $script:PackageNewline) }
    if ($NamedInstruction) {
        $mission = $script:PackageUtf8.GetString([byte[]](Get-Dlss5BootstrapIdentity -Bytes $bytes).MissionFiles['MISSION.md'])
        $added['MISSION.md'] = $script:PackageUtf8.GetBytes($mission.Replace('Hello from {{package_dir}}.', 'Hello from {{package_dir}}. Read {{instruction:guide}}.'))
        $added['INSTRUCTIONS.guide.md'] = $script:PackageUtf8.GetBytes('Guide.' + $script:PackageNewline)
    }
    if ($null -ne $Files) { foreach ($name in $Files.Keys) { $added[$name] = $Files[$name] } }

    return ,(New-Dlss5PackageVariant -Bytes $bytes -Files $added)
}

function New-Dlss5RemoveRequest {
    param([Parameter(Mandatory=$true)]$Identity, [Parameter(Mandatory=$true)][string]$Names, [string]$MissionSha256 = '')

    $mission = if ($MissionSha256.Length -gt 0) { $MissionSha256 } else { $Identity.MissionSha256 }

    return [pscustomobject]@{ Item = '--internal-remove'; Expect = [pscustomobject]@{ Version = $Identity.Version; EngineSha256 = $Identity.EngineSha256; MissionSha256 = $mission }; Folder = $Names }
}

Invoke-Dlss5Case 'remove offers only instruction and test files and parses its headless item' {
    $dlss = Get-Dlss5RemovableMissionFiles $script:CandidateIdentity.MissionFiles
    Assert-Dlss5Equal ($dlss -join ',') 'INSTRUCTIONS.bootstrap-changes.md,INSTRUCTIONS.cleanup-boundary.md,INSTRUCTIONS.local-runtime-build.md,INSTRUCTIONS.settings-optimization.md' 'The DLSS mission offered the wrong files.'
    $plain = Get-Dlss5BootstrapIdentity -Bytes (New-Dlss5RemovablePackageBytes -Seed) -Strict
    Assert-Dlss5Equal ((Get-Dlss5RemovableMissionFiles $plain.MissionFiles) -join ',') 'INSTRUCTIONS.extra.md,TEST.other.ps1,TEST.unit.ps1' 'MISSION.md, PROJECT.json or SEED.json was offered, or a removable file was not.'
    $token = Get-Dlss5ExpectationToken $script:CandidateIdentity
    $parse = { param([string]$Names) Resolve-Dlss5LaunchRequest -Launch (Resolve-Dlss5LaunchArguments @('--internal-remove', $token, $Names)) -Tokens @('--internal-remove', $token, $Names) }
    $request = & $parse 'TEST.unit.ps1+INSTRUCTIONS.extra.md'
    Assert-Dlss5True ($request.Kind -ceq 'item' -and $request.Item -ceq '--internal-remove' -and $request.Folder -ceq 'TEST.unit.ps1+INSTRUCTIONS.extra.md') 'The headless item did not carry its names.'
    foreach ($bad in @('', 'TEST.unit.ps1,INSTRUCTIONS.extra.md', 'TEST.unit.ps1+', '+TEST.unit.ps1', 'notes.txt', 'C:\x\TEST.unit.ps1')) {
        Assert-Dlss5Throws { $null = & $parse $bad } ([ArgumentException]) "The headless item accepted the names '$bad'."
    }
    Assert-Dlss5Throws { $null = Resolve-Dlss5LaunchRequest -Launch (Resolve-Dlss5LaunchArguments @('--internal-remove', 'TEST.unit.ps1')) -Tokens @('--internal-remove', 'TEST.unit.ps1') } ([ArgumentException]) 'The headless item ran without its expectation token.'
}

Invoke-Dlss5Case 'remove takes a test with its declaration and an instruction file in one write that disarms and drops the records' {
    $plainMission = (Get-Dlss5BootstrapIdentity -Bytes (New-Dlss5RemovablePackageBytes) -Strict).MissionSha256
    $state = New-Dlss5RecordStateLines -Records @((New-Dlss5TestRecordFixture -Name 'unit' -Mission $plainMission)) -Armed $true
    Invoke-Dlss5PackageInteraction -Name 'remove-headless' -Bytes (New-Dlss5RemovablePackageBytes -State $state) -Action {
        param($PackagePath)
        $script:Dlss5Console = New-Dlss5SubstitutedConsole @()
        $identity = $script:Dlss5ExecutingIdentity
        Assert-Dlss5True ($identity.State.Armed -and (Get-Dlss5StateRecords $identity.State).Count -eq 1) 'The fixture is not armed with a record.'
        Assert-Dlss5Equal (Invoke-Dlss5PackageItem -Path $PackagePath -Request (New-Dlss5RemoveRequest $identity 'TEST.other.ps1+INSTRUCTIONS.extra.md')) 0 "The headless removal failed: $(Get-Dlss5ConsoleText)"
        $text = Get-Dlss5ConsoleText
        Assert-Dlss5True ($text.Contains('The declarations of the removed tests are removed from PROJECT.json too.') -and $text.Contains('Removed: TEST.other.ps1, INSTRUCTIONS.extra.md') -and $text.Contains('The package is disarmed.')) "The removal was not reported: $text"
        $after = Get-Dlss5PackageIdentityAt $PackagePath
        Assert-Dlss5True (-not $after.MissionFiles.Contains('TEST.other.ps1') -and -not $after.MissionFiles.Contains('INSTRUCTIONS.extra.md') -and $after.MissionFiles.Contains('TEST.unit.ps1')) 'The wrong files were removed.'
        Assert-Dlss5Equal (@($after.Project.Tests | ForEach-Object { $_.Name }) -join ',') 'unit' 'The removed test kept its declaration, or another declaration went.'
        Assert-Dlss5True ($after.Project.Tests[0].Required -and $after.Project.Tests[0].Role -ceq 'dev' -and -not $after.Project.Rerun) 'The rewritten PROJECT.json changed the remaining project.'
        Assert-Dlss5True (-not $after.State.Armed -and (Get-Dlss5StateRecords $after.State).Count -eq 0 -and $after.State.MissionEdited) 'The removal did not disarm, drop the records and mark the mission edited.'
        # Removing only an instruction file leaves PROJECT.json byte for byte.
        $project = [byte[]]$after.MissionFiles['PROJECT.json']
        $script:Dlss5ExecutingIdentity = $after
        $null = Invoke-Dlss5RemoveMissionFiles -Path $PackagePath -Names @('TEST.unit.ps1') -Headless
        $last = Get-Dlss5PackageIdentityAt $PackagePath
        Assert-Dlss5True (-not $last.MissionFiles.Contains('TEST.unit.ps1') -and (Get-Dlss5ProjectTests $last.Project).Count -eq 0) "The last test did not go with its declaration: $(Get-Dlss5ConsoleText)"
        Assert-Dlss5True (-not (Test-Dlss5ByteEquality -Left ([byte[]]$last.MissionFiles['PROJECT.json']) -Right $project)) 'The last declaration stayed in PROJECT.json.'
    }
    Invoke-Dlss5PackageInteraction -Name 'remove-instruction-only' -Bytes (New-Dlss5RemovablePackageBytes) -Action {
        param($PackagePath)
        $script:Dlss5Console = New-Dlss5SubstitutedConsole @()
        $project = [byte[]]$script:Dlss5ExecutingIdentity.MissionFiles['PROJECT.json']
        Assert-Dlss5Equal (Invoke-Dlss5RemoveMissionFiles -Path $PackagePath -Names @('INSTRUCTIONS.extra.md') -Headless) 0 "The instruction file was not removed: $(Get-Dlss5ConsoleText)"
        $after = Get-Dlss5PackageIdentityAt $PackagePath
        Assert-Dlss5True (-not $after.MissionFiles.Contains('INSTRUCTIONS.extra.md') -and (Test-Dlss5ByteEquality -Left ([byte[]]$after.MissionFiles['PROJECT.json']) -Right $project)) 'Removing an instruction file rewrote PROJECT.json.'
        Assert-Dlss5True (-not (Get-Dlss5ConsoleText).Contains('declarations of the removed tests')) 'A removal without tests spoke of declarations.'
    }
}

Invoke-Dlss5Case 'remove refuses the mission itself, the seed, a missing or repeated file, a still-named instruction file and a stale or blocked package, writing nothing' {
    $bytes = New-Dlss5RemovablePackageBytes -Seed -NamedInstruction
    Invoke-Dlss5PackageInteraction -Name 'remove-refusals' -Bytes $bytes -Action {
        param($PackagePath)
        $identity = $script:Dlss5ExecutingIdentity
        $refusals = [ordered]@{
            'MISSION.md' = 'MISSION.md is the mission itself and cannot be removed.'
            'PROJECT.json' = 'PROJECT.json is the mission itself and cannot be removed.'
            'SEED.json' = 'the seed is removed through Configure''s Remove seed.'
            'INSTRUCTIONS.none.md' = 'the mission has no INSTRUCTIONS.none.md.'
            'TEST.unit.ps1+TEST.unit.ps1' = 'TEST.unit.ps1 is named twice.'
            'INSTRUCTIONS.guide.md' = 'MISSION.md would no longer be valid without them: The template names a missing instruction file: instruction:guide. Absorb a MISSION.md that no longer names them first.'
        }
        foreach ($names in $refusals.Keys) {
            $script:Dlss5Console = New-Dlss5SubstitutedConsole @()
            Assert-Dlss5Equal (Invoke-Dlss5PackageItem -Path $PackagePath -Request (New-Dlss5RemoveRequest $identity $names)) $script:Dlss5RefusedExitCode "Removing $names was not refused."
            $text = Get-Dlss5ConsoleText
            Assert-Dlss5True ($text.Contains('Remove refused: ' + $refusals[$names] + ' Nothing was removed.') -and -not $text.Contains('Mission files to remove:')) "Removing $names was refused without its reason: $text"
            Assert-Dlss5True (Test-Dlss5ByteEquality -Left ([IO.File]::ReadAllBytes($PackagePath)) -Right $bytes) "A refused removal of $names changed the package."
        }
        # A file that is removable on its own is still refused in the company of one that is not.
        $script:Dlss5Console = New-Dlss5SubstitutedConsole @()
        Assert-Dlss5Equal (Invoke-Dlss5PackageItem -Path $PackagePath -Request (New-Dlss5RemoveRequest $identity 'INSTRUCTIONS.extra.md+MISSION.md')) $script:Dlss5RefusedExitCode 'A mixed removal was not refused.'
        $script:Dlss5Console = New-Dlss5SubstitutedConsole @()
        Assert-Dlss5Equal (Invoke-Dlss5PackageItem -Path $PackagePath -Request (New-Dlss5RemoveRequest $identity 'INSTRUCTIONS.extra.md' -MissionSha256 ('0' * 64))) $script:Dlss5RefusedExitCode 'A stale expectation removed a file.'
        Assert-Dlss5True (Get-Dlss5ConsoleText).Contains('not the one this command expected') 'The stale expectation was not reported.'
        # A window opened before the mission changed refuses inside the write.
        $changed = New-Dlss5PackageVariant -Bytes $bytes -Files ([ordered]@{ 'INSTRUCTIONS.extra.md' = $script:PackageUtf8.GetBytes('Changed.' + $script:PackageNewline) })
        [IO.File]::WriteAllBytes($PackagePath, $changed)
        $script:Dlss5Console = New-Dlss5SubstitutedConsole @()
        Assert-Dlss5Equal (Invoke-Dlss5RemoveMissionFiles -Path $PackagePath -Names @('INSTRUCTIONS.extra.md') -Headless) $script:Dlss5RefusedExitCode 'A stale window removed a file.'
        Assert-Dlss5True (Get-Dlss5ConsoleText).Contains('Remove failed; the package is unchanged: The mission changed in another window.') "The stale window did not say why: $(Get-Dlss5ConsoleText)"
        Assert-Dlss5True (Test-Dlss5ByteEquality -Left ([IO.File]::ReadAllBytes($PackagePath)) -Right $changed) 'A stale window changed the package.'
        Assert-Dlss5Equal (Invoke-Dlss5RemoveMissionFiles -Path $PackagePath -Names @() -Headless) 0 'An empty choice was refused.'
        Assert-Dlss5True (Get-Dlss5ConsoleText).Contains('No file was chosen, so nothing was removed.') 'An empty choice was not explained.'
    }
    # A pending update, the diagnosis condition and the shared AppData copy each refuse before anything is listed.
    $update = [pscustomobject]@{ FromVersion = 55; FromMissionHash = $null; FromSha256 = ('a' * 64); ReplacedEdit = $false; BackupSha256 = $null }
    $pending = New-Dlss5RemovablePackageBytes -State (New-Dlss5RecordStateLines -Records @() -Update $update)
    Invoke-Dlss5PackageInteraction -Name 'remove-pending' -Bytes $pending -Action {
        param($PackagePath)
        $script:Dlss5Console = New-Dlss5SubstitutedConsole @()
        Assert-Dlss5Equal (Invoke-Dlss5RemoveMissionFiles -Path $PackagePath -Names @('INSTRUCTIONS.extra.md') -Headless) $script:Dlss5RefusedExitCode 'A pending update did not refuse the removal.'
        Assert-Dlss5True (Get-Dlss5ConsoleText).Contains('Remove refused: acknowledge the what''s-changed box first.') "The pending update was not named: $(Get-Dlss5ConsoleText)"
        Assert-Dlss5True (Test-Dlss5ByteEquality -Left ([IO.File]::ReadAllBytes($PackagePath)) -Right $pending) 'A refused removal changed a pending package.'
    }
    $diagnosis = [pscustomobject]@{ Reason = 'git-missing'; Evidence = 'no git' }
    Invoke-Dlss5PackageInteraction -Name 'remove-diagnosis' -Bytes (New-Dlss5RemovablePackageBytes) -Diagnosis $diagnosis -Action {
        param($PackagePath)
        $script:Dlss5Console = New-Dlss5SubstitutedConsole @()
        Assert-Dlss5Equal (Invoke-Dlss5RemoveMissionFiles -Path $PackagePath -Names @('INSTRUCTIONS.extra.md') -Headless) $script:Dlss5RefusedExitCode 'The diagnosis condition did not refuse the removal.'
        Assert-Dlss5True (Get-Dlss5ConsoleText).Contains('Remove refused: A startup check failed') "The diagnosis condition was not named: $(Get-Dlss5ConsoleText)"
    }
    Invoke-Dlss5PackageInteraction -Name 'remove-slot' -Bytes (New-Dlss5RemovablePackageBytes) -Action {
        param($PackagePath)
        $slot = Get-Dlss5StorePath 'DLSS5-ADDER.cmd'
        $slotBytes = [IO.File]::ReadAllBytes($PackagePath)
        [IO.File]::WriteAllBytes($slot, $slotBytes)
        $script:Dlss5Console = New-Dlss5SubstitutedConsole @()
        Assert-Dlss5Equal (Invoke-Dlss5RemoveMissionFiles -Path $slot -Names @('INSTRUCTIONS.extra.md') -Headless) $script:Dlss5RefusedExitCode 'The shared copy allowed a removal.'
        Assert-Dlss5True (Get-Dlss5ConsoleText).Contains('Remove refused: This is the shared AppData copy') "The shared copy was not named: $(Get-Dlss5ConsoleText)"
        Assert-Dlss5True (Test-Dlss5ByteEquality -Left ([IO.File]::ReadAllBytes($slot)) -Right $slotBytes) 'A refused removal changed the shared copy.'
    }
}

Invoke-Dlss5Case 'remove menu ticks and unticks files, asks before writing and is hidden when nothing is removable' {
    $bytes = New-Dlss5RemovablePackageBytes -Seed
    Invoke-Dlss5PackageInteraction -Name 'remove-menu' -Bytes $bytes -Action {
        param($PackagePath)
        # The files are listed in order: INSTRUCTIONS.extra.md, TEST.other.ps1, TEST.unit.ps1. Tick the first two, untick and tick the
        # second again, remove, confirm, then leave the menu.
        $script:Dlss5Console = New-Dlss5SubstitutedConsole @('r', 'Enter', '1', 'Enter', '2', 'Enter', '2', 'Enter', '2', 'Enter', 'r', 'Enter', 'y', 'Enter', 'Escape')
        $null = Invoke-Dlss5Menu -Path $PackagePath
        $text = Get-Dlss5ConsoleText
        Assert-Dlss5True ($text.Contains('[r] Remove mission files') -and $text.Contains('INSTRUCTIONS.extra.md (ticked)') -and $text.Contains('The seed is removed through Configure''s Remove seed, so it is not listed here.')) "The removal menu was not shown as expected: $text"
        Assert-Dlss5True ($text.Contains('Remove these files from DLSS5-ADDER.cmd? The package will be disarmed and its test records removed.') -and $text.Contains('Removed: INSTRUCTIONS.extra.md, TEST.other.ps1')) "The removal was not confirmed and reported: $text"
        $after = Get-Dlss5PackageIdentityAt $PackagePath
        Assert-Dlss5True (-not $after.MissionFiles.Contains('INSTRUCTIONS.extra.md') -and -not $after.MissionFiles.Contains('TEST.other.ps1') -and $after.MissionFiles.Contains('TEST.unit.ps1') -and $after.MissionFiles.Contains('SEED.json')) 'The menu removed the wrong files.'
    }
    Invoke-Dlss5PackageInteraction -Name 'remove-menu-cancel' -Bytes $bytes -Action {
        param($PackagePath)
        # Tick a file and decline the question; then open the list again, untick it, ask to remove nothing, and cancel.
        $script:Dlss5Console = New-Dlss5SubstitutedConsole @('r', 'Enter', '1', 'Enter', 'r', 'Enter', 'n', 'Enter', 'r', 'Enter', '1', 'Enter', '1', 'Enter', 'r', 'Enter', 'c', 'Enter', 'Escape')
        $null = Invoke-Dlss5Menu -Path $PackagePath
        $text = Get-Dlss5ConsoleText
        Assert-Dlss5True ($text.Contains('Tick at least one file first.') -and ([regex]::Matches($text, 'Remove cancelled; the package is unchanged\.')).Count -eq 2) "Declining and cancelling were not reported: $text"
        Assert-Dlss5True (Test-Dlss5ByteEquality -Left ([IO.File]::ReadAllBytes($PackagePath)) -Right $bytes) 'A declined or cancelled removal changed the package.'
    }
    # A mission without instruction or test files, a seed only, offers no removal.
    $seed = $script:PackageUtf8.GetBytes('{"schema_version":1,"host":"claude"}' + $script:PackageNewline)
    $bare = New-Dlss5PackageVariant -Bytes (New-Dlss5PlainPackageBytes) -Files ([ordered]@{ 'SEED.json' = $seed }) -State (New-Dlss5RecordStateLines -Records @())
    Invoke-Dlss5PackageInteraction -Name 'remove-menu-hidden' -Bytes $bare -Action {
        param($PackagePath)
        $script:Dlss5Console = New-Dlss5SubstitutedConsole @('Escape')
        $null = Invoke-Dlss5Menu -Path $PackagePath
        Assert-Dlss5True (-not (Get-Dlss5ConsoleText).Contains('Remove mission files')) "The removal item was offered with nothing to remove: $(Get-Dlss5ConsoleText)"
    }
}

Invoke-Dlss5Case 'remove is refused before its question while another process holds the folder' {
    $root = Join-Path $script:ScratchRoot 'remove-guard'
    $bytes = New-Dlss5RemovablePackageBytes
    Invoke-Dlss5PackageInteraction -Name 'remove-guard' -Bytes $bytes -Action {
        param($PackagePath)
        $holder = Start-Dlss5GuardHolder -Package $PackagePath -LocalAppData (Join-Path $root 'localappdata')
        try {
            $text = Get-Dlss5HolderText $holder
            $script:Dlss5Console = New-Dlss5SubstitutedConsole @('Enter')
            Assert-Dlss5Equal (Invoke-Dlss5RemoveMissionFiles -Path $PackagePath -Names @('INSTRUCTIONS.extra.md')) $script:Dlss5RefusedExitCode 'The removal was not refused while the folder was held.'
            $output = Get-Dlss5ConsoleText
            Assert-Dlss5True ($output.Contains('Remove refused: ' + $text) -and -not $output.Contains('Remove these files')) "The removal was not refused before its question: $output"
            $script:Dlss5Console = New-Dlss5SubstitutedConsole @()
            Assert-Dlss5Equal (Invoke-Dlss5RemoveMissionFiles -Path $PackagePath -Names @('INSTRUCTIONS.extra.md') -Headless) $script:Dlss5RefusedExitCode 'The headless removal was not refused while the folder was held.'
            Assert-Dlss5True (Get-Dlss5ConsoleText).Contains('Remove failed; the package is unchanged: ' + $text) "The headless removal did not name the holder: $(Get-Dlss5ConsoleText)"
            Assert-Dlss5True (Test-Dlss5ByteEquality -Left ([IO.File]::ReadAllBytes($PackagePath)) -Right $bytes) 'A refused removal changed the package.'
        }
        finally { Stop-Dlss5GuardHolder $holder }
    }
}

Invoke-Dlss5Case 'remove through a real launch carries several names and refuses a still-named instruction file' {
    $fixture = New-Dlss5IsolatedLaunchFixture -Name 'remove-launch'
    $status = Get-Dlss5LaunchStatus $fixture
    $before = [IO.File]::ReadAllBytes($fixture.Updater)
    $process = Invoke-Dlss5IsolatedLaunch -Fixture $fixture -Arguments @('--internal-remove', $status.expect, 'INSTRUCTIONS.bootstrap-changes.md+INSTRUCTIONS.cleanup-boundary.md')
    Assert-Dlss5True ($process.ExitCode -eq 8 -and $process.StandardOutput.Contains('Remove refused: MISSION.md would no longer be valid without them') -and $process.StandardOutput.Contains('Nothing was removed.')) "The launch did not refuse the still-named instruction files (exit $($process.ExitCode)): $($process.StandardOutput) $($process.StandardError)"
    Assert-Dlss5True (Test-Dlss5ByteEquality -Left ([IO.File]::ReadAllBytes($fixture.Updater)) -Right $before) 'A refused launch changed the copy.'
}
