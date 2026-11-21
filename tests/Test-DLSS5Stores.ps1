# Loaded by the release suite after the guard cases: the engine store cases added in v53.
if ($null -eq (Get-Command Get-Dlss5LocationIdentity -ErrorAction SilentlyContinue)) {
    $script:Failures.Add('FAIL store cases: the updater under test has no engine store')
    return
}

function Get-Dlss5TestLocationFolderName {
    param([Parameter(Mandatory=$true)][string]$Path)

    # The record folder name the design gives a location path: every run of characters outside [A-Za-z0-9] as one hyphen, at most 80
    # characters, then a hyphen and the first 16 hex characters of the SHA-256 of the upper-cased path.
    $hash = (Get-Sha256Text -Text $Path.ToUpperInvariant()).Substring(0, 16)
    $encoded = [regex]::Replace($Path, '[^A-Za-z0-9]+', '-')
    if ($encoded.Length -gt 80) { $encoded = $encoded.Substring(0, 80) }

    return $encoded + '-' + $hash
}

function Write-Dlss5TestLocationRecord {
    param([Parameter(Mandatory=$true)][string]$LocationPath, [hashtable]$Fields = @{}, [string]$FolderName = '')

    # Writes a record straight into the current store, as an earlier session at that location would have, and returns its folder.
    if ($FolderName.Length -eq 0) { $FolderName = Get-Dlss5TestLocationFolderName $LocationPath }
    $folder = Join-Path (Get-Dlss5LocationsDirectory) $FolderName
    New-Item -ItemType Directory -Force $folder | Out-Null
    $notes = New-Dlss5LocationNotes
    $notes['location_path'] = $LocationPath
    foreach ($key in $Fields.Keys) { $notes[$key] = [string]$Fields[$key] }
    Write-Dlss5LocationNotes -Path (Join-Path $folder 'LOCATION.md') -Notes $notes

    return $folder
}

function Write-Dlss5TestStoreNotes {
    param([Parameter(Mandatory=$true)][Collections.IDictionary]$Notes, [switch]$Machine)

    # Writes the engine file, or the machine notes, of the current store directly, as an earlier release or a test fixture would.
    $path = if ($Machine) { Get-Dlss5StorePath 'DLSS5_MACHINE_NOTES.md' } else { Get-Dlss5EngineFilePath }
    New-Item -ItemType Directory -Force (Split-Path -Parent $path) | Out-Null
    if (-not $Notes.Contains('schema_version')) { $Notes['schema_version'] = '1' }
    $text = if ($Machine) { ConvertTo-Dlss5NotesDocument -Notes $Notes -BeginMarker $MachineNotesBeginMarker -EndMarker $MachineNotesEndMarker -KnownOrder $MachineNotesOrder }
    else { ConvertTo-Dlss5NotesDocument -Notes $Notes -BeginMarker $EngineBeginMarker -EndMarker $EngineEndMarker -KnownOrder $EngineFileOrder }
    [IO.File]::WriteAllText($path, $text, [Text.UTF8Encoding]::new($false))

    return $path
}

function Read-Dlss5TestStoreNotes {
    param([switch]$Machine)

    if ($Machine) { return Read-Dlss5NotesFile -Path (Get-Dlss5StorePath 'DLSS5_MACHINE_NOTES.md') -BeginMarker $MachineNotesBeginMarker -EndMarker $MachineNotesEndMarker }

    return Read-Dlss5NotesFile -Path (Get-Dlss5EngineFilePath) -BeginMarker $EngineBeginMarker -EndMarker $EngineEndMarker
}

function Invoke-Dlss5StoreCase {
    param([Parameter(Mandatory=$true)][string]$Name, [Parameter(Mandatory=$true)][scriptblock]$Body, [string]$GameRoot = '')

    # An isolated store and a game folder holding the candidate, for cases that call the store functions in this process.
    $root = Join-Path $script:ScratchRoot $Name
    $gameParent = if ($GameRoot.Length -gt 0) { $GameRoot } else { $root }
    $game = Join-Path $gameParent 'Store Game'
    New-Item -ItemType Directory -Force (Join-Path $game 'bin') | Out-Null
    [IO.File]::WriteAllBytes((Join-Path (Join-Path $game 'bin') 'game.exe'), [byte[]](1))
    $package = Join-Path $game 'DLSS5-ADDER.cmd'
    [IO.File]::WriteAllBytes($package, $script:CandidateBytes)
    $storeBody = $Body

    return Invoke-Dlss5WithLocalAppData -Path (Join-Path $root 'localappdata') -Action {
        New-Item -ItemType Directory -Force (Get-Dlss5StorePath) | Out-Null
        & $storeBody ([pscustomobject]@{ Root = $root; Game = $game; Package = $package })
    }
}

function Invoke-Dlss5TestLocationStep {
    param([Parameter(Mandatory=$true)][string]$Package, [AllowNull()][Collections.IDictionary]$GameNotes = $null)

    # The session's read-only location checks and its migration step for the record, as a DLSS session runs them.
    $location = Get-Dlss5LocationIdentity -PackagePath $Package
    $identity = Get-GameIdentity -Dir (Split-Path -Parent $Package)
    $plan = Get-Dlss5SessionLocationPlan -Location $location -GameIdentity $identity -GameNotes $GameNotes -GameNotesPath (Join-Path (Split-Path -Parent $Package) 'DLSS5-ADDER.md')
    $result = Update-Dlss5SessionLocationRecord -Location $location -GameIdentity $identity -Plan $plan -Timestamp ((Get-Date).ToString('o'))

    return [pscustomobject]@{ Location = $location; Identity = $identity; Plan = $plan; Result = $result }
}

function Get-Dlss5FixtureLocation {
    param([Parameter(Mandatory=$true)]$Fixture)

    return Invoke-Dlss5WithLocalAppData -Path $Fixture.LocalAppData -Action { Get-Dlss5LocationIdentity -PackagePath $Fixture.Updater }
}

function Get-Dlss5FixtureStoreState {
    param([Parameter(Mandatory=$true)]$Fixture)

    # Every store file outside the per-launch folders, and the game notes, by hash, so a refused session can be shown to have written nothing.
    $lines = [Collections.Generic.List[string]]::new()
    if (Test-Path -LiteralPath $Fixture.MachineDirectory) {
        foreach ($file in @(Get-ChildItem -LiteralPath $Fixture.MachineDirectory -Recurse -File -Force | Where-Object { $_.FullName -notmatch 'guards|sessions|updates|prompts|snapshots' } | Sort-Object FullName)) {
            $lines.Add($file.FullName + '=' + (Get-FileHash -LiteralPath $file.FullName).Hash)
        }
    }
    if (Test-Path -LiteralPath $Fixture.GameNotesPath) { $lines.Add('game notes=' + (Get-FileHash -LiteralPath $Fixture.GameNotesPath).Hash) }

    return $lines -join '|'
}

function Read-Dlss5PromptCapture {
    param([Parameter(Mandatory=$true)][string]$Path)

    Assert-Dlss5True (Test-Path -LiteralPath $Path -PathType Leaf) 'The agent stub did not capture the generated prompt.'

    return [IO.File]::ReadAllText($Path, [Text.UTF8Encoding]::new($false, $true))
}

function Invoke-Dlss5LocationChannel {
    param([Parameter(Mandatory=$true)]$Fixture, [Parameter(Mandatory=$true)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Arguments)

    return Invoke-Dlss5ProcessWithInput -FilePath 'cmd.exe' -Arguments (@('/d', '/c', $Fixture.Updater, '--internal-location-set') + $Arguments) -InputLines @() -WorkingDirectory $Fixture.Game -Environment @{ LOCALAPPDATA = $Fixture.LocalAppData }
}

$script:StorePromptStubLine = 'copy /b "%LOCALAPPDATA%\DLSS5-ADDER\prompts\dlss5-agent-prompt-*.md" "%DLSS5_TEST_PROMPT_CAPTURE_PATH%" >nul'

Invoke-Dlss5Case 'store engine file and location record round trip' {
    Invoke-Dlss5StoreCase -Name 'store-round-trip' -Body {
        param($Case)
        $trust = New-Dlss5TrustFixture -Whole @{ $script:CandidateVersion = ('a' * 64) } -Engine @{ $script:CandidateVersion = ('b' * 64) }
        $lock = Enter-Dlss5BootstrapLock
        try {
            $notes = $trust.Notes
            $notes['gpu'] = 'Fixture GPU'
            $notes['display.desk.alias'] = 'Desk'
            Write-Dlss5EngineFileNotes -Notes $notes -Current (Read-Dlss5EngineFile)
        }
        finally { Exit-Dlss5BootstrapLock $lock }
        $engine = Read-Dlss5EngineFile
        Assert-Dlss5Equal $engine.Notes['gpu'] 'Fixture GPU' 'The engine file lost a hardware fact.'
        Assert-Dlss5Equal $engine.Trust.EngineEntries[[int]$script:CandidateVersion] ('b' * 64) 'The engine file lost its engine entry.'
        $text = [IO.File]::ReadAllText((Get-Dlss5EngineFilePath))
        Assert-Dlss5Equal $text (ConvertTo-Dlss5NotesDocument -Notes $engine.Notes -BeginMarker $EngineBeginMarker -EndMarker $EngineEndMarker -KnownOrder $EngineFileOrder) 'The engine file did not round trip byte for byte.'
        Assert-Dlss5True $text.StartsWith($EngineBeginMarker + "`r`n### schema_version: 1`r`n### bootstrap_highest_version_seen: ", [StringComparison]::Ordinal) 'The engine file does not open with its marker, schema and trust records.'
        $step = Invoke-Dlss5TestLocationStep -Package $Case.Package
        Assert-Dlss5True $step.Result.Created 'The first session did not create the location record.'
        $state = Get-Dlss5LocationState -Location $step.Location
        $lines = @([IO.File]::ReadAllLines($state.RecordPath))
        Assert-Dlss5Equal $lines[0] $LocationBeginMarker 'The location record does not open with its marker.'
        Assert-Dlss5Equal (@($lines[1..($lines.Count - 2)] | ForEach-Object { $_.Substring(4, $_.IndexOf(':') - 4) }) -join ',') ($LocationRecordOrder -join ',') 'The location record does not hold exactly its key set in order.'
        Assert-Dlss5Equal $state.Record.Notes['location_path'] $step.Location.Path 'The record does not name its location.'
        Assert-Dlss5Equal $state.Record.Notes['folder_token'] (Get-Dlss5GuardToken $Case.Package) 'The record does not carry the guard token of its folder.'
        Assert-Dlss5Equal $state.Record.Notes['game_fingerprint'] $step.Identity.Fingerprint 'The record does not carry the computed fingerprint.'
        Assert-Dlss5Equal $state.Record.Notes['game_name'] 'Store Game' 'The record does not carry the game name.'
        Assert-Dlss5Equal $state.Record.Notes['session_status'] 'new_game_detected' 'A new record was not marked new_game_detected.'
        $again = Invoke-Dlss5TestLocationStep -Package $Case.Package
        Assert-Dlss5True (-not $again.Result.Created) 'A second session created another record.'
        Assert-Dlss5Equal @(Get-Dlss5LocationFolders).Count 1 'A second session left more than one location folder.'
    }
}

Invoke-Dlss5Case 'store location naming, collision refusal, and junction and case variants giving one record' {
    Invoke-Dlss5StoreCase -Name 'store-naming' -Body {
        param($Case)
        $location = Get-Dlss5LocationIdentity -PackagePath $Case.Package
        Assert-Dlss5Equal $location.Path ([IO.Path]::GetFullPath($Case.Game)) 'The location path is not the folder''s final path.'
        Assert-Dlss5Equal $location.FolderName (Get-Dlss5TestLocationFolderName $location.Path) 'The record folder name does not follow the encoding.'
        Assert-Dlss5True ($location.FolderName -cmatch '\A[A-Za-z0-9-]{1,80}-[0-9a-f]{16}\z') "The record folder name has the wrong form: $($location.FolderName)"
        Assert-Dlss5Equal (Get-Dlss5LocationIdentity -PackagePath ($Case.Package.ToUpperInvariant())).Hash $location.Hash 'A case variant of the path gave another location.'
        Assert-Dlss5Equal (Get-Dlss5LocationIdentity -PackagePath ($Case.Package.ToUpperInvariant())).Path $location.Path 'A case variant of the path did not resolve to the folder''s own spelling.'
        $junction = Join-Path $Case.Root 'Junction'
        New-Item -ItemType Junction -Path $junction -Target $Case.Game | Out-Null
        try {
            $through = Get-Dlss5LocationIdentity -PackagePath (Join-Path $junction 'DLSS5-ADDER.cmd')
            Assert-Dlss5True ($through.Path -ceq $location.Path -and $through.Hash -ceq $location.Hash) 'A junction to the folder gave another location.'
        }
        finally { Remove-Item -LiteralPath $junction -Force }
        $message = ''
        try { $null = Get-Dlss5LocationIdentity -PackagePath (Join-Path (Join-Path $Case.Root 'Absent') 'DLSS5-ADDER.cmd') }
        catch [InvalidOperationException] { $message = $_.Exception.Message }
        Assert-Dlss5True $message.StartsWith('the location of ', [StringComparison]::Ordinal) "A folder that cannot be opened did not refuse: $message"
        # Another folder's record under this location's name refuses the session and is left as it is.
        $folder = Write-Dlss5TestLocationRecord -LocationPath 'C:\Elsewhere\Other Game' -FolderName $location.FolderName -Fields @{ game_fingerprint = (Get-GameIdentity -Dir $Case.Game).Fingerprint }
        $before = [IO.File]::ReadAllBytes((Join-Path $folder 'LOCATION.md'))
        $message = ''
        try { $null = Invoke-Dlss5TestLocationStep -Package $Case.Package }
        catch [IO.InvalidDataException] { $message = $_.Exception.Message }
        Assert-Dlss5True ($message.Contains('belongs to C:\Elsewhere\Other Game') -and $message.Contains('Nothing was written')) "A collision did not refuse the session: $message"
        Assert-Dlss5True (Test-Dlss5ByteEquality -Left ([IO.File]::ReadAllBytes((Join-Path $folder 'LOCATION.md'))) -Right $before) 'A collision changed the other folder''s record.'
        Assert-Dlss5Equal @(Get-Dlss5LocationFolders).Count 1 'A collision created another record.'
    }
    # A long path keeps only the first 80 characters of its encoding.
    $long = 'C:\' + ('Long Folder Name ' * 8) + 'End'
    $name = Get-Dlss5TestLocationFolderName $long
    Assert-Dlss5Equal $name.Length (80 + 17) 'A long location path was not cut at 80 characters.'
}

Invoke-Dlss5Case 'store case-only rename keeps the same record, with and without a marker, and completes after a crash' {
    # A short game path keeps the case change inside the 80-character encoding, so the folder itself is renamed.
    $temp = Join-Path ([IO.Path]::GetTempPath()) ('D5S-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force $temp | Out-Null
    try {
        foreach ($marker in @('stage 1: before copy', '')) {
            Invoke-Dlss5StoreCase -Name ('store-case-' + [Guid]::NewGuid().ToString('N').Substring(0, 6)) -GameRoot (Join-Path $temp ([Guid]::NewGuid().ToString('N').Substring(0, 6))) -Body {
                param($Case)
                $first = Invoke-Dlss5TestLocationStep -Package $Case.Package
                $savedMarker = $marker
                if ($savedMarker.Length -gt 0) { $null = Update-Dlss5LocationRecord -Location $first.Location -Change { param($recordNotes) $recordNotes['transaction_status'] = $savedMarker } }
                $renamed = Join-Path (Split-Path -Parent $Case.Game) 'STORE GAME'
                [IO.Directory]::Move($Case.Game, $renamed)
                $package = Join-Path $renamed 'DLSS5-ADDER.cmd'
                $location = Get-Dlss5LocationIdentity -PackagePath $package
                Assert-Dlss5True ($location.Hash -ceq $first.Location.Hash -and $location.Path -cne $first.Location.Path -and $location.FolderName -cne $first.Location.FolderName) 'The case-only rename did not change the path and encoding while keeping the hash.'
                $second = Invoke-Dlss5TestLocationStep -Package $package
                Assert-Dlss5True (-not $second.Result.Created) 'A case-only rename created a fresh record.'
                $folders = @(Get-Dlss5LocationFolders)
                Assert-Dlss5True ($folders.Count -eq 1 -and $folders[0].Name -ceq $location.FolderName) "The record folder was not renamed to the current encoding: $($folders.Name -join ', ')"
                $record = (Get-Dlss5LocationState -Location $location).Record.Notes
                Assert-Dlss5Equal $record['location_path'] $location.Path 'location_path was not updated after the case-only rename.'
                Assert-Dlss5Equal $record['transaction_status'] $savedMarker 'The marker did not survive the case-only rename.'
                # A crash after the folder rename and before the update leaves the old location_path; the next session completes it.
                [IO.Directory]::Move($renamed, $Case.Game)
                $restored = Get-Dlss5LocationIdentity -PackagePath $Case.Package
                [IO.Directory]::Move($folders[0].Path, (Join-Path (Get-Dlss5LocationsDirectory) $restored.FolderName))
                $third = Invoke-Dlss5TestLocationStep -Package $Case.Package
                $record = (Get-Dlss5LocationState -Location $restored).Record.Notes
                Assert-Dlss5True (-not $third.Result.Created -and $record['location_path'] -ceq $restored.Path -and $record['transaction_status'] -ceq $savedMarker) 'A crash between the folder rename and the location_path update was not completed.'
            }
        }
    }
    finally { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
    # Beyond the 80-character encoding a case change leaves the folder name alone, and only location_path follows.
    Invoke-Dlss5StoreCase -Name 'store-case-long' -Body {
        param($Case)
        $first = Invoke-Dlss5TestLocationStep -Package $Case.Package
        Assert-Dlss5True ($first.Location.Path.Length -gt 80) 'The scratch path is too short for the long case.'
        $renamed = Join-Path (Split-Path -Parent $Case.Game) 'store game'
        [IO.Directory]::Move($Case.Game, $renamed)
        $location = Get-Dlss5LocationIdentity -PackagePath (Join-Path $renamed 'DLSS5-ADDER.cmd')
        Assert-Dlss5Equal $location.FolderName $first.Location.FolderName 'A case change beyond 80 characters changed the encoding.'
        $null = Invoke-Dlss5TestLocationStep -Package (Join-Path $renamed 'DLSS5-ADDER.cmd')
        Assert-Dlss5Equal (Get-Dlss5LocationState -Location $location).Record.Notes['location_path'] $location.Path 'A case change beyond 80 characters did not update location_path.'
        Assert-Dlss5Equal @(Get-Dlss5LocationFolders).Count 1 'A case change beyond 80 characters left another record.'
    }
}

Invoke-Dlss5Case 'store unreadable location folder or final path refuses the session with no session write' {
    Invoke-Dlss5StoreCase -Name 'store-final-path' -Body {
        param($Case)
        $saved = @{ Console = $script:Dlss5Console; Prompt = $script:Dlss5UserPrompt }
        $observed = [pscustomobject]@{ Ran = $false }
        try {
            $script:Dlss5Console = New-Dlss5SubstitutedConsole @()
            function Get-Dlss5FolderFinalPath { throw [ComponentModel.Win32Exception]::new(5) }
            function Invoke-Dlss5Updater { $observed.Ran = $true }
            $code = Invoke-Dlss5GameSession -SelfPath $Case.Package
            $output = $script:Dlss5Console.Output -join "`n"
        }
        finally { $script:Dlss5Console = $saved.Console; $script:Dlss5UserPrompt = $saved.Prompt }
        Assert-Dlss5Equal $code $script:Dlss5RefusedExitCode 'A folder whose final path cannot be read did not refuse the session.'
        Assert-Dlss5True ($output.Contains('Refused: the location of ' + $Case.Game + ' could not be identified') -and $output.Contains('Nothing was written.')) "The refusal did not name the folder: $output"
        Assert-Dlss5True (-not $observed.Ran) 'The session ran without its location identity.'
        Assert-Dlss5Equal (Test-Path -LiteralPath (Get-Dlss5StorePath 'engine')) $false 'A refused session wrote into the engine store.'
        Assert-Dlss5Equal (Test-Path -LiteralPath (Join-Path $Case.Game 'DLSS5-ADDER.md')) $false 'A refused session wrote game notes.'
    }
}

Invoke-Dlss5Case 'store command-line task under the diagnosis condition is a task session' {
    $fixture = New-Dlss5IsolatedLaunchFixture -Name 'store-diagnosis-task' -StubBody @($script:StorePromptStubLine)
    $null = Get-Dlss5LaunchStatus $fixture
    New-Item -ItemType Directory -Force (Join-Path $fixture.Game '.git') | Out-Null
    $capture = Join-Path $fixture.StubRoot 'prompt.txt'
    $process = Invoke-Dlss5IsolatedLaunch -Fixture $fixture -Arguments @('check where git went') -Environment @{ PATH = (Get-Dlss5PathWithoutGit); DLSS5_TEST_PROMPT_CAPTURE_PATH = $capture }
    Assert-Dlss5Equal $process.ExitCode 0 "The diagnosis task failed: $($process.StandardOutput) $($process.StandardError)"
    $prompt = Read-Dlss5PromptCapture $capture
    Assert-Dlss5True ($prompt.Contains('This is a DIAGNOSIS-ONLY session.') -and $prompt.Contains('check where git went')) 'The task did not run as the diagnosis-only session.'
    Assert-Dlss5True ([regex]::IsMatch($prompt, '(?m)^legacy_transaction_status: none\r?$')) 'The diagnosis task prompt did not state the leftover marker line.'
    Assert-Dlss5Equal (Test-Path -LiteralPath $fixture.GameNotesPath) $false 'A task session under the diagnosis condition created game notes.'
    $record = Get-Dlss5FixtureLocationRecord $fixture
    Assert-Dlss5Equal $record['session_status'] 'agent_session_ended' 'The diagnosis task did not record its session status.'
    Assert-Dlss5Equal $record['display_check'] '' 'A task session ran the display check.'
}

Invoke-Dlss5Case 'store last_checked advances at launch and at session end' {
    $fixture = New-Dlss5IsolatedLaunchFixture -Name 'store-last-checked' -StubBody @('copy /b "%DLSS5_TEST_RECORD%" "%DLSS5_TEST_CAPTURE%" >nul')
    $location = Get-Dlss5FixtureLocation $fixture
    $capture = Join-Path $fixture.StubRoot 'record.md'
    $start = [DateTimeOffset]::Now
    $null = Invoke-Dlss5IsolatedLaunch -Fixture $fixture -Environment @{ DLSS5_TEST_RECORD = $location.RecordPath; DLSS5_TEST_CAPTURE = $capture }
    Assert-Dlss5True (Test-Path -LiteralPath $capture -PathType Leaf) 'The agent stub did not capture the location record.'
    $during = Read-Dlss5NotesFile -Path $capture -BeginMarker $LocationBeginMarker -EndMarker $LocationEndMarker
    $after = Get-Dlss5FixtureLocationRecord $fixture
    Assert-Dlss5Equal $during['session_status'] 'agent_session_started' 'The launch did not record agent_session_started.'
    $launch = [DateTimeOffset]::Parse($during['last_checked'], [Globalization.CultureInfo]::InvariantCulture)
    $end = [DateTimeOffset]::Parse($after['last_checked'], [Globalization.CultureInfo]::InvariantCulture)
    Assert-Dlss5True ($launch -ge $start.AddSeconds(-1) -and $end -gt $launch) "last_checked did not advance at launch and again at session end: $start, $launch, $end"
}

Invoke-Dlss5Case 'store lock order, timeouts and abandoned mutexes fail closed' {
    Invoke-Dlss5StoreCase -Name 'store-locks' -Body {
        param($Case)
        Assert-Dlss5Throws { Write-Dlss5EngineFileNotes -Notes (New-Dlss5TrustFixture).Notes -Current (Read-Dlss5EngineFile) } ([InvalidOperationException]) 'An engine file write ran without the bootstrap lock.'
        Assert-Dlss5Throws { Sync-Dlss5TrustStores } ([InvalidOperationException]) 'Trust reconciliation ran without the bootstrap lock.'
        $step = Invoke-Dlss5TestLocationStep -Package $Case.Package
        $recordPath = (Get-Dlss5LocationState -Location $step.Location).RecordPath
        $before = [IO.File]::ReadAllBytes($recordPath)
        $mutexName = 'Local\DLSS5-ADDER-LOCATION-' + $step.Location.Hash
        # The location mutex held by another process times out and writes nothing.
        $ready = Join-Path $Case.Root 'mutex-ready'
        $helper = Join-Path $Case.Root 'hold-mutex.ps1'
        [IO.File]::WriteAllText($helper, "param([string]`$MutexName, [string]`$ReadyPath)`r`n`$mutex = [Threading.Mutex]::new(`$false, `$MutexName)`r`n[void]`$mutex.WaitOne()`r`n[IO.File]::WriteAllText(`$ReadyPath, 'ready')`r`nStart-Sleep -Seconds 4`r`n`$mutex.ReleaseMutex()`r`n", [Text.UTF8Encoding]::new($false))
        $info = [Diagnostics.ProcessStartInfo]::new('pwsh')
        foreach ($argument in @('-NoProfile', '-File', $helper, '-MutexName', $mutexName, '-ReadyPath', $ready)) { $info.ArgumentList.Add($argument) }
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        $holder = [Diagnostics.Process]::Start($info)
        $savedTimeout = $script:Dlss5LocationMutexTimeout
        try {
            $timer = [Diagnostics.Stopwatch]::StartNew()
            while (-not (Test-Path -LiteralPath $ready) -and $timer.Elapsed.TotalSeconds -lt 30) { Start-Sleep -Milliseconds 25 }
            Assert-Dlss5True (Test-Path -LiteralPath $ready) 'The mutex holder did not become ready.'
            $script:Dlss5LocationMutexTimeout = [TimeSpan]::FromMilliseconds(200)
            Assert-Dlss5Throws { $null = Update-Dlss5LocationRecord -Location $step.Location -Change { param($recordNotes) $recordNotes['transaction_status'] = 'late' } } ([TimeoutException]) 'A held location mutex did not time out.'
        }
        finally {
            $script:Dlss5LocationMutexTimeout = $savedTimeout
            if (-not $holder.HasExited) { $holder.Kill($true) }
            $holder.WaitForExit()
            $holder.Dispose()
        }
        Assert-Dlss5True (Test-Dlss5ByteEquality -Left ([IO.File]::ReadAllBytes($recordPath)) -Right $before) 'A timed-out write changed the record.'
        # An abandoned location mutex fails closed.
        if ($null -eq ('Dlss5StoreAbandonedMutex' -as [type])) {
            Add-Type -TypeDefinition @'
using System.Collections.Generic;
using System.Threading;

public static class Dlss5StoreAbandonedMutex
{
    private static readonly List<Mutex> Mutexes = new List<Mutex>();

    public static void Create(string name)
    {
        Thread thread = new Thread(() =>
        {
            Mutex mutex = new Mutex(false, name);
            lock (Mutexes)
            {
                Mutexes.Add(mutex);
            }
            mutex.WaitOne();
        });
        thread.Start();
        thread.Join();
    }

    public static void DisposeAll()
    {
        lock (Mutexes)
        {
            foreach (Mutex mutex in Mutexes)
            {
                mutex.Dispose();
            }
            Mutexes.Clear();
        }
    }
}
'@
        }
        [Dlss5StoreAbandonedMutex]::Create($mutexName)
        try { Assert-Dlss5Throws { $null = Update-Dlss5LocationRecord -Location $step.Location -Change { param($recordNotes) $recordNotes['transaction_status'] = 'late' } } ([IO.InvalidDataException]) 'An abandoned location mutex was accepted.' }
        finally { [Dlss5StoreAbandonedMutex]::DisposeAll() }
        Assert-Dlss5True (Test-Dlss5ByteEquality -Left ([IO.File]::ReadAllBytes($recordPath)) -Right $before) 'An abandoned mutex let a write through.'
        # A removal waits for the bootstrap lock, fails closed when it cannot be taken, and keeps the record.
        $orphan = Write-Dlss5TestLocationRecord -LocationPath 'C:\Gone\Locked Game' -Fields @{ game_fingerprint = ('c' * 64); folder_token = ('d' * 48) }
        $listed = @((Get-Dlss5LocationOrphans -Folders @(Get-Dlss5LocationFolders) -ExcludeHash $step.Location.Hash).Orphans | Where-Object { $_.Folder.Path -ceq $orphan })[0]
        $entry = [pscustomobject]@{ Kind = 'orphan'; Folder = $listed.Folder; Record = $listed.Record; Reason = '' }
        $blocker = [IO.File]::Open((Get-Dlss5StorePath '.bootstrap.lock'), [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        try { Assert-Dlss5Throws { Remove-Dlss5ListedLocationRecord $entry } ([TimeoutException]) 'A removal did not wait for the bootstrap lock.' }
        finally { $blocker.Dispose() }
        Assert-Dlss5True (Test-Path -LiteralPath $orphan) 'A removal without the bootstrap lock removed the record.'
        # Every writer that needs both takes the bootstrap lock before any location mutex.
        $realLocked = ${function:Invoke-Dlss5LocationLocked}
        $order = [Collections.Generic.List[bool]]::new()
        function Invoke-Dlss5LocationLocked {
            param([string[]]$Hashes, [scriptblock]$Action)

            if ($Hashes.Count -gt 0) { $order.Add($script:Dlss5HeldLocks.ContainsKey((Get-Dlss5StorePath '.bootstrap.lock'))) }

            return & $realLocked -Hashes $Hashes -Action $Action
        }
        $null = Invoke-Dlss5TestLocationStep -Package $Case.Package
        Remove-Dlss5ListedLocationRecord $entry
        Assert-Dlss5True ($order.Count -ge 2 -and -not $order.Contains($false)) "A location mutex was taken before the bootstrap lock: $($order -join ',')"
        Assert-Dlss5Equal (Test-Path -LiteralPath $orphan) $false 'The confirmed removal did not remove the record.'
    }
}

Invoke-Dlss5Case 'store unreadable engine file and location record refuse and stay unchanged' {
    Invoke-Dlss5StoreCase -Name 'store-unreadable' -Body {
        param($Case)
        $path = Get-Dlss5EngineFilePath
        New-Item -ItemType Directory -Force (Split-Path -Parent $path) | Out-Null
        foreach ($content in @("not an engine file`r`n", "$EngineBeginMarker`r`n### schema_version: 2`r`n$EngineEndMarker`r`n", "$EngineBeginMarker`r`n### schema_version: 1`r`n### bootstrap_highest_version_seen: 9`r`n$EngineEndMarker`r`n")) {
            [IO.File]::WriteAllText($path, $content, [Text.UTF8Encoding]::new($false))
            $message = ''
            try { $null = Read-Dlss5TrustState }
            catch [IO.InvalidDataException] { $message = $_.Exception.Message }
            Assert-Dlss5True $message.StartsWith('The engine file ' + $path + ' cannot be used: ', [StringComparison]::Ordinal) "A damaged engine file was not refused naming the file: $message"
            Assert-Dlss5Equal ([IO.File]::ReadAllText($path)) $content 'A refused engine file was changed.'
        }
        Remove-Item -LiteralPath $path
        $location = Get-Dlss5LocationIdentity -PackagePath $Case.Package
        $folder = Join-Path (Get-Dlss5LocationsDirectory) $location.FolderName
        New-Item -ItemType Directory -Force $folder | Out-Null
        $record = Join-Path $folder 'LOCATION.md'
        $extra = New-Dlss5LocationNotes
        $extra['location_path'] = $location.Path
        $extra['colour'] = 'blue'
        $extraText = ConvertTo-Dlss5NotesDocument -Notes $extra -BeginMarker $LocationBeginMarker -EndMarker $LocationEndMarker -KnownOrder $LocationRecordOrder
        foreach ($content in @("broken`r`n", $extraText)) {
            [IO.File]::WriteAllText($record, $content, [Text.UTF8Encoding]::new($false))
            $message = ''
            try { $null = Invoke-Dlss5TestLocationStep -Package $Case.Package }
            catch [IO.InvalidDataException] { $message = $_.Exception.Message }
            Assert-Dlss5True $message.StartsWith('The location record ' + $record + ' cannot be used: ', [StringComparison]::Ordinal) "A damaged location record was not refused naming it: $message"
            Assert-Dlss5Equal ([IO.File]::ReadAllText($record)) $content 'A refused location record was changed.'
        }
    }
    # A launch on a machine whose engine file is damaged refuses at trust admission.
    $fixture = New-Dlss5IsolatedLaunchFixture -Name 'store-unreadable-launch'
    $enginePath = Join-Path (Join-Path $fixture.MachineDirectory 'engine') 'ENGINE.md'
    New-Item -ItemType Directory -Force (Split-Path -Parent $enginePath) | Out-Null
    [IO.File]::WriteAllText($enginePath, "damaged`r`n", [Text.UTF8Encoding]::new($false))
    $process = Invoke-Dlss5IsolatedLaunch -Fixture $fixture -Arguments @('--internal-status')
    Assert-Dlss5Equal $process.ExitCode 4 'A launch with a damaged engine file was not refused.'
    Assert-Dlss5True ($process.StandardError.Contains('The engine file ' + $enginePath + ' cannot be used')) "The launch refusal did not name the engine file: $($process.StandardError)"
    Assert-Dlss5Equal ([IO.File]::ReadAllText($enginePath)) "damaged`r`n" 'A refused launch replaced the damaged engine file.'
}

Invoke-Dlss5Case 'store trust union, conflict refusal and two-way reconciliation including an interrupted mirror' {
    Invoke-Dlss5StoreCase -Name 'store-trust' -Body {
        param($Case)
        $machine = (New-Dlss5TrustFixture -Whole @{ 52 = ('a' * 64) } -Engine @{ 52 = ('b' * 64) }).Notes
        $machine['hardware_constraints'] = 'user note'
        $machinePath = Write-Dlss5TestStoreNotes -Notes $machine -Machine
        $null = Write-Dlss5TestStoreNotes -Notes (New-Dlss5TrustFixture -Whole @{ 53 = ('c' * 64) } -Engine @{ 53 = ('d' * 64) }).Notes
        $union = (Read-Dlss5TrustState).Trust
        Assert-Dlss5True ($union.Entries[52] -ceq ('a' * 64) -and $union.Entries[53] -ceq ('c' * 64) -and $union.EngineEntries[52] -ceq ('b' * 64) -and $union.EngineEntries[53] -ceq ('d' * 64)) 'Trust is not the union of both files.'
        Assert-Dlss5True ($union.Maximum -eq 53 -and $union.EngineMaximum -eq 53) 'The highest version seen is not the maximum over the union.'
        $lock = Enter-Dlss5BootstrapLock
        try { Sync-Dlss5TrustStores }
        finally { Exit-Dlss5BootstrapLock $lock }
        $engine = Read-Dlss5TestStoreNotes
        $machine = Read-Dlss5TestStoreNotes -Machine
        foreach ($notes in @($engine, $machine)) {
            Assert-Dlss5True ($notes['bootstrap_checksum.52'] -ceq ('a' * 64) -and $notes['bootstrap_checksum.53'] -ceq ('c' * 64) -and $notes['bootstrap_engine_checksum.52'] -ceq ('b' * 64) -and $notes['bootstrap_engine_checksum.53'] -ceq ('d' * 64)) 'Reconciliation did not copy each entry into the file that lacked it.'
            Assert-Dlss5True ($notes['bootstrap_highest_version_seen'] -ceq '53' -and $notes['bootstrap_engine_highest_version_seen'] -ceq '53') 'Reconciliation left a file maximum behind its entries.'
        }
        Assert-Dlss5Equal $machine['hardware_constraints'] 'user note' 'Reconciliation lost mission memory in the machine notes.'
        # An entry written into the engine file whose mirror write was interrupted is mirrored by the next reconciliation.
        $identity = [pscustomobject]@{ Version = 60; PublishedSha256 = ('e' * 64); Sectioned = $false }
        $lock = Enter-Dlss5BootstrapLock
        try {
            & {
                function Write-Dlss5MachineNotesState { throw [IO.IOException]::new('mirror interrupted') }
                Assert-Dlss5Throws { Write-Dlss5ImmutableTrust $identity } ([IO.IOException]) 'An interrupted mirror write was not reported.'
            }
            Assert-Dlss5Equal (Read-Dlss5TestStoreNotes)['bootstrap_checksum.60'] ('e' * 64) 'The engine file was not written before the mirror.'
            Assert-Dlss5True (-not (Read-Dlss5TestStoreNotes -Machine).Contains('bootstrap_checksum.60')) 'The interrupted mirror wrote the machine notes.'
            Sync-Dlss5TrustStores
            Assert-Dlss5Equal (Read-Dlss5TestStoreNotes -Machine)['bootstrap_checksum.60'] ('e' * 64) 'Reconciliation did not complete the interrupted mirror.'
            # An entry an older updater wrote into the machine notes alone reaches the engine file.
            $machine = Read-Dlss5TestStoreNotes -Machine
            $machine['bootstrap_checksum.61'] = ('f' * 64)
            $machine['bootstrap_highest_version_seen'] = '61'
            $null = Write-Dlss5TestStoreNotes -Notes $machine -Machine
            Sync-Dlss5TrustStores
            Assert-Dlss5Equal (Read-Dlss5TestStoreNotes)['bootstrap_checksum.61'] ('f' * 64) 'Reconciliation did not copy an older updater''s entry into the engine file.'
        }
        finally { Exit-Dlss5BootstrapLock $lock }
        # The same version with two values is trust damage and refuses, changing neither file.
        $machine = Read-Dlss5TestStoreNotes -Machine
        $machine['bootstrap_checksum.53'] = ('0' * 64)
        $null = Write-Dlss5TestStoreNotes -Notes $machine -Machine
        $enginePath = Get-Dlss5EngineFilePath
        $before = @([IO.File]::ReadAllText($machinePath), [IO.File]::ReadAllText($enginePath))
        Assert-Dlss5Throws { $null = Read-Dlss5TrustState } ([IO.InvalidDataException]) 'Conflicting entries were accepted.'
        $lock = Enter-Dlss5BootstrapLock
        try { Assert-Dlss5Throws { Sync-Dlss5TrustStores } ([IO.InvalidDataException]) 'Reconciliation accepted conflicting entries.' }
        finally { Exit-Dlss5BootstrapLock $lock }
        Assert-Dlss5True ([IO.File]::ReadAllText($machinePath) -ceq $before[0] -and [IO.File]::ReadAllText($enginePath) -ceq $before[1]) 'A trust conflict changed a file.'
    }
}

Invoke-Dlss5Case 'store hardware and display migration covers every state and a later v52 rewrite' {
    Invoke-Dlss5StoreCase -Name 'store-hardware-migration' -Body {
        param($Case)
        $legacy = [ordered]@{ gpu = 'Old GPU'; cpu = 'Old CPU'; probe_status = 'verified'; 'display.desk.alias' = 'My Desk'; 'display.desk.observed_name' = 'Old Monitor'; display_topology_status = 'verified' }
        $machine = (New-Dlss5TrustFixture -Whole @{ 52 = ('a' * 64) }).Notes
        $machine['hardware_constraints'] = 'user note'
        foreach ($key in $legacy.Keys) { $machine[$key] = $legacy[$key] }
        $null = Write-Dlss5TestStoreNotes -Notes $machine -Machine
        # Nothing copied yet: everything moves in one engine file write, then leaves the machine notes in a second.
        Move-Dlss5LegacyHardwareKeys
        $engine = Read-Dlss5TestStoreNotes
        foreach ($key in $legacy.Keys) { Assert-Dlss5Equal $engine[$key] $legacy[$key] "The engine file did not receive $key." }
        $machine = Read-Dlss5TestStoreNotes -Machine
        Assert-Dlss5True (@($machine.Keys | Where-Object { $_ -cin @('gpu', 'cpu', 'probe_status', 'display_topology_status') -or ([string]$_).StartsWith('display.', [StringComparison]::Ordinal) }).Count -eq 0) 'Legacy hardware keys stayed in the machine notes.'
        Assert-Dlss5True ($machine['hardware_constraints'] -ceq 'user note' -and $machine['bootstrap_checksum.52'] -ceq ('a' * 64)) 'Migration removed hardware_constraints or trust from the machine notes.'
        # Done: a second run writes nothing.
        $stamps = @((Get-Item -LiteralPath (Get-Dlss5EngineFilePath)).LastWriteTimeUtc, (Get-Item -LiteralPath (Get-Dlss5StorePath 'DLSS5_MACHINE_NOTES.md')).LastWriteTimeUtc)
        $bytes = @([IO.File]::ReadAllBytes((Get-Dlss5EngineFilePath)), [IO.File]::ReadAllBytes((Get-Dlss5StorePath 'DLSS5_MACHINE_NOTES.md')))
        Move-Dlss5LegacyHardwareKeys
        Assert-Dlss5True ((Test-Dlss5ByteEquality -Left ([IO.File]::ReadAllBytes((Get-Dlss5EngineFilePath))) -Right $bytes[0]) -and (Test-Dlss5ByteEquality -Left ([IO.File]::ReadAllBytes((Get-Dlss5StorePath 'DLSS5_MACHINE_NOTES.md'))) -Right $bytes[1])) 'A finished migration wrote again.'
        Assert-Dlss5True ((Get-Item -LiteralPath (Get-Dlss5EngineFilePath)).LastWriteTimeUtc -eq $stamps[0]) 'A finished migration rewrote the engine file.'
        # Copied but not removed, as a crash between the two writes or a v52 copy writing its keys back leaves it: the engine file keeps its
        # own values, gains only the keys it lacks, and the machine notes are cleaned again.
        $machine = Read-Dlss5TestStoreNotes -Machine
        $machine['gpu'] = 'v52 GPU'
        $machine['display.desk.alias'] = 'v52 Desk'
        $machine['ram_mib'] = '1024'
        $null = Write-Dlss5TestStoreNotes -Notes $machine -Machine
        Move-Dlss5LegacyHardwareKeys
        $engine = Read-Dlss5TestStoreNotes
        Assert-Dlss5True ($engine['gpu'] -ceq 'Old GPU' -and $engine['display.desk.alias'] -ceq 'My Desk' -and $engine['ram_mib'] -ceq '1024') 'Re-migration did not keep the engine file''s values and add only missing keys.'
        Assert-Dlss5True (-not (Read-Dlss5TestStoreNotes -Machine).Contains('gpu') -and -not (Read-Dlss5TestStoreNotes -Machine).Contains('ram_mib')) 'Re-migration left the rewritten keys in the machine notes.'
    }
    # A machine without display records moves its hardware keys alone.
    Invoke-Dlss5StoreCase -Name 'store-hardware-no-display' -Body {
        param($Case)
        $machine = (New-Dlss5TrustFixture -Whole @{ 52 = ('a' * 64) }).Notes
        $machine['gpu'] = 'Old GPU'
        $null = Write-Dlss5TestStoreNotes -Notes $machine -Machine
        Move-Dlss5LegacyHardwareKeys
        $engine = Read-Dlss5TestStoreNotes
        Assert-Dlss5True ($engine['gpu'] -ceq 'Old GPU' -and @($engine.Keys | Where-Object { ([string]$_).StartsWith('display.', [StringComparison]::Ordinal) }).Count -eq 0) 'A machine without display records was not migrated.'
        Assert-Dlss5True (-not (Read-Dlss5TestStoreNotes -Machine).Contains('gpu')) 'The machine notes kept the moved key.'
    }
}

Invoke-Dlss5Case 'store game notes migration covers every state' {
    Invoke-Dlss5StoreCase -Name 'store-notes-migration' -Body {
        param($Case)
        $step = Invoke-Dlss5TestLocationStep -Package $Case.Package
        $notesPath = Join-Path $Case.Game 'DLSS5-ADDER.md'
        $write = {
            param([string]$Marker, [string]$Fingerprint)
            $notes = New-Dlss5GameNotesFixture
            $notes['game_fingerprint'] = $Fingerprint
            $notes['game_name'] = 'Store Game'
            $notes['steam_appid'] = ''
            $notes['main_executables'] = 'game.exe'
            $notes['last_checked'] = '2026-01-01T00:00:00Z'
            $notes['transaction_status'] = $Marker
            $notes['status'] = 'mine'
            $notes['visual_verification'] = 'agent text'
            Write-Dlss5NotesFileAtomically -Path $notesPath -Notes $notes -BeginMarker $GameNotesBeginMarker -EndMarker $GameNotesEndMarker -KnownOrder $GameNotesOrder

            return Read-Dlss5NotesFile -Path $notesPath -BeginMarker $GameNotesBeginMarker -EndMarker $GameNotesEndMarker
        }
        $record = { (Get-Dlss5LocationState -Location $step.Location).Record.Notes }
        $assertMigrated = {
            param([string]$Label)
            $after = Read-Dlss5NotesFile -Path $notesPath -BeginMarker $GameNotesBeginMarker -EndMarker $GameNotesEndMarker
            Assert-Dlss5Equal @($GameNotesMovedKeys | Where-Object { $after.Contains($_) }).Count 0 "$Label left moved keys in the game notes."
            Assert-Dlss5True ($after['status'] -ceq 'mine' -and $after['visual_verification'] -ceq 'agent text' -and $after['game_fingerprint'] -ceq $step.Identity.Fingerprint) "$Label changed agent-only keys or the fingerprint."
        }
        # Marker present and not copied: copied into the record, then the moved keys leave the game notes.
        $notes = & $write 'stage A: unpacking' $step.Identity.Fingerprint
        Assert-Dlss5True (Invoke-Dlss5GameNotesMigration -GameNotesPath $notesPath -GameNotes $notes -Location $step.Location -Fingerprint $step.Identity.Fingerprint) 'Migration reported no change.'
        Assert-Dlss5Equal (& $record)['transaction_status'] 'stage A: unpacking' 'The marker was not copied into the record.'
        & $assertMigrated 'Copying the marker'
        # Marker copied, keys not removed: the record keeps the marker and the keys are removed.
        $notes = & $write 'stage A: unpacking' $step.Identity.Fingerprint
        $null = Invoke-Dlss5GameNotesMigration -GameNotesPath $notesPath -GameNotes $notes -Location $step.Location -Fingerprint $step.Identity.Fingerprint
        Assert-Dlss5Equal (& $record)['transaction_status'] 'stage A: unpacking' 'An already copied marker was changed.'
        & $assertMigrated 'Removing after a copy'
        # No marker: the record is not written, and the keys are removed.
        $null = Update-Dlss5LocationRecord -Location $step.Location -Change { param($recordNotes) $recordNotes['transaction_status'] = '' }
        $recordBytes = [IO.File]::ReadAllBytes($step.Result.Path)
        $notes = & $write '' $step.Identity.Fingerprint
        $null = Invoke-Dlss5GameNotesMigration -GameNotesPath $notesPath -GameNotes $notes -Location $step.Location -Fingerprint $step.Identity.Fingerprint
        Assert-Dlss5True (Test-Dlss5ByteEquality -Left ([IO.File]::ReadAllBytes($step.Result.Path)) -Right $recordBytes) 'Migration without a marker wrote the record.'
        & $assertMigrated 'Migration without a marker'
        # Done: nothing to change writes nothing.
        $notes = Read-Dlss5NotesFile -Path $notesPath -BeginMarker $GameNotesBeginMarker -EndMarker $GameNotesEndMarker
        Assert-Dlss5Equal (Invoke-Dlss5GameNotesMigration -GameNotesPath $notesPath -GameNotes $notes -Location $step.Location -Fingerprint $step.Identity.Fingerprint) $false 'Migrated game notes were written again.'
        # A legacy fingerprint, which the guard accepted before migration, is brought to the current one in the same write.
        $notes = & $write '' ('1' * 64)
        $null = Invoke-Dlss5GameNotesMigration -GameNotesPath $notesPath -GameNotes $notes -Location $step.Location -Fingerprint $step.Identity.Fingerprint
        & $assertMigrated 'A legacy fingerprint migration'
    }
}

Invoke-Dlss5Case 'store task session writes the location record without touching game notes and states a leftover marker' {
    $steamApps = Join-Path (Join-Path $script:ScratchRoot 'store-task-notes') 'steamapps'
    $fixture = New-Dlss5IsolatedLaunchFixture -Name 'store-task-notes' -GameDirectory (Join-Path (Join-Path $steamApps 'common') 'Fixture Game') -StubBody @($script:StorePromptStubLine)
    [IO.File]::WriteAllBytes((Join-Path $fixture.Game 'game.exe'), [byte[]](1))
    [IO.File]::WriteAllText((Join-Path $steamApps 'appmanifest_123.acf'), "`"AppState`"`r`n{`r`n`"appid`" `"123`"`r`n`"installdir`" `"Fixture Game`"`r`n}`r`n", [Text.UTF8Encoding]::new($false))
    $legacyFingerprint = Get-Sha256Text -Text (@('steam_appid=123 ', 'folder=fixture game', 'executables=game.exe') -join "`n")
    $stableFingerprint = Get-Sha256Text -Text (@('steam_appid=123', 'folder=fixture game', 'executables=game.exe') -join "`n")
    $writeNotes = {
        param([string]$Marker)
        $notes = New-Dlss5GameNotesFixture
        $notes['game_fingerprint'] = $legacyFingerprint
        $notes['game_name'] = 'Fixture Game'
        $notes['last_checked'] = '2026-01-01T00:00:00Z'
        $notes['transaction_status'] = $Marker
        Write-Dlss5NotesFileAtomically -Path $fixture.GameNotesPath -Notes $notes -BeginMarker $GameNotesBeginMarker -EndMarker $GameNotesEndMarker -KnownOrder $GameNotesOrder
    }
    & $writeNotes 'stage A: before swap'
    $null = Set-Dlss5FixtureArmed $fixture
    $capture = Join-Path $fixture.StubRoot 'prompt.txt'
    foreach ($case in @(@('stage A: before swap', 'stage A: before swap'), @('', 'none'))) {
        & $writeNotes $case[0]
        $before = [IO.File]::ReadAllBytes($fixture.GameNotesPath)
        Remove-Item -LiteralPath $capture -ErrorAction SilentlyContinue
        # A one-word task keeps cmd's quote handling intact for a package path with a space in it.
        $process = Invoke-Dlss5IsolatedLaunch -Fixture $fixture -Arguments @('describe-the-setup') -Environment @{ DLSS5_TEST_PROMPT_CAPTURE_PATH = $capture }
        Assert-Dlss5Equal $process.ExitCode 0 "The task session failed: $($process.StandardOutput) $($process.StandardError)"
        Assert-Dlss5True (Test-Dlss5ByteEquality -Left ([IO.File]::ReadAllBytes($fixture.GameNotesPath)) -Right $before) 'A task session changed the game notes.'
        $prompt = Read-Dlss5PromptCapture $capture
        Assert-Dlss5True ([regex]::IsMatch($prompt, '(?m)^legacy_transaction_status: ' + [regex]::Escape($case[1]) + '\r?$')) "The task prompt did not state the leftover marker as $($case[1])."
        $record = Get-Dlss5FixtureLocationRecord $fixture
        Assert-Dlss5Equal $record['game_fingerprint'] $stableFingerprint 'A task session did not rewrite a legacy fingerprint in the location record.'
        Assert-Dlss5Equal $record['transaction_status'] '' 'A task session copied a marker out of the game notes.'
    }
    # The next default session migrates the game notes in one sequence.
    $process = Invoke-Dlss5IsolatedLaunch -Fixture $fixture
    $notes = Read-Dlss5NotesFile -Path $fixture.GameNotesPath -BeginMarker $GameNotesBeginMarker -EndMarker $GameNotesEndMarker
    Assert-Dlss5True ($notes['game_fingerprint'] -ceq $stableFingerprint -and -not $notes.Contains('game_name') -and -not $notes.Contains('last_checked') -and -not $notes.Contains('transaction_status')) "The default session did not migrate the game notes (exit $($process.ExitCode)): $($process.StandardError)"
}

Invoke-Dlss5Case 'store transaction conflict refuses, including a pair arriving through a moved directory' {
    Invoke-Dlss5StoreCase -Name 'store-conflict' -Body {
        param($Case)
        $notesPath = Join-Path $Case.Game 'DLSS5-ADDER.md'
        $identity = Get-GameIdentity -Dir $Case.Game
        $location = Get-Dlss5LocationIdentity -PackagePath $Case.Package
        $notes = New-Dlss5GameNotesFixture
        $notes['game_fingerprint'] = $identity.Fingerprint
        $notes['transaction_status'] = 'stage B'
        # Through a moved directory: no record here yet, and the orphan a takeover would select holds another marker.
        $orphan = Write-Dlss5TestLocationRecord -LocationPath 'C:\Gone\Moved Game' -Fields @{ folder_token = $location.Token; game_fingerprint = $identity.Fingerprint; transaction_status = 'stage A' }
        $message = ''
        try { $null = Get-Dlss5SessionLocationPlan -Location $location -GameIdentity $identity -GameNotes $notes -GameNotesPath $notesPath }
        catch [IO.InvalidDataException] { $message = $_.Exception.Message }
        Assert-Dlss5True ($message.Contains('(stage B)') -and $message.Contains('(stage A)') -and $message.Contains($notesPath) -and $message.Contains((Join-Path $orphan 'LOCATION.md'))) "A conflict through a moved directory did not refuse naming both values and files: $message"
        # At this location's own record.
        Remove-Dlss5LocationFolder $orphan
        $null = Invoke-Dlss5TestLocationStep -Package $Case.Package
        $null = Update-Dlss5LocationRecord -Location $location -Change { param($recordNotes) $recordNotes['transaction_status'] = 'stage A' }
        $message = ''
        try { $null = Get-Dlss5SessionLocationPlan -Location $location -GameIdentity $identity -GameNotes $notes -GameNotesPath $notesPath }
        catch [IO.InvalidDataException] { $message = $_.Exception.Message }
        Assert-Dlss5True ($message.Contains('(stage B)') -and $message.Contains('(stage A)') -and $message.Contains($location.RecordPath)) "A conflict with this location's record did not refuse: $message"
        # Equal markers, or a marker on one side only, are no conflict.
        $notes['transaction_status'] = 'stage A'
        $null = Get-Dlss5SessionLocationPlan -Location $location -GameIdentity $identity -GameNotes $notes -GameNotesPath $notesPath
        $notes['transaction_status'] = ''
        $null = Get-Dlss5SessionLocationPlan -Location $location -GameIdentity $identity -GameNotes $notes -GameNotesPath $notesPath
    }
}

Invoke-Dlss5Case 'store location folder without a readable record counts as unreadable' {
    Invoke-Dlss5StoreCase -Name 'store-creation-crash' -Body {
        param($Case)
        $location = Get-Dlss5LocationIdentity -PackagePath $Case.Package
        $own = Join-Path (Get-Dlss5LocationsDirectory) $location.FolderName
        New-Item -ItemType Directory -Force $own | Out-Null
        $message = ''
        try { $null = Invoke-Dlss5TestLocationStep -Package $Case.Package }
        catch [IO.InvalidDataException] { $message = $_.Exception.Message }
        Assert-Dlss5True $message.Contains('The folder holds no LOCATION.md.') "A record folder without its record did not refuse the session at its location: $message"
        Assert-Dlss5Equal @(Get-ChildItem -LiteralPath $own -Force).Count 0 'A refused session wrote into the empty record folder.'
        # At another location it is listed as unreadable and never taken over.
        $elsewhere = Join-Path (Get-Dlss5LocationsDirectory) ((Get-Dlss5TestLocationFolderName 'C:\Gone\Crashed Game'))
        New-Item -ItemType Directory -Force $elsewhere | Out-Null
        # A folder without the hash suffix is not a record at all, so it is neither unreadable nor an orphan.
        New-Item -ItemType Directory -Force (Join-Path (Get-Dlss5LocationsDirectory) 'stray-folder') | Out-Null
        Remove-Item -LiteralPath $own
        $scan = Get-Dlss5LocationOrphans -Folders @(Get-Dlss5LocationFolders) -ExcludeHash $location.Hash
        Assert-Dlss5True ($scan.Unreadable.Count -eq 1 -and $scan.Unreadable[0].Folder.Path -ceq $elsewhere -and $scan.Orphans.Count -eq 0) 'A folder without a record was not counted as unreadable.'
        $step = Invoke-Dlss5TestLocationStep -Package $Case.Package
        Assert-Dlss5True ($step.Result.Created -and (Test-Path -LiteralPath $elsewhere)) 'A folder without a record was taken over or removed.'
    }
}

Invoke-Dlss5Case 'store engine file writes keep existing trust entries' {
    Invoke-Dlss5StoreCase -Name 'store-trust-kept' -Body {
        param($Case)
        $trust = New-Dlss5TrustFixture -Whole @{ 52 = ('a' * 64); $script:CandidateVersion = $script:CandidateIdentity.PublishedSha256 } -Engine @{ $script:CandidateVersion = $script:CandidateIdentity.EngineSha256 }
        $null = Write-Dlss5TestStoreNotes -Notes $trust.Notes
        $lock = Enter-Dlss5BootstrapLock
        try {
            $current = Read-Dlss5EngineFile
            $dropped = [Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
            foreach ($key in $current.Notes.Keys) { if ($key -cne 'bootstrap_checksum.52') { $dropped[$key] = $current.Notes[$key] } }
            Assert-Dlss5Throws { Write-Dlss5EngineFileNotes -Notes $dropped -Current $current } ([IO.InvalidDataException]) 'An engine file write dropped a trust entry.'
            $changed = Read-Dlss5TestStoreNotes
            $changed['bootstrap_engine_checksum.' + $script:CandidateVersion] = ('9' * 64)
            Assert-Dlss5Throws { Write-Dlss5EngineFileNotes -Notes $changed -Current $current } ([IO.InvalidDataException]) 'An engine file write changed a trust entry.'
        }
        finally { Exit-Dlss5BootstrapLock $lock }
        $hardware = Get-Dlss5HardwareSnapshot -GpuProbe { [pscustomobject]@{ Status = 'not-found'; Path = ''; Evidence = 'none'; Gpu = $null } }
        $null = Update-Dlss5EngineHardware -Identity $script:CandidateIdentity -Hardware $hardware
        $engine = Read-Dlss5TestStoreNotes
        Assert-Dlss5True ($engine['bootstrap_checksum.52'] -ceq ('a' * 64) -and $engine['bootstrap_engine_checksum.' + $script:CandidateVersion] -ceq $script:CandidateIdentity.EngineSha256 -and $engine['gpu_probe_status'] -ceq 'not-found') 'The hardware snapshot write did not keep every trust entry.'
    }
}

Invoke-Dlss5Case 'store first session and first hardware probe on a v52 machine move a customized display alias' {
    # live-input: asserts on what this machine's hardware and display probes returned, not a fixture.
    foreach ($kind in @('session', 'probe')) {
        $fixture = New-Dlss5IsolatedLaunchFixture -Name ('store-v52-machine-' + $kind)
        $notes = (New-Dlss5TrustFixture -Whole @{ $script:CandidateVersion = $script:CandidateIdentity.PublishedSha256 } -Engine @{ $script:CandidateVersion = $script:CandidateIdentity.EngineSha256 }).Notes
        foreach ($pair in @(@('last_checked', '2026-01-01T00:00:00Z'), @('gpu', 'Old GPU'), @('hardware_constraints', 'user note'), @('display_topology_status', 'verified'), @('display.desk.alias', 'My Desk'), @('display.desk.observed_name', 'Old Monitor'), @('display.desk.connection', 'HDMI'), @('display.desk.resolution', '1920x1080'), @('display.desk.availability', 'active'))) { $notes[$pair[0]] = $pair[1] }
        New-Item -ItemType Directory -Force $fixture.MachineDirectory | Out-Null
        $machinePath = Join-Path $fixture.MachineDirectory 'DLSS5_MACHINE_NOTES.md'
        [IO.File]::WriteAllText($machinePath, (ConvertTo-Dlss5NotesDocument -Notes $notes -BeginMarker $MachineNotesBeginMarker -EndMarker $MachineNotesEndMarker -KnownOrder $MachineNotesOrder), [Text.UTF8Encoding]::new($false))
        if ($kind -ceq 'session') { $process = Invoke-Dlss5IsolatedLaunch -Fixture $fixture }
        else { $process = Invoke-Dlss5ProcessWithInput -FilePath 'cmd.exe' -Arguments @('/d', '/c', $fixture.Updater, '--internal-hardware-probe', $fixture.Updater) -InputLines @() -WorkingDirectory $fixture.Game -Environment @{ LOCALAPPDATA = $fixture.LocalAppData } }
        Assert-Dlss5True ($process.ExitCode -in @(0, 4)) "The first $kind on a v52 machine failed: $($process.ExitCode) $($process.StandardError)"
        $engine = Read-Dlss5FixtureEngineFile $fixture
        Assert-Dlss5Equal $engine['display.desk.alias'] 'My Desk' "The first $kind did not land the customized display alias in the engine file."
        $machine = Read-Dlss5NotesFile -Path $machinePath -BeginMarker $MachineNotesBeginMarker -EndMarker $MachineNotesEndMarker
        Assert-Dlss5True (@($machine.Keys | Where-Object { ([string]$_).StartsWith('display.', [StringComparison]::Ordinal) -or $_ -cin @('gpu', 'last_checked', 'display_topology_status') }).Count -eq 0) "The first $kind left hardware or display keys in the machine notes."
        Assert-Dlss5Equal $machine['hardware_constraints'] 'user note' "The first $kind removed hardware_constraints from the machine notes."
    }
}

Invoke-Dlss5Case 'store marker set through the channel during a session survives its status and display writes' {
    $fixture = New-Dlss5IsolatedLaunchFixture -Name 'store-channel-session' -StubBody @(
        'call "%DLSS5_TEST_UPDATER%" --internal-location-set transaction_status "stage 2: copy (dlls) to C:/Games/x" > "%DLSS5_TEST_CHANNEL_OUT%" 2>&1',
        '>"%DLSS5_TEST_CHANNEL_CODE%" echo %ERRORLEVEL%'
    )
    $out = Join-Path $fixture.StubRoot 'channel.txt'
    $code = Join-Path $fixture.StubRoot 'code.txt'
    $process = Invoke-Dlss5IsolatedLaunch -Fixture $fixture -Environment @{ DLSS5_TEST_UPDATER = $fixture.Updater; DLSS5_TEST_CHANNEL_OUT = $out; DLSS5_TEST_CHANNEL_CODE = $code }
    Assert-Dlss5Equal ([IO.File]::ReadAllText($code).Trim()) '0' "The channel failed inside the session: $([IO.File]::ReadAllText($out))"
    Assert-Dlss5True ([IO.File]::ReadAllText($out).Contains('transaction_status: stage 2: copy (dlls) to C:/Games/x')) 'The channel did not print the written value.'
    Assert-Dlss5Equal $process.ExitCode 4 'The session without a target display did not end pending.'
    $record = Get-Dlss5FixtureLocationRecord $fixture
    Assert-Dlss5Equal $record['transaction_status'] 'stage 2: copy (dlls) to C:/Games/x' 'The session''s own writes lost the marker the agent set.'
    Assert-Dlss5True ($record['session_status'] -ceq 'display_selection_pending' -and ([string]$record['display_check']).StartsWith('pending: ', [StringComparison]::Ordinal)) 'The session status and display finding were not written.'
}

Invoke-Dlss5Case 'store refused sessions write nothing, project knowledge included' {
    # Each launch follows a status launch, so trust is already reconciled and the refused session is the only thing that could write.
    $prepare = {
        param([string]$Name)
        $fixture = New-Dlss5IsolatedLaunchFixture -Name $Name -StubBody @('echo started>"%DLSS5_TEST_STARTED_PATH%"')
        $null = Get-Dlss5LaunchStatus $fixture
        $null = Set-Dlss5FixtureArmed $fixture

        return $fixture
    }
    $refuse = {
        param($Fixture, [string[]]$Expected)
        $before = Get-Dlss5FixtureStoreState $Fixture
        $started = Join-Path $Fixture.StubRoot 'started.txt'
        $process = Invoke-Dlss5IsolatedLaunch -Fixture $Fixture -Environment @{ DLSS5_TEST_STARTED_PATH = $started }
        $output = $process.StandardOutput + $process.StandardError
        Assert-Dlss5Equal $process.ExitCode 4 "The session was not refused: $output"
        foreach ($text in $Expected) { Assert-Dlss5True $output.Contains($text) "The refusal did not say [$text]: $output" }
        Assert-Dlss5Equal (Get-Dlss5FixtureStoreState $Fixture) $before 'A refused session wrote into the store or the game notes.'
        Assert-Dlss5Equal (Test-Path -LiteralPath (Join-Path $Fixture.MachineDirectory 'DLSS5_PROJECT_KNOWLEDGE.md')) $false 'A refused session wrote project knowledge.'
        Assert-Dlss5Equal (Test-Path -LiteralPath $started) $false 'A refused session started its agent.'
    }
    # The game notes belong to another game.
    $fixture = & $prepare 'store-refused-notes'
    $notes = New-Dlss5GameNotesFixture
    Write-Dlss5NotesFileAtomically -Path $fixture.GameNotesPath -Notes $notes -BeginMarker $GameNotesBeginMarker -EndMarker $GameNotesEndMarker -KnownOrder $GameNotesOrder
    & $refuse $fixture @(($fixture.GameNotesPath + ' belongs to a different game'))
    Assert-Dlss5Equal (Test-Path -LiteralPath (Join-Path $fixture.MachineDirectory 'engine\locations')) $false 'A refused session created a location record.'
    # The location record belongs to another game.
    $fixture = & $prepare 'store-refused-record'
    $location = Get-Dlss5FixtureLocation $fixture
    $null = Invoke-Dlss5WithLocalAppData -Path $fixture.LocalAppData -Action { Write-Dlss5TestLocationRecord -LocationPath $location.Path -Fields @{ folder_token = $location.Token; game_fingerprint = ('f' * 64) } }
    & $refuse $fixture @(($location.RecordPath + ' belongs to a different game'))
    # The game notes and the location record hold different transaction markers.
    $fixture = & $prepare 'store-refused-conflict'
    $location = Get-Dlss5FixtureLocation $fixture
    $fingerprint = (Get-GameIdentity -Dir $fixture.Game).Fingerprint
    $null = Invoke-Dlss5WithLocalAppData -Path $fixture.LocalAppData -Action { Write-Dlss5TestLocationRecord -LocationPath $location.Path -Fields @{ folder_token = $location.Token; game_fingerprint = $fingerprint; transaction_status = 'stage A' } }
    $notes = New-Dlss5GameNotesFixture
    $notes['game_fingerprint'] = $fingerprint
    $notes['transaction_status'] = 'stage B'
    Write-Dlss5NotesFileAtomically -Path $fixture.GameNotesPath -Notes $notes -BeginMarker $GameNotesBeginMarker -EndMarker $GameNotesEndMarker -KnownOrder $GameNotesOrder
    & $refuse $fixture @('(stage B) differs from the one in', '(stage A)')
}

Invoke-Dlss5Case 'store session-end readback of the engine file and the location record exits 5 on damage' {
    foreach ($target in @('engine', 'record')) {
        $fixture = New-Dlss5IsolatedLaunchFixture -Name ('store-damage-' + $target) -StubBody @('echo broken>"%DLSS5_TEST_DAMAGE%"')
        $path = if ($target -ceq 'engine') { Join-Path (Join-Path $fixture.MachineDirectory 'engine') 'ENGINE.md' } else { (Get-Dlss5FixtureLocation $fixture).RecordPath }
        $process = Invoke-Dlss5IsolatedLaunch -Fixture $fixture -Environment @{ DLSS5_TEST_DAMAGE = $path }
        Assert-Dlss5Equal $process.ExitCode 5 "Damage to the $target did not exit 5: $($process.StandardError)"
        Assert-Dlss5Equal ([IO.File]::ReadAllText($path).Trim()) 'broken' "The damaged $target was rewritten."
    }
}

Invoke-Dlss5Case 'store session-end readback exits 5 when the machine notes disappear during the session' {
    $fixture = New-Dlss5IsolatedLaunchFixture -Name 'store-machine-deleted' -StubBody @('del "%DLSS5_TEST_DAMAGE%"')
    $path = Join-Path $fixture.MachineDirectory 'DLSS5_MACHINE_NOTES.md'
    $process = Invoke-Dlss5IsolatedLaunch -Fixture $fixture -Environment @{ DLSS5_TEST_DAMAGE = $path }
    Assert-Dlss5Equal $process.ExitCode 5 "Machine notes deleted during the session did not exit 5: $($process.StandardError)"
}

Invoke-Dlss5Case 'store write channel accepts, clears and refuses values, keys and copies, and takes no guard' {
    Assert-Dlss5True (Test-Dlss5LocationValue 'stage 2: copy C:/Games/x (part 1)') 'A value with spaces, colons, slashes and parentheses was refused.'
    Assert-Dlss5True (Test-Dlss5LocationValue '') 'The empty value was refused.'
    foreach ($bad in @('say "hi"', 'at 50%', "two`r`nlines", "tab`there", ('x' * 1025), ('caf' + [char]233))) { Assert-Dlss5True (-not (Test-Dlss5LocationValue $bad)) "A value that cannot be carried was accepted: [$bad]" }
    Assert-Dlss5True (Test-Dlss5LocationValue ('x' * 1024)) 'A value of 1024 characters was refused.'
    # An untrusted copy is refused before anything is read or written.
    $untrusted = New-Dlss5IsolatedLaunchFixture -Name 'store-channel-untrusted'
    $process = Invoke-Dlss5LocationChannel $untrusted @('transaction_status', 'stage 1')
    Assert-Dlss5True ($process.ExitCode -eq 4 -and $process.StandardError.Contains('not trusted')) "An untrusted copy was not refused: $($process.ExitCode) $($process.StandardError)"
    Assert-Dlss5Equal (Test-Path -LiteralPath (Join-Path $untrusted.MachineDirectory 'engine')) $false 'An untrusted copy wrote into the engine store.'
    $fixture = New-Dlss5IsolatedLaunchFixture -Name 'store-channel'
    $null = Get-Dlss5LaunchStatus $fixture
    $location = Get-Dlss5FixtureLocation $fixture
    # Without a record the channel refuses, naming the record's path, and never creates one.
    $process = Invoke-Dlss5LocationChannel $fixture @('transaction_status', 'stage 1')
    Assert-Dlss5True ($process.ExitCode -eq 4 -and $process.StandardError.Contains($location.RecordPath)) "A missing record was not refused naming its path: $($process.ExitCode) $($process.StandardError)"
    Assert-Dlss5Equal (Test-Path -LiteralPath $location.FolderPath) $false 'The channel created a location record.'
    $fingerprint = (Get-GameIdentity -Dir $fixture.Game).Fingerprint
    $null = Invoke-Dlss5WithLocalAppData -Path $fixture.LocalAppData -Action { Write-Dlss5TestLocationRecord -LocationPath $location.Path -Fields @{ folder_token = $location.Token; game_fingerprint = $fingerprint; session_status = 'agent_session_ended' } }
    $value = 'stage 2: copy C:/Games/x (part 1)'
    $process = Invoke-Dlss5LocationChannel $fixture @('transaction_status', $value)
    Assert-Dlss5True ($process.ExitCode -eq 0 -and $process.StandardOutput.Contains('transaction_status: ' + $value)) "An accepted value was not written and printed: $($process.ExitCode) $($process.StandardOutput) $($process.StandardError)"
    $record = Get-Dlss5FixtureLocationRecord $fixture
    Assert-Dlss5True ($record['transaction_status'] -ceq $value -and $record['session_status'] -ceq 'agent_session_ended') 'The channel did not write only the marker.'
    $recordBytes = [IO.File]::ReadAllBytes($location.RecordPath)
    foreach ($arguments in @(@('session_status', 'x'), @('transaction_status', 'say "hi"'), @('transaction_status', 'at 50%b'), @('transaction_status', ('x' * 1025)), @('transaction_status', 'a', 'b'), @('transaction_status'))) {
        $process = Invoke-Dlss5LocationChannel $fixture $arguments
        Assert-Dlss5Equal $process.ExitCode 2 "The channel accepted [$($arguments -join '] [')]."
        Assert-Dlss5True (Test-Dlss5ByteEquality -Left ([IO.File]::ReadAllBytes($location.RecordPath)) -Right $recordBytes) "A refused value [$($arguments -join '] [')] changed the record."
    }
    # A session holding the folder guard does not block the channel, which never takes it.
    $holder = Start-Dlss5GuardHolder -Package $fixture.Updater -LocalAppData $fixture.LocalAppData
    try {
        $process = Invoke-Dlss5LocationChannel $fixture @('transaction_status', '')
        Assert-Dlss5Equal $process.ExitCode 0 "The channel was blocked by a held guard: $($process.StandardError)"
    }
    finally { Stop-Dlss5GuardHolder $holder }
    Assert-Dlss5Equal (Get-Dlss5FixtureLocationRecord $fixture)['transaction_status'] '' 'The empty value did not clear the marker.'
    # An unreadable record refuses and stays as it is.
    [IO.File]::WriteAllText($location.RecordPath, "broken`r`n", [Text.UTF8Encoding]::new($false))
    $process = Invoke-Dlss5LocationChannel $fixture @('transaction_status', 'stage 3')
    Assert-Dlss5True ($process.ExitCode -eq 4 -and $process.StandardError.Contains($location.RecordPath)) "An unreadable record was not refused: $($process.ExitCode) $($process.StandardError)"
    Assert-Dlss5Equal ([IO.File]::ReadAllText($location.RecordPath)) "broken`r`n" 'The channel replaced an unreadable record.'
}

Invoke-Dlss5Case 'store moved-location takeover, its crash state, ambiguous orphans, a changed token and a fingerprint mismatch' {
    Invoke-Dlss5StoreCase -Name 'store-takeover' -Body {
        param($Case)
        $location = Get-Dlss5LocationIdentity -PackagePath $Case.Package
        $identity = Get-GameIdentity -Dir $Case.Game
        $fields = @{ folder_token = $location.Token; game_fingerprint = $identity.Fingerprint; transaction_status = 'stage 3: swapping'; session_status = 'agent_session_ended'; game_name = 'Store Game' }
        $orphan = Write-Dlss5TestLocationRecord -LocationPath 'C:\Gone\Moved Game' -Fields $fields
        $step = Invoke-Dlss5TestLocationStep -Package $Case.Package
        $record = (Get-Dlss5LocationState -Location $location).Record.Notes
        Assert-Dlss5True (-not $step.Result.Created -and $record['transaction_status'] -ceq 'stage 3: swapping' -and $record['location_path'] -ceq $location.Path) 'The moved location was not taken over with its marker.'
        Assert-Dlss5Equal (Test-Path -LiteralPath $orphan) $false 'The superseded orphan was not removed after the takeover.'
        # The crash state between the two writes: the new record exists and the orphan is still there; the next session removes it.
        $orphan = Write-Dlss5TestLocationRecord -LocationPath 'C:\Gone\Moved Game' -Fields $fields
        $step = Invoke-Dlss5TestLocationStep -Package $Case.Package
        Assert-Dlss5True ($null -ne $step.Plan.Superseded -and -not (Test-Path -LiteralPath $orphan)) 'An interrupted takeover was not completed.'
        Assert-Dlss5Equal (Get-Dlss5LocationState -Location $location).Record.Notes['transaction_status'] 'stage 3: swapping' 'Completing the takeover changed the record.'
    }
    $cases = [ordered]@{
        'two orphans with the same token and fingerprint' = { param($Location, $Identity) @(@('C:\Gone\First Copy', $Location.Token, $Identity.Fingerprint, 'stage 4'), @('C:\Gone\Second Copy', $Location.Token, $Identity.Fingerprint, 'stage 5')) }
        'a changed folder token' = { param($Location, $Identity) @(, @('C:\Gone\Other Volume', ('P' + ('1' * 64)), $Identity.Fingerprint, 'stage 6')) }
        'a fingerprint mismatch' = { param($Location, $Identity) @(, @('C:\Gone\Other Game', $Location.Token, ('f' * 64), 'stage 7')) }
    }
    foreach ($caseName in $cases.Keys) {
        $build = $cases[$caseName]
        Invoke-Dlss5StoreCase -Name ('store-fresh-' + [Guid]::NewGuid().ToString('N').Substring(0, 6)) -Body {
            param($Case)
            $location = Get-Dlss5LocationIdentity -PackagePath $Case.Package
            $identity = Get-GameIdentity -Dir $Case.Game
            $orphans = @(foreach ($spec in @(& $build $location $identity)) { [pscustomobject]@{ Path = $spec[0]; Folder = (Write-Dlss5TestLocationRecord -LocationPath $spec[0] -Fields @{ folder_token = $spec[1]; game_fingerprint = $spec[2]; transaction_status = $spec[3] }); Marker = $spec[3]; Matches = $spec[2] -ceq $identity.Fingerprint } })
            $step = Invoke-Dlss5TestLocationStep -Package $Case.Package
            Assert-Dlss5True ($step.Result.Created -and (Get-Dlss5LocationState -Location $location).Record.Notes['transaction_status'] -ceq '') "$caseName did not give a fresh record."
            foreach ($orphan in $orphans) { Assert-Dlss5True (Test-Path -LiteralPath $orphan.Folder) "$caseName removed an orphan." }
            $named = Format-Dlss5AbandonedMarkers -Abandoned $step.Plan.Abandoned
            foreach ($orphan in $orphans) {
                $text = $orphan.Path + ' (record ' + (Join-Path $orphan.Folder 'LOCATION.md') + '): ' + $orphan.Marker
                Assert-Dlss5Equal $named.Contains($text) $orphan.Matches "$caseName did not name exactly the abandoned markers of this game: $named"
            }
        }
    }
    # The prompt names the abandoned marker.
    $fixture = New-Dlss5IsolatedLaunchFixture -Name 'store-abandoned-prompt' -StubBody @($script:StorePromptStubLine)
    $fingerprint = (Get-GameIdentity -Dir $fixture.Game).Fingerprint
    $folder = Invoke-Dlss5WithLocalAppData -Path $fixture.LocalAppData -Action { New-Item -ItemType Directory -Force (Get-Dlss5StorePath) | Out-Null; Write-Dlss5TestLocationRecord -LocationPath 'C:\Gone\Old Copy' -Fields @{ folder_token = ('P' + ('2' * 64)); game_fingerprint = $fingerprint; transaction_status = 'stage 9: half copied' } }
    $capture = Join-Path $fixture.StubRoot 'prompt.txt'
    $null = Invoke-Dlss5IsolatedLaunch -Fixture $fixture -Environment @{ DLSS5_TEST_PROMPT_CAPTURE_PATH = $capture }
    $prompt = Read-Dlss5PromptCapture $capture
    Assert-Dlss5True $prompt.Contains('orphaned_transaction_markers: C:\Gone\Old Copy (record ' + (Join-Path $folder 'LOCATION.md') + '): stage 9: half copied') 'The prompt did not name the abandoned marker.'
    Assert-Dlss5True ([regex]::IsMatch($prompt, '(?m)^transaction_status: \r?$')) 'A fresh record did not start without a marker.'
}

Invoke-Dlss5Case 'store session status is written before a malformed display record exits 5' {
    $fixture = New-Dlss5IsolatedLaunchFixture -Name 'store-status-before-display' -StubBody @('pwsh -NoProfile -File "%DLSS5_TEST_AGENT_SCRIPT%" -GameNotesPath "%DLSS5_TEST_GAME_NOTES_PATH%"')
    $agentScript = Join-Path $fixture.StubRoot 'write-invalid-target.ps1'
    [IO.File]::WriteAllText($agentScript, "param([string]`$GameNotesPath)`r`n`$end = '### === DLSS5_GAME_NOTES_' + 'END ==='`r`n`$text = [IO.File]::ReadAllText(`$GameNotesPath)`r`n[IO.File]::WriteAllText(`$GameNotesPath, `$text.Replace(`$end, '### target_display.tv.runtime_status: unverified' + [char]13 + [char]10 + `$end), [Text.UTF8Encoding]::new(`$false))`r`n", [Text.UTF8Encoding]::new($false))
    $process = Invoke-Dlss5IsolatedLaunch -Fixture $fixture -Environment @{ DLSS5_TEST_AGENT_SCRIPT = $agentScript; DLSS5_TEST_GAME_NOTES_PATH = $fixture.GameNotesPath }
    Assert-Dlss5Equal $process.ExitCode 5 "A malformed target record did not exit 5: $($process.StandardError)"
    Assert-Dlss5Equal (Get-Dlss5FixtureLocationRecord $fixture)['session_status'] 'agent_session_ended' 'The session status was lost to the malformed target record.'
}

Invoke-Dlss5Case 'store menu lists the engine store and removes orphaned, unreadable, mismatched and collision records on confirmation' {
    $opened = [Collections.Generic.List[string]]::new()
    $savedOpen = $script:Dlss5OpenFile
    $script:Dlss5OpenFile = { param($FilePath) $opened.Add($FilePath) }
    try {
        $bytes = New-Dlss5PackageVariant -Bytes $script:CandidateBytes -State (New-Dlss5StateLines)
        Invoke-Dlss5PackageInteraction -Name 'store-menu-game' -Bytes $bytes -Action {
            param($PackagePath, $Game)
            $location = Get-Dlss5LocationIdentity -PackagePath $PackagePath
            # Neither file exists yet: both are shown as not created, with nothing to open, and the menu offers the view.
            $script:Dlss5Console = New-Dlss5SubstitutedConsole @('n', 'Enter', 'Escape', 'Escape')
            $null = Invoke-Dlss5Menu -Path $PackagePath
            $output = $script:Dlss5Console.Output -join "`n"
            Assert-Dlss5True ($output.Contains('[n] Stores') -and $output.Contains('  Engine file: ' + (Get-Dlss5EngineFilePath) + ' (not created)') -and $output.Contains('  This location''s record: ' + $location.RecordPath + ' (not created)')) "The view did not list both files as not created: $output"
            Assert-Dlss5True (-not $output.Contains('Open the engine file')) 'The view offered to open a file that does not exist.'
            # Both files present: each opens, and neither can be cleared.
            $lock = Enter-Dlss5BootstrapLock
            try { Write-Dlss5EngineFileNotes -Notes (New-Dlss5TrustFixture).Notes -Current (Read-Dlss5EngineFile) }
            finally { Exit-Dlss5BootstrapLock $lock }
            $null = Invoke-Dlss5TestLocationStep -Package $PackagePath
            $script:Dlss5Console = New-Dlss5SubstitutedConsole @('e', 'Enter', 'l', 'Enter', 'Escape')
            Invoke-Dlss5StoreMenu -Path $PackagePath
            $output = $script:Dlss5Console.Output -join "`n"
            Assert-Dlss5True ($opened.Contains((Get-Dlss5EngineFilePath)) -and $opened.Contains($location.RecordPath)) "The view did not open both files: $($opened -join ', ')"
            Assert-Dlss5True ($output.Contains('(present)') -and -not $output.Contains('Clear the engine') -and -not $output.Contains('Clear this location')) "The view offered to clear a file, or did not show it present: $output"
            # An orphan with a pending marker and an unreadable folder are listed; a cancelled removal keeps the record.
            $orphan = Write-Dlss5TestLocationRecord -LocationPath 'C:\Gone\Listed Game' -Fields @{ folder_token = ('e' * 48); game_fingerprint = ('c' * 64); transaction_status = 'stage 8: pending' }
            $unreadable = Join-Path (Get-Dlss5LocationsDirectory) (Get-Dlss5TestLocationFolderName 'C:\Gone\Broken Game')
            New-Item -ItemType Directory -Force $unreadable | Out-Null
            [IO.File]::WriteAllText((Join-Path $unreadable 'LOCATION.md'), "broken`r`n")
            $view = Get-Dlss5StoreView -Path $PackagePath
            $orphanIndex = [array]::IndexOf(@($view.Removable | ForEach-Object { $_.Folder.Path }), $orphan) + 1
            $unreadableIndex = [array]::IndexOf(@($view.Removable | ForEach-Object { $_.Folder.Path }), $unreadable) + 1
            Assert-Dlss5True ($orphanIndex -gt 0 -and $unreadableIndex -gt 0) 'The orphan and the unreadable folder were not both listed.'
            $script:Dlss5Console = New-Dlss5SubstitutedConsole @([string]$orphanIndex, 'Enter', 'Enter', 'Escape')
            Invoke-Dlss5StoreMenu -Path $PackagePath
            $output = $script:Dlss5Console.Output -join "`n"
            Assert-Dlss5True ($output.Contains('the record of C:\Gone\Listed Game, a folder that no longer exists, with the pending transaction marker: stage 8: pending') -and $output.Contains('the record folder ' + (Split-Path -Leaf $unreadable) + ', whose contents cannot be read')) "The listing did not show the orphan's path and marker and the unreadable folder's name: $output"
            Assert-Dlss5True ($output.Contains('Remove the record of C:\Gone\Listed Game, a folder that no longer exists, with the pending transaction marker: stage 8: pending') -and $output.Contains('Kept; nothing was removed.')) "The confirmation did not show the marker, or a cancel removed the record: $output"
            Assert-Dlss5True (Test-Path -LiteralPath $orphan) 'A cancelled removal removed the orphan.'
            foreach ($target in @($orphan, $unreadable)) {
                $index = [array]::IndexOf(@((Get-Dlss5StoreView -Path $PackagePath).Removable | ForEach-Object { $_.Folder.Path }), $target) + 1
                $script:Dlss5Console = New-Dlss5SubstitutedConsole @([string]$index, 'Enter', 'y', 'Enter', 'Escape')
                Invoke-Dlss5StoreMenu -Path $PackagePath
                Assert-Dlss5Equal (Test-Path -LiteralPath $target) $false "A confirmed removal did not remove $target"
            }
            # This location's record for another game, then a collision record in its place, are listed and removable.
            $own = (Get-Dlss5LocationState -Location $location).FolderPath
            foreach ($fieldsSet in @(@{ location_path = $location.Path; game_fingerprint = ('f' * 64); folder_token = $location.Token }, @{ location_path = 'C:\Elsewhere\Collided'; game_fingerprint = ('f' * 64); folder_token = $location.Token })) {
                $null = Write-Dlss5TestLocationRecord -LocationPath $fieldsSet['location_path'] -FolderName (Split-Path -Leaf $own) -Fields $fieldsSet
                $view = Get-Dlss5StoreView -Path $PackagePath
                Assert-Dlss5True (@($view.Removable | Where-Object { $_.Folder.Path -ceq $own -and $_.Kind -cin @('mismatch', 'collision') }).Count -eq 1) "This location's refused record was not listed: $($view.OwnStatus)"
                $index = [array]::IndexOf(@($view.Removable | ForEach-Object { $_.Folder.Path }), $own) + 1
                $script:Dlss5Console = New-Dlss5SubstitutedConsole @([string]$index, 'Enter', 'y', 'Enter', 'Escape')
                Invoke-Dlss5StoreMenu -Path $PackagePath
                Assert-Dlss5Equal (Test-Path -LiteralPath $own) $false "This location's refused record was not removed: $($view.OwnStatus)"
            }
        }
        # The shared AppData copy lists the engine file and the removable records, but no record of its own. Pluri-Bot checks the same for the hello-world base.
        foreach ($variant in @(,@('slot', $script:CandidateBytes))) {
            Invoke-Dlss5PackageInteraction -Name ('store-menu-' + $variant[0]) -Bytes ([byte[]]$variant[1]) -Action {
                param($PackagePath, $Game)
                $path = $PackagePath
                if ($variant[0] -ceq 'slot') { $path = Get-Dlss5StorePath 'DLSS5-ADDER.cmd'; [IO.File]::WriteAllBytes($path, [byte[]]$variant[1]) }
                $orphan = Write-Dlss5TestLocationRecord -LocationPath 'C:\Gone\Slot Game' -Fields @{ folder_token = ('e' * 48); game_fingerprint = ('c' * 64); transaction_status = 'stage 1' }
                $unreadable = Join-Path (Get-Dlss5LocationsDirectory) (Get-Dlss5TestLocationFolderName 'C:\Gone\Slot Broken')
                New-Item -ItemType Directory -Force $unreadable | Out-Null
                $view = Get-Dlss5StoreView -Path $path
                Assert-Dlss5True ($null -eq $view.OwnStatus -and $view.Removable.Count -eq 2) "The $($variant[0]) view did not list the records without one of its own: $($view.OwnStatus) $($view.Removable.Count)"
                foreach ($target in @($orphan, $unreadable)) {
                    $index = [array]::IndexOf(@((Get-Dlss5StoreView -Path $path).Removable | ForEach-Object { $_.Folder.Path }), $target) + 1
                    $script:Dlss5Console = New-Dlss5SubstitutedConsole @([string]$index, 'Enter', 'y', 'Enter', 'Escape')
                    Invoke-Dlss5StoreMenu -Path $path
                    $output = $script:Dlss5Console.Output -join "`n"
                    Assert-Dlss5Equal (Test-Path -LiteralPath $target) $false "The $($variant[0]) view did not remove $target"
                    Assert-Dlss5True (-not $output.Contains('This location''s record')) "The $($variant[0]) view showed a record of its own."
                }
            }
        }
    }
    finally { $script:Dlss5OpenFile = $savedOpen }
}
