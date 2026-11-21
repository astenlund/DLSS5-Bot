# Loaded by the release suite after the mission file removal cases: the mission memory store and post-run check cases added in v57.
if ($null -eq (Get-Command Get-Dlss5MissionStores -ErrorAction SilentlyContinue)) {
    $script:Failures.Add('FAIL mission stores cases: the updater under test has no mission stores')
    return
}

function ConvertTo-Dlss5TestProject {
    param([Parameter(Mandatory=$true)][string]$MissionId, [string]$Extra = '')

    return ConvertFrom-Dlss5ProjectConfig -Bytes $script:PackageUtf8.GetBytes('{"mission_id":"' + $MissionId + '","rerun":false' + $Extra + '}') -Strict
}

function New-Dlss5FreeFormPackageBytes {
    param([Parameter(Mandatory=$true)][string]$Stores, [AllowNull()][string[]]$State = $null)

    # A plain package declaring the given stores and placing the generated rules in its template.
    $mission = $script:PackageUtf8.GetString([byte[]](Get-Dlss5BootstrapIdentity -Bytes (New-Dlss5PlainPackageBytes)).MissionFiles['MISSION.md'])
    $files = [ordered]@{
        'MISSION.md' = $script:PackageUtf8.GetBytes($mission.Replace('Hello from {{package_dir}}.', 'Hello from {{package_dir}}.' + $script:PackageNewline + '{{stores}}'))
        'PROJECT.json' = $script:PackageUtf8.GetBytes('{"mission_id":"note-taker","rerun":false,"stores":' + $Stores + '}' + $script:PackageNewline)
    }

    return ,(New-Dlss5PackageVariant -Bytes (New-Dlss5PlainPackageBytes) -Files $files -State $State)
}

function New-Dlss5DeclaredDlssBytes {
    param([Parameter(Mandatory=$true)][AllowEmptyCollection()][string[]]$Slots, [Parameter(Mandatory=$true)][AllowEmptyCollection()][string[]]$Checks, [AllowNull()][string[]]$State = $null)

    # The published DLSS mission with only the given stores and checks; the placeholders of the other slots are written out as plain words.
    $mission = $script:PackageUtf8.GetString([byte[]]$script:CandidateIdentity.MissionFiles['MISSION.md'])
    foreach ($slot in $script:Dlss5StoreSlots) {
        if ($slot -cin $Slots) { continue }
        foreach ($name in $script:Dlss5StorePlaceholders[$slot]) { $mission = $mission.Replace('{{' + $name + '}}', $name) }
    }
    if ($Slots.Count -eq 0) { $mission = $mission.Replace('{{stores}}', 'No stores.') }
    $declared = [string]::Join(',', @($Slots | ForEach-Object { '"' + $_ + '":"keyed"' }))
    $names = [string]::Join(',', @($Checks | ForEach-Object { '"' + $_ + '"' }))
    $project = $script:PackageUtf8.GetString([byte[]]$script:CandidateIdentity.MissionFiles['PROJECT.json'])
    $project = $project.Replace('"stores":{"target":"keyed","machine":"keyed","knowledge":"keyed"},"post_run_checks":["display-targets"]', '"stores":{' + $declared + '},"post_run_checks":[' + $names + ']')
    $files = [ordered]@{ 'MISSION.md' = $script:PackageUtf8.GetBytes($mission); 'PROJECT.json' = $script:PackageUtf8.GetBytes($project) }

    return ,(New-Dlss5PackageVariant -Bytes $script:CandidateBytes -Files $files -State $(if ($null -ne $State) { $State } else { New-Dlss5StateLines -Armed $true -MissionEdited $true }))
}

function New-Dlss5StoreLaunchFixture {
    param([Parameter(Mandatory=$true)][string]$Name, [Parameter(Mandatory=$true)][byte[]]$Bytes, [string[]]$StubBody = @())

    $fixture = New-Dlss5IsolatedLaunchFixture -Name $Name -StubBody $StubBody
    [IO.File]::WriteAllBytes($fixture.Updater, $Bytes)
    Write-Dlss5MachineTrustFixture -MachineDirectory $fixture.MachineDirectory -Engine @{ $script:CandidateVersion = $script:CandidateIdentity.EngineSha256 }

    return $fixture
}

function Invoke-Dlss5StoreExecute {
    param([Parameter(Mandatory=$true)]$Fixture, [hashtable]$Environment = @{}, [string[]]$Task = @())

    $status = Get-Dlss5LaunchStatus $Fixture $Environment
    if (-not $status.armed) {
        [void](Invoke-Dlss5IsolatedLaunch -Fixture $Fixture -Arguments @('--internal-accept', $status.expect))
        $status = Get-Dlss5LaunchStatus $Fixture $Environment
        if (-not $status.armed) {
            $armed = Invoke-Dlss5IsolatedLaunch -Fixture $Fixture -Arguments @('--internal-arm', $status.expect)
            Assert-Dlss5Equal $armed.ExitCode 0 "Arming failed: $($armed.StandardOutput) $($armed.StandardError)"
            $status = Get-Dlss5LaunchStatus $Fixture $Environment
        }
    }
    if ($Task.Count -gt 0) { return Invoke-Dlss5IsolatedLaunch -Fixture $Fixture -Arguments $Task -Environment $Environment }

    return Invoke-Dlss5IsolatedLaunch -Fixture $Fixture -Arguments @('--internal-execute', $status.expect) -Environment $Environment
}

$script:StoreArgsStubLine = 'if defined DLSS5_TEST_ARGS_PATH echo %*> "%DLSS5_TEST_ARGS_PATH%"'

Invoke-Dlss5Case 'mission stores declarations parse, refuse every illegal form, default literally and survive the project writer' {
    $project = ConvertTo-Dlss5TestProject 'note-taker' ',"stores":{"knowledge":"free-form","target":"free-form"},"post_run_checks":[]'
    Assert-Dlss5Equal (@((Get-Dlss5ProjectStores $project).Keys) -join ',') 'target,knowledge' 'The declared slots were not read in slot order.'
    Assert-Dlss5Equal (Get-Dlss5ProjectPostRunChecks $project).Count 0 'An empty check list did not mean no checks.'
    $dlss = ConvertTo-Dlss5TestProject 'dlss5' ',"stores":{"target":"keyed"},"post_run_checks":["display-targets"]'
    Assert-Dlss5Equal ((Get-Dlss5ProjectPostRunChecks $dlss) -join ',') 'display-targets' 'The declared check was not read.'
    $illegal = [ordered]@{
        'an unknown slot' = @('note-taker', ',"stores":{"other":"free-form"}')
        'a slot differing in case' = @('note-taker', ',"stores":{"Target":"free-form"}')
        'an unknown format' = @('note-taker', ',"stores":{"target":"plain"}')
        'stores that are not an object' = @('note-taker', ',"stores":["target"]')
        'keyed on another mission' = @('note-taker', ',"stores":{"target":"keyed"}')
        'free-form on dlss5' = @('dlss5', ',"stores":{"target":"free-form"}')
        'checks that are not an array' = @('dlss5', ',"post_run_checks":"display-targets"')
        'an unknown check' = @('dlss5', ',"post_run_checks":["other"]')
        'a repeated check' = @('dlss5', ',"post_run_checks":["display-targets","display-targets"]')
        'a check of the wrong type' = @('dlss5', ',"post_run_checks":[1]')
        'the display check on another mission' = @('note-taker', ',"post_run_checks":["display-targets"]')
        'the display check without the target store' = @('dlss5', ',"stores":{"machine":"keyed"},"post_run_checks":["display-targets"]')
    }
    foreach ($name in $illegal.Keys) { Assert-Dlss5Throws { $null = ConvertTo-Dlss5TestProject $illegal[$name][0] $illegal[$name][1] } ([FormatException]) "PROJECT.json accepted $name." }
    # An absent field means what the mission had before v57, whatever is declared elsewhere.
    $bare = ConvertTo-Dlss5TestProject 'dlss5'
    Assert-Dlss5Equal (@((Get-Dlss5ProjectStores $bare).Values) -join ',') 'keyed,keyed,keyed' 'An absent stores field did not default to all three keyed stores for dlss5.'
    Assert-Dlss5Equal ((Get-Dlss5ProjectPostRunChecks $bare) -join ',') 'display-targets' 'An absent check list did not default to the display check for dlss5.'
    $plain = ConvertTo-Dlss5TestProject 'note-taker'
    Assert-Dlss5True ((Get-Dlss5ProjectStores $plain).Count -eq 0 -and (Get-Dlss5ProjectPostRunChecks $plain).Count -eq 0) 'An absent field gave another mission stores or checks.'
    $older = [pscustomobject]@{ MissionId = 'dlss5' }
    Assert-Dlss5Equal (Get-Dlss5ProjectStores $older).Count 3 'A project built before v57 did not take the historical stores.'
    # The writer keeps an absent field absent and a present field present.
    $absent = $script:PackageUtf8.GetString((ConvertTo-Dlss5ProjectConfigBytes $bare))
    Assert-Dlss5True (-not $absent.Contains('stores') -and -not $absent.Contains('post_run_checks')) "The writer invented a declaration: $absent"
    $present = ConvertFrom-Dlss5ProjectConfig -Bytes (ConvertTo-Dlss5ProjectConfigBytes $dlss) -Strict
    Assert-Dlss5True ($present.Stores.Count -eq 1 -and $present.Stores['target'] -ceq 'keyed' -and (@($present.PostRunChecks) -join ',') -ceq 'display-targets') 'The writer lost a declaration.'
    $empty = ConvertFrom-Dlss5ProjectConfig -Bytes (ConvertTo-Dlss5ProjectConfigBytes (ConvertTo-Dlss5TestProject 'dlss5' ',"stores":{},"post_run_checks":[]')) -Strict
    Assert-Dlss5True ($empty.Stores.Count -eq 0 -and @($empty.PostRunChecks).Count -eq 0) 'The writer turned an explicit empty declaration into the default.'
    # The published packages declare what the spec says.
    Assert-Dlss5Equal (@($script:CandidateIdentity.Project.Stores.Keys) -join ',') 'target,machine,knowledge' 'The published DLSS mission does not declare its stores explicitly.'
    Assert-Dlss5Equal ((@($script:CandidateIdentity.Project.PostRunChecks)) -join ',') 'display-targets' 'The published DLSS mission does not declare its check explicitly.'
}

Invoke-Dlss5Case 'mission stores placeholders follow the declared slots, and the generated rules are placed once in the template text' {
    $files = [ordered]@{}
    foreach ($name in $script:CandidateIdentity.MissionFiles.Keys) { $files[$name] = $script:CandidateIdentity.MissionFiles[$name] }
    $missionText = $script:PackageUtf8.GetString([byte[]]$files['MISSION.md'])
    $projectText = $script:PackageUtf8.GetString([byte[]]$files['PROJECT.json'])
    $withProject = { param([string]$Stores) $copy = [ordered]@{}; foreach ($name in $files.Keys) { $copy[$name] = $files[$name] }; $copy['PROJECT.json'] = $script:PackageUtf8.GetBytes($projectText.Replace('"stores":{"target":"keyed","machine":"keyed","knowledge":"keyed"},"post_run_checks":["display-targets"]', '"stores":{' + $Stores + '},"post_run_checks":[]')); return $copy }
    $null = Get-Dlss5MissionTemplate -Files $files -MissionId 'dlss5'
    foreach ($slot in $script:Dlss5StoreSlots) {
        $others = [string]::Join(',', @($script:Dlss5StoreSlots | Where-Object { $_ -cne $slot } | ForEach-Object { '"' + $_ + '":"keyed"' }))
        Assert-Dlss5Throws { $null = Get-Dlss5MissionTemplate -Files (& $withProject $others) -MissionId 'dlss5' } ([FormatException]) "A template kept naming the placeholders of the undeclared $slot slot."
    }
    $plain = [ordered]@{}
    $plainFiles = (Get-Dlss5BootstrapIdentity -Bytes (New-Dlss5FreeFormPackageBytes -Stores '{"target":"free-form"}')).MissionFiles
    foreach ($name in $plainFiles.Keys) { $plain[$name] = $plainFiles[$name] }
    $null = Get-Dlss5MissionTemplate -Files $plain -MissionId 'note-taker'
    $text = $script:PackageUtf8.GetString([byte[]]$plain['MISSION.md'])
    $variant = { param([string]$Mission, [string]$Project) $copy = [ordered]@{}; foreach ($name in $plain.Keys) { $copy[$name] = $plain[$name] }; $copy['MISSION.md'] = $script:PackageUtf8.GetBytes($Mission); if ($Project.Length -gt 0) { $copy['PROJECT.json'] = $script:PackageUtf8.GetBytes($Project + $script:PackageNewline) }; return $copy }
    Assert-Dlss5Throws { $null = Get-Dlss5MissionTemplate -Files (& $variant $text.Replace('{{stores}}', 'none') '') -MissionId 'note-taker' } ([FormatException]) 'A mission with stores was accepted without the generated rules.'
    Assert-Dlss5Throws { $null = Get-Dlss5MissionTemplate -Files (& $variant $text.Replace('{{stores}}', '{{stores}}{{stores}}') '') -MissionId 'note-taker' } ([FormatException]) 'The generated rules were accepted twice.'
    Assert-Dlss5Throws { $null = Get-Dlss5MissionTemplate -Files (& $variant $text.Replace('Greet.', 'Greet. {{stores}}') '') -MissionId 'note-taker' } ([FormatException]) 'The generated rules were accepted in a mode part.'
    Assert-Dlss5Throws { $null = Get-Dlss5MissionTemplate -Files (& $variant $text '{"mission_id":"note-taker","rerun":false}') -MissionId 'note-taker' } ([FormatException]) 'A mission without stores was accepted naming the generated rules.'
    Assert-Dlss5True ($missionText.Contains('{{stores}}') -and -not $missionText.Contains('External notes write safety')) 'The DLSS template still carries the write safety block.'
}

Invoke-Dlss5Case 'mission stores keyed rules name only the declared stores, and free-form rules list each store with its protocol' {
    $render = { param([string[]]$Slots) Get-Dlss5KeyedStoreRules -Slots $Slots -EngineFilePath 'C:\Store\engine\ENGINE.md' }
    $all = & $render @('target', 'machine', 'knowledge')
    foreach ($expected in @('any of the three notes files', 'All three files require', 'between game, machine, and shared-project ownership.', 'Local\DLSS5-ADDER-MACHINE-NOTES', ' Game notes', 'do not use the machine mutex', 'remove them. Current trust is in the engine file C:\Store\engine\ENGINE.md. The engine file')) { Assert-Dlss5True ($all.Contains($expected)) "The full rules lack: $expected" }
    $two = & $render @('target', 'knowledge')
    Assert-Dlss5True ($two.Contains('either of the two notes files') -and $two.Contains('Both files require') -and $two.Contains('between game and shared-project ownership.')) "The two-store rules were wrong: $two"
    Assert-Dlss5True (-not $two.Contains('.bootstrap.lock') -and -not $two.Contains('bootstrap_ keys') -and -not $two.Contains('machine mutex')) "The rules named the undeclared machine notes: $two"
    $machine = & $render @('machine')
    Assert-Dlss5True ($machine.Contains('the notes file') -and $machine.Contains('The file requires') -and $machine.Contains('     in their documented order.' + [char]13)) "The one-store rules were wrong: $machine"
    Assert-Dlss5True ($machine.Contains('.bootstrap.lock') -and $machine.Contains('bootstrap_ keys') -and -not $machine.Contains('Game notes') -and -not $machine.Contains('crosses between')) "The machine-only rules were wrong: $machine"
    $target = & $render @('target')
    Assert-Dlss5True (-not $target.Contains('.bootstrap.lock') -and -not $target.Contains('crosses between')) "The target-only rules were wrong: $target"
    $targetMachine = & $render @('target', 'machine')
    Assert-Dlss5True ($targetMachine.Contains('either of the two notes files') -and $targetMachine.Contains('Both files require') -and $targetMachine.Contains('between game and machine ownership.')) "The target and machine rules were wrong: $targetMachine"
    Assert-Dlss5True ($targetMachine.Contains('.bootstrap.lock') -and $targetMachine.Contains(' Game notes') -and $targetMachine.Contains('do not use the machine mutex') -and $targetMachine.Contains('bootstrap_ keys')) "The target and machine rules lost a machine or game rule: $targetMachine"
    $machineKnowledge = & $render @('machine', 'knowledge')
    Assert-Dlss5True ($machineKnowledge.Contains('either of the two notes files') -and $machineKnowledge.Contains('between machine and shared-project ownership.') -and $machineKnowledge.Contains('.bootstrap.lock') -and $machineKnowledge.Contains('bootstrap_ keys')) "The machine and knowledge rules were wrong: $machineKnowledge"
    Assert-Dlss5True (-not $machineKnowledge.Contains('Game notes') -and -not $machineKnowledge.Contains('do not use the machine mutex')) "The machine and knowledge rules named the undeclared game notes: $machineKnowledge"
    $knowledgeOnly = & $render @('knowledge')
    Assert-Dlss5True ($knowledgeOnly.Contains('the notes file') -and $knowledgeOnly.Contains('The file requires') -and $knowledgeOnly.Contains('     in their documented order.' + [char]13)) "The knowledge-only rules were wrong: $knowledgeOnly"
    Assert-Dlss5True (-not $knowledgeOnly.Contains('.bootstrap.lock') -and -not $knowledgeOnly.Contains('bootstrap_ keys') -and -not $knowledgeOnly.Contains('Game notes') -and -not $knowledgeOnly.Contains('crosses between')) "The knowledge-only rules named an undeclared store: $knowledgeOnly"
    Assert-Dlss5Equal (Get-Dlss5StoreRulesText -Stores @()) '' 'A mission without stores rendered rules.'
    Invoke-Dlss5PackageInteraction -Name 'mission-stores-rules' -Bytes (New-Dlss5FreeFormPackageBytes -Stores '{"target":"free-form","machine":"free-form"}') -Action {
        param($PackagePath, $Game)
        $stores = Get-Dlss5MissionStores -Project $script:Dlss5ExecutingIdentity.Project -PackagePath $PackagePath
        Assert-Dlss5Equal $stores[0].Path (Join-Path $Game 'note-taker.notes.md') 'The target store is not beside the package.'
        Assert-Dlss5Equal $stores[1].Path (Get-Dlss5StorePath 'missions\note-taker\MACHINE.md') 'The machine store is not in the mission folder.'
        Assert-Dlss5Equal $stores[0].Mutex '' 'A target store took a mutex.'
        Assert-Dlss5Equal $stores[1].Mutex 'Local\DLSS5-ADDER-STORE-note-taker-machine' 'The machine store took the wrong mutex.'
        $rules = Get-Dlss5StoreRulesText -Stores $stores
        foreach ($expected in @($stores[0].Path, $stores[1].Path, 'Read each store at the start', 'at most 1 MiB', 'create-new semantics', 'retain the candidate', 'hold the named mutex Local\DLSS5-ADDER-STORE-note-taker-machine')) { Assert-Dlss5True ($rules.Contains($expected)) "The free-form rules lack: $expected" }
        Assert-Dlss5True (-not $rules.Contains('### key: value')) 'The free-form rules carry the keyed grammar.'
    }
}

Invoke-Dlss5Case 'mission stores seed a missing free-form store, refuse a damaged one, and use the store mutex' {
    Invoke-Dlss5PackageInteraction -Name 'mission-stores-free-form' -Bytes (New-Dlss5FreeFormPackageBytes -Stores '{"target":"free-form","knowledge":"free-form"}') -Action {
        param($PackagePath, $Game)
        $stores = Get-Dlss5MissionStores -Project $script:Dlss5ExecutingIdentity.Project -PackagePath $PackagePath
        Initialize-Dlss5MissionStores -Stores $stores -MissionId 'note-taker'
        Assert-Dlss5Equal ([IO.File]::ReadAllText($stores[0].Path)) ("# note-taker: target store`r`n") 'The target store was not seeded.'
        Assert-Dlss5True (Test-Path -LiteralPath $stores[1].Path -PathType Leaf) 'The knowledge store was not seeded.'
        Assert-Dlss5MissionStoresAfterSession -Stores $stores
        # Existing content is kept.
        [IO.File]::WriteAllText($stores[0].Path, "kept`r`n", [Text.UTF8Encoding]::new($false))
        Initialize-Dlss5MissionStores -Stores $stores -MissionId 'note-taker'
        Assert-Dlss5Equal ([IO.File]::ReadAllText($stores[0].Path)) "kept`r`n" 'A second launch rewrote the store.'
        # Only the size is wrong here: the bytes are valid UTF-8 and end with a CRLF newline.
        $oversized = [byte[]]::new($script:Dlss5StoreByteLimit + 2)
        $oversized[-2] = 13
        $oversized[-1] = 10
        $bad = [ordered]@{
            'a byte-order mark' = [byte[]](239, 187, 191, 65, 13, 10)
            'invalid UTF-8' = [byte[]](255, 13, 10)
            'bare LF endings' = [byte[]](65, 10)
            'mixed endings' = [byte[]](65, 13, 10, 66, 10, 67, 13, 10)
            'no terminal newline' = [byte[]](65)
            'an empty file' = [byte[]]@()
            'more than the limit' = $oversized
        }
        $reasons = @{
            'a byte-order mark' = 'it starts with a byte-order mark.'
            'invalid UTF-8' = 'it is not valid UTF-8.'
            'bare LF endings' = 'it does not end with a CRLF newline.'
            'mixed endings' = 'its line endings are not uniform CRLF.'
            'no terminal newline' = 'it does not end with a CRLF newline.'
            'an empty file' = 'it does not end with a CRLF newline.'
            'more than the limit' = 'it is larger than the store limit of 1 MiB.'
        }
        foreach ($name in $bad.Keys) {
            [IO.File]::WriteAllBytes($stores[0].Path, $bad[$name])
            foreach ($moment in @(@('at launch', { Initialize-Dlss5MissionStores -Stores $stores -MissionId 'note-taker' }), @('after the session', { Assert-Dlss5MissionStoresAfterSession -Stores $stores }))) {
                $refusal = $null
                try { & $moment[1] }
                catch { $refusal = $_.Exception }
                Assert-Dlss5True ($refusal -is [IO.InvalidDataException]) "A store with $name was not refused $($moment[0]): $refusal"
                Assert-Dlss5Equal $refusal.Message ($stores[0].Path + ': ' + $reasons[$name]) "A store with $name was refused for another reason $($moment[0])."
            }
        }
        $atLimit = [byte[]]::new($script:Dlss5StoreByteLimit)
        $atLimit[-2] = 13
        $atLimit[-1] = 10
        [IO.File]::WriteAllBytes($stores[0].Path, $atLimit)
        Initialize-Dlss5MissionStores -Stores $stores -MissionId 'note-taker'
        Assert-Dlss5MissionStoresAfterSession -Stores $stores
        [IO.File]::Delete($stores[0].Path)
        Assert-Dlss5Throws { Assert-Dlss5MissionStoresAfterSession -Stores $stores } ([IO.InvalidDataException]) 'A missing store passed after the session.'
        $used = [Collections.Generic.List[string]]::new()
        $subjects = [Collections.Generic.List[string]]::new()
        function Invoke-Dlss5MachineNotesLocked { param([string]$MutexName, [TimeSpan]$Timeout, [scriptblock]$Action, [string]$LockSubject) $used.Add($MutexName); $subjects.Add($LockSubject); return & $Action }
        Initialize-Dlss5MissionStores -Stores $stores -MissionId 'note-taker'
        Assert-Dlss5Equal ($used -join ',') 'Local\DLSS5-ADDER-STORE-note-taker-knowledge' 'Only the knowledge store should take its mutex.'
        Assert-Dlss5Equal ($subjects -join ',') ('knowledge store (' + $stores[1].Path + ')') 'A lock failure would not name the store path.'
        $used.Clear()
        Assert-Dlss5MissionStoresAfterSession -Stores $stores
        Assert-Dlss5Equal ($used -join ',') 'Local\DLSS5-ADDER-STORE-note-taker-knowledge' 'The check after the session did not take the store mutex.'
    }
}

Invoke-Dlss5Case 'mission stores launch a plain mission with one granted folder, and exit 5 for a damaged store before or after the session' {
    $prompt = 'if defined DLSS5_TEST_PROMPT_CAPTURE_PATH for /d %%F in ("%LOCALAPPDATA%\DLSS5-ADDER\missions\note-taker\prompts\dlss5-agent-sections-*") do copy /b "%%~fF\dlss5-agent-prompt-*.md" "%DLSS5_TEST_PROMPT_CAPTURE_PATH%" >nul'
    $damage = 'if defined DLSS5_TEST_DAMAGE_PATH echo broken> "%DLSS5_TEST_DAMAGE_PATH%.lf" & if defined DLSS5_TEST_DAMAGE_PATH del "%DLSS5_TEST_DAMAGE_PATH%"'
    $fixture = New-Dlss5StoreLaunchFixture -Name 'mission-stores-plain' -Bytes (New-Dlss5FreeFormPackageBytes -Stores '{"target":"free-form","machine":"free-form"}') -StubBody @($script:StoreArgsStubLine, $prompt, $damage)
    $argsPath = Join-Path $fixture.Root 'args.txt'
    $capture = Join-Path $fixture.Root 'prompt.txt'
    $run = Invoke-Dlss5StoreExecute -Fixture $fixture -Environment @{ DLSS5_TEST_ARGS_PATH = $argsPath; DLSS5_TEST_PROMPT_CAPTURE_PATH = $capture }
    Assert-Dlss5Equal $run.ExitCode 0 "The session failed: $($run.StandardOutput) $($run.StandardError)"
    $grant = Join-Path $fixture.MachineDirectory 'missions\note-taker'
    $arguments = [IO.File]::ReadAllText($argsPath)
    Assert-Dlss5Equal ([regex]::Matches($arguments, '--add-dir ')).Count 1 "The launch did not grant exactly one directory: $arguments"
    Assert-Dlss5True ($arguments.Contains($grant)) "The launch did not grant the mission folder: $arguments"
    Assert-Dlss5True (-not $arguments.Contains('--add-dir "' + $fixture.MachineDirectory + '"')) 'The launch granted the whole state folder.'
    $text = Read-Dlss5PromptCapture $capture
    Assert-Dlss5True ($text.Contains('Mission memory stores.') -and $text.Contains((Join-Path $grant 'MACHINE.md')) -and $text.Contains((Join-Path $fixture.Game 'note-taker.notes.md'))) "The prompt did not list the stores: $text"
    Assert-Dlss5True ((Test-Path -LiteralPath (Join-Path $grant 'MACHINE.md')) -and (Test-Path -LiteralPath (Join-Path $fixture.Game 'note-taker.notes.md'))) 'The stores were not seeded.'
    Assert-Dlss5Equal @(Get-ChildItem -LiteralPath (Join-Path $grant 'prompts') -Filter 'dlss5-agent-sections-*' -ErrorAction SilentlyContinue).Count 0 'The prompt files were left behind.'
    Assert-Dlss5True (-not (Get-Dlss5LaunchStatus $fixture).armed) 'A successful run did not disarm.'
    # A store the agent leaves damaged fails the run, which stays armed.
    $target = Join-Path $fixture.Game 'note-taker.notes.md'
    $run = Invoke-Dlss5StoreExecute -Fixture $fixture -Environment @{ DLSS5_TEST_DAMAGE_PATH = $target }
    Assert-Dlss5Equal $run.ExitCode 5 "A store damaged by the agent did not fail the run: $($run.StandardOutput) $($run.StandardError)"
    Assert-Dlss5True ($run.StandardOutput.Contains('Could not validate mission stores after the agent session:') -and $run.StandardOutput.Contains($target)) "The failure did not name the store: $($run.StandardOutput)"
    Assert-Dlss5True ((Get-Dlss5LaunchStatus $fixture).armed) 'A failed run disarmed the package.'
    # A store already damaged refuses the launch before the agent runs.
    [IO.File]::WriteAllText($target, "lf only`n", [Text.UTF8Encoding]::new($false))
    Remove-Item -LiteralPath $argsPath -Force
    $run = Invoke-Dlss5StoreExecute -Fixture $fixture -Environment @{ DLSS5_TEST_ARGS_PATH = $argsPath }
    Assert-Dlss5Equal $run.ExitCode 5 "A damaged store did not refuse the launch: $($run.StandardOutput) $($run.StandardError)"
    Assert-Dlss5True ($run.StandardOutput.Contains('Could not prepare the mission stores:') -and $run.StandardOutput.Contains($target)) "The refusal did not name the store: $($run.StandardOutput)"
    Assert-Dlss5True (-not (Test-Path -LiteralPath $argsPath)) 'The agent ran with a damaged store.'
    # A target store alone keeps the grant of the launch folder.
    $alone = New-Dlss5StoreLaunchFixture -Name 'mission-stores-target-only' -Bytes (New-Dlss5FreeFormPackageBytes -Stores '{"target":"free-form"}') -StubBody @($script:StoreArgsStubLine)
    $aloneArgs = Join-Path $alone.Root 'args.txt'
    Assert-Dlss5Equal (Invoke-Dlss5StoreExecute -Fixture $alone -Environment @{ DLSS5_TEST_ARGS_PATH = $aloneArgs }).ExitCode 0 'The target-only session failed.'
    Assert-Dlss5True ([IO.File]::ReadAllText($aloneArgs) -match '--add-dir "?[^"]*dlss5-agent-sections-[0-9a-f]{32}') 'A target-only mission lost its launch folder grant.'
    # A session with a command-line task seeds the stores too.
    $tasked = New-Dlss5StoreLaunchFixture -Name 'mission-stores-plain-task' -Bytes (New-Dlss5FreeFormPackageBytes -Stores '{"target":"free-form","machine":"free-form"}')
    $run = Invoke-Dlss5StoreExecute -Fixture $tasked -Task @('just look around')
    Assert-Dlss5Equal $run.ExitCode 0 "The task session failed: $($run.StandardOutput) $($run.StandardError)"
    Assert-Dlss5True ((Test-Path -LiteralPath (Join-Path $tasked.Game 'note-taker.notes.md')) -and (Test-Path -LiteralPath (Join-Path $tasked.MachineDirectory 'missions\note-taker\MACHINE.md'))) 'A task session did not seed the stores.'
}

Invoke-Dlss5Case 'mission stores leave an undeclared slot of a DLSS session alone, and transaction recovery works with no stores' {
    $promptLine = $script:StorePromptStubLine
    $knowledgePath = { param($Fixture) Join-Path $Fixture.MachineDirectory 'DLSS5_PROJECT_KNOWLEDGE.md' }
    $noTarget = New-Dlss5StoreLaunchFixture -Name 'mission-stores-no-target' -Bytes (New-Dlss5DeclaredDlssBytes -Slots @('machine', 'knowledge') -Checks @()) -StubBody @($promptLine)
    $capture = Join-Path $noTarget.Root 'prompt.txt'
    $run = Invoke-Dlss5StoreExecute -Fixture $noTarget -Environment @{ DLSS5_TEST_PROMPT_CAPTURE_PATH = $capture }
    Assert-Dlss5Equal $run.ExitCode 0 "The session without a target store failed: $($run.StandardOutput) $($run.StandardError)"
    Assert-Dlss5True (-not (Test-Path -LiteralPath $noTarget.GameNotesPath)) 'A session without the target store created game notes.'
    $text = Read-Dlss5PromptCapture $capture
    Assert-Dlss5True ($text.Contains('either of the two notes files') -and $text.Contains('expected_post_preflight_change: none until installation begins')) "The prompt did not reflect the undeclared store: $text"
    Assert-Dlss5Equal (Get-Dlss5FixtureLocationRecord $noTarget)['display_check'] '' 'A finding was recorded without a declared check.'
    # A diagnosis-only session without the target store promises no writes at all.
    New-Item -ItemType Directory -Force (Join-Path $noTarget.Game '.git') | Out-Null
    $run = Invoke-Dlss5IsolatedLaunch -Fixture $noTarget -Arguments (Get-Dlss5DiagnoseArguments $noTarget) -Environment @{ PATH = (Get-Dlss5PathWithoutGit); DLSS5_TEST_PROMPT_CAPTURE_PATH = $capture }
    Assert-Dlss5Equal $run.ExitCode 0 "The diagnosis-only session without a target store failed: $($run.StandardOutput) $($run.StandardError)"
    $text = Read-Dlss5PromptCapture $capture
    Assert-Dlss5True ($text.Contains('session_mode: diagnosis-only') -and $text.Contains('expected_post_preflight_change: none; no installation in this session')) "The diagnosis-only prompt did not reflect the undeclared store: $text"
    $noKnowledge = New-Dlss5StoreLaunchFixture -Name 'mission-stores-no-knowledge' -Bytes (New-Dlss5DeclaredDlssBytes -Slots @('target', 'machine') -Checks @('display-targets'))
    $run = Invoke-Dlss5StoreExecute -Fixture $noKnowledge
    Assert-Dlss5Equal $run.ExitCode 4 "The display check did not report a pending selection: $($run.StandardOutput) $($run.StandardError)"
    Assert-Dlss5True (-not (Test-Path -LiteralPath (& $knowledgePath $noKnowledge))) 'A session without the knowledge store created it.'
    Assert-Dlss5True (Test-Path -LiteralPath $noKnowledge.GameNotesPath) 'A declared target store was not seeded.'
    # An undeclared knowledge file is not read before or after the session, so damage in it fails nothing and stays as it is.
    $unreadKnowledge = New-Dlss5StoreLaunchFixture -Name 'mission-stores-knowledge-unread' -Bytes (New-Dlss5DeclaredDlssBytes -Slots @('target', 'machine') -Checks @())
    [IO.File]::WriteAllText((& $knowledgePath $unreadKnowledge), "broken`r`n", [Text.UTF8Encoding]::new($false))
    $run = Invoke-Dlss5StoreExecute -Fixture $unreadKnowledge
    Assert-Dlss5Equal $run.ExitCode 0 "Damaged notes of an undeclared knowledge store failed the run: $($run.StandardOutput) $($run.StandardError)"
    Assert-Dlss5Equal ([IO.File]::ReadAllText((& $knowledgePath $unreadKnowledge))) "broken`r`n" 'A session changed the undeclared knowledge file.'
    $damageMachine = 'if defined DLSS5_TEST_MACHINE_NOTES_PATH echo broken> "%DLSS5_TEST_MACHINE_NOTES_PATH%"'
    $noMachine = New-Dlss5StoreLaunchFixture -Name 'mission-stores-no-machine' -Bytes (New-Dlss5DeclaredDlssBytes -Slots @('target', 'knowledge') -Checks @()) -StubBody @($promptLine, $damageMachine)
    $capture = Join-Path $noMachine.Root 'prompt.txt'
    Assert-Dlss5Equal (Invoke-Dlss5StoreExecute -Fixture $noMachine -Environment @{ DLSS5_TEST_PROMPT_CAPTURE_PATH = $capture }).ExitCode 0 'The session without a machine store failed.'
    Assert-Dlss5True (-not (Read-Dlss5PromptCapture $capture).Contains('DLSS5-ADDER-MACHINE-NOTES')) 'The prompt named the undeclared machine notes lock.'
    # The end of a session does not read back an undeclared store, so notes the agent damaged do not fail the run.
    $run = Invoke-Dlss5StoreExecute -Fixture $noMachine -Environment @{ DLSS5_TEST_MACHINE_NOTES_PATH = (Join-Path $noMachine.MachineDirectory 'DLSS5_MACHINE_NOTES.md') }
    Assert-Dlss5Equal $run.ExitCode 0 "Damaged notes of an undeclared store failed the run: $($run.StandardOutput) $($run.StandardError)"
    # With no stores at all the session still records its status, and a marker in the location record still reaches the agent.
    $none = New-Dlss5StoreLaunchFixture -Name 'mission-stores-none' -Bytes (New-Dlss5DeclaredDlssBytes -Slots @() -Checks @()) -StubBody @($promptLine)
    $capture = Join-Path $none.Root 'prompt.txt'
    Assert-Dlss5Equal (Invoke-Dlss5StoreExecute -Fixture $none -Environment @{ DLSS5_TEST_PROMPT_CAPTURE_PATH = $capture }).ExitCode 0 'The session without stores failed.'
    Assert-Dlss5True (-not (Test-Path -LiteralPath $none.GameNotesPath) -and -not (Test-Path -LiteralPath (& $knowledgePath $none))) 'A session without stores created a store.'
    Assert-Dlss5Equal (Get-Dlss5FixtureLocationRecord $none)['session_status'] 'agent_session_ended' 'A session without stores recorded no status.'
    Assert-Dlss5Equal (Invoke-Dlss5LocationChannel $none @('transaction_status', 'stage 3: copying')).ExitCode 0 'The marker was not recorded.'
    Assert-Dlss5Equal (Invoke-Dlss5StoreExecute -Fixture $none -Environment @{ DLSS5_TEST_PROMPT_CAPTURE_PATH = $capture }).ExitCode 0 'The second session without stores failed.'
    Assert-Dlss5True ([regex]::IsMatch((Read-Dlss5PromptCapture $capture), '(?m)^transaction_status: stage 3: copying\r?$')) 'The marker did not reach the agent without stores.'
    # A wrong-game location record is still refused without the notes.
    $location = Get-Dlss5FixtureLocation $none
    $recordText = [IO.File]::ReadAllText($location.RecordPath)
    [IO.File]::WriteAllText($location.RecordPath, [regex]::Replace($recordText, '### game_fingerprint: [^\r\n]*', '### game_fingerprint: ' + ('c' * 64)), [Text.UTF8Encoding]::new($false))
    $run = Invoke-Dlss5StoreExecute -Fixture $none
    Assert-Dlss5True ($run.ExitCode -ne 0 -and ($run.StandardOutput + $run.StandardError).Contains('belongs to a different game')) "The wrong-directory guard did not work from the record alone: $($run.StandardOutput) $($run.StandardError)"
}

Invoke-Dlss5Case 'mission stores refuse a session without the target store when the game notes hold a legacy marker or cannot be read' {
    $fixture = New-Dlss5StoreLaunchFixture -Name 'mission-stores-legacy-marker' -Bytes (New-Dlss5DeclaredDlssBytes -Slots @('machine', 'knowledge') -Checks @())
    $utf8 = [Text.UTF8Encoding]::new($false)
    # A first session creates the location record with an empty marker, as a task session under an earlier release leaves it.
    Assert-Dlss5Equal (Invoke-Dlss5StoreExecute -Fixture $fixture).ExitCode 0 'The first session failed.'
    Assert-Dlss5Equal (Get-Dlss5FixtureLocationRecord $fixture)['transaction_status'] '' 'The fixture record is not empty.'
    $notes = "$GameNotesBeginMarker`r`n### schema_version: 1`r`n### transaction_status: stage 7: replacing`r`n$GameNotesEndMarker`r`n"
    [IO.File]::WriteAllText($fixture.GameNotesPath, $notes, $utf8)
    $before = Get-Dlss5FixtureStoreState $fixture
    $run = Invoke-Dlss5StoreExecute -Fixture $fixture
    Assert-Dlss5True ($run.ExitCode -ne 0 -and ($run.StandardOutput + $run.StandardError).Contains('holds a pending transaction marker') -and ($run.StandardOutput + $run.StandardError).Contains($fixture.GameNotesPath)) "The legacy marker did not refuse the session: $($run.StandardOutput) $($run.StandardError)"
    Assert-Dlss5Equal ([IO.File]::ReadAllText($fixture.GameNotesPath)) $notes 'The refused session changed the game notes.'
    Assert-Dlss5Equal (Get-Dlss5FixtureStoreState $fixture) $before 'The refused session wrote something.'
    [IO.File]::WriteAllText($fixture.GameNotesPath, "broken`r`n", $utf8)
    $run = Invoke-Dlss5StoreExecute -Fixture $fixture
    Assert-Dlss5True ($run.ExitCode -ne 0 -and ($run.StandardOutput + $run.StandardError).Contains($fixture.GameNotesPath + ' cannot be read') -and ($run.StandardOutput + $run.StandardError).Contains('from a mission that declares the target store')) "Unreadable game notes did not refuse the session with the remedy: $($run.StandardOutput) $($run.StandardError)"
    Assert-Dlss5Equal ([IO.File]::ReadAllText($fixture.GameNotesPath)) "broken`r`n" 'The refused session changed unreadable notes.'
    [IO.File]::WriteAllText($fixture.GameNotesPath, "$GameNotesBeginMarker`r`n### schema_version: 1`r`n$GameNotesEndMarker`r`n", $utf8)
    Assert-Dlss5Equal (Invoke-Dlss5StoreExecute -Fixture $fixture).ExitCode 0 'Notes with no marker refused the session.'
    Assert-Dlss5Equal ([IO.File]::ReadAllText($fixture.GameNotesPath)) "$GameNotesBeginMarker`r`n### schema_version: 1`r`n$GameNotesEndMarker`r`n" 'A session without the target store rewrote the notes.'
}

Invoke-Dlss5Case 'mission stores run the display check only when declared, still report damaged notes, and skip task sessions' {
    $corrupt = 'if defined DLSS5_TEST_GAME_NOTES_PATH echo broken> "%DLSS5_TEST_GAME_NOTES_PATH%"'
    $undeclared = New-Dlss5StoreLaunchFixture -Name 'mission-stores-no-check' -Bytes (New-Dlss5DeclaredDlssBytes -Slots @('target', 'machine', 'knowledge') -Checks @()) -StubBody @($corrupt)
    $run = Invoke-Dlss5StoreExecute -Fixture $undeclared
    Assert-Dlss5Equal $run.ExitCode 0 "An undeclared check still ran: $($run.StandardOutput) $($run.StandardError)"
    Assert-Dlss5Equal (Get-Dlss5FixtureLocationRecord $undeclared)['display_check'] '' 'An undeclared check left a finding.'
    Assert-Dlss5Equal (Get-Dlss5FixtureLocationRecord $undeclared)['session_status'] 'agent_session_ended' 'An undeclared check changed the session status.'
    # A finding left by an earlier mission does not linger once the mission declares no check.
    $recordPath = (Get-Dlss5FixtureLocation $undeclared).RecordPath
    $seeded = [regex]::Replace([IO.File]::ReadAllText($recordPath), '### display_check: [^\r\n]*', '### display_check: pending: an earlier finding')
    Assert-Dlss5True ($seeded.Contains('pending: an earlier finding')) 'The fixture record has no display_check entry.'
    [IO.File]::WriteAllText($recordPath, $seeded, [Text.UTF8Encoding]::new($false))
    Assert-Dlss5Equal (Invoke-Dlss5StoreExecute -Fixture $undeclared).ExitCode 0 'The session after a lingering finding failed.'
    Assert-Dlss5Equal (Get-Dlss5FixtureLocationRecord $undeclared)['display_check'] '' 'A finding from an earlier mission lingered.'
    $run = Invoke-Dlss5StoreExecute -Fixture $undeclared -Environment @{ DLSS5_TEST_GAME_NOTES_PATH = $undeclared.GameNotesPath }
    Assert-Dlss5Equal $run.ExitCode 5 "Damaged notes were not reported without a declared check: $($run.StandardOutput) $($run.StandardError)"
    $declared = New-Dlss5StoreLaunchFixture -Name 'mission-stores-check' -Bytes (New-Dlss5DeclaredDlssBytes -Slots @('target', 'machine', 'knowledge') -Checks @('display-targets'))
    $run = Invoke-Dlss5StoreExecute -Fixture $declared
    Assert-Dlss5Equal $run.ExitCode 4 "A declared check did not report the pending selection: $($run.StandardOutput) $($run.StandardError)"
    $record = Get-Dlss5FixtureLocationRecord $declared
    Assert-Dlss5True ($record['session_status'] -ceq 'display_selection_pending' -and ([string]$record['display_check']).StartsWith('pending: ', [StringComparison]::Ordinal)) 'The pending finding was not recorded.'
    $task = Invoke-Dlss5StoreExecute -Fixture $declared -Task @('just look around')
    Assert-Dlss5Equal $task.ExitCode 0 "A task session ran the check: $($task.StandardOutput) $($task.StandardError)"
    Assert-Dlss5Equal (Get-Dlss5PostRunFinding -Name 'display-targets' -GameNotes ([ordered]@{})) 'At least one gameplay target display is required before completion.' 'The check lost its incomplete outcome.'
    Assert-Dlss5Throws { Get-Dlss5PostRunFinding -Name 'other' -GameNotes ([ordered]@{}) } ([ArgumentException]) 'An unknown check ran.'
}

Invoke-Dlss5Case 'mission stores notes validation reports pass, finding and damage as the session end judges the notes, and writes nothing' {
    $validate = {
        param($Fixture, [string[]]$Arguments = @(), [string]$Updater = $Fixture.Updater)
        $process = Invoke-Dlss5ProcessWithInput -FilePath 'cmd.exe' -Arguments (@('/d', '/c', $Updater, '--internal-notes-validate') + $Arguments) -InputLines @() -WorkingDirectory $Fixture.Game -Environment @{ LOCALAPPDATA = $Fixture.LocalAppData }
        $lines = @($process.StandardOutput.Split([char[]]@([char]13, [char]10), [StringSplitOptions]::RemoveEmptyEntries) | Where-Object { $_.StartsWith('{', [StringComparison]::Ordinal) })
        # A report counts only as the whole output: one JSON line and nothing else.
        $report = if ($lines.Count -eq 1 -and $process.StandardOutput.Trim() -ceq $lines[0]) { $lines[0] | ConvertFrom-Json } else { $null }

        return [pscustomobject]@{ Process = $process; Report = $report; Lines = $lines.Count }
    }
    $writeNotes = {
        param($Fixture, [hashtable]$Changes = @{})
        # One complete primary target, then the changes; a null value removes the key.
        $notes = [ordered]@{ 'schema_version' = '1' }
        $record = [ordered]@{ alias = 'Desk'; observed_name = 'Desk monitor'; role = 'primary'; availability = 'active'; match_status = 'matched'; runtime_status = 'verified'; visual_status = 'passed'; settings = 'DLSS quality'; last_checked = '2026-11-06T23:17:27+01:00' }
        foreach ($suffix in $record.Keys) { $notes["target_display.desk.$suffix"] = $record[$suffix] }
        foreach ($key in $Changes.Keys) { if ($null -eq $Changes[$key]) { $notes.Remove($key) } else { $notes[$key] = $Changes[$key] } }
        $text = ConvertTo-Dlss5NotesDocument -Notes $notes -BeginMarker $GameNotesBeginMarker -EndMarker $GameNotesEndMarker -KnownOrder $GameNotesOrder
        [IO.File]::WriteAllText($Fixture.GameNotesPath, $text, [Text.UTF8Encoding]::new($false))
    }
    # An untrusted copy is refused before anything is read, and nothing is reported.
    $untrusted = New-Dlss5IsolatedLaunchFixture -Name 'notes-validate-untrusted'
    & $writeNotes $untrusted
    $run = & $validate $untrusted
    Assert-Dlss5True ($run.Process.ExitCode -eq 4 -and $run.Process.StandardError.Contains('not trusted') -and $run.Lines -eq 0) "An untrusted copy was not refused: $($run.Process.ExitCode) $($run.Process.StandardOutput) $($run.Process.StandardError)"
    $fixture = New-Dlss5IsolatedLaunchFixture -Name 'notes-validate'
    $null = Get-Dlss5LaunchStatus $fixture
    & $writeNotes $fixture
    $before = Get-Dlss5FixtureStoreState $fixture
    $run = & $validate $fixture
    Assert-Dlss5True ($run.Process.ExitCode -eq 0 -and $null -ne $run.Report -and $run.Report.outcome -ceq 'pass') "Complete notes did not pass: $($run.Process.ExitCode) $($run.Process.StandardOutput) $($run.Process.StandardError)"
    Assert-Dlss5Equal (Get-Dlss5FixtureStoreState $fixture) $before 'The check wrote something.'
    # A bare date and a value outside its domain are damage, with the session end's own error.
    foreach ($case in @(@{ Changes = @{ 'target_display.desk.last_checked' = '2026-11-06' }; Error = 'Target display timestamp is invalid: target_display.desk.last_checked' }, @{ Changes = @{ 'target_display.desk.role' = 'main' }; Error = 'Target display value is invalid: target_display.desk.role' }, @{ Changes = @{ 'target_display.desk.settings' = $null }; Error = 'Target display record is incomplete: target_display.desk.settings' })) {
        & $writeNotes $fixture $case.Changes
        $before = Get-Dlss5FixtureStoreState $fixture
        $run = & $validate $fixture
        Assert-Dlss5True ($run.Process.ExitCode -eq 0 -and $null -ne $run.Report -and $run.Report.outcome -ceq 'damage' -and $run.Report.error -ceq $case.Error) "Damaged notes were not reported as [$($case.Error)]: $($run.Process.ExitCode) $($run.Process.StandardOutput) $($run.Process.StandardError)"
        Assert-Dlss5Equal (Get-Dlss5FixtureStoreState $fixture) $before 'The check wrote something for damaged notes.'
    }
    # Unreadable notes are damage too, and an error naming a path outside ASCII reaches the agent escaped, so no code page can mangle it.
    [IO.File]::WriteAllText($fixture.GameNotesPath, "broken`r`n", [Text.UTF8Encoding]::new($false))
    $run = & $validate $fixture
    Assert-Dlss5True ($run.Process.ExitCode -eq 0 -and $run.Report.outcome -ceq 'damage' -and ([string]$run.Report.error).Length -gt 0) "Unreadable notes were not reported as damage: $($run.Process.StandardOutput) $($run.Process.StandardError)"
    [IO.File]::WriteAllBytes($fixture.GameNotesPath, [byte[]]@(255, 254, 13, 10))
    $run = & $validate $fixture
    Assert-Dlss5True ($run.Report.outcome -ceq 'damage' -and ([string]$run.Report.error).Contains('Notes file is not valid UTF-8')) "Notes that are not UTF-8 were not reported as damage: $($run.Process.StandardOutput) $($run.Process.StandardError)"
    $accented = New-Dlss5IsolatedLaunchFixture -Name 'notes-validate-accented' -GameDirectory (Join-Path $script:ScratchRoot ('notes-validate-accented\Caf' + [char]233))
    New-Dlss5TargetExecutable $accented.Game
    $null = Get-Dlss5LaunchStatus $accented
    [IO.File]::WriteAllBytes($accented.GameNotesPath, [byte[]]@(255, 254, 13, 10))
    $run = & $validate $accented
    Assert-Dlss5True ($run.Report.outcome -ceq 'damage' -and ([string]$run.Report.error).Contains($accented.GameNotesPath) -and @($run.Process.StandardOutput.ToCharArray() | Where-Object { [int]$_ -gt 127 }).Count -eq 0) "A non-ASCII path did not reach the agent escaped: $($run.Process.StandardOutput) $($run.Process.StandardError)"
    # An incomplete selection is a finding, with the session end's finding text.
    & $writeNotes $fixture @{ 'target_display.desk.visual_status' = 'pending' }
    $run = & $validate $fixture
    Assert-Dlss5True ($run.Process.ExitCode -eq 0 -and $run.Report.outcome -ceq 'finding' -and (@($run.Report.findings) -join '|') -ceq 'Primary target display has not completed required runtime and visual validation.') "An incomplete selection was not a finding: $($run.Process.StandardOutput) $($run.Process.StandardError)"
    [IO.File]::WriteAllText($fixture.GameNotesPath, (ConvertTo-Dlss5NotesDocument -Notes ([ordered]@{ 'schema_version' = '1' }) -BeginMarker $GameNotesBeginMarker -EndMarker $GameNotesEndMarker -KnownOrder $GameNotesOrder), [Text.UTF8Encoding]::new($false))
    $run = & $validate $fixture
    Assert-Dlss5True ($run.Report.outcome -ceq 'finding' -and (@($run.Report.findings) -join '|') -ceq 'At least one gameplay target display is required before completion.') "Notes without a target were not a finding: $($run.Process.StandardOutput)"
    # A session holding the folder guard does not block the check, which never takes it.
    $holder = Start-Dlss5GuardHolder -Package $fixture.Updater -LocalAppData $fixture.LocalAppData
    try { Assert-Dlss5Equal (& $validate $fixture).Process.ExitCode 0 'The check was blocked by a held guard.' }
    finally { Stop-Dlss5GuardHolder $holder }
    # The session end judges the same notes the same way: the bare date the check reports as damage fails the finalize step.
    & $writeNotes $fixture @{ 'target_display.desk.last_checked' = '2026-11-06' }
    $session = Invoke-Dlss5IsolatedLaunch -Fixture $fixture
    Assert-Dlss5True ($session.ExitCode -eq 5 -and $session.StandardOutput.Contains('Could not finalize game notes: Target display timestamp is invalid: target_display.desk.last_checked')) "The session end did not reject the notes the check reported: $($session.ExitCode) $($session.StandardOutput) $($session.StandardError)"
    # Any argument, and the shared copy, are refused without a report.
    foreach ($arguments in @(@('x'), @(''), @($fixture.GameNotesPath))) {
        $run = & $validate $fixture $arguments
        Assert-Dlss5True ($run.Process.ExitCode -eq 2 -and $run.Process.StandardError.Contains('Nothing was checked.') -and $run.Lines -eq 0) "The check accepted [$($arguments -join '] [')]: $($run.Process.ExitCode) $($run.Process.StandardOutput) $($run.Process.StandardError)"
    }
    $slot = Join-Path $fixture.MachineDirectory 'DLSS5-ADDER.cmd'
    if (-not (Test-Path -LiteralPath $slot)) { Copy-Item -LiteralPath $fixture.Updater -Destination $slot }
    $run = & $validate $fixture @() $slot
    Assert-Dlss5True ($run.Process.ExitCode -eq 2 -and $run.Process.StandardError.Contains('Nothing was checked.') -and $run.Lines -eq 0) "The shared copy ran the check: $($run.Process.ExitCode) $($run.Process.StandardOutput) $($run.Process.StandardError)"
}

Invoke-Dlss5Case 'mission stores notes validation reports absent game notes as missing, which a task session leaves uncreated' {
    $validate = {
        param($Fixture, [string[]]$Prefix = @())
        $process = Invoke-Dlss5ProcessWithInput -FilePath 'cmd.exe' -Arguments (@('/d', '/c', $Fixture.Updater) + $Prefix + @('--internal-notes-validate')) -InputLines @() -WorkingDirectory $Fixture.Game -Environment @{ LOCALAPPDATA = $Fixture.LocalAppData }
        $lines = @($process.StandardOutput.Split([char[]]@([char]13, [char]10), [StringSplitOptions]::RemoveEmptyEntries) | Where-Object { $_.StartsWith('{', [StringComparison]::Ordinal) })
        $report = if ($lines.Count -eq 1 -and $process.StandardOutput.Trim() -ceq $lines[0]) { $lines[0] | ConvertFrom-Json } else { $null }

        return [pscustomobject]@{ Process = $process; Report = $report; Lines = $lines.Count }
    }
    $fixture = New-Dlss5StoreLaunchFixture -Name 'notes-validate-missing' -Bytes (New-Dlss5DeclaredDlssBytes -Slots @('target', 'machine', 'knowledge') -Checks @('display-targets'))
    # A task session never creates the game notes, and the check then reports them missing, writing nothing.
    $task = Invoke-Dlss5StoreExecute -Fixture $fixture -Task @('just look around')
    Assert-Dlss5Equal $task.ExitCode 0 "The task session failed: $($task.StandardOutput) $($task.StandardError)"
    Assert-Dlss5Equal (Test-Path -LiteralPath $fixture.GameNotesPath) $false 'The task session created game notes.'
    $before = Get-Dlss5FixtureStoreState $fixture
    $run = & $validate $fixture
    Assert-Dlss5True ($run.Process.ExitCode -eq 0 -and $null -ne $run.Report -and $run.Report.outcome -ceq 'missing' -and @($run.Report.PSObject.Properties).Count -eq 1) "Absent game notes were not reported as missing: $($run.Process.ExitCode) $($run.Process.StandardOutput) $($run.Process.StandardError)"
    Assert-Dlss5Equal (Get-Dlss5FixtureStoreState $fixture) $before 'The check wrote something for absent game notes.'
    Assert-Dlss5Equal (Test-Path -LiteralPath $fixture.GameNotesPath) $false 'The check created game notes.'
    # Only a file positively found absent is missing: a folder where the notes file belongs cannot be read and is damage.
    [void](New-Item -ItemType Directory -Path $fixture.GameNotesPath)
    $run = & $validate $fixture
    Assert-Dlss5True ($run.Process.ExitCode -eq 0 -and $null -ne $run.Report -and $run.Report.outcome -ceq 'damage' -and ([string]$run.Report.error).Contains('Guarded path has an unexpected type')) "A folder in place of the game notes was not damage: $($run.Process.ExitCode) $($run.Process.StandardOutput) $($run.Process.StandardError)"
    Remove-Item -LiteralPath $fixture.GameNotesPath
    # Without the target store the game notes are not read, so their absence passes.
    $noTarget = New-Dlss5StoreLaunchFixture -Name 'notes-validate-missing-no-target' -Bytes (New-Dlss5DeclaredDlssBytes -Slots @('machine', 'knowledge') -Checks @())
    $null = Get-Dlss5LaunchStatus $noTarget
    Assert-Dlss5Equal (Test-Path -LiteralPath $noTarget.GameNotesPath) $false 'The fixture has game notes.'
    Assert-Dlss5Equal (& $validate $noTarget).Report.outcome 'pass' 'A mission without the target store judged the absent game notes.'
    # The generic refusal of --host or --model before any internal mode comes first, with its own exit 4 and no report.
    $run = & $validate $fixture @('--host', 'claude')
    Assert-Dlss5True ($run.Process.ExitCode -eq 4 -and $run.Process.StandardError.Contains('--host and --model are only supported for agent sessions.') -and $run.Lines -eq 0) "A host before the check was not refused as every internal mode is: $($run.Process.ExitCode) $($run.Process.StandardOutput) $($run.Process.StandardError)"
}

Invoke-Dlss5Case 'mission stores notes validation reads only the declared target store and runs only the declared checks' {
    $validate = {
        param($Fixture)
        $process = Invoke-Dlss5ProcessWithInput -FilePath 'cmd.exe' -Arguments @('/d', '/c', $Fixture.Updater, '--internal-notes-validate') -InputLines @() -WorkingDirectory $Fixture.Game -Environment @{ LOCALAPPDATA = $Fixture.LocalAppData }
        Assert-Dlss5Equal $process.ExitCode 0 "The check did not report: $($process.StandardOutput) $($process.StandardError)"

        return @($process.StandardOutput.Split([char[]]@([char]13, [char]10), [StringSplitOptions]::RemoveEmptyEntries) | Where-Object { $_.StartsWith('{', [StringComparison]::Ordinal) })[-1] | ConvertFrom-Json
    }
    $empty = ConvertTo-Dlss5NotesDocument -Notes ([ordered]@{ 'schema_version' = '1' }) -BeginMarker $GameNotesBeginMarker -EndMarker $GameNotesEndMarker -KnownOrder $GameNotesOrder
    # Without a declared check, notes with no target pass, and the store read still reports damage, as the session end does.
    $noCheck = New-Dlss5StoreLaunchFixture -Name 'notes-validate-no-check' -Bytes (New-Dlss5DeclaredDlssBytes -Slots @('target', 'machine', 'knowledge') -Checks @())
    [IO.File]::WriteAllText($noCheck.GameNotesPath, $empty, [Text.UTF8Encoding]::new($false))
    Assert-Dlss5Equal (& $validate $noCheck).outcome 'pass' 'Notes without a target failed a mission that declares no check.'
    [IO.File]::WriteAllText($noCheck.GameNotesPath, "broken`r`n", [Text.UTF8Encoding]::new($false))
    Assert-Dlss5Equal (& $validate $noCheck).outcome 'damage' 'Unreadable notes passed a mission that declares the target store.'
    # Without the target store, the game notes are not read at all.
    $noTarget = New-Dlss5StoreLaunchFixture -Name 'notes-validate-no-target' -Bytes (New-Dlss5DeclaredDlssBytes -Slots @('machine', 'knowledge') -Checks @())
    [IO.File]::WriteAllText($noTarget.GameNotesPath, "broken`r`n", [Text.UTF8Encoding]::new($false))
    Assert-Dlss5Equal (& $validate $noTarget).outcome 'pass' 'A mission without the target store read the game notes.'
    # With the check declared, the same empty notes are a finding.
    $declared = New-Dlss5StoreLaunchFixture -Name 'notes-validate-declared' -Bytes (New-Dlss5DeclaredDlssBytes -Slots @('target', 'machine', 'knowledge') -Checks @('display-targets'))
    [IO.File]::WriteAllText($declared.GameNotesPath, $empty, [Text.UTF8Encoding]::new($false))
    Assert-Dlss5Equal (& $validate $declared).outcome 'finding' 'A declared check did not report the incomplete selection.'
    # Another mission's check is its own session end's: its free-form stores, never the DLSS game notes.
    $plain = New-Dlss5StoreLaunchFixture -Name 'notes-validate-plain' -Bytes (New-Dlss5FreeFormPackageBytes -Stores '{"target":"free-form","machine":"free-form"}')
    $target = Join-Path $plain.Game 'note-taker.notes.md'
    $report = & $validate $plain
    Assert-Dlss5True ($report.outcome -ceq 'damage' -and ([string]$report.error).Contains($target + ': the store is missing.')) "A missing free-form store was not reported as the session end reports it: $($report | ConvertTo-Json -Compress)"
    Assert-Dlss5Equal (Invoke-Dlss5StoreExecute -Fixture $plain).ExitCode 0 'The plain session failed.'
    [IO.File]::WriteAllText($plain.GameNotesPath, "broken`r`n", [Text.UTF8Encoding]::new($false))
    Assert-Dlss5Equal (& $validate $plain).outcome 'pass' 'Seeded free-form stores did not pass, or the DLSS game notes were read for another mission.'
    [IO.File]::WriteAllText($target, "lf only`n", [Text.UTF8Encoding]::new($false))
    $report = & $validate $plain
    Assert-Dlss5True ($report.outcome -ceq 'damage' -and ([string]$report.error).Contains($target)) "A damaged free-form store was not reported: $($report | ConvertTo-Json -Compress)"
}

Invoke-Dlss5Case 'mission stores refuse a Windows device name as the id of a mission with stores' {
    foreach ($id in @(@('con', 'prn', 'aux', 'nul') + @(1..9 | ForEach-Object { "com$_"; "lpt$_" }))) {
        foreach ($slot in @('target', 'machine', 'knowledge')) {
            Assert-Dlss5Throws { $null = ConvertTo-Dlss5TestProject -MissionId $id -Extra (',"stores":{"' + $slot + '":"free-form"}') } ([FormatException]) "The device name $id was accepted with the $slot store."
        }
        $null = ConvertTo-Dlss5TestProject -MissionId $id
        $null = ConvertTo-Dlss5TestProject -MissionId $id -Extra ',"stores":{}'
        # The framing reading stays as it was, so a later version's package can still be staged.
        Assert-Dlss5Equal (ConvertFrom-Dlss5ProjectConfig -Bytes $script:PackageUtf8.GetBytes('{"mission_id":"' + $id + '","stores":{"machine":"free-form"}}')).MissionId $id 'The framing reading refused the id.'
    }
    $message = ''
    try { $null = ConvertTo-Dlss5TestProject -MissionId 'nul' -Extra ',"stores":{"machine":"free-form"}' } catch [FormatException] { $message = $_.Exception.Message }
    Assert-Dlss5True ($message.Contains('names a Windows device') -and $message.Contains('nul')) "The refusal does not say why: $message"
    foreach ($id in @('note-taker', 'console', 'com10', 'nul-store', 'lpt')) {
        Assert-Dlss5Equal (ConvertTo-Dlss5TestProject -MissionId $id -Extra ',"stores":{"machine":"free-form"}').MissionId $id "The ordinary id $id was refused."
    }
}

Invoke-Dlss5Case 'mission stores view lists and opens the declared stores, and Clear keeps what the engine relies on' {
    $opened = [Collections.Generic.List[string]]::new()
    $savedOpen = $script:Dlss5OpenFile
    $script:Dlss5OpenFile = { param($FilePath) $opened.Add($FilePath) }
    try {
        Invoke-Dlss5PackageInteraction -Name 'mission-stores-keyed-clear' -Bytes (New-Dlss5PackageVariant -Bytes $script:CandidateBytes -State (New-Dlss5StateLines)) -Action {
            param($PackagePath, $Game)
            $utf8 = [Text.UTF8Encoding]::new($false)
            $machinePath = Get-Dlss5MachineNotesPath
            $knowledgePath = Get-Dlss5ProjectKnowledgePath
            $gameNotesPath = Join-Path $Game 'DLSS5-ADDER.md'
            $script:Dlss5Console = New-Dlss5SubstitutedConsole @('Escape')
            Invoke-Dlss5StoreMenu -Path $PackagePath
            $output = Get-Dlss5ConsoleText
            Assert-Dlss5True ($output.Contains('Mission stores') -and $output.Contains('  target: ' + $gameNotesPath + ' (not created)') -and $output.Contains('  knowledge: ' + $knowledgePath + ' (not created)')) "The view did not list the stores: $output"
            Assert-Dlss5True (-not $output.Contains('Open the target store') -and -not $output.Contains('Clear the target store')) 'The view offered a store that does not exist.'
            $fingerprint = (Get-GameIdentity -Dir $Game).Fingerprint
            $notes = New-Dlss5SeededGameNotes -Fingerprint $fingerprint
            $notes['game_quirks'] = 'remembered'
            Write-Dlss5NotesFileAtomically -Path $gameNotesPath -Notes $notes -BeginMarker $GameNotesBeginMarker -EndMarker $GameNotesEndMarker -KnownOrder $GameNotesOrder
            Write-Dlss5MachineTrustFixture -MachineDirectory (Get-Dlss5StorePath) -Whole @{ $script:CandidateVersion = $script:CandidateIdentity.Sha256 } -Engine @{ $script:CandidateVersion = $script:CandidateIdentity.EngineSha256 }
            $machineText = [IO.File]::ReadAllText($machinePath)
            [IO.File]::WriteAllText($machinePath, $machineText.Replace("### schema_version: 1`r`n", "### schema_version: 1`r`n### hardware_constraints: remembered`r`n### dlssnr_patcher.note: remembered`r`n"), $utf8)
            $knowledge = New-Dlss5SeededProjectKnowledge
            $knowledge['renodx'] = 'remembered'
            Write-Dlss5NotesFileAtomically -Path $knowledgePath -Notes $knowledge -BeginMarker $ProjectKnowledgeBeginMarker -EndMarker $ProjectKnowledgeEndMarker -KnownOrder $ProjectKnowledgeOrder
            # Open, then a declined Clear, then each Clear.
            $script:Dlss5Console = New-Dlss5SubstitutedConsole @('t', 'Enter', 'y', 'Enter', 'Enter', 'Escape')
            Invoke-Dlss5StoreMenu -Path $PackagePath
            $output = Get-Dlss5ConsoleText
            Assert-Dlss5True ($opened.Contains($gameNotesPath) -and $output.Contains('Opened ' + $gameNotesPath + '.') -and -not $output.Contains('do not edit it')) "The store did not open as a store: $output"
            Assert-Dlss5True ($output.Contains('Kept; nothing was cleared.') -and $output.Contains('If Git tracks this file, commit the change before the next launch.') -and $output.Contains('Its contents cannot be recovered.')) "The declined Clear was wrong: $output"
            Assert-Dlss5Equal (Read-Dlss5NotesFile -Path $gameNotesPath -BeginMarker $GameNotesBeginMarker -EndMarker $GameNotesEndMarker)['game_quirks'] 'remembered' 'A declined Clear changed the notes.'
            $script:Dlss5Console = New-Dlss5SubstitutedConsole @('y', 'Enter', 'y', 'Enter', 'h', 'Enter', 'y', 'Enter', 'w', 'Enter', 'y', 'Enter', 'Escape')
            $keyedLocks = [Collections.Generic.List[string]]::new()
            & {
                function Invoke-Dlss5MachineNotesLocked { param([string]$MutexName, [TimeSpan]$Timeout, [scriptblock]$Action, [string]$LockSubject) $keyedLocks.Add($MutexName); return & $Action }
                Invoke-Dlss5StoreMenu -Path $PackagePath
            }
            Assert-Dlss5Equal ($keyedLocks -join ',') 'Local\DLSS5-ADDER-MACHINE-NOTES,Local\DLSS5-ADDER-PROJECT-KNOWLEDGE' 'A keyed Clear did not take its store mutex.'
            $output = Get-Dlss5ConsoleText
            Assert-Dlss5True ($output.Contains('Cleared ' + $gameNotesPath + '.') -and $output.Contains('Cleared ' + $machinePath + '.') -and $output.Contains('Cleared ' + $knowledgePath + '.')) "A Clear was not reported: $output"
            $clearedGame = Read-Dlss5NotesFile -Path $gameNotesPath -BeginMarker $GameNotesBeginMarker -EndMarker $GameNotesEndMarker
            Assert-Dlss5True ($clearedGame['game_quirks'] -ceq '' -and $clearedGame['game_fingerprint'] -ceq $fingerprint) 'Clear lost the fingerprint or kept the memory of the game notes.'
            $clearedMachine = Read-Dlss5NotesFile -Path $machinePath -BeginMarker $MachineNotesBeginMarker -EndMarker $MachineNotesEndMarker
            Assert-Dlss5True (-not $clearedMachine.Contains('hardware_constraints') -and -not $clearedMachine.Contains('dlssnr_patcher.note')) 'Clear kept the mission memory of the machine notes.'
            Assert-Dlss5Equal $clearedMachine[('bootstrap_checksum.' + $script:CandidateVersion)] $script:CandidateIdentity.Sha256 'Clear lost the whole-file trust entry.'
            Assert-Dlss5Equal $clearedMachine[('bootstrap_engine_checksum.' + $script:CandidateVersion)] $script:CandidateIdentity.EngineSha256 'Clear lost the engine trust entry.'
            $clearedKnowledge = Read-Dlss5NotesFile -Path $knowledgePath -BeginMarker $ProjectKnowledgeBeginMarker -EndMarker $ProjectKnowledgeEndMarker
            Assert-Dlss5True ($clearedKnowledge['renodx'] -ceq '' -and $clearedKnowledge['status'] -ceq 'empty') 'Clear did not empty the knowledge.'
            # A pending legacy marker and unreadable files refuse, leaving the file alone.
            $notes = New-Dlss5SeededGameNotes -Fingerprint $fingerprint
            $notes['transaction_status'] = 'stage 2: pending'
            Write-Dlss5NotesFileAtomically -Path $gameNotesPath -Notes $notes -BeginMarker $GameNotesBeginMarker -EndMarker $GameNotesEndMarker -KnownOrder $GameNotesOrder
            $held = [IO.File]::ReadAllBytes($gameNotesPath)
            $script:Dlss5Console = New-Dlss5SubstitutedConsole @('y', 'Enter', 'y', 'Enter', 'Escape')
            Invoke-Dlss5StoreMenu -Path $PackagePath
            Assert-Dlss5True ((Get-Dlss5ConsoleText).Contains('Not cleared: the store still holds a pending transaction marker.')) "The pending marker did not refuse: $(Get-Dlss5ConsoleText)"
            Assert-Dlss5True (Test-Dlss5ByteEquality -Left ([IO.File]::ReadAllBytes($gameNotesPath)) -Right $held) 'A refused Clear changed the notes.'
            foreach ($broken in @(@('y', $gameNotesPath), @('h', $machinePath), @('w', $knowledgePath))) {
                [IO.File]::WriteAllText($broken[1], "broken`r`n", $utf8)
                $script:Dlss5Console = New-Dlss5SubstitutedConsole @($broken[0], 'Enter', 'y', 'Enter', 'Escape')
                Invoke-Dlss5StoreMenu -Path $PackagePath
                Assert-Dlss5True ((Get-Dlss5ConsoleText).Contains('Not cleared:')) "An unreadable store did not refuse: $(Get-Dlss5ConsoleText)"
                Assert-Dlss5Equal ([IO.File]::ReadAllText($broken[1])) "broken`r`n" 'A refused Clear changed an unreadable store.'
            }
        }
        $root = Join-Path $script:ScratchRoot 'mission-stores-free-clear'
        Invoke-Dlss5PackageInteraction -Name 'mission-stores-free-clear' -Bytes (New-Dlss5FreeFormPackageBytes -Stores '{"target":"free-form","knowledge":"free-form"}' -State (New-Dlss5StateLines)) -Action {
            param($PackagePath, $Game)
            $stores = Get-Dlss5MissionStores -Project $script:Dlss5ExecutingIdentity.Project -PackagePath $PackagePath
            Initialize-Dlss5MissionStores -Stores $stores -MissionId 'note-taker'
            $seed = [IO.File]::ReadAllText($stores[0].Path)
            [IO.File]::WriteAllText($stores[0].Path, "remembered`r`n", [Text.UTF8Encoding]::new($false))
            $script:Dlss5Console = New-Dlss5SubstitutedConsole @('y', 'Enter', 'y', 'Enter', 'Escape')
            Invoke-Dlss5StoreMenu -Path $PackagePath
            Assert-Dlss5Equal ([IO.File]::ReadAllText($stores[0].Path)) $seed "Clear did not restore the seed: $(Get-Dlss5ConsoleText)"
            Assert-Dlss5True (-not (Get-Dlss5ConsoleText).Contains('If Git tracks this file')) 'A free-form Clear spoke of Git.'
            # A store far over the size limit fails validation at launch, and Clear is the way out of that.
            [IO.File]::WriteAllBytes($stores[0].Path, [byte[]]::new(5MB))
            $script:Dlss5Console = New-Dlss5SubstitutedConsole @('y', 'Enter', 'y', 'Enter', 'Escape')
            Invoke-Dlss5StoreMenu -Path $PackagePath
            Assert-Dlss5Equal ([IO.File]::ReadAllText($stores[0].Path)) $seed "Clear did not reset an oversized store: $(Get-Dlss5ConsoleText)"
            Assert-Dlss5Equal @(Get-ChildItem -LiteralPath $Game -Force -Filter '.note-taker.notes.md.*').Count 0 'Clear left a candidate or rollback file beside the store.'
            # A candidate left by a failed create-new write is reported by its path, and the store stays as it was.
            [IO.File]::WriteAllText($stores[0].Path, "remembered`r`n", [Text.UTF8Encoding]::new($false))
            $realWrite = ${function:Write-Dlss5GuardedNewFile}
            & {
                function Write-Dlss5GuardedNewFile {
                    param([string]$Path, [byte[]]$Bytes, [switch]$GamePath)
                    $snapshot = & $realWrite -Path $Path -Bytes $Bytes -GamePath:$GamePath
                    $failure = [IO.IOException]::new('Created file readback differs.')
                    $failure.Data['OwnedSnapshot'] = $snapshot
                    throw $failure
                }
                $script:Dlss5Console = New-Dlss5SubstitutedConsole @('y', 'Enter', 'y', 'Enter', 'Escape')
                Invoke-Dlss5StoreMenu -Path $PackagePath
            }
            $retained = @(Get-ChildItem -LiteralPath $Game -Force -Filter '.note-taker.notes.md.candidate-*')
            Assert-Dlss5Equal $retained.Count 1 'A failed create-new write did not leave its candidate.'
            Assert-Dlss5True ((Get-Dlss5ConsoleText).Contains('Retained candidate: ' + $retained[0].FullName) -and (Get-Dlss5ConsoleText).Contains('Created file readback differs.')) "The retained candidate or the cause was not reported: $(Get-Dlss5ConsoleText)"
            Assert-Dlss5Equal ([IO.File]::ReadAllText($stores[0].Path)) "remembered`r`n" 'A failed create-new write changed the store.'
            Remove-Item -LiteralPath $retained[0].FullName
            # A failure before any candidate exists is not a retained candidate: it passes through unchanged and leaves nothing beside the store.
            $plainFailure = [IO.IOException]::new('Could not create the candidate.')
            $caught = [Collections.Generic.List[Exception]]::new()
            & {
                function Write-Dlss5GuardedNewFile { param([string]$Path, [byte[]]$Bytes, [switch]$GamePath) throw $plainFailure }
                try { Invoke-Dlss5AtomicReplacement -Path $stores[0].Path -Bytes ([byte[]]@(65)) -GamePath:$stores[0].GamePath } catch { $caught.Add($_.Exception) }
            }
            Assert-Dlss5True ($caught.Count -eq 1 -and [object]::ReferenceEquals($caught[0], $plainFailure)) 'A failure without a snapshot was not rethrown unchanged.'
            Assert-Dlss5True (-not $caught[0].Data.Contains('CandidatePath')) 'A failure without a snapshot claimed a retained candidate.'
            Assert-Dlss5Equal @(Get-ChildItem -LiteralPath $Game -Force -Filter '.note-taker.notes.md.candidate-*').Count 0 'A failure without a snapshot left a candidate.'
            Assert-Dlss5Equal ([IO.File]::ReadAllText($stores[0].Path)) "remembered`r`n" 'A failure without a snapshot changed the store.'
            # A store with a mutex is cleared under it.
            [IO.File]::WriteAllText($stores[1].Path, "remembered`r`n", [Text.UTF8Encoding]::new($false))
            $locked = [Collections.Generic.List[string]]::new()
            & {
                function Invoke-Dlss5MachineNotesLocked { param([string]$MutexName, [TimeSpan]$Timeout, [scriptblock]$Action, [string]$LockSubject) $locked.Add($MutexName); return & $Action }
                Clear-Dlss5MissionStore -Path $PackagePath -Store $stores[1]
            }
            Assert-Dlss5Equal ($locked -join ',') 'Local\DLSS5-ADDER-STORE-note-taker-knowledge' 'Clear did not take the store mutex.'
            Assert-Dlss5Equal ([IO.File]::ReadAllText($stores[1].Path)) "# note-taker: knowledge store`r`n" 'Clear did not reset the store with a mutex.'
            # Another process holding the folder refuses before the question.
            $holder = Start-Dlss5GuardHolder -Package $PackagePath -LocalAppData (Join-Path $root 'localappdata')
            try {
                [IO.File]::WriteAllText($stores[0].Path, "remembered`r`n", [Text.UTF8Encoding]::new($false))
                $script:Dlss5Console = New-Dlss5SubstitutedConsole @('y', 'Enter', 'Escape')
                Invoke-Dlss5StoreMenu -Path $PackagePath
                Assert-Dlss5True ((Get-Dlss5ConsoleText).Contains('Not cleared:') -and -not (Get-Dlss5ConsoleText).Contains('Its contents cannot be recovered.')) "A held folder did not refuse before the question: $(Get-Dlss5ConsoleText)"
                Assert-Dlss5Equal ([IO.File]::ReadAllText($stores[0].Path)) "remembered`r`n" 'A refused Clear changed the store.'
                Assert-Dlss5Throws { Clear-Dlss5MissionStore -Path $PackagePath -Store $stores[0] } ([InvalidOperationException]) 'Clear did not take the folder guard.'
            }
            finally { Stop-Dlss5GuardHolder $holder }
        }
        # The shared copy lists the machine stores but not a target store.
        $slotRoot = Join-Path $script:ScratchRoot 'mission-stores-slot'
        Invoke-Dlss5WithLocalAppData -Path (Join-Path $slotRoot 'localappdata') -Action {
            New-Item -ItemType Directory -Force (Get-Dlss5StorePath) | Out-Null
            $slot = Get-Dlss5StorePath 'DLSS5-ADDER.cmd'
            [IO.File]::WriteAllBytes($slot, $script:CandidateBytes)
            $saved = $script:Dlss5ExecutingIdentity
            $script:Dlss5ExecutingIdentity = $script:CandidateIdentity
            try {
                $view = Get-Dlss5StoreView -Path $slot
                Assert-Dlss5Equal (@($view.MissionStores | ForEach-Object { $_.Store.Slot }) -join ',') 'machine,knowledge' 'The shared copy listed the wrong stores.'
            }
            finally { $script:Dlss5ExecutingIdentity = $saved }
        }
    }
    finally { $script:Dlss5OpenFile = $savedOpen }
}
