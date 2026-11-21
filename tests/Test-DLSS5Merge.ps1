# Loaded by the release suite after the mission store cases: the AI-assisted mission merge and mission ancestor cases added in v60.
if ($null -eq (Get-Command Invoke-Dlss5MissionMerge -ErrorAction SilentlyContinue)) {
    $script:Failures.Add('FAIL mission merge cases: the updater under test has no mission merge')
    return
}

function Get-Dlss5MergeText {
    param([Parameter(Mandatory=$true)][string]$Text)

    return [Text.UTF8Encoding]::new($false).GetBytes($Text + "`r`n")
}

# The published mission an edit started from: the candidate's mission with one instruction file as an earlier release had it.
$script:MergeAncestorFiles = [Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
foreach ($name in $script:CandidateIdentity.MissionFiles.Keys) { $script:MergeAncestorFiles[$name] = [byte[]]$script:CandidateIdentity.MissionFiles[$name] }
$script:MergeAncestorFiles['INSTRUCTIONS.settings-optimization.md'] = Get-Dlss5MergeText 'The settings optimization rules as an earlier release had them.'
$script:MergeAncestorHash = Get-Dlss5MissionHash $script:MergeAncestorFiles
$script:MergeEdit = Get-Dlss5MergeText 'The cleanup boundary as the user edited it.'
$script:MergeSeed = Get-Dlss5MergeText '{"schema_version":1,"host":"claude"}'

function New-Dlss5MergeCopyBytes {
    # Untyped, so a null replaced mission stays null rather than becoming an empty string.
    param($Replaced = $script:MergeAncestorHash, [switch]$Seed, [switch]$NoOffer)

    # An edited copy of the ancestor after an engine-only update whose release mission is the candidate's, offered unless -NoOffer.
    $offer = if ($NoOffer) { $null } else { $script:CandidateIdentity.MissionSha256 }
    $update = [pscustomobject]@{ FromVersion = $script:CandidateVersion - 1; FromMissionHash = $Replaced; FromSha256 = ('d' * 64); ReplacedEdit = $false; BackupSha256 = $null; KeptMission = $true; OfferedMissionHash = $offer }
    $files = [ordered]@{ 'INSTRUCTIONS.cleanup-boundary.md' = $script:MergeEdit; 'INSTRUCTIONS.settings-optimization.md' = [byte[]]$script:MergeAncestorFiles['INSTRUCTIONS.settings-optimization.md'] }
    if ($Seed) { $files['SEED.json'] = $script:MergeSeed }

    return ,(New-Dlss5PackageVariant -Bytes $script:CandidateBytes -Files $files -State (New-Dlss5StateLines -MissionEdited $true -ReplacedMissionHash $Replaced -Update $update))
}

function Initialize-Dlss5MergeMachine {
    param([switch]$NoSlot, [switch]$NoAncestor)

    # Trust for the candidate, the candidate as the shared copy holding the offered mission, and the ancestor kept on this machine.
    Write-Dlss5MachineTrustFixture -MachineDirectory (Get-Dlss5StorePath) -Whole @{ $script:CandidateVersion = $script:CandidateIdentity.Sha256 } -Engine @{ $script:CandidateVersion = $script:CandidateIdentity.EngineSha256 }
    if (-not $NoSlot) { [IO.File]::WriteAllBytes((Get-Dlss5StorePath 'DLSS5-ADDER.cmd'), $script:CandidateBytes) }
    if (-not $NoAncestor) { Save-Dlss5MissionAncestor -Files $script:MergeAncestorFiles -MissionHash $script:MergeAncestorHash }
}

function Get-Dlss5MergeFolders {
    $updates = Get-Dlss5StorePath 'updates'
    if (-not (Test-Path -LiteralPath $updates)) { return ,[string[]]@() }

    return ,[string[]]@(Get-ChildItem -LiteralPath $updates -Directory -Filter 'mission-merge-*' | ForEach-Object { $_.FullName })
}

function Copy-Dlss5MissionFileSet {
    param([Parameter(Mandatory=$true)][Collections.IDictionary]$Files, [Parameter(Mandatory=$true)][string]$Folder, [string[]]$Skip = @())

    foreach ($name in $Files.Keys) { if ($name -cnotin $Skip) { [IO.File]::WriteAllBytes((Join-Path $Folder $name), [byte[]]$Files[$name]) } }
}

function Get-Dlss5MergeInputFolders {
    param([Parameter(Mandatory=$true)][string]$Scratch)

    # Each input folder's files by name, with their bytes.
    $folders = [ordered]@{}
    foreach ($name in @('edited', 'release', 'ancestor')) {
        $folder = Join-Path $Scratch $name
        if (-not (Test-Path -LiteralPath $folder)) { continue }
        $files = [Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
        foreach ($file in @(Get-ChildItem -LiteralPath $folder -File | Sort-Object Name)) { $files[$file.Name] = [IO.File]::ReadAllBytes($file.FullName) }
        $folders[$name] = $files
    }

    return $folders
}

function Test-Dlss5MergeInputFolder {
    param([Parameter(Mandatory=$true)][Collections.IDictionary]$Folder, [Parameter(Mandatory=$true)][Collections.IDictionary]$Mission)

    # The folder holds exactly the mission's files apart from SEED.json, byte for byte.
    $expected = @($Mission.Keys | Where-Object { $_ -cne 'SEED.json' } | Sort-Object)
    if ((@($Folder.Keys) -join '|') -cne ($expected -join '|')) { return $false }
    foreach ($name in $expected) { if (-not (Test-Dlss5ByteEquality -Left ([byte[]]$Folder[$name]) -Right ([byte[]]$Mission[$name]))) { return $false } }

    return $true
}

function Invoke-Dlss5MergeWithAgent {
    param([Parameter(Mandatory=$true)][string]$PackagePath, [scriptblock]$Write = $null, [object[]]$Keys = @(), [ValidateSet('normal', 'unproven', 'not-started')][string]$Agent = 'normal', [ValidateSet('claude', 'codex')][string]$Kind = 'claude', [string]$Preflight = '', [string]$SelectFailure = '')

    # Replaces the host, its preflight and its process: the fake agent records what it was given, runs the writer on the scratch folder and exits.
    $hostKind = $Kind
    $preflightRefusal = $Preflight
    $selectFailure = $SelectFailure
    function Select-Dlss5Agent {
        if ($selectFailure.Length -gt 0) { throw [IO.FileNotFoundException]::new($selectFailure) }

        return [pscustomobject]@{ Kind = $hostKind; Command = ('C:\fake-host\' + $hostKind + '.exe'); Model = ''; Effort = 'high' }
    }
    function Get-Dlss5LaunchPreflightRefusal { param([string]$Path, [switch]$Target) return $preflightRefusal }
    $writer = $Write
    $agentKind = $Agent
    $script:MergeSeen = $null
    function Start-Dlss5AgentProcess {
        param($Info)
        $scratch = $Info.WorkingDirectory
        $prompt = @(Get-ChildItem -LiteralPath $scratch -File -Filter 'dlss5-agent-prompt-*.md')
        $script:MergeSeen = [pscustomobject]@{
            Scratch = $scratch
            Folders = [string[]]@(Get-ChildItem -LiteralPath $scratch -Directory | ForEach-Object { $_.Name } | Sort-Object)
            Edited = [string[]]@(Get-ChildItem -LiteralPath (Join-Path $scratch 'edited') -File | ForEach-Object { $_.Name })
            EditedCleanup = [IO.File]::ReadAllBytes((Join-Path $scratch 'edited\INSTRUCTIONS.cleanup-boundary.md'))
            Inputs = (Get-Dlss5MergeInputFolders $scratch)
            Prompt = $(if ($prompt.Count -eq 1) { [IO.File]::ReadAllText($prompt[0].FullName) } else { '' })
            Arguments = [string[]]@($Info.ArgumentList)
            Refusal = (Get-Dlss5GuardRefusal (Get-Dlss5GuardToken $PackagePath))
        }
        if ($agentKind -ceq 'not-started') { throw [ComponentModel.Win32Exception]::new(2) }
        if ($agentKind -ceq 'unproven') { throw [InvalidOperationException]::new('Injected ambiguous launch.') }
        if ($null -ne $writer) { & $writer $scratch }
        $start = [Diagnostics.ProcessStartInfo]::new('cmd.exe', '/d /c exit 0')
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true

        return [Diagnostics.Process]::Start($start)
    }
    $script:Dlss5Console = New-Dlss5SubstitutedConsole $Keys
    # A menu launch has never set the update channel, which StrictMode makes an error to read.
    Remove-Variable -Name Dlss5Channel -Scope Script -ErrorAction SilentlyContinue
    $identity = $script:Dlss5ExecutingIdentity
    $message = ''
    try { Invoke-Dlss5MissionMerge -Path $PackagePath -ExpectMission $identity.MissionSha256 -Offered (Get-Dlss5UpdateOffer $identity.State.Update).Offered }
    catch [InvalidOperationException] { $message = $_.Exception.Message }
    finally { if ($null -eq (Get-Variable -Name Dlss5Channel -Scope Script -ErrorAction SilentlyContinue)) { $script:Dlss5Channel = $null } }

    return [pscustomobject]@{ Message = $message; Text = (Get-Dlss5ConsoleText); Seen = $script:MergeSeen }
}

function Test-Dlss5MergeGrant {
    param([Parameter(Mandatory=$true)]$Seen, [Parameter(Mandatory=$true)][string]$Kind, [Parameter(Mandatory=$true)][string]$PackagePath)

    # The host is granted the scratch folder and nothing else: no store folder and not the package's own folder.
    $arguments = [string[]]$Seen.Arguments
    $flags = if ($Kind -ceq 'codex') { @('-C', '--add-dir') } else { @('--add-dir') }
    foreach ($flag in $flags) {
        $at = [Array]::IndexOf($arguments, $flag)
        if ($at -lt 0 -or $at + 1 -ge $arguments.Length -or $arguments[$at + 1] -cne $Seen.Scratch) { return $false }
    }
    $forbidden = @((Get-Dlss5StorePath), (Split-Path -Parent $PackagePath))
    foreach ($argument in $arguments) { if ($argument -in $forbidden) { return $false } }

    return $true
}

# The merged mission most cases write: the user's edit kept, the release's version of everything else.
$script:MergeWriteBoth = {
    param($Scratch)
    $merged = Join-Path $Scratch 'merged'
    Copy-Dlss5MissionFileSet -Files $script:CandidateIdentity.MissionFiles -Folder $merged
    [IO.File]::WriteAllBytes((Join-Path $merged 'INSTRUCTIONS.cleanup-boundary.md'), $script:MergeEdit)
}

Invoke-Dlss5Case 'merge keeps the ancestor at a copy''s first mission edit and reads it back' {
    $edit = Join-Path $script:ScratchRoot 'merge-ancestor-edit'
    New-Item -ItemType Directory -Force $edit | Out-Null
    $dropped = Join-Path $edit 'INSTRUCTIONS.cleanup-boundary.md'
    $published = New-Dlss5PackageVariant -Bytes $script:CandidateBytes -State (New-Dlss5StateLines)
    $result = Invoke-Dlss5PackageInteraction -Name 'merge-ancestor-first' -Bytes $published -Action {
        param($PackagePath)
        Initialize-Dlss5MergeMachine -NoSlot -NoAncestor
        $script:Dlss5Console = New-Dlss5SubstitutedConsole @()
        [IO.File]::WriteAllBytes($dropped, $script:MergeEdit)
        $first = Invoke-Dlss5Absorb -Path $PackagePath -Files @($dropped) -Headless
        $path = Get-Dlss5AncestorPath $script:CandidateIdentity.MissionSha256
        $kept = Read-Dlss5MissionAncestor $script:CandidateIdentity.MissionSha256
        $stamp = if (Test-Path -LiteralPath $path) { (Get-Item -LiteralPath $path).LastWriteTimeUtc } else { $null }
        [IO.File]::WriteAllBytes($dropped, (Get-Dlss5MergeText 'A second edit.'))
        $second = Invoke-Dlss5Absorb -Path $PackagePath -Files @($dropped) -Headless
        $after = Get-Dlss5PackageIdentityAt $PackagePath

        return [pscustomobject]@{ First = $first; Second = $second; Kept = $kept; Stamp = $stamp; StampAfter = (Get-Item -LiteralPath $path).LastWriteTimeUtc; After = $after; Count = @(Get-ChildItem -LiteralPath (Get-Dlss5AncestorDirectory)).Count; Text = (Get-Dlss5ConsoleText) }
    }
    Assert-Dlss5True ($result.First -eq 0 -and $result.Second -eq 0) "An absorb failed: $($result.Text)"
    Assert-Dlss5True ($null -ne $result.Kept.Files -and (Get-Dlss5MissionHash $result.Kept.Files) -ceq $script:CandidateIdentity.MissionSha256) "The first edit did not keep the published mission: $($result.Kept.Reason)"
    Assert-Dlss5True ($result.Stamp -eq $result.StampAfter -and $result.Count -eq 1) 'A later edit rewrote the ancestor or kept another.'
    Assert-Dlss5Equal $result.After.State.ReplacedMissionHash $script:CandidateIdentity.MissionSha256 'The edit did not record the mission it replaced.'
    $hand = New-Dlss5PackageVariant -Bytes $script:CandidateBytes -Files ([ordered]@{ 'INSTRUCTIONS.cleanup-boundary.md' = $script:MergeEdit }) -State (New-Dlss5StateLines)
    $none = Invoke-Dlss5PackageInteraction -Name 'merge-ancestor-hand' -Bytes $hand -Action {
        param($PackagePath)
        Initialize-Dlss5MergeMachine -NoSlot -NoAncestor
        $script:Dlss5Console = New-Dlss5SubstitutedConsole @()
        [IO.File]::WriteAllBytes($dropped, (Get-Dlss5MergeText 'Edited again.'))
        $code = Invoke-Dlss5Absorb -Path $PackagePath -Files @($dropped) -Headless

        return [pscustomobject]@{ Code = $code; Exists = (Test-Path -LiteralPath (Get-Dlss5AncestorDirectory)); Replaced = (Get-Dlss5PackageIdentityAt $PackagePath).State.ReplacedMissionHash }
    }
    Assert-Dlss5True ($none.Code -eq 0 -and -not $none.Exists -and $null -eq $none.Replaced) 'A hand-edited copy kept an ancestor or recorded a replaced mission.'
}

Invoke-Dlss5Case 'merge reports an invalid ancestor without touching it, and a failed ancestor write lets the edit finish' {
    Invoke-Dlss5WithLocalAppData -Path (Join-Path $script:ScratchRoot 'merge-ancestor-invalid') -Action {
        New-Item -ItemType Directory -Force (Get-Dlss5AncestorDirectory) | Out-Null
        $garbage = Get-Dlss5AncestorPath ('a' * 64)
        [IO.File]::WriteAllBytes($garbage, (Get-Dlss5MergeText 'not a mission body'))
        $read = Read-Dlss5MissionAncestor ('a' * 64)
        Assert-Dlss5True ($null -eq $read.Files -and $read.Reason.StartsWith('the kept copy cannot be read', [StringComparison]::Ordinal)) "A malformed ancestor did not read as not kept: $($read.Reason)"
        Assert-Dlss5True (Test-Dlss5ByteEquality -Left ([IO.File]::ReadAllBytes($garbage)) -Right (Get-Dlss5MergeText 'not a mission body')) 'Reading changed the malformed ancestor.'
        $wrong = Get-Dlss5AncestorPath ('b' * 64)
        [IO.File]::WriteAllBytes($wrong, (ConvertTo-Dlss5AncestorBytes $script:MergeAncestorFiles))
        Assert-Dlss5Equal (Read-Dlss5MissionAncestor ('b' * 64)).Reason 'the kept copy does not match its mission hash' 'An ancestor under another hash was accepted.'
        Assert-Dlss5Equal (Read-Dlss5MissionAncestor ('c' * 64)).Reason 'it is not kept on this machine' 'A missing ancestor gave the wrong reason.'
        # A writer replaces an invalid file under the right name.
        [IO.File]::WriteAllBytes((Get-Dlss5AncestorPath $script:MergeAncestorHash), (Get-Dlss5MergeText 'damaged'))
        $script:Dlss5Console = New-Dlss5SubstitutedConsole @()
        Save-Dlss5MissionAncestor -Files $script:MergeAncestorFiles -MissionHash $script:MergeAncestorHash
        Assert-Dlss5True ($null -ne (Read-Dlss5MissionAncestor $script:MergeAncestorHash).Files) 'A writer did not replace a damaged ancestor.'
        # Saving an ancestor that is already kept and valid leaves its file alone.
        $kept = Get-Dlss5AncestorPath $script:MergeAncestorHash
        $identity = (Get-Dlss5PathSnapshot -Path $kept).LeafIdentity
        $stamp = (Get-Item -LiteralPath $kept).LastWriteTimeUtc
        Save-Dlss5MissionAncestor -Files $script:MergeAncestorFiles -MissionHash $script:MergeAncestorHash
        Assert-Dlss5True ((Get-Dlss5PathSnapshot -Path $kept).LeafIdentity -ceq $identity -and (Get-Item -LiteralPath $kept).LastWriteTimeUtc -eq $stamp) 'A valid ancestor was rewritten.'
    }
    $edit = Join-Path $script:ScratchRoot 'merge-ancestor-blocked-edit'
    New-Item -ItemType Directory -Force $edit | Out-Null
    $dropped = Join-Path $edit 'INSTRUCTIONS.cleanup-boundary.md'
    $result = Invoke-Dlss5PackageInteraction -Name 'merge-ancestor-blocked' -Bytes (New-Dlss5PackageVariant -Bytes $script:CandidateBytes -State (New-Dlss5StateLines)) -Action {
        param($PackagePath)
        Initialize-Dlss5MergeMachine -NoSlot -NoAncestor
        # A file where the ancestor folder belongs makes the ancestor write fail.
        New-Item -ItemType Directory -Force (Split-Path -Parent (Get-Dlss5AncestorDirectory)) | Out-Null
        [IO.File]::WriteAllBytes((Get-Dlss5AncestorDirectory), [byte[]](65))
        $script:Dlss5Console = New-Dlss5SubstitutedConsole @()
        [IO.File]::WriteAllBytes($dropped, $script:MergeEdit)
        $code = Invoke-Dlss5Absorb -Path $PackagePath -Files @($dropped) -Headless

        return [pscustomobject]@{ Code = $code; Text = (Get-Dlss5ConsoleText); After = (Get-Dlss5PackageIdentityAt $PackagePath) }
    }
    Assert-Dlss5True ($result.Code -eq 0 -and $result.After.MissionFiles['INSTRUCTIONS.cleanup-boundary.md'].Length -eq $script:MergeEdit.Length) "The edit did not finish when its ancestor could not be kept: $($result.Text)"
    Assert-Dlss5True $result.Text.Contains('could not be kept on this machine, so a later merge will compare only two versions') "The failed ancestor write was not reported: $($result.Text)"
}

Invoke-Dlss5Case 'merge is offered beside Take, with the three-way or two-way line and its reason' {
    $result = Invoke-Dlss5PackageInteraction -Name 'merge-box' -Bytes (New-Dlss5MergeCopyBytes) -Action {
        param($PackagePath)
        Initialize-Dlss5MergeMachine
        $texts = [ordered]@{}
        foreach ($case in @(@('kept', (New-Dlss5MergeCopyBytes)), @('missing', (New-Dlss5MergeCopyBytes -Replaced ('c' * 64))), @('unknown', (New-Dlss5MergeCopyBytes -Replaced $null)), @('quiet', (New-Dlss5MergeCopyBytes -NoOffer)))) {
            $script:Dlss5Console = New-Dlss5SubstitutedConsole @()
            Write-Dlss5ChangesBox -Identity (Get-Dlss5BootstrapIdentity -Bytes $case[1] -Strict) -Path $PackagePath
            $texts[$case[0]] = Get-Dlss5ConsoleText
        }
        $script:Dlss5Console = New-Dlss5SubstitutedConsole @('q', 'Enter')
        $null = Invoke-Dlss5Menu -Path $PackagePath
        $texts['menu'] = Get-Dlss5ConsoleText
        [IO.File]::WriteAllBytes($PackagePath, (New-Dlss5MergeCopyBytes -NoOffer))
        $script:Dlss5ExecutingIdentity = Get-Dlss5PackageIdentityAt $PackagePath
        $script:Dlss5Console = New-Dlss5SubstitutedConsole @('q', 'Enter')
        $null = Invoke-Dlss5Menu -Path $PackagePath
        $texts['quiet-menu'] = Get-Dlss5ConsoleText

        return $texts
    }
    Assert-Dlss5True $result['kept'].Contains('seeing what each side changed from the mission your edit replaced') "The box did not offer a three-way merge: $($result['kept'])"
    Assert-Dlss5True $result['missing'].Contains('is not available (it is not kept on this machine), so it compares only the two versions') "The box did not give the missing ancestor's reason: $($result['missing'])"
    Assert-Dlss5True $result['unknown'].Contains('(it is not known)') "The box did not give the unknown ancestor's reason: $($result['unknown'])"
    Assert-Dlss5True (-not $result['quiet'].Contains('Merging asks')) 'The box offered a merge without an offered mission.'
    Assert-Dlss5True ($result['menu'].Contains('Take the release''s mission') -and $result['menu'].Contains('Merge with the release''s mission')) "The box did not offer Merge beside Take: $($result['menu'])"
    Assert-Dlss5True (-not $result['quiet-menu'].Contains('Merge with the release''s mission') -and -not $result['quiet-menu'].Contains('Take the release''s mission')) 'Merge was offered where Take is not.'
}

Invoke-Dlss5Case 'merge writes the confirmed result with the .bkp, the release''s mission as the replaced one and its ancestor kept' {
    $bytes = New-Dlss5MergeCopyBytes -Seed
    $result = Invoke-Dlss5PackageInteraction -Name 'merge-apply' -Bytes $bytes -Action {
        param($PackagePath)
        Initialize-Dlss5MergeMachine
        $run = Invoke-Dlss5MergeWithAgent -PackagePath $PackagePath -Write $script:MergeWriteBoth -Keys @('y', 'Enter')
        $grant = $null -ne $run.Seen -and (Test-Dlss5MergeGrant -Seen $run.Seen -Kind 'claude' -PackagePath $PackagePath)

        return [pscustomobject]@{ Run = $run; Grant = $grant; After = (Get-Dlss5PackageIdentityAt $PackagePath); Backup = [IO.File]::ReadAllBytes($PackagePath + '.bkp'); Kept = (Read-Dlss5MissionAncestor $script:CandidateIdentity.MissionSha256); Folders = (Get-Dlss5MergeFolders) }
    }
    $seen = $result.Run.Seen
    Assert-Dlss5Equal $result.Run.Message '' "The merge refused: $($result.Run.Message) $($result.Run.Text)"
    Assert-Dlss5Equal ($seen.Folders -join ',') 'ancestor,edited,merged,release' 'The scratch folder did not hold the three inputs and the output.'
    Assert-Dlss5True $result.Grant "The host was not granted exactly the scratch folder: $($seen.Arguments -join ' ')"
    Assert-Dlss5True (-not ($seen.Edited -contains 'SEED.json') -and (Test-Dlss5ByteEquality -Left $seen.EditedCleanup -Right $script:MergeEdit)) 'The edited input held the seed or not the edit.'
    $editedMission = (Get-Dlss5BootstrapIdentity -Bytes $bytes -Strict).MissionFiles
    Assert-Dlss5True (Test-Dlss5MergeInputFolder -Folder $seen.Inputs['edited'] -Mission $editedMission) 'The edited input folder is not the edited mission without its seed.'
    Assert-Dlss5True (Test-Dlss5MergeInputFolder -Folder $seen.Inputs['release'] -Mission $script:CandidateIdentity.MissionFiles) 'The release input folder is not the release''s mission.'
    Assert-Dlss5True (Test-Dlss5MergeInputFolder -Folder $seen.Inputs['ancestor'] -Mission $script:MergeAncestorFiles) 'The ancestor input folder is not the kept ancestor.'
    Assert-Dlss5True ($seen.Prompt.Contains('(the common ancestor)') -and $seen.Prompt.Contains('Never write SEED.json') -and $seen.Prompt.Contains('at most 40 characters') -and $seen.Prompt.Contains('larger than 2 MiB')) "The prompt did not name the ancestor, the seed rule or the file limits: $($seen.Prompt)"
    Assert-Dlss5True ($seen.Refusal.Contains('another DLSS 5 ADDER mission merge is running') -and $seen.Refusal.Contains('host claude')) "The guard did not name the merge and its host: $($seen.Refusal)"
    $after = $result.After
    Assert-Dlss5True ($after.State.MissionEdited -and $after.State.ReplacedMissionHash -ceq $script:CandidateIdentity.MissionSha256 -and $null -eq $after.State.Update -and -not $after.State.Armed -and (Get-Dlss5StateRecords $after.State).Count -eq 0) 'The merge did not leave an edited, disarmed copy with the release''s mission as the replaced one.'
    Assert-Dlss5True ((Test-Dlss5ByteEquality -Left ([byte[]]$after.MissionFiles['INSTRUCTIONS.cleanup-boundary.md']) -Right $script:MergeEdit) -and (Test-Dlss5ByteEquality -Left ([byte[]]$after.MissionFiles['INSTRUCTIONS.settings-optimization.md']) -Right ([byte[]]$script:CandidateIdentity.MissionFiles['INSTRUCTIONS.settings-optimization.md']))) 'The merged files were not written.'
    Assert-Dlss5True (Test-Dlss5ByteEquality -Left ([byte[]]$after.MissionFiles['SEED.json']) -Right $script:MergeSeed) 'The copy lost its seed.'
    Assert-Dlss5True (Test-Dlss5ByteEquality -Left $result.Backup -Right $bytes) 'The edited file was not kept as the .bkp.'
    Assert-Dlss5True ($null -ne $result.Kept.Files) "The release's mission was not kept as the next ancestor: $($result.Kept.Reason)"
    Assert-Dlss5True ($result.Folders.Count -eq 0) 'The merge folder was left behind.'
    Assert-Dlss5True ($result.Run.Text.Contains('INSTRUCTIONS.cleanup-boundary.md: as in your edit; different from the release''s version.') -and $result.Run.Text.Contains('SEED.json: kept from your copy.') -and $result.Run.Text.Contains('Merged the release''s mission into your edit.')) "The review or the result was not reported: $($result.Run.Text)"
}

Invoke-Dlss5Case 'merge ends as Take for the release''s mission, writes nothing for the edit itself or on Discard, and compares two versions without an ancestor' {
    $bytes = New-Dlss5MergeCopyBytes -Replaced $null
    $result = Invoke-Dlss5PackageInteraction -Name 'merge-outcomes' -Bytes $bytes -Action {
        param($PackagePath)
        Initialize-Dlss5MergeMachine -NoAncestor
        $same = Invoke-Dlss5MergeWithAgent -PackagePath $PackagePath -Write { param($Scratch) Copy-Dlss5MissionFileSet -Files $script:Dlss5ExecutingIdentity.MissionFiles -Folder (Join-Path $Scratch 'merged') }
        $sameBytes = [IO.File]::ReadAllBytes($PackagePath)
        $discard = Invoke-Dlss5MergeWithAgent -PackagePath $PackagePath -Write $script:MergeWriteBoth -Keys @('n', 'Enter')
        $discardBytes = [IO.File]::ReadAllBytes($PackagePath)
        $release = Invoke-Dlss5MergeWithAgent -PackagePath $PackagePath -Write { param($Scratch) Copy-Dlss5MissionFileSet -Files $script:CandidateIdentity.MissionFiles -Folder (Join-Path $Scratch 'merged') } -Keys @('y', 'Enter')

        return [pscustomobject]@{ Same = $same; SameBytes = $sameBytes; Discard = $discard; DiscardBytes = $discardBytes; Release = $release; After = (Get-Dlss5PackageIdentityAt $PackagePath); Folders = (Get-Dlss5MergeFolders) }
    }
    Assert-Dlss5True ($result.Same.Text.Contains('The merge changed nothing in your edited mission.') -and (Test-Dlss5ByteEquality -Left $result.SameBytes -Right $bytes)) "A merge equal to the edit wrote something: $($result.Same.Text)"
    Assert-Dlss5True (($result.Same.Seen.Folders -join ',') -ceq 'edited,merged,release' -and $result.Same.Seen.Prompt.Contains('no common ancestor')) 'A merge without an ancestor did not compare two versions.'
    Assert-Dlss5True ($result.Discard.Text.Contains('Discarded the merge; nothing was written.') -and (Test-Dlss5ByteEquality -Left $result.DiscardBytes -Right $bytes)) "Discard wrote something: $($result.Discard.Text)"
    Assert-Dlss5True ($result.Release.Text.Contains('Took the release''s mission') -and $result.After.PublishedSha256 -ceq $script:CandidateIdentity.Sha256 -and -not $result.After.State.MissionEdited) "A merge equal to the release did not end as Take: $($result.Release.Text)"
    Assert-Dlss5True ($result.Folders.Count -eq 0) 'A merge folder was left behind.'
}

Invoke-Dlss5Case 'merge converts mission files written with LF line breaks only to CRLF and says so' {
    $result = Invoke-Dlss5PackageInteraction -Name 'merge-bare-lf' -Bytes (New-Dlss5MergeCopyBytes) -Action {
        param($PackagePath)
        Initialize-Dlss5MergeMachine
        $lf = {
            param($Scratch)
            & $script:MergeWriteBoth $Scratch
            foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $Scratch 'merged') -File)) {
                $text = [IO.File]::ReadAllText($file.FullName, [Text.UTF8Encoding]::new($false))
                [IO.File]::WriteAllText($file.FullName, $text.Replace("`r`n", "`n"), [Text.UTF8Encoding]::new($false))
            }
        }
        $run = Invoke-Dlss5MergeWithAgent -PackagePath $PackagePath -Write $lf -Keys @('y', 'Enter')

        return [pscustomobject]@{ Run = $run; After = (Get-Dlss5PackageIdentityAt $PackagePath) }
    }
    Assert-Dlss5Equal $result.Run.Message '' "A merge written with LF line breaks was refused: $($result.Run.Message)"
    Assert-Dlss5True $result.Run.Text.Contains('MISSION.md was written with LF line breaks; the engine converted them to CRLF.') "The conversion was not reported: $($result.Run.Text)"
    Assert-Dlss5True ($result.Run.Text.Contains('INSTRUCTIONS.cleanup-boundary.md: as in your edit; different from the release''s version.') -and $result.Run.Text.Contains('MISSION.md: as in your edit; equal to the release''s version.')) "Converted files did not compare equal to their CRLF sources: $($result.Run.Text)"
    foreach ($name in $script:CandidateIdentity.MissionFiles.Keys) {
        $expected = if ($name -ceq 'INSTRUCTIONS.cleanup-boundary.md') { $script:MergeEdit } else { [byte[]]$script:CandidateIdentity.MissionFiles[$name] }
        Assert-Dlss5True (Test-Dlss5ByteEquality -Left ([byte[]]$result.After.MissionFiles[$name]) -Right $expected) "$name was not written in its CRLF form."
    }
    # An edit that is itself LF-only, copied unchanged, keeps its bytes, so a merge that changes nothing still says so; so does an empty file.
    $lfEdit = [Text.UTF8Encoding]::new($false).GetBytes("An edit saved with LF line breaks.`n")
    $lfCopy = New-Dlss5PackageVariant -Bytes (New-Dlss5MergeCopyBytes) -Files ([ordered]@{ 'INSTRUCTIONS.cleanup-boundary.md' = $lfEdit; 'INSTRUCTIONS.empty.md' = [byte[]]@() })
    $kept = Invoke-Dlss5PackageInteraction -Name 'merge-bare-lf-copied' -Bytes $lfCopy -Action {
        param($PackagePath)
        Initialize-Dlss5MergeMachine
        $run = Invoke-Dlss5MergeWithAgent -PackagePath $PackagePath -Write { param($Scratch) Copy-Dlss5MissionFileSet -Files $script:Dlss5ExecutingIdentity.MissionFiles -Folder (Join-Path $Scratch 'merged') }

        return [pscustomobject]@{ Run = $run; Bytes = [IO.File]::ReadAllBytes($PackagePath) }
    }
    Assert-Dlss5True ($kept.Run.Text.Contains('The merge changed nothing in your edited mission.') -and -not $kept.Run.Text.Contains('converted them to CRLF') -and (Test-Dlss5ByteEquality -Left $kept.Bytes -Right $lfCopy)) "An LF-only file copied from the edit was converted: $($kept.Run.Text)"
}

Invoke-Dlss5Case 'merge refuses invalid results, lists ignored entries and leaves the package unchanged' {
    $bytes = New-Dlss5MergeCopyBytes
    $result = Invoke-Dlss5PackageInteraction -Name 'merge-invalid' -Bytes $bytes -Action {
        param($PackagePath)
        Initialize-Dlss5MergeMachine
        $runs = [ordered]@{}
        $runs['empty'] = Invoke-Dlss5MergeWithAgent -PackagePath $PackagePath
        $runs['no-mission'] = Invoke-Dlss5MergeWithAgent -PackagePath $PackagePath -Write { param($Scratch) Copy-Dlss5MissionFileSet -Files $script:CandidateIdentity.MissionFiles -Folder (Join-Path $Scratch 'merged') -Skip @('MISSION.md') }
        $runs['undeclared'] = Invoke-Dlss5MergeWithAgent -PackagePath $PackagePath -Write { param($Scratch) & $script:MergeWriteBoth $Scratch; [IO.File]::WriteAllBytes((Join-Path $Scratch 'merged\TEST.extra.ps1'), (Get-Dlss5MergeText 'exit 0')) }
        $runs['bad-project'] = Invoke-Dlss5MergeWithAgent -PackagePath $PackagePath -Write { param($Scratch) & $script:MergeWriteBoth $Scratch; [IO.File]::WriteAllBytes((Join-Path $Scratch 'merged\PROJECT.json'), (Get-Dlss5MergeText '{ not json')) }
        $runs['bad-utf8'] = Invoke-Dlss5MergeWithAgent -PackagePath $PackagePath -Write { param($Scratch) & $script:MergeWriteBoth $Scratch; [IO.File]::WriteAllBytes((Join-Path $Scratch 'merged\PROJECT.json'), [byte[]](255, 123, 125, 13, 10)) }
        $runs['bad-template'] = Invoke-Dlss5MergeWithAgent -PackagePath $PackagePath -Write { param($Scratch) & $script:MergeWriteBoth $Scratch; [IO.File]::WriteAllBytes((Join-Path $Scratch 'merged\MISSION.md'), (Get-Dlss5MergeText 'A prompt without its template header.')) }
        $runs['ignored'] = Invoke-Dlss5MergeWithAgent -PackagePath $PackagePath -Keys @('n', 'Enter') -Write {
            param($Scratch)
            & $script:MergeWriteBoth $Scratch
            [IO.File]::WriteAllBytes((Join-Path $Scratch 'merged\notes.txt'), (Get-Dlss5MergeText 'conflict notes'))
            [IO.File]::WriteAllBytes((Join-Path $Scratch 'merged\SEED.json'), $script:MergeSeed)
            [IO.File]::WriteAllBytes((Join-Path $Scratch 'merged\INSTRUCTIONS.settings-optimization.md'), (Get-Dlss5MergeText 'Merged settings rules.'))
        }

        return [pscustomobject]@{ Runs = $runs; Bytes = [IO.File]::ReadAllBytes($PackagePath); Folders = (Get-Dlss5MergeFolders); Backup = (Test-Path -LiteralPath ($PackagePath + '.bkp')) }
    }
    $runs = $result.Runs
    Assert-Dlss5True ($runs['empty'].Message.Contains('the merged mission has no MISSION.md.')) "An empty output folder was not refused: $($runs['empty'].Message)"
    Assert-Dlss5True ($runs['no-mission'].Message.Contains('the merged mission has no MISSION.md.')) "A result without MISSION.md was not refused: $($runs['no-mission'].Message)"
    Assert-Dlss5True ($runs['undeclared'].Message.Contains('the merged mission''s tests are inconsistent')) "An undeclared test was not refused: $($runs['undeclared'].Message)"
    Assert-Dlss5True ($runs['bad-project'].Message.Contains('The merge was not applied:')) "An invalid PROJECT.json was not refused: $($runs['bad-project'].Message)"
    Assert-Dlss5True ($runs['bad-utf8'].Message.StartsWith('The merge was not applied: the merged mission is not valid: ', [StringComparison]::Ordinal) -and $runs['bad-utf8'].Message.EndsWith(' Nothing was written.', [StringComparison]::Ordinal)) "A PROJECT.json with invalid UTF-8 was not refused as an invalid merge: $($runs['bad-utf8'].Message)"
    Assert-Dlss5True ($runs['bad-template'].Message.Contains('the merged mission is not valid: MISSION.md must start with @@template.')) "A template that does not read strictly was not refused: $($runs['bad-template'].Message)"
    $ignored = $runs['ignored'].Text
    Assert-Dlss5True ($ignored.Contains('Ignored, not a mission file: notes.txt') -and $ignored.Contains('Ignored, not a mission file: SEED.json') -and $ignored.Contains('INSTRUCTIONS.settings-optimization.md: changed from your edit; different from the release''s version.')) "The ignored entries or the review were not shown: $ignored"
    Assert-Dlss5True ((Test-Dlss5ByteEquality -Left $result.Bytes -Right $bytes) -and -not $result.Backup -and $result.Folders.Count -eq 0) 'A refused merge changed the package, wrote a .bkp or left its folder.'
}

Invoke-Dlss5Case 'merge refuses before the agent without the offered mission or when Git tracks the .bkp, and at the write when the package changed' {
    $bytes = New-Dlss5MergeCopyBytes
    $result = Invoke-Dlss5PackageInteraction -Name 'merge-refusals' -Bytes $bytes -Action {
        param($PackagePath)
        Initialize-Dlss5MergeMachine -NoSlot
        $noSlot = Invoke-Dlss5MergeWithAgent -PackagePath $PackagePath -Write $script:MergeWriteBoth
        [IO.File]::WriteAllBytes((Get-Dlss5StorePath 'DLSS5-ADDER.cmd'), $script:CandidateBytes)
        $changed = New-Dlss5PackageVariant -Bytes $bytes -Files ([ordered]@{ 'INSTRUCTIONS.cleanup-boundary.md' = (Get-Dlss5MergeText 'Changed in another window.') })
        # Changed after the box was shown and before the merge starts: refused when the inputs are read, before any agent starts.
        [IO.File]::WriteAllBytes($PackagePath, $changed)
        $early = Invoke-Dlss5MergeWithAgent -PackagePath $PackagePath -Write $script:MergeWriteBoth
        $earlyBytes = [IO.File]::ReadAllBytes($PackagePath)
        [IO.File]::WriteAllBytes($PackagePath, $bytes)
        $script:Dlss5ExecutingIdentity = Get-Dlss5BootstrapIdentity -Bytes $bytes -Strict
        $raced = Invoke-Dlss5MergeWithAgent -PackagePath $PackagePath -Keys @('y', 'Enter') -Write { param($Scratch) & $script:MergeWriteBoth $Scratch; [IO.File]::WriteAllBytes($PackagePath, $changed) }

        return [pscustomobject]@{ NoSlot = $noSlot; Early = $early; EarlyBytes = $earlyBytes; Raced = $raced; Bytes = [IO.File]::ReadAllBytes($PackagePath); Backup = (Test-Path -LiteralPath ($PackagePath + '.bkp')); Folders = (Get-Dlss5MergeFolders); Changed = $changed }
    }
    Assert-Dlss5True ($result.NoSlot.Message.Contains('not available from the shared AppData copy any more') -and $null -eq $result.NoSlot.Seen) "A merge without the offered mission did not refuse before the agent: $($result.NoSlot.Message)"
    Assert-Dlss5True ($result.Early.Message.Contains('The package changed in another window') -and $null -eq $result.Early.Seen -and (Test-Dlss5ByteEquality -Left $result.EarlyBytes -Right $result.Changed)) "A package changed since the box did not refuse before the agent: $($result.Early.Message)"
    Assert-Dlss5True ($result.Raced.Message.Contains('The package changed in another window') -and (Test-Dlss5ByteEquality -Left $result.Bytes -Right $result.Changed) -and -not $result.Backup) "A package changed during the merge was overwritten: $($result.Raced.Message)"
    Assert-Dlss5True ($result.Folders.Count -eq 0) 'A refused merge left its folder.'
    $fixture = New-Dlss5GitFixture 'merge-tracked-backup'
    $backup = [Text.Encoding]::ASCII.GetBytes("a committed backup`r`n")
    [IO.File]::WriteAllBytes($fixture.Backup, $backup)
    [void](Invoke-Dlss5Git -Repository $fixture.Root add -- 'Game/DLSS5-ADDER.cmd.bkp')
    [void](Invoke-Dlss5Git -Repository $fixture.Root commit -m 'test: track only the backup')
    [IO.File]::WriteAllBytes($fixture.Updater, $bytes)
    $localAppData = Join-Path $fixture.Root 'LocalAppData'
    $saved = @{ Identity = (Get-Variable -Name Dlss5ExecutingIdentity -Scope Script -ValueOnly -ErrorAction SilentlyContinue); Startup = (Get-Variable -Name Dlss5Startup -Scope Script -ValueOnly -ErrorAction SilentlyContinue); Engine = (Get-Variable -Name Dlss5ExecutingEngineSha256 -Scope Script -ValueOnly -ErrorAction SilentlyContinue); Console = $script:Dlss5Console }
    try {
        $tracked = Invoke-Dlss5WithLocalAppData -Path $localAppData -Action {
            New-Item -ItemType Directory -Force (Get-Dlss5StorePath) | Out-Null
            Initialize-Dlss5MergeMachine
            $script:Dlss5ExecutingEngineSha256 = $script:CandidateIdentity.EngineSha256
            $script:Dlss5ExecutingIdentity = Get-Dlss5BootstrapIdentity -Bytes $bytes -Strict
            $script:Dlss5Startup = [pscustomobject]@{ Diagnosis = $null }

            return Invoke-Dlss5MergeWithAgent -PackagePath $fixture.Updater -Write $script:MergeWriteBoth -Keys @('y', 'Enter')
        }
    }
    finally { $script:Dlss5ExecutingIdentity = $saved.Identity; $script:Dlss5Startup = $saved.Startup; $script:Dlss5ExecutingEngineSha256 = $saved.Engine; $script:Dlss5Console = $saved.Console }
    Assert-Dlss5True ($tracked.Message.Contains('Merging keeps your edited file as DLSS5-ADDER.cmd.bkp, but Git tracks that .bkp file') -and $null -eq $tracked.Seen) "A merge beside a tracked .bkp did not refuse before the agent: $($tracked.Message)"
    Assert-Dlss5True ((Test-Dlss5ByteEquality -Left ([IO.File]::ReadAllBytes($fixture.Updater)) -Right $bytes) -and (Test-Dlss5ByteEquality -Left ([IO.File]::ReadAllBytes($fixture.Backup)) -Right $backup)) 'A refused merge changed the copy or the tracked .bkp.'
}

Invoke-Dlss5Case 'merge keeps and names its folder when the agent''s exit is unproven, and removes it when the agent cannot start' {
    $bytes = New-Dlss5MergeCopyBytes
    $result = Invoke-Dlss5PackageInteraction -Name 'merge-agent-failures' -Bytes $bytes -Action {
        param($PackagePath)
        Initialize-Dlss5MergeMachine
        $notStarted = Invoke-Dlss5MergeWithAgent -PackagePath $PackagePath -Agent 'not-started'
        $afterNotStarted = Get-Dlss5MergeFolders
        $unproven = Invoke-Dlss5MergeWithAgent -PackagePath $PackagePath -Agent 'unproven'
        $kept = Get-Dlss5MergeFolders

        return [pscustomobject]@{ NotStarted = $notStarted; AfterNotStarted = $afterNotStarted; Unproven = $unproven; Kept = $kept; Bytes = [IO.File]::ReadAllBytes($PackagePath) }
    }
    Assert-Dlss5True ($result.NotStarted.Message.Contains('the AI host could not be started') -and $result.AfterNotStarted.Count -eq 0) "An agent that could not start did not refuse cleanly: $($result.NotStarted.Message)"
    Assert-Dlss5True ($result.Unproven.Message.Contains('so its folder is kept') -and $result.Kept.Count -eq 1 -and $result.Unproven.Message.Contains($result.Kept[0])) "An unproven agent exit did not keep and name the folder: $($result.Unproven.Message)"
    Assert-Dlss5True (Test-Dlss5ByteEquality -Left $result.Bytes -Right $bytes) 'A failed agent changed the package.'
}

Invoke-Dlss5Case 'merge grants Codex only the scratch folder, and refuses before the agent when the preflight or host selection refuses' {
    $bytes = New-Dlss5MergeCopyBytes
    $result = Invoke-Dlss5PackageInteraction -Name 'merge-host' -Bytes $bytes -Action {
        param($PackagePath)
        Initialize-Dlss5MergeMachine
        $codex = Invoke-Dlss5MergeWithAgent -PackagePath $PackagePath -Kind 'codex'
        $grant = $null -ne $codex.Seen -and (Test-Dlss5MergeGrant -Seen $codex.Seen -Kind 'codex' -PackagePath $PackagePath)
        $preflight = Invoke-Dlss5MergeWithAgent -PackagePath $PackagePath -Preflight 'Injected preflight refusal.'
        $select = Invoke-Dlss5MergeWithAgent -PackagePath $PackagePath -SelectFailure 'Injected host not found.'

        return [pscustomobject]@{ Codex = $codex; Grant = $grant; Preflight = $preflight; Select = $select; Bytes = [IO.File]::ReadAllBytes($PackagePath); Folders = (Get-Dlss5MergeFolders) }
    }
    Assert-Dlss5True $result.Grant "Codex was not granted exactly the scratch folder: $($result.Codex.Seen.Arguments -join ' ')"
    Assert-Dlss5True ($result.Codex.Message.Contains('the merged mission has no MISSION.md.')) "The Codex merge did not reach the result check: $($result.Codex.Message)"
    Assert-Dlss5True ($result.Preflight.Message -ceq 'The merge cannot start: Injected preflight refusal.' -and $null -eq $result.Preflight.Seen) "A preflight refusal did not stop the merge before the agent: $($result.Preflight.Message)"
    Assert-Dlss5True ($result.Select.Message -ceq 'The merge cannot start: Injected host not found.' -and $null -eq $result.Select.Seen) "A host selection failure did not stop the merge before the agent: $($result.Select.Message)"
    Assert-Dlss5True ((Test-Dlss5ByteEquality -Left $result.Bytes -Right $bytes) -and $result.Folders.Count -eq 0) 'A refused merge changed the package or left its folder.'
}

Invoke-Dlss5Case 'merge ancestors are listed, opened and cleared in the Stores view' {
    $result = Invoke-Dlss5PackageInteraction -Name 'merge-store-view' -Bytes (New-Dlss5MergeCopyBytes -NoOffer) -Action {
        param($PackagePath)
        Initialize-Dlss5MergeMachine -NoSlot
        [IO.File]::WriteAllBytes((Get-Dlss5AncestorPath ('a' * 64)), (Get-Dlss5MergeText 'damaged'))
        $script:MergeOpened = $null
        $savedOpen = $script:Dlss5OpenFolder
        try {
            $script:Dlss5OpenFolder = { param($FolderPath) $script:MergeOpened = $FolderPath }
            $script:Dlss5Console = New-Dlss5SubstitutedConsole @('o', 'Enter', 'c', 'Enter', 'y', 'Enter', 'b', 'Enter')
            Invoke-Dlss5StoreMenu -Path $PackagePath
        }
        finally { $script:Dlss5OpenFolder = $savedOpen }

        return [pscustomobject]@{ Text = (Get-Dlss5ConsoleText); Opened = $script:MergeOpened; Exists = (Test-Path -LiteralPath (Get-Dlss5AncestorDirectory)); Directory = (Get-Dlss5AncestorDirectory) }
    }
    Assert-Dlss5True ($result.Text.Contains('Mission ancestors') -and $result.Text.Contains('(1 kept, 1 unreadable)')) "The Stores view did not list the ancestors: $($result.Text)"
    Assert-Dlss5Equal $result.Opened $result.Directory 'Open did not open the ancestors folder.'
    Assert-Dlss5True ($result.Text.Contains('Cleared the mission ancestors.') -and -not $result.Exists -and $result.Text.Contains('(none kept)')) "Clear did not remove the ancestors: $($result.Text)"
}

Invoke-Dlss5Case 'merge states the mode it runs, two-way once the ancestor was cleared after the box described a three-way merge' {
    $result = Invoke-Dlss5PackageInteraction -Name 'merge-run-mode' -Bytes (New-Dlss5MergeCopyBytes) -Action {
        param($PackagePath)
        Initialize-Dlss5MergeMachine
        $script:Dlss5Console = New-Dlss5SubstitutedConsole @()
        Write-Dlss5ChangesBox -Identity $script:Dlss5ExecutingIdentity -Path $PackagePath
        $box = Get-Dlss5ConsoleText
        $three = Invoke-Dlss5MergeWithAgent -PackagePath $PackagePath -Write $script:MergeWriteBoth -Keys @('n', 'Enter')
        # Another window's Stores view clears the ancestors between the box and the user's choice.
        $kept = Clear-Dlss5MissionAncestors
        $two = Invoke-Dlss5MergeWithAgent -PackagePath $PackagePath -Write $script:MergeWriteBoth -Keys @('n', 'Enter')

        return [pscustomobject]@{ Box = $box; Three = $three; Kept = $kept; Two = $two }
    }
    Assert-Dlss5True $result.Box.Contains('seeing what each side changed from the mission your edit replaced') "The box did not describe a three-way merge: $($result.Box)"
    foreach ($run in @($result.Three, $result.Two)) {
        $mode = $run.Text.IndexOf('This merge compares ', [StringComparison]::Ordinal)
        $start = $run.Text.IndexOf('Starting claude to merge the missions in ', [StringComparison]::Ordinal)
        Assert-Dlss5True ($mode -ge 0 -and $start -gt $mode) "The mode line is not followed by the start line: $($run.Text)"
    }
    Assert-Dlss5True ($result.Three.Text.Contains('This merge compares your edit and the release''s mission with the mission your edit replaced (a three-way merge).') -and ($result.Three.Seen.Folders -join ',') -ceq 'ancestor,edited,merged,release') "A merge with the ancestor did not state a three-way merge: $($result.Three.Text)"
    Assert-Dlss5Equal $result.Kept.Length 0 'Clear kept an ancestor file.'
    Assert-Dlss5True ($result.Two.Text.Contains('This merge compares only your edit and the release''s mission (a two-way merge): the mission your edit replaced is not available (it is not kept on this machine).') -and -not $result.Two.Text.Contains('(a three-way merge)') -and ($result.Two.Seen.Folders -join ',') -ceq 'edited,merged,release') "A merge after the ancestor was cleared did not state a two-way merge: $($result.Two.Text)"
}

Invoke-Dlss5Case 'merge names a failed prompt write apart from a host that could not start, each with its cause' {
    $bytes = New-Dlss5MergeCopyBytes
    $result = Invoke-Dlss5PackageInteraction -Name 'merge-prompt-write' -Bytes $bytes -Action {
        param($PackagePath)
        Initialize-Dlss5MergeMachine
        # The prompt file's create-new write fails, as a full disk or a locked folder would make it; every other write goes through.
        # The override lives only in this inner scope, so the next merge writes its prompt as usual.
        $realWrite = ${function:Write-Dlss5GuardedNewFile}
        $write = & {
            function Write-Dlss5GuardedNewFile {
                param([Parameter(Mandatory=$true)][string]$Path, [Parameter(Mandatory=$true)][AllowEmptyCollection()][byte[]]$Bytes, [switch]$GamePath)
                if ([IO.Path]::GetFileName($Path).StartsWith('dlss5-agent-prompt-', [StringComparison]::Ordinal)) { throw [IO.IOException]::new('Injected prompt write failure.') }

                return & $realWrite -Path $Path -Bytes $Bytes -GamePath:$GamePath
            }

            return Invoke-Dlss5MergeWithAgent -PackagePath $PackagePath -Write $script:MergeWriteBoth
        }
        $afterWrite = Get-Dlss5MergeFolders
        $notStarted = Invoke-Dlss5MergeWithAgent -PackagePath $PackagePath -Agent 'not-started'

        return [pscustomobject]@{ Write = $write; AfterWrite = $afterWrite; NotStarted = $notStarted; Folders = (Get-Dlss5MergeFolders); Bytes = [IO.File]::ReadAllBytes($PackagePath) }
    }
    $message = $result.Write.Message
    Assert-Dlss5True ($message.StartsWith('The merge stopped: the merge prompt could not be written to ', [StringComparison]::Ordinal) -and $message.EndsWith(': Injected prompt write failure. Nothing was written.', [StringComparison]::Ordinal) -and -not $message.Contains('could not be started')) "A failed prompt write was not named: $message"
    Assert-Dlss5True ($null -eq $result.Write.Seen -and $result.AfterWrite.Count -eq 0) 'A merge whose prompt could not be written started the host or left its folder.'
    $win32 = [ComponentModel.Win32Exception]::new(2).Message
    Assert-Dlss5Equal $result.NotStarted.Message ('The merge stopped: the AI host could not be started: ' + $win32 + ' Nothing was written.') 'A host that could not start was not reported with its cause.'
    Assert-Dlss5True ((Test-Dlss5ByteEquality -Left $result.Bytes -Right $bytes) -and $result.Folders.Count -eq 0) 'A merge stopped before the host ran changed the package or left its folder.'
}

Invoke-Dlss5Case 'merge ancestors folder that cannot be listed is shown as unavailable without Open or Clear' {
    $result = Invoke-Dlss5PackageInteraction -Name 'merge-store-unlistable' -Bytes (New-Dlss5MergeCopyBytes -NoOffer) -Action {
        param($PackagePath)
        Initialize-Dlss5MergeMachine -NoSlot
        $directory = Get-Dlss5AncestorDirectory
        # Denying this user the listing of the folder keeps it visible to the existence check while its enumeration fails.
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent().User
        $rule = [Security.AccessControl.FileSystemAccessRule]::new($identity, [Security.AccessControl.FileSystemRights]::ListDirectory, [Security.AccessControl.AccessControlType]::Deny)
        $info = [IO.DirectoryInfo]::new($directory)
        $acl = [IO.FileSystemAclExtensions]::GetAccessControl($info)
        $acl.AddAccessRule($rule)
        [IO.FileSystemAclExtensions]::SetAccessControl($info, $acl)
        try {
            $view = Get-Dlss5AncestorView
            $script:Dlss5Console = New-Dlss5SubstitutedConsole @('b', 'Enter')
            Invoke-Dlss5StoreMenu -Path $PackagePath
            $text = Get-Dlss5ConsoleText
        }
        finally {
            $acl = [IO.FileSystemAclExtensions]::GetAccessControl($info)
            $restored = $acl.RemoveAccessRule($rule)
            [IO.FileSystemAclExtensions]::SetAccessControl($info, $acl)
        }

        return [pscustomobject]@{ View = $view; Text = $text; Restored = $restored; Listed = @([IO.Directory]::EnumerateFiles($directory)).Count; After = (Get-Dlss5AncestorView) }
    }
    Assert-Dlss5True ($result.Restored -and $result.Listed -eq 1 -and $result.After.Exists -and $result.After.Files -eq 1) "The folder could not be listed again after the deny was removed: restored $($result.Restored) listed $($result.Listed) status $($result.After.Status)"
    Assert-Dlss5True ($result.View.Status.StartsWith('unavailable: ', [StringComparison]::Ordinal) -and -not $result.View.Exists -and $result.View.Files -eq 0) "An unlistable folder was not reported as unavailable without Open or Clear: $($result.View.Status) exists $($result.View.Exists) files $($result.View.Files)"
    Assert-Dlss5True ($result.Text.Contains('(unavailable: ') -and -not $result.Text.Contains('Open the mission ancestors folder') -and -not $result.Text.Contains('Clear the mission ancestors')) "The Stores view offered Open or Clear for an unlistable folder: $($result.Text)"
}
