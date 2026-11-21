# Loaded by the release suite after the Configuration cases: the single-instance guard cases added in v52.
if ($null -eq (Get-Command Enter-Dlss5FolderGuard -ErrorAction SilentlyContinue)) {
    $script:Failures.Add('FAIL guard cases: the updater under test has no single-instance guard')
    return
}

function Start-Dlss5GuardHolder {
    param(
        [Parameter(Mandatory=$true)][string]$Package,
        [Parameter(Mandatory=$true)][string]$LocalAppData,
        [string]$Operation = 'execute',
        [string]$HostKind = 'claude',
        [switch]$NoRecord,
        [string]$ChildArguments = ''
    )

    # Holds the package folder's guard from a separate process until Stop-Dlss5GuardHolder, as a running session would.
    $id = [Guid]::NewGuid().ToString('N').Substring(0, 12)
    $base = Join-Path (Split-Path -Parent $Package) ('..\holder-' + $id)
    $holder = [pscustomobject]@{ Ready = [IO.Path]::GetFullPath($base + '.ready'); Release = [IO.Path]::GetFullPath($base + '.release'); Result = [IO.Path]::GetFullPath($base + '.json'); Process = $null; ProcessId = 0 }
    $info = [Diagnostics.ProcessStartInfo]::new('pwsh')
    foreach ($argument in @('-NoProfile', '-File', (Join-Path $PSScriptRoot 'Hold-DLSS5Guard.ps1'), '-Library', $script:Library.Path, '-SelfPath', $script:Library.SelfPath, '-Package', $Package, '-LocalAppData', $LocalAppData, '-ReadyPath', $holder.Ready, '-ReleasePath', $holder.Release, '-Operation', $Operation)) { $info.ArgumentList.Add($argument) }
    if ($HostKind.Length -gt 0) { $info.ArgumentList.Add('-HostKind'); $info.ArgumentList.Add($HostKind) }
    if ($NoRecord) { $info.ArgumentList.Add('-NoRecord') }
    if ($ChildArguments.Length -gt 0) { foreach ($argument in @('-ChildArguments', $ChildArguments, '-ChildResultPath', $holder.Result)) { $info.ArgumentList.Add($argument) } }
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $holder.Process = [Diagnostics.Process]::Start($info)
    $holder.ProcessId = $holder.Process.Id
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while (-not (Test-Path -LiteralPath $holder.Ready)) {
        if ($holder.Process.HasExited) { throw "The guard holder exited with code $($holder.Process.ExitCode) before it was ready." }
        if ($timer.Elapsed.TotalSeconds -gt 120) { $holder.Process.Kill($true); throw 'The guard holder did not become ready within two minutes.' }
        Start-Sleep -Milliseconds 50
    }

    return $holder
}

function Stop-Dlss5GuardHolder {
    param([Parameter(Mandatory=$true)]$Holder, [switch]$Kill)

    if ($Kill) { $Holder.Process.Kill($true) }
    else { [IO.File]::WriteAllText($Holder.Release, 'release') }
    if (-not $Holder.Process.WaitForExit(60000)) { $Holder.Process.Kill($true); throw 'The guard holder did not exit.' }
    $Holder.Process.Dispose()
}

function Get-Dlss5HolderText {
    param([Parameter(Mandatory=$true)]$Holder, [string]$Label = 'session', [string]$HostKind = 'claude')

    # The refusal names the holder's process and, for a session whose agent was selected, its host.
    $start = [Diagnostics.Process]::GetProcessById($Holder.ProcessId).StartTime.ToUniversalTime()
    $local = [datetime]::new($start.Ticks - ($start.Ticks % [TimeSpan]::TicksPerSecond), [DateTimeKind]::Utc).ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)
    $hostPart = if ($HostKind.Length -gt 0) { ', host ' + $HostKind } else { '' }

    return "another DLSS 5 ADDER $Label is running for this folder (process $($Holder.ProcessId), started $local$hostPart)."
}

function Write-Dlss5TestGuardRecord {
    param([Parameter(Mandatory=$true)][string]$Token, [Parameter(Mandatory=$true)][Collections.IDictionary]$Fields)

    $path = Get-Dlss5GuardRecordPath $Token
    New-Item -ItemType Directory -Force (Split-Path -Parent $path) | Out-Null
    [IO.File]::WriteAllText($path, (ConvertTo-Json -InputObject $Fields -Compress) + "`r`n", [Text.UTF8Encoding]::new($false))
}

function New-Dlss5TestGuardFields {
    param([Parameter(Mandatory=$true)][string]$Token, [int]$ProcessId = $PID, [string]$Started = '', [string]$Operation = 'execute', [string]$HostKind = '')

    if ($Started.Length -eq 0) { $Started = Get-Dlss5ProcessStartStamp ([Diagnostics.Process]::GetProcessById($ProcessId)) }

    return [ordered]@{ schema_version = 1; token = $Token; pid = $ProcessId; started_utc = $Started; operation = $Operation; host = $HostKind; folder = 'C:\Games\Fixture' }
}

$script:GuardUnavailable = 'another DLSS 5 ADDER operation is running for this folder, and its details are unavailable. Close the other DLSS 5 ADDER windows for this folder, then try again.'

Invoke-Dlss5Case 'guard folder identity follows the folder, not its spelling' {
    $root = Join-Path $script:ScratchRoot 'guard-identity'
    $first = Join-Path $root 'A folder with a long name'
    $second = Join-Path $root 'second'
    $junction = Join-Path $root 'junction'
    New-Item -ItemType Directory -Force $first, $second | Out-Null
    New-Item -ItemType Junction -Path $junction -Target $first | Out-Null
    try {
        $token = Get-Dlss5GuardToken (Join-Path $first 'DLSS5-ADDER.cmd')
        Assert-Dlss5True ($token -cmatch '\A[0-9a-f]{48}\z') "The file-ID token has the wrong form: $token"
        Assert-Dlss5Equal (Get-Dlss5GuardToken (Join-Path $junction 'DLSS5-ADDER.cmd')) $token 'A junction to the folder gave another guard.'
        Assert-Dlss5Equal (Get-Dlss5GuardToken ((Join-Path $first 'DLSS5-ADDER.cmd').ToUpperInvariant())) $token 'A case variant of the path gave another guard.'
        Assert-Dlss5Equal (Get-Dlss5GuardToken ($first + '\\DLSS5-ADDER.cmd')) $token 'A doubled separator gave another guard.'
        Assert-Dlss5True ((Get-Dlss5GuardToken (Join-Path $second 'DLSS5-ADDER.cmd')) -cne $token) 'Two folders shared one guard.'
        $short = (New-Object -ComObject Scripting.FileSystemObject).GetFolder($first).ShortPath
        if ($short -cne $first) { Assert-Dlss5Equal (Get-Dlss5GuardToken (Join-Path $short 'DLSS5-ADDER.cmd')) $token 'The folder''s short name gave another guard.' }
        else { Write-Host 'SKIP guard short name: the test volume provides no short names' }
        $script:Dlss5GuardForcePathToken = $true
        try {
            $pathToken = Get-Dlss5GuardToken (Join-Path $first 'DLSS5-ADDER.cmd')
            Assert-Dlss5True ($pathToken -cmatch '\AP[0-9a-f]{64}\z') "The path token has the wrong form: $pathToken"
            Assert-Dlss5Equal (Get-Dlss5GuardToken (Join-Path $junction 'DLSS5-ADDER.cmd')) $pathToken 'The path token differs through a junction.'
            Assert-Dlss5Equal (Get-Dlss5GuardToken ((Join-Path $first 'DLSS5-ADDER.cmd').ToLowerInvariant())) $pathToken 'The path token differs by case.'
            if ($short -cne $first) { Assert-Dlss5Equal (Get-Dlss5GuardToken (Join-Path $short 'DLSS5-ADDER.cmd')) $pathToken 'The path token differs for the folder''s short name.' }
        }
        finally { $script:Dlss5GuardForcePathToken = $false }
        $message = ''
        try { $null = Get-Dlss5GuardToken (Join-Path $root 'absent\DLSS5-ADDER.cmd') }
        catch [InvalidOperationException] { $message = $_.Exception.Message }
        Assert-Dlss5True $message.StartsWith('the single-instance guard could not identify this folder: ') "A missing folder did not refuse: $message"
    }
    finally { Remove-Item -LiteralPath $junction -Force }
}

Invoke-Dlss5Case 'guard holds, re-enters, releases and records its holder' {
    $root = Join-Path $script:ScratchRoot 'guard-lifecycle'
    $game = Join-Path $root 'game'
    New-Item -ItemType Directory -Force $game | Out-Null
    $package = Join-Path $game 'DLSS5-ADDER.cmd'
    Invoke-Dlss5WithLocalAppData -Path (Join-Path $root 'localappdata') -Action {
        New-Item -ItemType Directory -Force (Get-Dlss5StorePath) | Out-Null
        $token = Get-Dlss5GuardToken $package
        $recordPath = Get-Dlss5GuardRecordPath $token
        # A probe writes no record and leaves no hold.
        Assert-Dlss5FolderGuardFree $package
        Assert-Dlss5True (-not (Test-Path -LiteralPath $recordPath)) 'A probe wrote a holder record.'
        Assert-Dlss5Equal $script:Dlss5GuardHolds.Count 0 'A probe left a hold.'
        Assert-Dlss5Throws { Assert-Dlss5FolderGuardHeld $package } ([IO.InvalidDataException]) 'The backstop passed without a hold.'
        $outer = Enter-Dlss5FolderGuard -Path $package -Operation 'task'
        try {
            $fields = ConvertFrom-Dlss5JsonObject -Bytes ([IO.File]::ReadAllBytes($recordPath)) -Limit 4096
            Assert-Dlss5Equal ([string]::Join(',', @($fields.Keys))) 'schema_version,token,pid,started_utc,operation,host,folder' 'The record does not have exactly its fields in order.'
            Assert-Dlss5True ($fields['token'].GetString() -ceq $token -and $fields['pid'].GetInt32() -eq $PID -and $fields['operation'].GetString() -ceq 'task' -and $fields['host'].GetString() -ceq '' -and $fields['folder'].GetString() -ceq $game) 'The record does not describe this holder.'
            Assert-Dlss5Equal $fields['started_utc'].GetString() (Get-Dlss5ProcessStartStamp ([Diagnostics.Process]::GetCurrentProcess())) 'The record does not carry this process start time.'
            Update-Dlss5FolderGuardHost 'codex'
            Assert-Dlss5Equal (ConvertFrom-Dlss5JsonObject -Bytes ([IO.File]::ReadAllBytes($recordPath)) -Limit 4096)['host'].GetString() 'codex' 'The host refresh did not land.'
            Assert-Dlss5FolderGuardHeld $package
            Assert-Dlss5FolderGuardFree $package
            $inner = Enter-Dlss5FolderGuard -Path $package -Operation 'package-write'
            Assert-Dlss5Equal $script:Dlss5GuardHolds[$token].Count 2 'Re-entry did not count.'
            Exit-Dlss5FolderGuard $inner
            Assert-Dlss5True (Test-Path -LiteralPath $recordPath) 'An inner release removed the record.'
            Assert-Dlss5Equal (ConvertFrom-Dlss5JsonObject -Bytes ([IO.File]::ReadAllBytes($recordPath)) -Limit 4096)['operation'].GetString() 'task' 'Re-entry rewrote the record.'
        }
        finally { Exit-Dlss5FolderGuard $outer }
        Assert-Dlss5True (-not (Test-Path -LiteralPath $recordPath)) 'The last release left the record.'
        Assert-Dlss5Equal $script:Dlss5GuardHolds.Count 0 'The last release left a hold.'
        # A record that cannot be written is reported, and the operation still holds the guard.
        Remove-Item -LiteralPath (Get-Dlss5StorePath 'guards') -Recurse -Force
        [IO.File]::WriteAllText((Get-Dlss5StorePath 'guards'), 'not a directory')
        $saved = $script:Dlss5Console
        try {
            $script:Dlss5Console = New-Dlss5SubstitutedConsole @()
            $held = Enter-Dlss5FolderGuard -Path $package -Operation 'execute'
            Assert-Dlss5True ($script:Dlss5GuardHolds.ContainsKey($token)) 'A record write failure dropped the hold.'
            Exit-Dlss5FolderGuard $held
            Assert-Dlss5True (($script:Dlss5Console.Output -join "`n").Contains('The guard''s holder details could not be recorded: ')) 'A record write failure was not reported.'
        }
        finally { $script:Dlss5Console = $saved; Remove-Item -LiteralPath (Get-Dlss5StorePath 'guards') -Force }
    }
}

Invoke-Dlss5Case 'guard refusal names a usable holder and reports the details unavailable otherwise' {
    $root = Join-Path $script:ScratchRoot 'guard-records'
    $game = Join-Path $root 'game'
    New-Item -ItemType Directory -Force $game | Out-Null
    $package = Join-Path $game 'DLSS5-ADDER.cmd'
    Invoke-Dlss5WithLocalAppData -Path (Join-Path $root 'localappdata') -Action {
        New-Item -ItemType Directory -Force (Get-Dlss5StorePath) | Out-Null
        $token = Get-Dlss5GuardToken $package
        Assert-Dlss5Equal (Get-Dlss5GuardRefusal $token) $script:GuardUnavailable 'A missing record did not report the details unavailable.'
        $start = [Diagnostics.Process]::GetCurrentProcess().StartTime.ToUniversalTime()
        $local = [datetime]::new($start.Ticks - ($start.Ticks % [TimeSpan]::TicksPerSecond), [DateTimeKind]::Utc).ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)
        foreach ($case in @(@('execute', 'session'), @('task', 'session'), @('diagnose', 'session'), @('update', 'update'), @('adopt', 'bootstrap adoption'), @('package-write', 'package change'))) {
            Write-Dlss5TestGuardRecord $token (New-Dlss5TestGuardFields -Token $token -Operation $case[0])
            Assert-Dlss5Equal (Get-Dlss5GuardRefusal $token) "another DLSS 5 ADDER $($case[1]) is running for this folder (process $PID, started $local). Switch to that window and let it finish, or end process $PID in Task Manager, then try again." "The refusal for operation $($case[0]) is wrong."
        }
        Write-Dlss5TestGuardRecord $token (New-Dlss5TestGuardFields -Token $token -HostKind 'claude')
        Assert-Dlss5True (Get-Dlss5GuardRefusal $token).Contains("started $local, host claude).") 'The refusal did not name the host.'
        $endedInfo = [Diagnostics.ProcessStartInfo]::new('cmd.exe', '/d /c exit 0')
        $endedInfo.UseShellExecute = $false
        $endedInfo.CreateNoWindow = $true
        $ended = [Diagnostics.Process]::Start($endedInfo)
        $ended.WaitForExit()
        $endedStamp = $ended.StartTime.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
        $unusable = [ordered]@{
            'a malformed record' = $null
            'another token' = (New-Dlss5TestGuardFields -Token ('0' * 48))
            'an ended process' = (New-Dlss5TestGuardFields -Token $token -ProcessId $ended.Id -Started $endedStamp)
            'a reused process id' = (New-Dlss5TestGuardFields -Token $token -Started '2000-01-01T00:00:00Z')
            'an unknown operation' = (New-Dlss5TestGuardFields -Token $token -Operation 'arm')
            'an unknown host' = (New-Dlss5TestGuardFields -Token $token -HostKind 'vibe')
        }
        $ended.Dispose()
        foreach ($name in $unusable.Keys) {
            if ($null -eq $unusable[$name]) { [IO.File]::WriteAllText((Get-Dlss5GuardRecordPath $token), '{"schema_version":1') }
            else { Write-Dlss5TestGuardRecord $token $unusable[$name] }
            Assert-Dlss5Equal (Get-Dlss5GuardRefusal $token) $script:GuardUnavailable "A record with $name was used."
        }
        $extra = New-Dlss5TestGuardFields -Token $token
        $extra['more'] = 1
        Write-Dlss5TestGuardRecord $token $extra
        Assert-Dlss5Equal (Get-Dlss5GuardRefusal $token) $script:GuardUnavailable 'A record with an extra field was used.'
    }
}

Invoke-Dlss5Case 'guard ancestor check follows parent processes and fails closed' {
    $root = Join-Path $script:ScratchRoot 'guard-ancestor'
    $game = Join-Path $root 'game'
    New-Item -ItemType Directory -Force $game | Out-Null
    $package = Join-Path $game 'DLSS5-ADDER.cmd'
    Invoke-Dlss5WithLocalAppData -Path (Join-Path $root 'localappdata') -Action {
        New-Item -ItemType Directory -Force (Get-Dlss5StorePath) | Out-Null
        $token = Get-Dlss5GuardToken $package
        $parent = [int](Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $PID").ParentProcessId
        Write-Dlss5TestGuardRecord $token (New-Dlss5TestGuardFields -Token $token -ProcessId $parent)
        Assert-Dlss5True (Test-Dlss5GuardHolderAncestor $token) 'The parent process was not recognized as an ancestor.'
        # The listing is replaced in a child scope only, so the real one is back once the block ends.
        & {
            function Get-Dlss5ProcessTable { throw [InvalidOperationException]::new('listing unavailable') }
            Assert-Dlss5True (-not (Test-Dlss5GuardHolderAncestor $token)) 'An ancestor walk that could not run passed.'
        }
        Write-Dlss5TestGuardRecord $token (New-Dlss5TestGuardFields -Token $token)
        Assert-Dlss5True (-not (Test-Dlss5GuardHolderAncestor $token)) 'The process itself passed as its own ancestor.'
        Remove-Item -LiteralPath (Get-Dlss5GuardRecordPath $token)
        Assert-Dlss5True (-not (Test-Dlss5GuardHolderAncestor $token)) 'A missing record passed as an ancestor.'
    }
}

Invoke-Dlss5Case 'guard refuses every guarded operation while another process holds the folder' {
    $fixture = New-Dlss5IsolatedLaunchFixture -Name 'guard-held' -StubBody @('echo started>"%DLSS5_TEST_STARTED_PATH%"')
    $started = Join-Path $fixture.StubRoot 'started.txt'
    $environment = @{ DLSS5_TEST_STARTED_PATH = $started }
    $status = Get-Dlss5LaunchStatus $fixture
    $launch = { param([string[]]$Arguments) Invoke-Dlss5IsolatedLaunch -Fixture $fixture -Arguments $Arguments -Environment $environment }
    $request = { param([string]$Json) $path = Join-Path $fixture.Root ('request-' + [Guid]::NewGuid().ToString('N') + '.json'); [IO.File]::WriteAllText($path, $Json); $path }
    # The new-package box is due, so both of its choices are refused first, then accepted once the holder is gone.
    $holder = Start-Dlss5GuardHolder -Package $fixture.Updater -LocalAppData $fixture.LocalAppData
    try {
        $before = [IO.File]::ReadAllBytes($fixture.Updater)
        $text = Get-Dlss5HolderText $holder
        foreach ($item in @('--internal-accept', '--internal-keep-disarmed')) {
            $process = & $launch @($item, $status.expect)
            Assert-Dlss5True ($process.ExitCode -eq 8 -and $process.StandardOutput.Contains('Refused: ' + $text)) "$item was not refused naming the holder (exit $($process.ExitCode)): $($process.StandardOutput)"
        }
        Assert-Dlss5True (Test-Dlss5ByteEquality -Left ([IO.File]::ReadAllBytes($fixture.Updater)) -Right $before) 'A refused box choice changed the copy.'
    }
    finally { Stop-Dlss5GuardHolder $holder }
    Assert-Dlss5Equal (& $launch @('--internal-accept', $status.expect)).ExitCode 0 'Accept did not run once the guard was free.'
    $status = Get-Dlss5LaunchStatus $fixture
    $folder = Join-Path $fixture.Root 'absorb'
    New-Item -ItemType Directory -Force $folder | Out-Null
    [IO.File]::WriteAllText((Join-Path $folder 'INSTRUCTIONS.cleanup-boundary.md'), "## Edited`r`n")
    $holder = Start-Dlss5GuardHolder -Package $fixture.Updater -LocalAppData $fixture.LocalAppData
    try {
        $before = [IO.File]::ReadAllBytes($fixture.Updater)
        $text = Get-Dlss5HolderText $holder
        $refusals = [ordered]@{
            'Disarm' = @(@('--internal-disarm', $status.expect), ('Refused: ' + $text))
            'Arm' = @(@('--internal-arm', $status.expect), ('Refused: ' + $text))
            'Execute' = @(@('--internal-execute', $status.expect), ('Execute refused: ' + $text))
            'a command-line task' = @(@('a task'), ('Execute refused: ' + $text))
            'absorb' = @(@('--internal-absorb', $status.expect, $folder), ('Absorb failed; the package and the files are unchanged: ' + $text))
            'a project config write' = @(@('--internal-configure', $status.expect, (& $request '{"action":"set-project","rerun":false}')), ('Refused: ' + $text))
        }
        foreach ($name in $refusals.Keys) {
            $process = & $launch $refusals[$name][0]
            Assert-Dlss5True ($process.ExitCode -eq 8 -and $process.StandardOutput.Contains($refusals[$name][1])) "$name was not refused naming the holder (exit $($process.ExitCode)): $($process.StandardOutput) $($process.StandardError)"
        }
        Assert-Dlss5True (-not (Test-Path -LiteralPath $started)) 'An agent started while another process held the folder.'
        Assert-Dlss5True (Test-Path -LiteralPath (Join-Path $folder 'INSTRUCTIONS.cleanup-boundary.md')) 'A refused absorb removed its file.'
        # Machine config writes, Explode and the status view stay available.
        Assert-Dlss5Equal (& $launch @('--internal-configure', $status.expect, (& $request '{"action":"set-machine","field":"claude.model","value":"opus"}'))).ExitCode 0 'A machine config write was refused while the folder was held.'
        $process = & $launch @('--internal-configure', $status.expect, (& $request '{"action":"bake-seed","fields":["claude.model"]}'))
        Assert-Dlss5True ($process.ExitCode -eq 8 -and $process.StandardOutput.Contains('Refused: ' + $text)) "A seed bake was not refused naming the holder: $($process.StandardOutput)"
        Assert-Dlss5Equal (& $launch @('--internal-explode')).ExitCode 0 'Explode was refused while the folder was held.'
        Assert-Dlss5Equal (& $launch @('--internal-status')).ExitCode 0 'The status view was refused while the folder was held.'
        Assert-Dlss5True (Test-Dlss5ByteEquality -Left ([IO.File]::ReadAllBytes($fixture.Updater)) -Right $before) 'A refused operation changed the copy.'
        # A session in another folder still runs.
        $other = New-Dlss5IsolatedLaunchFixture -Name 'guard-other-folder' -StubBody @('echo started>"%DLSS5_TEST_STARTED_PATH%"')
        $otherStarted = Join-Path $other.StubRoot 'started.txt'
        $null = Invoke-Dlss5IsolatedLaunch -Fixture $other -Environment @{ DLSS5_TEST_STARTED_PATH = $otherStarted }
        Assert-Dlss5True (Test-Path -LiteralPath $otherStarted) 'A session in another folder did not start while this one was held.'
        # Diagnose is guarded too: an empty .git directory is Git metadata git cannot inspect.
        New-Item -ItemType Directory -Force (Join-Path $fixture.Game '.git') | Out-Null
        $process = & $launch @('--internal-diagnose')
        Assert-Dlss5True ($process.ExitCode -eq 8 -and $process.StandardOutput.Contains('Diagnose refused: ' + $text)) "Diagnose was not refused naming the holder: $($process.StandardOutput)"
        Assert-Dlss5True (-not (Test-Path -LiteralPath $started)) 'A diagnosis-only agent started while another process held the folder.'
    }
    finally { Stop-Dlss5GuardHolder $holder }
    $process = & $launch @('--internal-diagnose')
    Assert-Dlss5True (Test-Path -LiteralPath $started) "Diagnose did not start once the guard was free (exit $($process.ExitCode)): $($process.StandardOutput)"
}

Invoke-Dlss5Case 'guard counts an abandoned holder as ended and refuses when the mutex cannot be taken' {
    $fixture = New-Dlss5IsolatedLaunchFixture -Name 'guard-abandoned'
    $holder = Start-Dlss5GuardHolder -Package $fixture.Updater -LocalAppData $fixture.LocalAppData
    Stop-Dlss5GuardHolder $holder -Kill
    Invoke-Dlss5WithLocalAppData -Path $fixture.LocalAppData -Action {
        $token = Enter-Dlss5FolderGuard -Path $fixture.Updater -Operation 'execute'
        try {
            $fields = ConvertFrom-Dlss5JsonObject -Bytes ([IO.File]::ReadAllBytes((Get-Dlss5GuardRecordPath $token))) -Limit 4096
            Assert-Dlss5Equal $fields['pid'].GetInt32() $PID 'The abandoned holder''s record was not overwritten.'
        }
        finally { Exit-Dlss5FolderGuard $token }
        # Another kind of object under the guard's name makes the mutex impossible to create.
        $squatter = [Threading.EventWaitHandle]::new($false, [Threading.EventResetMode]::ManualReset, 'Local\DLSS5-ADDER-GUARD-' + $token)
        try {
            $message = ''
            try { $null = Enter-Dlss5FolderGuard -Path $fixture.Updater -Operation 'package-write' }
            catch [InvalidOperationException] { $message = $_.Exception.Message }
            Assert-Dlss5True $message.StartsWith('the single-instance guard could not be taken: ') "A mutex that could not be created did not refuse: $message"
            Assert-Dlss5Equal $script:Dlss5GuardHolds.Count 0 'A failed acquisition left a hold.'
        }
        finally { $squatter.Dispose() }
    }
}

Invoke-Dlss5Case 'guard Execute holds the folder through the session and releases it on every branch' {
    $variants = [ordered]@{
        'a failed run' = @('{"mission_id":"dlss5","rerun":false}', 3, $false, 3)
        'a rerunnable mission''s run' = @('{"mission_id":"dlss5","rerun":true}', 0, $false, 0)
        'a run followed by the post-run disarm' = @('{"mission_id":"dlss5","rerun":false}', 0, $false, 0)
        'a run whose post-run disarm fails' = @('{"mission_id":"dlss5","rerun":false}', 0, $true, 4)
    }
    foreach ($name in $variants.Keys) {
        $variant = $variants[$name]
        $bytes = New-Dlss5PackageVariant -Bytes (New-Dlss5ProjectVariantBytes -ProjectJson $variant[0]) -State (New-Dlss5StateLines -Armed $true)
        $result = Invoke-Dlss5PackageInteraction -Name ('guard-execute-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)) -Bytes $bytes -Action {
            param($PackagePath)
            $script:Dlss5Console = New-Dlss5SubstitutedConsole @()
            $savedMissionId = Get-Variable -Name Dlss5StartupMissionId -Scope Script -ValueOnly -ErrorAction SilentlyContinue
            $script:Dlss5StartupMissionId = 'dlss5'
            try {
                # The session and its preflight are replaced in this scope, which the call below resolves them from.
                $observed = [pscustomobject]@{ Held = $false }
                $sessionCode = $variant[1]
                function Get-Dlss5LaunchPreflightRefusal { return '' }
                function Invoke-Dlss5GameSession { $observed.Held = $script:Dlss5GuardHolds.Count -eq 1; return $sessionCode }
                if ($variant[2]) { function Set-Dlss5Disarmed { throw [IO.IOException]::new('disarm failed') } }
                $code = Invoke-Dlss5Execute -Path $PackagePath

                return [pscustomobject]@{ Code = $code; Held = $observed.Held; Left = $script:Dlss5GuardHolds.Count; Armed = (Get-Dlss5BootstrapIdentity -Bytes ([IO.File]::ReadAllBytes($PackagePath))).State.Armed }
            }
            finally { $script:Dlss5StartupMissionId = $savedMissionId }
        }
        Assert-Dlss5True $result.Held "Execute did not hold the guard during the session for $name."
        Assert-Dlss5Equal $result.Code $variant[3] "Execute returned the wrong code for $name."
        Assert-Dlss5Equal $result.Left 0 "Execute left the guard held after $name."
        if ($name -ceq 'a run followed by the post-run disarm') { Assert-Dlss5True (-not $result.Armed) 'The post-run disarm did not run under the session''s own hold.' }
    }
}

Invoke-Dlss5Case 'guard menu and Configure questions and absorb are refused before anything is asked' {
    $root = Join-Path $script:ScratchRoot 'guard-menu'
    $bytes = New-Dlss5PackageVariant -Bytes $script:CandidateBytes -State (New-Dlss5StateLines)
    Invoke-Dlss5PackageInteraction -Name 'guard-menu' -Bytes $bytes -Action {
        param($PackagePath, $Game)
        $holder = Start-Dlss5GuardHolder -Package $PackagePath -LocalAppData (Join-Path $root 'localappdata')
        try {
            $text = Get-Dlss5HolderText $holder
            $script:Dlss5Console = New-Dlss5SubstitutedConsole @('a', 'Enter', 'Escape')
            $null = Invoke-Dlss5Menu -Path $PackagePath
            $output = $script:Dlss5Console.Output -join "`n"
            Assert-Dlss5True ($output.Contains($text) -and -not $output.Contains('Arm it?')) "Arm was not refused before its question: $output"
            foreach ($keys in @(@('r'), @('u'), @('t'))) {
                $script:Dlss5Console = New-Dlss5SubstitutedConsole (@('c', 'Enter') + $keys + @('Enter', 'b', 'Enter', 'Escape'))
                $null = Invoke-Dlss5Menu -Path $PackagePath
                $output = $script:Dlss5Console.Output -join "`n"
                Assert-Dlss5True ($output.Contains('Not changed: ' + $text) -and -not $output.Contains('Approval mode (manual refuses on Codex):') -and -not $output.Contains('Rerun:')) "Configure item $keys was not refused before its question: $output"
            }
            $dropped = Join-Path (Split-Path -Parent $Game) 'dropped'
            New-Item -ItemType Directory -Force $dropped | Out-Null
            $file = Join-Path $dropped 'INSTRUCTIONS.cleanup-boundary.md'
            [IO.File]::WriteAllText($file, "## Edited`r`n")
            $script:Dlss5Console = New-Dlss5SubstitutedConsole @('Enter')
            $code = Invoke-Dlss5Absorb -Path $PackagePath -Files @($file)
            $output = $script:Dlss5Console.Output -join "`n"
            Assert-Dlss5True ($code -eq 8 -and $output.Contains('Absorb refused: ' + $text) -and -not $output.Contains('Absorb these files')) "A dropped file was not refused before its question: $output"
            Assert-Dlss5True (Test-Path -LiteralPath $file) 'A refused drop removed the dropped file.'
            # Disarm and the box choices ask nothing, so the package write refuses them directly.
            Assert-Dlss5Throws { $null = Set-Dlss5Disarmed -Path $PackagePath } ([InvalidOperationException]) 'A package write ran while another process held the folder.'
        }
        finally { Stop-Dlss5GuardHolder $holder }
    }
}

Invoke-Dlss5Case 'guard skips a startup update while the folder is held and applies it once free' {
    $root = Join-Path $script:ScratchRoot 'guard-startup-update'
    $game = Join-Path $root 'game'
    New-Item -ItemType Directory -Force $game | Out-Null
    $packagePath = Join-Path $game 'DLSS5-ADDER.cmd'
    [IO.File]::WriteAllBytes($packagePath, $script:CandidateBytes)
    $localAppData = Join-Path $root 'localappdata'
    $store = Join-Path $localAppData 'DLSS5-ADDER'
    New-Item -ItemType Directory -Force $store | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $store 'DLSS5-ADDER.cmd'), $script:CandidateBytes)
    Write-Dlss5MachineTrustFixture -MachineDirectory $store -Whole @{ $script:CandidateVersion = $script:CandidateIdentity.Sha256 } -Engine @{ $script:CandidateVersion = $script:CandidateIdentity.EngineSha256 }
    $null = Write-Dlss5StageFixture -MachineDirectory $store -Bytes (New-Dlss5LaterVersionBytes)
    $reconcile = {
        $priorOut = [Console]::Out
        $output = [IO.StringWriter]::new()
        try {
            [Console]::SetOut($output)
            $result = Invoke-Dlss5WithLocalAppData -Path $localAppData -Action { Invoke-Dlss5StartupReconciliation -Path $packagePath -Executing (Read-Dlss5InstalledBootstrap -Path $packagePath -GamePath) }
        }
        finally { [Console]::SetOut($priorOut) }

        return [pscustomobject]@{ Result = $result; Output = $output.ToString() }
    }
    $holder = Start-Dlss5GuardHolder -Package $packagePath -LocalAppData $localAppData
    try {
        $text = Get-Dlss5HolderText $holder
        $skipped = & $reconcile
        Assert-Dlss5True ($skipped.Output.Contains('The update was not applied: ' + $text) -and $skipped.Output.Contains('The update is applied at a later launch, once that has ended.') -and -not $skipped.Result.Reexecute) "The update was not skipped while the folder was held: $($skipped.Output)"
        Assert-Dlss5True (Test-Dlss5ByteEquality -Left ([IO.File]::ReadAllBytes($packagePath)) -Right $script:CandidateBytes) 'The held game copy was changed.'
    }
    finally { Stop-Dlss5GuardHolder $holder }
    # A guard that cannot be taken skips the update the same way.
    $token = Invoke-Dlss5WithLocalAppData -Path $localAppData -Action { Get-Dlss5GuardToken $packagePath }
    $squatter = [Threading.EventWaitHandle]::new($false, [Threading.EventResetMode]::ManualReset, 'Local\DLSS5-ADDER-GUARD-' + $token)
    try {
        $failed = & $reconcile
        Assert-Dlss5True ($failed.Output.Contains('The update was not applied: the single-instance guard could not be taken: ') -and -not $failed.Result.Reexecute) "A guard failure did not skip the update: $($failed.Output)"
    }
    finally { $squatter.Dispose() }
    $applied = & $reconcile
    Assert-Dlss5True ($applied.Result.Reexecute -and $applied.Output.Contains('DLSS 5 ADDER update: version')) "The update was not applied once the folder was free: $($applied.Output)"
    Assert-Dlss5Equal (Get-Dlss5BootstrapIdentity -Bytes ([IO.File]::ReadAllBytes($packagePath))).Version $script:LaterVersion 'The game copy was not updated.'
    Assert-Dlss5Equal $script:Dlss5GuardHolds.Count 0 'The startup update left the guard held.'
}

Invoke-Dlss5Case 'guard adoption refuses another holder and runs under its ancestor session''s hold' {
    $fixture = New-Dlss5IsolatedLaunchFixture -Name 'guard-adoption'
    $null = Get-Dlss5LaunchStatus $fixture
    $later = New-Dlss5LaterVersionBytes
    $laterIdentity = Get-Dlss5BootstrapIdentity -Bytes $later
    $candidateDirectory = Join-Path $fixture.MachineDirectory 'development'
    New-Item -ItemType Directory -Force $candidateDirectory | Out-Null
    $candidate = Join-Path $candidateDirectory 'DLSS5-ADDER.candidate.cmd'
    [IO.File]::WriteAllBytes($candidate, $later)
    $arguments = '/d /c ""' + $candidate + '" --internal-adopt-bootstrap "' + $fixture.Updater + '" ' + $laterIdentity.Sha256 + '"'
    $adopt = {
        $info = [Diagnostics.ProcessStartInfo]::new('cmd.exe', $arguments)
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        $info.WorkingDirectory = $fixture.Game
        $info.Environment['LOCALAPPDATA'] = $fixture.LocalAppData
        $process = [Diagnostics.Process]::Start($info)
        $out = $process.StandardOutput.ReadToEndAsync()
        $err = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(120000)) { $process.Kill($true); throw 'Adoption did not exit.' }

        return [pscustomobject]@{ Code = $process.ExitCode; Out = $out.GetAwaiter().GetResult(); Err = $err.GetAwaiter().GetResult() }
    }
    $before = [IO.File]::ReadAllBytes($fixture.Updater)
    $holder = Start-Dlss5GuardHolder -Package $fixture.Updater -LocalAppData $fixture.LocalAppData
    try {
        $result = & $adopt
        Assert-Dlss5True ($result.Code -eq 6 -and $result.Err.Contains('Refused: ' + (Get-Dlss5HolderText $holder))) "Adoption under another holder was not refused with exit 6: $($result.Code) $($result.Err)"
        Assert-Dlss5True (-not $result.Err.Contains('run it again after that session ends')) 'A usable holder record still got the run-again remedy.'
    }
    finally { Stop-Dlss5GuardHolder $holder }
    $holder = Start-Dlss5GuardHolder -Package $fixture.Updater -LocalAppData $fixture.LocalAppData -NoRecord
    try {
        $result = & $adopt
        Assert-Dlss5True ($result.Code -eq 6 -and $result.Err.Contains('Refused: ' + $script:GuardUnavailable + ' If this adoption was approved inside the session that holds this folder, run it again after that session ends.')) "Adoption under a holder without a record did not refuse with the remedy: $($result.Code) $($result.Err)"
    }
    finally { Stop-Dlss5GuardHolder $holder }
    Assert-Dlss5True (Test-Dlss5ByteEquality -Left ([IO.File]::ReadAllBytes($fixture.Updater)) -Right $before) 'A refused adoption changed the copy.'
    $holder = Start-Dlss5GuardHolder -Package $fixture.Updater -LocalAppData $fixture.LocalAppData -ChildArguments $arguments
    try {
        $child = ConvertFrom-Json ([IO.File]::ReadAllText($holder.Result))
        Assert-Dlss5Equal ([int]$child.code) 0 "Adoption inside the holding session failed: $($child.out) $($child.err)"
        Assert-Dlss5Equal (Get-Dlss5BootstrapIdentity -Bytes ([IO.File]::ReadAllBytes($fixture.Updater))).Version $script:LaterVersion 'Adoption inside the holding session did not update the copy.'
        $record = Invoke-Dlss5WithLocalAppData -Path $fixture.LocalAppData -Action { ConvertFrom-Dlss5JsonObject -Bytes ([IO.File]::ReadAllBytes((Get-Dlss5GuardRecordPath (Get-Dlss5GuardToken $fixture.Updater)))) -Limit 4096 }
        Assert-Dlss5Equal $record['pid'].GetInt32() $holder.ProcessId 'Adoption under its ancestor''s hold changed the ancestor''s record.'
    }
    finally { Stop-Dlss5GuardHolder $holder }
}

Invoke-Dlss5Case 'guard menu Execute, Diagnose and the seed items are refused while another process holds the folder' {
    $seed = [Text.UTF8Encoding]::new($false).GetBytes('{"schema_version":1,"claude":{"model":"opus"}}' + "`r`n")
    $bytes = New-Dlss5PackageVariant -Bytes $script:CandidateBytes -Files ([ordered]@{ 'SEED.json' = $seed }) -State (New-Dlss5StateLines -Armed $true)
    $root = Join-Path $script:ScratchRoot 'guard-menu-session'
    Invoke-Dlss5PackageInteraction -Name 'guard-menu-session' -Bytes $bytes -Action {
        param($PackagePath)
        $holder = Start-Dlss5GuardHolder -Package $PackagePath -LocalAppData (Join-Path $root 'localappdata')
        try {
            $text = Get-Dlss5HolderText $holder
            $script:Dlss5Console = New-Dlss5SubstitutedConsole @('e', 'Enter')
            $code = Invoke-Dlss5Menu -Path $PackagePath
            $output = $script:Dlss5Console.Output -join "`n"
            Assert-Dlss5True ($code -eq 8 -and $output.Contains('Execute refused: ' + $text)) "The menu's Execute was not refused naming the holder (exit $code): $output"
            # A machine config field gives the seed bake something to offer, so only the probe can stop it.
            $null = Set-Dlss5MachineField -Field 'claude.model' -Value 'opus'
            foreach ($item in @(@('s', 'Fields to bake into the seed'), @('d', 'Remove the seed from this package?'))) {
                $script:Dlss5Console = New-Dlss5SubstitutedConsole @('c', 'Enter', $item[0], 'Enter', 'b', 'Enter', 'Escape')
                $null = Invoke-Dlss5Menu -Path $PackagePath
                $output = $script:Dlss5Console.Output -join "`n"
                Assert-Dlss5True ($output.Contains('Not changed: ' + $text) -and -not $output.Contains($item[1])) "Configure seed item $($item[0]) was not refused before its question: $output"
            }
            $request = Join-Path $root 'remove-seed.json'
            [IO.File]::WriteAllText($request, '{"action":"remove-seed"}')
            $script:Dlss5Console = New-Dlss5SubstitutedConsole @()
            $identity = $script:Dlss5ExecutingIdentity
            $code = Invoke-Dlss5PackageItem -Path $PackagePath -Request ([pscustomobject]@{ Item = '--internal-configure'; Expect = (ConvertFrom-Dlss5ExpectationToken (Get-Dlss5ExpectationToken $identity)); Folder = $request })
            $output = $script:Dlss5Console.Output -join "`n"
            Assert-Dlss5True ($code -eq 8 -and $output.Contains('Refused: ' + $text)) "A headless seed removal was not refused naming the holder (exit $code): $output"
            Assert-Dlss5True (Get-Dlss5BootstrapIdentity -Bytes ([IO.File]::ReadAllBytes($PackagePath))).MissionFiles.Contains('SEED.json') 'A refused seed removal removed the seed.'
            $script:Dlss5Startup = [pscustomobject]@{ Diagnosis = [pscustomobject]@{ Reason = 'git-unavailable'; Evidence = 'fixture' } }
            $script:Dlss5Console = New-Dlss5SubstitutedConsole @('d', 'Enter')
            $code = Invoke-Dlss5Menu -Path $PackagePath
            $output = $script:Dlss5Console.Output -join "`n"
            Assert-Dlss5True ($code -eq 8 -and $output.Contains('Diagnose refused: ' + $text)) "The menu's Diagnose was not refused naming the holder (exit $code): $output"
        }
        finally { Stop-Dlss5GuardHolder $holder }
    }
}
