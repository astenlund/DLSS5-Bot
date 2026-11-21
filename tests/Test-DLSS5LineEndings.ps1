# Loaded by the release suite after the engine store cases: the line-ending repair cases added in v54.
if ($null -eq (Get-Command Repair-Dlss5BootstrapLineEndings -ErrorAction SilentlyContinue)) {
    $script:Failures.Add('FAIL line-ending cases: the updater under test has no line-ending repair')
    return
}

$script:LineEndingNotice = 'had LF line endings'

function ConvertTo-Dlss5TestLfBytes {
    param([Parameter(Mandatory=$true)][byte[]]$Bytes)

    # The copy a Git checkout without CRLF conversion, or an editor saving with LF endings, leaves behind.
    $utf8 = [Text.UTF8Encoding]::new($false, $true)

    return $utf8.GetBytes($utf8.GetString($Bytes).Replace([string][char]13 + [char]10, [string][char]10))
}

function Get-Dlss5TestOccurrences {
    param([Parameter(Mandatory=$true)][AllowEmptyString()][string]$Text, [Parameter(Mandatory=$true)][string]$Value)

    return $Text.Split($Value).Length - 1
}

function Assert-Dlss5NoReplacementLeftovers {
    param([Parameter(Mandatory=$true)][string]$Directory)

    $leftovers = @(Get-ChildItem -LiteralPath $Directory -Force -File | Where-Object { $_.Name.StartsWith('.DLSS5-ADDER.cmd.', [StringComparison]::Ordinal) -or $_.Name -ceq 'DLSS5-ADDER.cmd.bkp' })
    Assert-Dlss5Equal $leftovers.Count 0 "The repair left files behind: $(@($leftovers | ForEach-Object Name) -join ', ')"
}

function Assert-Dlss5RefusedAsDamaged {
    param([Parameter(Mandatory=$true)]$Fixture, [Parameter(Mandatory=$true)][byte[]]$Bytes, [Parameter(Mandatory=$true)][string]$Label)

    [IO.File]::WriteAllBytes($Fixture.Updater, $Bytes)
    $process = Invoke-Dlss5IsolatedLaunch -Fixture $Fixture -Arguments @('check the settings')
    Assert-Dlss5Equal $process.ExitCode 4 "The $Label copy ran: $($process.StandardOutput) $($process.StandardError)"
    Assert-Dlss5True ($process.StandardError.Contains('This DLSS5-ADDER.cmd is damaged') -and -not $process.StandardOutput.Contains($script:LineEndingNotice)) "The $Label copy was not refused as damaged: $($process.StandardOutput) $($process.StandardError)"
    Assert-Dlss5True (Test-Dlss5ByteEquality -Left ([IO.File]::ReadAllBytes($Fixture.Updater)) -Right $Bytes) "The $Label copy was changed."
}

Invoke-Dlss5Case 'line endings an LF copy is rewritten to CRLF in place and relaunches itself with its task' {
    $fixture = New-Dlss5IsolatedLaunchFixture -Name 'line-endings-lf' -StubBody @('if not defined DLSS5_TEST_PROMPT_CAPTURE_PATH exit /b 0', 'copy /b "%LOCALAPPDATA%\DLSS5-ADDER\prompts\dlss5-agent-prompt-*.md" "%DLSS5_TEST_PROMPT_CAPTURE_PATH%" >nul', 'exit /b 0')
    $null = Set-Dlss5FixtureArmed $fixture
    $armed = [IO.File]::ReadAllBytes($fixture.Updater)
    [IO.File]::WriteAllBytes($fixture.Updater, (ConvertTo-Dlss5TestLfBytes $armed))
    $capture = Join-Path $fixture.StubRoot 'prompt.txt'
    $process = Invoke-Dlss5IsolatedLaunch -Fixture $fixture -Arguments @('check the settings') -Environment @{ DLSS5_TEST_PROMPT_CAPTURE_PATH = $capture }
    Assert-Dlss5Equal $process.ExitCode 0 "The repaired copy did not run its task: $($process.StandardOutput) $($process.StandardError)"
    Assert-Dlss5Equal (Get-Dlss5TestOccurrences -Text $process.StandardOutput -Value $script:LineEndingNotice) 1 "The repair was not reported exactly once: $($process.StandardOutput)"
    Assert-Dlss5True $process.StandardOutput.Contains('starting it again') "The notice did not say the copy starts again: $($process.StandardOutput)"
    Assert-Dlss5True (Test-Path -LiteralPath $capture) 'The relaunched copy did not start the agent session.'
    Assert-Dlss5True ([IO.File]::ReadAllText($capture, [Text.UTF8Encoding]::new($false, $true)).Contains('check the settings')) 'The relaunched session did not carry the task text.'
    Assert-Dlss5True (Test-Dlss5ByteEquality -Left ([IO.File]::ReadAllBytes($fixture.Updater)) -Right $armed) 'The repaired copy is not the exact CRLF package.'
    Assert-Dlss5NoReplacementLeftovers $fixture.Game
    # A later launch of the repaired copy starts directly, with no second repair.
    Remove-Item -LiteralPath $capture
    $rerun = Invoke-Dlss5IsolatedLaunch -Fixture $fixture -Arguments @('check the settings') -Environment @{ DLSS5_TEST_PROMPT_CAPTURE_PATH = $capture }
    Assert-Dlss5Equal $rerun.ExitCode 0 "The repaired copy did not run on a later launch: $($rerun.StandardOutput) $($rerun.StandardError)"
    Assert-Dlss5True (-not ($rerun.StandardOutput + $rerun.StandardError).Contains($script:LineEndingNotice) -and (Test-Path -LiteralPath $capture)) "The later launch did not start directly: $($rerun.StandardOutput) $($rerun.StandardError)"
}

Invoke-Dlss5Case 'line endings an LF copy launched without arguments relaunches with none and reaches the no-argument handling' {
    $fixture = New-Dlss5IsolatedLaunchFixture -Name 'line-endings-no-arguments'
    $published = [IO.File]::ReadAllBytes($fixture.Updater)
    [IO.File]::WriteAllBytes($fixture.Updater, (ConvertTo-Dlss5TestLfBytes $published))
    # Redirected input makes the launch non-interactive, so the relaunched copy refuses to open its menu instead of waiting for keys.
    $process = Invoke-Dlss5IsolatedLaunch -Fixture $fixture -Arguments ([string[]]@())
    Assert-Dlss5Equal $process.ExitCode 2 "The relaunched copy did not reach the non-interactive no-argument refusal: $($process.StandardOutput) $($process.StandardError)"
    Assert-Dlss5Equal (Get-Dlss5TestOccurrences -Text $process.StandardOutput -Value $script:LineEndingNotice) 1 "The repair was not reported exactly once: $($process.StandardOutput)"
    Assert-Dlss5True (-not $process.StandardError.Contains('handoff')) "The empty argument handoff was refused: $($process.StandardError)"
    Assert-Dlss5True (Test-Dlss5ByteEquality -Left ([IO.File]::ReadAllBytes($fixture.Updater)) -Right $published) 'The repaired copy is not the exact CRLF package.'
}

Invoke-Dlss5Case 'line endings a relaunched repair child that still runs from LF stops instead of repairing again' {
    $fixture = New-Dlss5IsolatedLaunchFixture -Name 'line-endings-loop-guard'
    $lf = ConvertTo-Dlss5TestLfBytes ([IO.File]::ReadAllBytes($fixture.Updater))
    [IO.File]::WriteAllBytes($fixture.Updater, $lf)
    # The marker a repair relaunch sets, on a launch that still runs from LF bytes, as when the file reverted before the child started.
    $process = Invoke-Dlss5IsolatedLaunch -Fixture $fixture -Arguments @('check the settings') -Environment @{ DLSS5_REEXEC_REPAIR = '1' }
    Assert-Dlss5Equal $process.ExitCode 4 "The repair child did not stop: $($process.StandardOutput) $($process.StandardError)"
    Assert-Dlss5True ($process.StandardError.Contains('The line-ending repair did not hold') -and -not $process.StandardOutput.Contains($script:LineEndingNotice)) "The repair child did not report the failed repair: $($process.StandardOutput) $($process.StandardError)"
    Assert-Dlss5True (Test-Dlss5ByteEquality -Left ([IO.File]::ReadAllBytes($fixture.Updater)) -Right $lf) 'The repair child rewrote the copy.'
}

Invoke-Dlss5Case 'line endings mixed endings, a doubled final newline and a BOM stay damage and leave the copy unchanged' {
    $fixture = New-Dlss5IsolatedLaunchFixture -Name 'line-endings-damaged'
    $lf = ConvertTo-Dlss5TestLfBytes ([IO.File]::ReadAllBytes($fixture.Updater))
    $first = [Array]::IndexOf($lf, [byte]10)
    Assert-Dlss5RefusedAsDamaged -Fixture $fixture -Bytes ([byte[]]($lf[0..($first - 1)] + [byte[]]@(13) + $lf[$first..($lf.Length - 1)])) -Label 'mixed'
    Assert-Dlss5RefusedAsDamaged -Fixture $fixture -Bytes ([byte[]]($lf + [byte[]]@(10))) -Label 'doubled'
    Assert-Dlss5RefusedAsDamaged -Fixture $fixture -Bytes ([byte[]]([byte[]]@(239, 187, 191) + $lf)) -Label 'BOM'
}

Invoke-Dlss5Case 'line endings an LF shared AppData copy is never repaired and stays damage' {
    $localAppData = Join-Path (Join-Path $script:ScratchRoot 'line-endings-slot') 'localappdata'
    $fixture = New-Dlss5IsolatedLaunchFixture -Name 'line-endings-slot' -GameDirectory (Join-Path $localAppData 'DLSS5-ADDER')
    Assert-Dlss5RefusedAsDamaged -Fixture $fixture -Bytes (ConvertTo-Dlss5TestLfBytes ([IO.File]::ReadAllBytes($fixture.Updater))) -Label 'shared LF'
}

function New-Dlss5TrackedLfFixture {
    param([Parameter(Mandatory=$true)][string]$Name, [switch]$Trusted)

    # A game folder whose Git repository holds the package with LF endings, as a checkout without CRLF conversion leaves it. A trusted
    # machine has run this version before, as the installed shared copy guarantees on the author's machine.
    $fixture = New-Dlss5IsolatedLaunchFixture -Name $Name
    if ($Trusted) { $null = Get-Dlss5LaunchStatus $fixture }
    $fixture | Add-Member -NotePropertyName Published -NotePropertyValue ([IO.File]::ReadAllBytes($fixture.Updater))
    [IO.File]::WriteAllBytes($fixture.Updater, (ConvertTo-Dlss5TestLfBytes $fixture.Published))
    foreach ($arguments in @(@('init', '--quiet'), @('config', 'core.autocrlf', 'false'), @('config', 'user.name', 'DLSS5 Tests'), @('config', 'user.email', 'a.stenlund@gmail.com'))) { & git -C $fixture.Game @arguments | Out-Null }
    & git -C $fixture.Game add -- 'DLSS5-ADDER.cmd' | Out-Null
    & git -C $fixture.Game commit --quiet -m 'test: track the LF copy' | Out-Null

    return $fixture
}

function Assert-Dlss5TrackedRepair {
    param([Parameter(Mandatory=$true)]$Fixture, [Parameter(Mandatory=$true)]$Process)

    Assert-Dlss5True ($Process.StandardOutput.Contains($script:LineEndingNotice) -and $Process.StandardOutput.Contains('commit that change')) "The repair of the tracked copy was not reported with its Git advice: $($Process.StandardOutput)"
    Assert-Dlss5True (Test-Dlss5ByteEquality -Left ([IO.File]::ReadAllBytes($Fixture.Updater)) -Right $Fixture.Published) 'The tracked copy is not the exact CRLF package.'
    $status = @(& git -C $Fixture.Game status --porcelain -- 'DLSS5-ADDER.cmd')
    Assert-Dlss5True ($status.Count -eq 1 -and $status[0] -ceq ' M DLSS5-ADDER.cmd') "Git does not see the repair as a plain modification: $($status -join ' | ')"
}

function Assert-Dlss5ReachesDisarmedRefusal {
    param([Parameter(Mandatory=$true)]$Process, [Parameter(Mandatory=$true)][string]$Context)

    $all = $Process.StandardOutput + $Process.StandardError
    Assert-Dlss5Equal $Process.ExitCode 8 "The tracked copy $Context did not reach the disarmed task refusal: $all"
    Assert-Dlss5True (-not $all.Contains('Updater Git state blocks replacement') -and -not $all.Contains('is damaged')) "The tracked copy $Context was refused: $all"
}

Invoke-Dlss5Case 'line endings a Git-tracked LF copy on a machine that trusts its version is repaired and its relaunch passes the Git check' {
    $fixture = New-Dlss5TrackedLfFixture -Name 'line-endings-tracked' -Trusted
    $process = Invoke-Dlss5IsolatedLaunch -Fixture $fixture -Arguments @('check the settings')
    Assert-Dlss5TrackedRepair -Fixture $fixture -Process $process
    Assert-Dlss5ReachesDisarmedRefusal -Process $process -Context 'relaunched after its repair'
}

Invoke-Dlss5Case 'line endings a Git-tracked LF copy on a machine new to its version is refused by the Git check until the repair is committed' {
    $fixture = New-Dlss5TrackedLfFixture -Name 'line-endings-tracked-new'
    $process = Invoke-Dlss5IsolatedLaunch -Fixture $fixture -Arguments @('check the settings')
    Assert-Dlss5TrackedRepair -Fixture $fixture -Process $process
    Assert-Dlss5True ($process.ExitCode -ne 0 -and ($process.StandardOutput + $process.StandardError).Contains('Updater Git state blocks replacement')) "The relaunch of the uncommitted repair on a new machine was not refused by the Git check: exit $($process.ExitCode) $($process.StandardOutput) $($process.StandardError)"
    & git -C $fixture.Game commit --quiet -am 'test: commit the CRLF repair' | Out-Null
    Assert-Dlss5ReachesDisarmedRefusal -Process (Invoke-Dlss5IsolatedLaunch -Fixture $fixture -Arguments @('check the settings')) -Context 'after its commit'
}
