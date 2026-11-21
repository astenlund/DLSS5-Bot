# Loaded by the release suite after the mission merge cases: the game fingerprint cases added in v61, where a store keeps the fingerprint
# it holds when that fingerprint covers a subset of the game's current executables.
if ($null -eq (Get-Command Resolve-Dlss5GameFingerprint -ErrorAction SilentlyContinue)) {
    $script:Failures.Add('FAIL game fingerprint cases: the updater under test does not keep a subset fingerprint')
    return
}

function Get-Dlss5ReferenceSubsetFingerprints {
    param([Parameter(Mandatory=$true)]$GameIdentity)

    # v62's construction of the subset search, name by name in PowerShell, as the reference the compiled search must reproduce.
    [string[]]$names = @($GameIdentity.FingerprintExecutables)
    $count = $names.Count
    $removals = [Collections.Generic.List[int[]]]::new()
    if ($count -le $script:Dlss5FingerprintFullSearchLimit) {
        for ($mask = 1; $mask -lt (1 -shl $count); $mask++) {
            $removals.Add([int[]]@(for ($index = 0; $index -lt $count; $index++) { if (($mask -band (1 -shl $index)) -ne 0) { $index } }))
        }
    }
    else {
        for ($first = 0; $first -lt $count; $first++) {
            $removals.Add([int[]]@($first))
            for ($second = $first + 1; $second -lt $count; $second++) { $removals.Add([int[]]@($first, $second)) }
        }
    }
    $fingerprints = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($removed in $removals) {
        [string[]]$kept = @(for ($index = 0; $index -lt $count; $index++) { if ($removed -notcontains $index) { $names[$index] } })
        [void]$fingerprints.Add((Get-Dlss5GameFingerprint -SteamAppId $GameIdentity.SteamAppId -FolderName $GameIdentity.FolderName -ExecutableNames $kept))
    }
    [string[]]$largest = @($GameIdentity.LargestExecutables)
    if ($largest.Count -lt $count) { [void]$fingerprints.Add((Get-Dlss5GameFingerprint -SteamAppId $GameIdentity.SteamAppId -FolderName $GameIdentity.FolderName -ExecutableNames $largest)) }

    return ,$fingerprints
}

function New-Dlss5FingerprintIdentity {
    param([Parameter(Mandatory=$true)][string]$FolderName, [Parameter(Mandatory=$true)][AllowEmptyCollection()][string[]]$Names, [string]$SteamAppId = '')

    # A game identity with the fields the subset search reads, the eight largest being the first eight names.
    [string[]]$sorted = @($Names)
    [Array]::Sort($sorted, [StringComparer]::Ordinal)
    [string[]]$largest = @($Names | Select-Object -First 8)
    [Array]::Sort($largest, [StringComparer]::Ordinal)

    return [pscustomobject]@{ SteamAppId = $SteamAppId; FolderName = $FolderName; FingerprintExecutables = $sorted; LargestExecutables = $largest }
}

function New-Dlss5FingerprintGame {
    param([Parameter(Mandatory=$true)][string]$Path, [Parameter(Mandatory=$true)][string[]]$Executables)

    New-Item -ItemType Directory -Force $Path | Out-Null
    foreach ($name in $Executables) { [IO.File]::WriteAllBytes((Join-Path $Path $name), [byte[]](1)) }

    return $Path
}

Invoke-Dlss5Case 'fingerprint keeps a subset fingerprint when an executable is added and matches again once it is removed' {
    $game = New-Dlss5FingerprintGame -Path (Join-Path $script:ScratchRoot 'fingerprint-added\Fixture Game') -Executables @('game.exe')
    $narrow = (Get-GameIdentity -Dir $game).Fingerprint
    [IO.File]::WriteAllBytes((Join-Path $game 'mod-helper64.exe'), [byte[]](1))
    $wide = Get-GameIdentity -Dir $game
    Assert-Dlss5True ($wide.Fingerprint -cne $narrow) 'The added executable did not change the current fingerprint, so the case tests nothing.'
    Assert-Dlss5Equal (Resolve-Dlss5GameFingerprint -Fingerprint $narrow -GameIdentity $wide) $narrow 'A fingerprint over a subset of the executables was not kept as it is.'
    Assert-Dlss5Equal (Resolve-Dlss5GameFingerprint -Fingerprint $wide.Fingerprint -GameIdentity $wide) $wide.Fingerprint 'The current fingerprint was not kept.'
    Remove-Item -LiteralPath (Join-Path $game 'mod-helper64.exe')
    $again = Get-GameIdentity -Dir $game
    Assert-Dlss5Equal (Resolve-Dlss5GameFingerprint -Fingerprint $narrow -GameIdentity $again) $narrow 'The kept fingerprint did not match once the added executable was removed.'
    # Another game, a renamed main executable, and values that are no fingerprint at all stay refused.
    $other = New-Dlss5FingerprintGame -Path (Join-Path $script:ScratchRoot 'fingerprint-added\Other Game') -Executables @('game.exe', 'mod-helper64.exe')
    Assert-Dlss5Equal (Resolve-Dlss5GameFingerprint -Fingerprint $narrow -GameIdentity (Get-GameIdentity -Dir $other)) $null 'A fingerprint of another game folder was accepted.'
    Rename-Item -LiteralPath (Join-Path $game 'game.exe') -NewName 'renamed.exe'
    [IO.File]::WriteAllBytes((Join-Path $game 'mod-helper64.exe'), [byte[]](1))
    Assert-Dlss5Equal (Resolve-Dlss5GameFingerprint -Fingerprint $narrow -GameIdentity (Get-GameIdentity -Dir $game)) $null 'A fingerprint whose executable is gone was accepted.'
    foreach ($value in @('', 'fingerprint', ('f' * 64), $narrow.ToUpperInvariant())) {
        Assert-Dlss5Equal (Resolve-Dlss5GameFingerprint -Fingerprint $value -GameIdentity $again) $null "A value that is no fingerprint of this game was accepted: [$value]"
    }
}

Invoke-Dlss5Case 'fingerprint over the eight largest executables is kept, not widened as a legacy form, when a smaller one is added' {
    # With eight executables the fingerprint is also the legacy form over the eight largest; a smaller added one leaves those eight the largest.
    $names = @(1..8 | ForEach-Object { 'main{0}.exe' -f $_ })
    $game = Join-Path $script:ScratchRoot 'fingerprint-largest\Largest Game'
    New-Item -ItemType Directory -Force $game | Out-Null
    foreach ($name in $names) { [IO.File]::WriteAllBytes((Join-Path $game $name), [byte[]]::new(100)) }
    $eight = (Get-GameIdentity -Dir $game).Fingerprint
    [IO.File]::WriteAllBytes((Join-Path $game 'helper.exe'), [byte[]](1))
    $nine = Get-GameIdentity -Dir $game
    Assert-Dlss5True ($nine.LegacyFingerprints -ccontains $eight) 'The stored fingerprint is not also the legacy form, so the case tests nothing.'
    Assert-Dlss5Equal (Resolve-Dlss5GameFingerprint -Fingerprint $eight -GameIdentity $nine) $eight 'A fingerprint over the eight largest was widened as a legacy form.'
    # Beyond the search limit the eight largest are searched too: three more small executables are three removed from the current set.
    foreach ($name in @('helper2.exe', 'helper3.exe')) { [IO.File]::WriteAllBytes((Join-Path $game $name), [byte[]](1)) }
    foreach ($name in @('extra1.exe', 'extra2.exe')) { [IO.File]::WriteAllBytes((Join-Path $game $name), [byte[]](2)) }
    Assert-Dlss5Equal (Resolve-Dlss5GameFingerprint -Fingerprint $eight -GameIdentity (Get-GameIdentity -Dir $game)) $eight 'Beyond the limit, a fingerprint over the eight largest was not kept.'
    foreach ($name in @('helper.exe', 'helper2.exe', 'helper3.exe', 'extra1.exe', 'extra2.exe')) { Remove-Item -LiteralPath (Join-Path $game $name) }
    Assert-Dlss5Equal (Resolve-Dlss5GameFingerprint -Fingerprint $eight -GameIdentity (Get-GameIdentity -Dir $game)) $eight 'The kept fingerprint did not match once the added executables were removed.'
}

Invoke-Dlss5Case 'fingerprint search covers every subset up to the limit and one or two removed executables beyond it' {
    $full = @(1..$script:Dlss5FingerprintFullSearchLimit | ForEach-Object { 'part{0:d2}.exe' -f $_ })
    $game = New-Dlss5FingerprintGame -Path (Join-Path $script:ScratchRoot 'fingerprint-limit\Limit Game') -Executables $full
    $identity = Get-GameIdentity -Dir $game
    $stored = {
        param([string[]]$Names)
        [string[]]$sorted = @($Names)
        [Array]::Sort($sorted, [StringComparer]::Ordinal)
        Get-Dlss5GameFingerprint -SteamAppId '' -FolderName 'Limit Game' -ExecutableNames $sorted
    }
    Assert-Dlss5Equal (Resolve-Dlss5GameFingerprint -Fingerprint (& $stored @('part02.exe')) -GameIdentity $identity) (& $stored @('part02.exe')) 'At the limit, a fingerprint with all but one executable removed was refused.'
    Assert-Dlss5Equal (Resolve-Dlss5GameFingerprint -Fingerprint (& $stored ([string[]]@())) -GameIdentity $identity) (& $stored ([string[]]@())) 'At the limit, a fingerprint over no executables was refused.'
    # The removed executables are among the eight largest, so no removal set below is the always-searched set of the eight largest.
    foreach ($name in @('part03.exe', 'part07.exe', 'part99.exe')) { [IO.File]::WriteAllBytes((Join-Path $game $name), [byte[]]::new(50)) }
    $beyond = Get-GameIdentity -Dir $game
    $twoRemoved = @($full | Where-Object { $_ -cnotin @('part03.exe', 'part07.exe') }) + 'part99.exe'
    $threeRemoved = @($full | Where-Object { $_ -cnotin @('part03.exe', 'part07.exe') })
    Assert-Dlss5Equal (Resolve-Dlss5GameFingerprint -Fingerprint (& $stored $twoRemoved) -GameIdentity $beyond) (& $stored $twoRemoved) 'Beyond the limit, a fingerprint with two executables removed was refused.'
    Assert-Dlss5Equal (Resolve-Dlss5GameFingerprint -Fingerprint (& $stored $full) -GameIdentity $beyond) (& $stored $full) 'Beyond the limit, a fingerprint with one executable removed was refused.'
    Assert-Dlss5Equal (Resolve-Dlss5GameFingerprint -Fingerprint (& $stored $threeRemoved) -GameIdentity $beyond) $null 'Beyond the limit, a fingerprint with three executables removed was accepted.'
}

Invoke-Dlss5Case 'fingerprint session step keeps the narrower fingerprint in the record, the game notes and a takeover' {
    Invoke-Dlss5StoreCase -Name 'fingerprint-store' -Body {
        param($Case)
        $notesPath = Join-Path $Case.Game 'DLSS5-ADDER.md'
        [IO.File]::WriteAllBytes((Join-Path $Case.Game 'game.exe'), [byte[]](1))
        $narrow = (Get-GameIdentity -Dir $Case.Game).Fingerprint
        $first = Invoke-Dlss5TestLocationStep -Package $Case.Package
        Assert-Dlss5Equal $first.Result.Notes['game_fingerprint'] $narrow 'The first record did not take the current fingerprint.'
        $notes = New-Dlss5SeededGameNotes -Fingerprint $narrow
        Write-Dlss5NotesFileAtomically -Path $notesPath -Notes $notes -BeginMarker $GameNotesBeginMarker -EndMarker $GameNotesEndMarker -KnownOrder $GameNotesOrder
        [IO.File]::WriteAllBytes((Join-Path $Case.Game 'mod-helper64.exe'), [byte[]](1))
        $notes = Read-Dlss5NotesFile -Path $notesPath -BeginMarker $GameNotesBeginMarker -EndMarker $GameNotesEndMarker
        $step = Invoke-Dlss5TestLocationStep -Package $Case.Package -GameNotes $notes
        Assert-Dlss5True ($step.Identity.Fingerprint -cne $narrow) 'The added executable did not change the current fingerprint, so the case tests nothing.'
        Assert-Dlss5True ($step.Plan.Fingerprint -ceq $narrow -and $step.Result.Notes['game_fingerprint'] -ceq $narrow) 'The record was widened to the current fingerprint.'
        Assert-Dlss5Equal (Invoke-Dlss5GameNotesMigration -GameNotesPath $notesPath -GameNotes $notes -Location $step.Location -Fingerprint $step.Plan.Fingerprint) $false 'Game notes holding the kept fingerprint were rewritten.'
        # Game notes over the wider set, beside a record over the narrower one, are brought to the record's fingerprint.
        $notes['game_fingerprint'] = $step.Identity.Fingerprint
        Write-Dlss5NotesFileAtomically -Path $notesPath -Notes $notes -BeginMarker $GameNotesBeginMarker -EndMarker $GameNotesEndMarker -KnownOrder $GameNotesOrder
        $step = Invoke-Dlss5TestLocationStep -Package $Case.Package -GameNotes $notes
        Assert-Dlss5Equal $step.Plan.Fingerprint $narrow 'The session did not keep the record''s fingerprint over the notes''.'
        $null = Invoke-Dlss5GameNotesMigration -GameNotesPath $notesPath -GameNotes $notes -Location $step.Location -Fingerprint $step.Plan.Fingerprint
        Assert-Dlss5Equal (Read-Dlss5NotesFile -Path $notesPath -BeginMarker $GameNotesBeginMarker -EndMarker $GameNotesEndMarker)['game_fingerprint'] $narrow 'The game notes did not take the record''s fingerprint.'
        # A moved location's record over the narrower set is taken over with its fingerprint.
        $location = $step.Location
        $fields = @{ folder_token = $location.Token; game_fingerprint = $narrow; session_status = 'agent_session_ended' }
        Remove-Dlss5LocationFolder $location.FolderPath
        $orphan = Write-Dlss5TestLocationRecord -LocationPath 'C:\Gone\Moved Game' -Fields $fields
        $step = Invoke-Dlss5TestLocationStep -Package $Case.Package
        Assert-Dlss5True (-not $step.Result.Created -and -not (Test-Path -LiteralPath $orphan)) 'The moved location over the narrower set was not taken over.'
        Assert-Dlss5Equal $step.Result.Notes['game_fingerprint'] $narrow 'The takeover widened the fingerprint.'
        # A record of another game is still refused.
        $null = Update-Dlss5LocationRecord -Location $location -Change { param($recordNotes) $recordNotes['game_fingerprint'] = ('f' * 64) }
        Assert-Dlss5Throws { Invoke-Dlss5TestLocationStep -Package $Case.Package } ([IO.InvalidDataException]) 'A record of another game was accepted.'
    }
}

Invoke-Dlss5Case 'fingerprint session plan skips the subset search for an orphaned record of another game' {
    Invoke-Dlss5StoreCase -Name 'fingerprint-foreign-orphan' -Body {
        param($Case)
        [IO.File]::WriteAllBytes((Join-Path $Case.Game 'game.exe'), [byte[]](1))
        $location = Get-Dlss5LocationIdentity -PackagePath $Case.Package
        $notesPath = Join-Path $Case.Game 'DLSS5-ADDER.md'
        # The other game's record holds a fingerprint that is neither this game's current one nor a legacy form, which v62 searched every subset for.
        $foreign = Write-Dlss5TestLocationRecord -LocationPath 'C:\Gone\Other Game' -Fields @{ folder_token = 'other-token'; game_fingerprint = ('a' * 64); game_name = 'Other Game'; steam_appid = '4321'; transaction_status = 'pending other' }
        $identity = Get-GameIdentity -Dir $Case.Game
        Assert-Dlss5True ($identity.LegacyFingerprints -cnotcontains ('a' * 64)) 'The foreign fingerprint is a legacy form of this game, so the case tests nothing.'
        $plan = Get-Dlss5SessionLocationPlan -Location $location -GameIdentity $identity -GameNotes $null -GameNotesPath $notesPath
        Assert-Dlss5True ($null -eq $identity.PSObject.Properties['SubsetFingerprints']) 'The session plan searched the subsets for a record of another game.'
        Assert-Dlss5True ($null -eq $plan.Takeover -and @($plan.Abandoned).Count -eq 0) 'The record of another game was treated as this game''s.'
        Assert-Dlss5True (Test-Path -LiteralPath $foreign) 'The plan touched the record of another game.'
        # A record without a game_name, which no session writes, is still searched.
        $null = Write-Dlss5TestLocationRecord -LocationPath 'C:\Gone\Nameless Game' -Fields @{ folder_token = 'nameless-token'; game_fingerprint = ('b' * 64) }
        $identity = Get-GameIdentity -Dir $Case.Game
        $null = Get-Dlss5SessionLocationPlan -Location $location -GameIdentity $identity -GameNotes $null -GameNotesPath $notesPath
        Assert-Dlss5True ($null -ne $identity.PSObject.Properties['SubsetFingerprints']) 'A record without a game_name skipped the subset search.'
    }
}

Invoke-Dlss5Case 'fingerprint search still finds a subset record of this game as a session writes it, and skips one that names another game' {
    Invoke-Dlss5StoreCase -Name 'fingerprint-named-record' -Body {
        param($Case)
        [IO.File]::WriteAllBytes((Join-Path $Case.Game 'game.exe'), [byte[]](1))
        $narrow = (Get-GameIdentity -Dir $Case.Game).Fingerprint
        [IO.File]::WriteAllBytes((Join-Path $Case.Game 'mod-helper64.exe'), [byte[]](1))
        $wide = Get-GameIdentity -Dir $Case.Game
        Assert-Dlss5True ($wide.Fingerprint -cne $narrow -and $wide.LegacyFingerprints -cnotcontains $narrow) 'The narrow fingerprint is neither a subset-only match nor different, so the case tests nothing.'
        # A moved location's record over the narrower set, with its game name in another case as the folder may have had, is taken over.
        $location = Get-Dlss5LocationIdentity -PackagePath $Case.Package
        $orphan = Write-Dlss5TestLocationRecord -LocationPath 'C:\Gone\Store Game' -Fields @{ folder_token = $location.Token; game_fingerprint = $narrow; game_name = 'STORE game'; steam_appid = ''; session_status = 'agent_session_ended' }
        $step = Invoke-Dlss5TestLocationStep -Package $Case.Package
        Assert-Dlss5True (-not $step.Result.Created -and -not (Test-Path -LiteralPath $orphan)) 'The moved location of this game over the narrower set was not taken over.'
        Assert-Dlss5Equal $step.Result.Notes['game_fingerprint'] $narrow 'The takeover did not keep the narrower fingerprint.'
        Assert-Dlss5Equal $step.Result.Notes['game_name'] 'Store Game' 'The takeover did not write the current game name.'
        # The record's names decide the subset search alone: one naming another game by folder or app id skips it, even for this game's subset fingerprint.
        $named = { param([string]$Name, [string]$AppId) $notes = New-Dlss5LocationNotes; $notes['game_name'] = $Name; $notes['steam_appid'] = $AppId; $notes }
        Assert-Dlss5Equal (Resolve-Dlss5GameFingerprint -Fingerprint $narrow -GameIdentity (Get-GameIdentity -Dir $Case.Game) -Record (& $named 'Other Game' '')) $null 'A record naming another folder was searched.'
        Assert-Dlss5Equal (Resolve-Dlss5GameFingerprint -Fingerprint $narrow -GameIdentity (Get-GameIdentity -Dir $Case.Game) -Record (& $named 'Store Game' '4321')) $null 'A record naming another app id was searched.'
        Assert-Dlss5Equal (Resolve-Dlss5GameFingerprint -Fingerprint $narrow -GameIdentity (Get-GameIdentity -Dir $Case.Game) -Record (& $named '' '')) $narrow 'A record without a game_name was not searched.'
        Assert-Dlss5Equal (Resolve-Dlss5GameFingerprint -Fingerprint $narrow -GameIdentity (Get-GameIdentity -Dir $Case.Game) -Record (& $named 'store GAME' '')) $narrow 'A record naming this game in another case was not searched.'
        # The exact and legacy checks do not depend on the record's names.
        Assert-Dlss5Equal (Resolve-Dlss5GameFingerprint -Fingerprint $wide.Fingerprint -GameIdentity (Get-GameIdentity -Dir $Case.Game) -Record (& $named 'Other Game' '')) $wide.Fingerprint 'The current fingerprint was refused for a record naming another game.'
    }
}

Invoke-Dlss5Case 'fingerprint compiled subset search builds the same sets as the PowerShell construction it replaced' {
    # The material format is pinned to the fingerprint v62 computes for this identity, so the reference and the search cannot drift together.
    $accented = 'Caf' + [char]0x00E9
    Assert-Dlss5Equal (Get-Dlss5GameFingerprint -SteamAppId '1234' -FolderName ('Pin ' + $accented) -ExecutableNames ([string[]]@('a.exe', ($accented.ToLowerInvariant() + '.exe')))) '6578f97a11ba3075a8d69979261e196b63c158c88bffa836b33efea2170544de' 'The fingerprint material changed.'
    foreach ($count in @(0, 1, 2, 10, 11, 12)) {
        [string[]]$names = @(for ($index = 1; $index -le $count; $index++) { 'part{0:d2}.exe' -f $index })
        foreach ($identity in @((New-Dlss5FingerprintIdentity -FolderName 'Subset Game' -Names $names -SteamAppId '1234'), (New-Dlss5FingerprintIdentity -FolderName ('Pin ' + $accented) -Names ([string[]]@($names | ForEach-Object { $accented.ToLowerInvariant() + $_ }))))) {
            [string[]]$expected = @(Get-Dlss5ReferenceSubsetFingerprints -GameIdentity $identity)
            [string[]]$actual = @(Get-Dlss5SubsetFingerprints -GameIdentity $identity)
            [Array]::Sort($expected, [StringComparer]::Ordinal)
            [Array]::Sort($actual, [StringComparer]::Ordinal)
            Assert-Dlss5Equal ($actual -join ',') ($expected -join ',') "The subset search differs from the reference at $count executables in $($identity.FolderName)."
        }
    }
}

Invoke-Dlss5Case 'fingerprint launch after a mod adds an executable runs the session and keeps the stored fingerprint' {
    $fixture = New-Dlss5IsolatedLaunchFixture -Name 'fingerprint-launch' -StubBody @($script:StorePromptStubLine)
    [IO.File]::WriteAllBytes((Join-Path $fixture.Game 'game.exe'), [byte[]](1))
    $narrow = (Get-GameIdentity -Dir $fixture.Game).Fingerprint
    $location = Get-Dlss5FixtureLocation $fixture
    $null = Invoke-Dlss5WithLocalAppData -Path $fixture.LocalAppData -Action { New-Item -ItemType Directory -Force (Get-Dlss5StorePath) | Out-Null; Write-Dlss5TestLocationRecord -LocationPath $location.Path -Fields @{ folder_token = $location.Token; game_fingerprint = $narrow; session_status = 'agent_session_ended' } }
    $notes = New-Dlss5GameNotesFixture
    $notes['game_fingerprint'] = $narrow
    Write-Dlss5NotesFileAtomically -Path $fixture.GameNotesPath -Notes $notes -BeginMarker $GameNotesBeginMarker -EndMarker $GameNotesEndMarker -KnownOrder $GameNotesOrder
    [IO.File]::WriteAllBytes((Join-Path $fixture.Game 'mod-helper64.exe'), [byte[]](1))
    $capture = Join-Path $fixture.StubRoot 'prompt.txt'
    $process = Invoke-Dlss5IsolatedLaunch -Fixture $fixture -Environment @{ DLSS5_TEST_PROMPT_CAPTURE_PATH = $capture }
    $output = $process.StandardOutput + $process.StandardError
    Assert-Dlss5True (-not $output.Contains('belongs to a different game')) "The session was refused as a different game: $output"
    $prompt = Read-Dlss5PromptCapture $capture
    Assert-Dlss5True ([regex]::IsMatch($prompt, '(?m)^game_fingerprint: ' + $narrow + '\r?$')) 'The prompt did not carry the kept fingerprint.'
    Assert-Dlss5Equal (Get-Dlss5FixtureLocationRecord $fixture)['game_fingerprint'] $narrow 'The session widened the record''s fingerprint.'
    Assert-Dlss5Equal (Read-Dlss5NotesFile -Path $fixture.GameNotesPath -BeginMarker $GameNotesBeginMarker -EndMarker $GameNotesEndMarker)['game_fingerprint'] $narrow 'The session widened the game notes'' fingerprint.'
}

Invoke-Dlss5Case 'fingerprint launch without game notes seeds them with the kept fingerprint' {
    $fixture = New-Dlss5IsolatedLaunchFixture -Name 'fingerprint-seed' -StubBody @($script:StorePromptStubLine)
    [IO.File]::WriteAllBytes((Join-Path $fixture.Game 'game.exe'), [byte[]](1))
    $narrow = (Get-GameIdentity -Dir $fixture.Game).Fingerprint
    $location = Get-Dlss5FixtureLocation $fixture
    $null = Invoke-Dlss5WithLocalAppData -Path $fixture.LocalAppData -Action { New-Item -ItemType Directory -Force (Get-Dlss5StorePath) | Out-Null; Write-Dlss5TestLocationRecord -LocationPath $location.Path -Fields @{ folder_token = $location.Token; game_fingerprint = $narrow; session_status = 'agent_session_ended' } }
    [IO.File]::WriteAllBytes((Join-Path $fixture.Game 'mod-helper64.exe'), [byte[]](1))
    $capture = Join-Path $fixture.StubRoot 'prompt.txt'
    $null = Invoke-Dlss5IsolatedLaunch -Fixture $fixture -Environment @{ DLSS5_TEST_PROMPT_CAPTURE_PATH = $capture }
    $null = Read-Dlss5PromptCapture $capture
    Assert-Dlss5Equal (Read-Dlss5NotesFile -Path $fixture.GameNotesPath -BeginMarker $GameNotesBeginMarker -EndMarker $GameNotesEndMarker)['game_fingerprint'] $narrow 'The seeded game notes did not take the kept fingerprint.'
}

Invoke-Dlss5Case 'fingerprint Stores view shows a record over a subset as present, and Clear keeps the notes fingerprint' {
    Invoke-Dlss5PackageInteraction -Name 'fingerprint-view' -Bytes $script:CandidateBytes -Action {
        param($PackagePath, $Game)
        [IO.File]::WriteAllBytes((Join-Path $Game 'game.exe'), [byte[]](1))
        $narrow = (Get-GameIdentity -Dir $Game).Fingerprint
        $null = Invoke-Dlss5TestLocationStep -Package $PackagePath
        $notesPath = Join-Path $Game 'DLSS5-ADDER.md'
        $notes = New-Dlss5SeededGameNotes -Fingerprint $narrow
        $notes['status'] = 'remembered'
        Write-Dlss5NotesFileAtomically -Path $notesPath -Notes $notes -BeginMarker $GameNotesBeginMarker -EndMarker $GameNotesEndMarker -KnownOrder $GameNotesOrder
        [IO.File]::WriteAllBytes((Join-Path $Game 'mod-helper64.exe'), [byte[]](1))
        Assert-Dlss5True ((Get-GameIdentity -Dir $Game).Fingerprint -cne $narrow) 'The added executable did not change the current fingerprint, so the case tests nothing.'
        $view = Get-Dlss5StoreView -Path $PackagePath
        Assert-Dlss5Equal $view.OwnStatus 'present' 'A record over a subset of the executables was not shown as present.'
        Assert-Dlss5Equal @($view.Removable).Count 0 'A record over a subset of the executables was offered for removal.'
        $target = @($view.MissionStores | Where-Object { $_.Store.Slot -ceq 'target' })
        Assert-Dlss5Equal $target.Count 1 'The view did not list the target store.'
        Clear-Dlss5MissionStore -Path $PackagePath -Store $target[0].Store
        $cleared = Read-Dlss5NotesFile -Path $notesPath -BeginMarker $GameNotesBeginMarker -EndMarker $GameNotesEndMarker
        Assert-Dlss5True ($cleared['status'] -ceq '' -and $cleared['game_fingerprint'] -ceq $narrow) 'Clear did not reset the notes while keeping their fingerprint.'
    }
}
