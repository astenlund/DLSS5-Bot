# Loaded by the release suite after importing the candidate library: the composable package cases added in v50.
if ($null -eq (Get-Command Get-Dlss5MissionTemplate -ErrorAction SilentlyContinue)) {
    $script:Failures.Add('FAIL package cases: the updater under test has no package support')
    return
}
$script:PackageNewline = [string][char]13 + [char]10
$script:PackageUtf8 = [Text.UTF8Encoding]::new($false, $true)

function Get-Dlss5PackageLines {
    param([Parameter(Mandatory=$true)][byte[]]$Bytes)

    return ,[Collections.Generic.List[string]]::new([string[]]$script:PackageUtf8.GetString($Bytes).Split($script:PackageNewline, [StringSplitOptions]::None))
}

function ConvertTo-Dlss5PackageBytes {
    param([Parameter(Mandatory=$true)][AllowEmptyString()][Collections.Generic.List[string]]$Lines)

    return ,$script:PackageUtf8.GetBytes([string]::Join($script:PackageNewline, $Lines))
}

function New-Dlss5StateLines {
    param([bool]$Armed = $false, [bool]$MissionEdited = $false, $ReplacedMissionHash = $null, $Update = $null)

    return ConvertTo-Dlss5StateBody ([pscustomobject]@{ Empty = $false; Armed = $Armed; MissionEdited = $MissionEdited; ReplacedMissionHash = $ReplacedMissionHash; Update = $Update })
}

function New-Dlss5PackageVariant {
    param([Parameter(Mandatory=$true)][byte[]]$Bytes, [Collections.IDictionary]$Files = $null, [AllowNull()][string[]]$State = $null)

    $bodies = [ordered]@{}
    if ($null -ne $Files) {
        $current = (Get-Dlss5BootstrapIdentity -Bytes $Bytes).MissionFiles
        $merged = [ordered]@{}
        foreach ($name in $current.Keys) { $merged[$name] = $current[$name] }
        foreach ($name in $Files.Keys) { if ($null -eq $Files[$name]) { $merged.Remove($name) } else { $merged[$name] = [byte[]]$Files[$name] } }
        $bodies['MISSION'] = ConvertTo-Dlss5MissionBody $merged
    }
    if ($null -ne $State) { $bodies['STATE'] = $State }

    return ,(Set-Dlss5PackageSections -Bytes $Bytes -Bodies $bodies)
}

function New-Dlss5TrustFixture {
    param([hashtable]$Whole = @{}, [hashtable]$Engine = @{})

    $notes = [Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
    $notes['schema_version'] = '1'
    if ($Whole.Count -gt 0) { $notes['bootstrap_highest_version_seen'] = [string](($Whole.Keys | Measure-Object -Maximum).Maximum) }
    foreach ($version in $Whole.Keys) { $notes["bootstrap_checksum.$version"] = $Whole[$version] }
    if ($Engine.Count -gt 0) { $notes['bootstrap_engine_highest_version_seen'] = [string](($Engine.Keys | Measure-Object -Maximum).Maximum) }
    foreach ($version in $Engine.Keys) { $notes["bootstrap_engine_checksum.$version"] = $Engine[$version] }

    return [pscustomobject]@{ Notes = $notes; Trust = Get-Dlss5TrustMap $notes }
}

function Write-Dlss5MachineTrustFixture {
    param([Parameter(Mandatory=$true)][string]$MachineDirectory, [hashtable]$Whole = @{}, [hashtable]$Engine = @{})

    New-Item -ItemType Directory -Force $MachineDirectory | Out-Null
    $fixture = New-Dlss5TrustFixture -Whole $Whole -Engine $Engine
    $text = ConvertTo-Dlss5NotesDocument -Notes $fixture.Notes -BeginMarker $MachineNotesBeginMarker -EndMarker $MachineNotesEndMarker -KnownOrder $MachineNotesOrder
    [IO.File]::WriteAllText((Join-Path $MachineDirectory 'DLSS5_MACHINE_NOTES.md'), $text, [Text.UTF8Encoding]::new($false))
}

function Get-Dlss5LaunchStatus {
    param([Parameter(Mandatory=$true)]$Fixture, [hashtable]$Environment = @{})

    $process = Invoke-Dlss5IsolatedLaunch -Fixture $Fixture -Arguments @('--internal-status') -Environment $Environment
    Assert-Dlss5Equal $process.ExitCode 0 "Status launch failed: $($process.StandardError) $($process.StandardOutput)"
    $line = @($process.StandardOutput.Split([char[]]@([char]13, [char]10), [StringSplitOptions]::RemoveEmptyEntries) | Where-Object { $_.StartsWith('{', [StringComparison]::Ordinal) })[-1]

    return $line | ConvertFrom-Json
}

function New-Dlss5SubstitutedConsole {
    param([object[]]$Keys)

    # Each entry is a key name or a single character, optionally with the milliseconds that pass before it arrives.
    $queue = [Collections.Generic.List[object]]::new()
    foreach ($entry in $Keys) {
        if ($entry -is [hashtable]) { $queue.Add([pscustomobject]@{ Key = $entry.Key; Char = [char]$entry.Char; Delay = $entry.Delay }); continue }
        $text = [string]$entry
        if ($text.Length -eq 1) { $queue.Add([pscustomobject]@{ Key = [string][char]::ToUpperInvariant($text[0]); Char = $text[0]; Delay = 1000 }) }
        else { $queue.Add([pscustomobject]@{ Key = $text; Char = [char]0; Delay = 1000 }) }
    }

    return [pscustomobject]@{ Queue = $queue; Output = [Collections.Generic.List[string]]::new() }
}

function Add-Dlss5PastedText {
    param([Parameter(Mandatory=$true)][AllowEmptyCollection()][object[]]$Keys, [Parameter(Mandatory=$true)][string]$Text, [int]$Gap = 0, [int]$ChunkSize = 0)

    $list = [Collections.Generic.List[object]]::new()
    foreach ($key in $Keys) { $list.Add($key) }
    for ($index = 0; $index -lt $Text.Length; $index++) {
        $delay = if ($index -eq 0) { 1000 } elseif ($ChunkSize -gt 0 -and $index % $ChunkSize -eq 0) { $Gap } else { 0 }
        $list.Add(@{ Key = 'Paste'; Char = $Text[$index]; Delay = $delay })
    }

    return ,$list.ToArray()
}

$script:CandidateBytes = [IO.File]::ReadAllBytes($UpdaterPath)
$script:CandidateIdentity = Get-Dlss5BootstrapIdentity -Bytes $script:CandidateBytes -Strict
# Versions are relative to the package under test: the legacy predecessor stays 49, and a later version is the next one.
$script:CandidateVersion = $script:CandidateIdentity.Version
$script:LaterVersion = $script:CandidateVersion + 1

Invoke-Dlss5Case 'package release file is a sectioned dlss5 package in published form' {
    $identity = $script:CandidateIdentity
    Assert-Dlss5True $identity.Sectioned 'The candidate is not sectioned.'
    Assert-Dlss5Equal $identity.MissionId 'dlss5' 'The candidate mission is not dlss5.'
    Assert-Dlss5True $identity.State.Empty 'The candidate does not ship with an empty state section.'
    Assert-Dlss5Equal $identity.PublishedSha256 $identity.Sha256 'The candidate is not its own published form.'
    Assert-Dlss5True $identity.Project.Rerun 'The DLSS mission is not rerunnable.'
    foreach ($name in @('MISSION.md', 'PROJECT.json', 'INSTRUCTIONS.cleanup-boundary.md', 'INSTRUCTIONS.settings-optimization.md', 'INSTRUCTIONS.local-runtime-build.md', 'INSTRUCTIONS.bootstrap-changes.md')) {
        Assert-Dlss5True $identity.MissionFiles.Contains($name) "The DLSS mission lacks $name."
    }
}

function Set-Dlss5PackageLinesVersion {
    param([Parameter(Mandatory=$true)][AllowEmptyString()][Collections.Generic.List[string]]$Lines, [Parameter(Mandatory=$true)][int]$Version)

    for ($index = 0; $index -lt $Lines.Count; $index++) {
        if ($Lines[$index] -ceq ('rem DLSS5_BOOTSTRAP_VERSION=' + $script:CandidateVersion)) { $Lines[$index] = 'rem DLSS5_BOOTSTRAP_VERSION=' + $Version }
        if ($Lines[$index] -ceq ('$script:Dlss5PayloadBootstrapVersion = ' + $script:CandidateVersion)) { $Lines[$index] = '$script:Dlss5PayloadBootstrapVersion = ' + $Version }
    }
}

# The candidate without its sections, declared as version 49: a legacy file as v49 wrote them.
function New-Dlss5LegacyBytes {
    $lines = Get-Dlss5PackageLines $script:CandidateBytes
    $begin = $lines.IndexOf('### === POWERSHELL_PAYLOAD_' + 'BEGIN ===')
    $close = -1
    for ($index = 1; $index -lt $begin; $index++) { if ($lines[$index] -ceq ')') { $close = $index; break } }
    $lines.RemoveRange($close + 1, $begin - $close - 1)
    Set-Dlss5PackageLinesVersion $lines 49

    return ConvertTo-Dlss5PackageBytes $lines
}

# The candidate declared as the next version, with an extra unknown section as a later version might carry.
function New-Dlss5LaterVersionBytes {
    $lines = Get-Dlss5PackageLines $script:CandidateBytes
    Set-Dlss5PackageLinesVersion $lines $script:LaterVersion
    $payloadBegin = $lines.IndexOf('### === POWERSHELL_PAYLOAD_' + 'BEGIN ===')
    $lines.InsertRange($payloadBegin, [string[]]@(('### === DLSS5_SECTION_' + 'CARGO_BEGIN ==='), ('### === DLSS5_SECTION_' + 'CARGO_END ===')))

    return ConvertTo-Dlss5PackageBytes $lines
}

# The candidate's engine carrying a small plain mission that is not rerunnable, without the DLSS instruction files.
function New-Dlss5PlainPackageBytes {
    $files = [ordered]@{
        'MISSION.md' = $script:PackageUtf8.GetBytes(('@@template', 'Hello from {{package_dir}}.', '{{part:task_instructions}}', '{{part:startup_instructions}}{{part:request}}', '@@mode default', '@@part task_instructions', 'Greet.', '@@part startup_instructions', 'Start.', '@@mode task', '@@part task_instructions', 'Do the task.', '@@part startup_instructions', 'Start.', '@@part request', '', 'USER REQUEST', '{{task_text}}', '') -join $script:PackageNewline)
        'PROJECT.json' = $script:PackageUtf8.GetBytes('{"mission_id":"hello-world","rerun":false}' + $script:PackageNewline)
    }
    foreach ($name in @($script:CandidateIdentity.MissionFiles.Keys | Where-Object { $_ -like 'INSTRUCTIONS.*' })) { $files[$name] = $null }

    return ,(New-Dlss5PackageVariant -Bytes $script:CandidateBytes -Files $files)
}

# A trusted stage under the machine directory: the staged file, its metadata, and its whole-file entry in the machine notes.
function Write-Dlss5StageFixture {
    param([Parameter(Mandatory=$true)][string]$MachineDirectory, [Parameter(Mandatory=$true)][byte[]]$Bytes, [switch]$Untrusted)

    $identity = Get-Dlss5BootstrapIdentity -Bytes $Bytes
    $updates = Join-Path $MachineDirectory 'updates'
    New-Item -ItemType Directory -Force $updates | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $updates 'DLSS5-ADDER.staged.cmd'), $Bytes)
    $metadata = [ordered]@{ schema_version = 1; state = 'staged'; version = $identity.Version; sha256 = $identity.Sha256; source_owner = $script:Dlss5GistOwner; gist_id = $script:Dlss5GistId; gist_revision = ('a' * 40); file_name = 'DLSS5-ADDER.cmd'; fetched_at = (Get-Dlss5UtcStamp) }
    [IO.File]::WriteAllText((Join-Path $updates 'stage.json'), ($metadata | ConvertTo-Json -Compress) + "`r`n", [Text.UTF8Encoding]::new($false))
    if ($Untrusted) { return $identity }
    $machinePath = Join-Path $MachineDirectory 'DLSS5_MACHINE_NOTES.md'
    $notes = if (Test-Path -LiteralPath $machinePath) { Read-Dlss5NotesFile -Path $machinePath -BeginMarker $MachineNotesBeginMarker -EndMarker $MachineNotesEndMarker } else { [Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal) }
    if (-not $notes.Contains('schema_version')) { $notes['schema_version'] = '1' }
    $notes['bootstrap_checksum.' + $identity.Version] = $identity.Sha256
    $highest = if ($notes.Contains('bootstrap_highest_version_seen')) { [int]$notes['bootstrap_highest_version_seen'] } else { 0 }
    $notes['bootstrap_highest_version_seen'] = [string][Math]::Max($highest, [int]$identity.Version)
    [IO.File]::WriteAllText($machinePath, (ConvertTo-Dlss5NotesDocument -Notes $notes -BeginMarker $MachineNotesBeginMarker -EndMarker $MachineNotesEndMarker -KnownOrder $MachineNotesOrder), [Text.UTF8Encoding]::new($false))

    return $identity
}

Invoke-Dlss5Case 'package legacy file parses as a legacy identity' {
    $legacy = Get-Dlss5BootstrapIdentity -Bytes (New-Dlss5LegacyBytes)
    Assert-Dlss5True (-not $legacy.Sectioned) 'A section-less version 49 file parsed as sectioned.'
    Assert-Dlss5Equal $legacy.PublishedSha256 $legacy.Sha256 'A legacy identity does not compare by its whole-file hash.'
    Assert-Dlss5Equal (Get-Dlss5ComparableHash $legacy) ('file:' + $legacy.Sha256) 'A legacy identity does not compare by its whole-file hash.'
    Assert-Dlss5True (Test-Dlss5CleanPublishedPackage $legacy) 'A legacy file is not a valid older update source.'
}

Invoke-Dlss5Case 'package malformed sections are refused in both readings' {
    $lines = Get-Dlss5PackageLines $script:CandidateBytes
    $missionBegin = $lines.IndexOf('### === DLSS5_SECTION_' + 'MISSION_BEGIN ===')
    $stateBegin = $lines.IndexOf('### === DLSS5_SECTION_' + 'STATE_BEGIN ===')
    $payloadBegin = $lines.IndexOf('### === POWERSHELL_PAYLOAD_' + 'BEGIN ===')
    $cases = [ordered]@{
        'a section marker after the payload begin marker' = { param($l) $l.Insert($payloadBegin + 1, '### === DLSS5_SECTION_' + 'EXTRA_BEGIN ===') }
        'a section marker before the batch block closes' = { param($l) $l.Insert(2, '### === DLSS5_SECTION_' + 'EXTRA_BEGIN ===') }
        'a repeated STATE section' = { param($l) $l.InsertRange($payloadBegin, [string[]]@(('### === DLSS5_SECTION_' + 'STATE_BEGIN ==='), ('### === DLSS5_SECTION_' + 'STATE_END ==='))) }
        'a line outside any section in the region' = { param($l) $l.Insert($stateBegin, 'stray') }
        # The line rules are the only guard for an unknown section's body, which the framing reading otherwise accepts.
        'a body line starting with a colon' = { param($l) $l.InsertRange($payloadBegin, [string[]]@(('### === DLSS5_SECTION_' + 'CARGO_BEGIN ==='), ' ;:label', ('### === DLSS5_SECTION_' + 'CARGO_END ==='))) }
        'a body line holding the payload marker text' = { param($l) $l.InsertRange($payloadBegin, [string[]]@(('### === DLSS5_SECTION_' + 'CARGO_BEGIN ==='), 'x ### === POWERSHELL_PAYLOAD_ y', ('### === DLSS5_SECTION_' + 'CARGO_END ==='))) }
        'a body line starting with the version declaration prefix' = { param($l) $l.InsertRange($payloadBegin, [string[]]@(('### === DLSS5_SECTION_' + 'CARGO_BEGIN ==='), 'rem DLSS5_BOOTSTRAP_VERSION and more', ('### === DLSS5_SECTION_' + 'CARGO_END ==='))) }
        'a body line starting with the payload version prefix' = { param($l) $l.InsertRange($payloadBegin, [string[]]@(('### === DLSS5_SECTION_' + 'CARGO_BEGIN ==='), '$script:Dlss5PayloadBootstrapVersion and more', ('### === DLSS5_SECTION_' + 'CARGO_END ==='))) }
        'a mission base64 line shorter than 76 characters before the last' = { param($l) $l[$missionBegin + 2] = $l[$missionBegin + 2].Substring(0, 75) }
        'state with an unknown key' = { param($l) $l.InsertRange($stateBegin + 1, [string[]]@('state_schema: 1', 'armed: false', 'mission_edited: false', 'colour: blue')) }
        'state with keys out of order' = { param($l) $l.InsertRange($stateBegin + 1, [string[]]@('state_schema: 1', 'mission_edited: false', 'armed: false')) }
        'state with a repeated key' = { param($l) $l.InsertRange($stateBegin + 1, [string[]]@('state_schema: 1', 'armed: false', 'armed: false', 'mission_edited: false')) }
        'state with an empty value' = { param($l) $l.InsertRange($stateBegin + 1, [string[]]@('state_schema: 1', 'armed: ', 'mission_edited: false')) }
        'state not starting with its schema' = { param($l) $l.InsertRange($stateBegin + 1, [string[]]@('armed: false', 'state_schema: 1', 'mission_edited: false')) }
    }
    foreach ($name in $cases.Keys) {
        $copy = [Collections.Generic.List[string]]::new([string[]]$lines)
        & $cases[$name] $copy
        $bytes = ConvertTo-Dlss5PackageBytes $copy
        Assert-Dlss5Throws { $null = Get-Dlss5BootstrapIdentity -Bytes $bytes } ([FormatException]) "The framing reading accepted $name."
        Assert-Dlss5Throws { $null = Get-Dlss5BootstrapIdentity -Bytes $bytes -Strict } ([FormatException]) "The strict reading accepted $name."
    }
    # Both version prefixes are also refused by the file readings' own counts, so each line rule is checked directly as well.
    foreach ($line in @(' ;:label', 'x ### === POWERSHELL_PAYLOAD_ y', 'rem DLSS5_BOOTSTRAP_VERSION and more', '$script:Dlss5PayloadBootstrapVersion and more', ('### === DLSS5_SECTION_' + 'X'))) {
        Assert-Dlss5True (-not (Test-Dlss5SectionLine $line)) "The section line rule accepted [$line]."
    }
    Assert-Dlss5True (Test-Dlss5SectionLine 'plain text: with a colon later') 'The section line rule refused an ordinary line.'
}

Invoke-Dlss5Case 'package mission file grammar refuses unsafe names and noncanonical layout' {
    foreach ($name in @('.hidden', 'CON.md', 'nul', 'COM0.md', 'lpt0', 'trailing.', 'Mission.md ', 'a/b.md')) { Assert-Dlss5True (-not (Test-Dlss5MissionFileName $name)) "An unsafe mission file name was accepted: [$name]" }
    foreach ($name in @('MISSION.md', 'INSTRUCTIONS.a-b.md', 'x_1.json')) { Assert-Dlss5True (Test-Dlss5MissionFileName $name) "A safe mission file name was refused: $name" }
    $caseVariants = [Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
    $caseVariants.Add('MISSION.md', [byte[]](1))
    $caseVariants.Add('mission.md', [byte[]](2))
    Assert-Dlss5Throws { ConvertTo-Dlss5MissionBody $caseVariants } ([FormatException]) 'Case-variant mission names were accepted.'
    $body = ConvertTo-Dlss5MissionBody ([ordered]@{ 'b.md' = [byte[]](1); 'a.md' = [byte[]]::new(0) })
    Assert-Dlss5Equal ($body -join '|') '@file a.md|@file b.md|AQ==' 'Mission files were not ordered ordinally, or an empty file got base64 lines.'
    Assert-Dlss5Throws { ConvertFrom-Dlss5MissionBody @('@file b.md', 'AQ==', '@file a.md') } ([FormatException]) 'Unordered mission files were accepted.'
    Assert-Dlss5Throws { ConvertFrom-Dlss5MissionBody @('@file a.md', 'AR==') } ([FormatException]) 'Noncanonical base64 was accepted.'
    $long = [byte[]]::new(57)
    $encoded = ConvertTo-Dlss5MissionBody ([ordered]@{ 'a.md' = $long })
    Assert-Dlss5Equal $encoded[1].Length 76 'A last base64 line of exactly 76 characters was not produced.'
    Assert-Dlss5Equal ([byte[]](ConvertFrom-Dlss5MissionBody $encoded)['a.md']).Length 57 'A 76-character last line did not round trip.'
}

Invoke-Dlss5Case 'package framing reading accepts later sections keys and files that the strict reading refuses' {
    $lines = Get-Dlss5PackageLines $script:CandidateBytes
    $payloadBegin = $lines.IndexOf('### === POWERSHELL_PAYLOAD_' + 'BEGIN ===')
    $lines.InsertRange($payloadBegin, [string[]]@(('### === DLSS5_SECTION_' + 'CARGO_BEGIN ==='), 'cargo-line', ('### === DLSS5_SECTION_' + 'CARGO_END ===')))
    $later = Get-Dlss5BootstrapIdentity -Bytes (ConvertTo-Dlss5PackageBytes $lines)
    $withCargoEmpty = [Collections.Generic.List[string]]::new([string[]]$lines)
    $withCargoEmpty.RemoveAt($payloadBegin + 1)
    Assert-Dlss5Equal $later.EngineSha256 (Get-Dlss5BootstrapIdentity -Bytes (ConvertTo-Dlss5PackageBytes $withCargoEmpty)).EngineSha256 'An unknown section body changed the engine hash.'
    Assert-Dlss5True ($later.PublishedSha256 -cne $later.Sha256) 'An unknown section body stayed in the published form.'
    $project = [Text.Encoding]::UTF8.GetBytes('{"mission_id":"dlss5","rerun":true,"approval_mode":"manual"}' + $script:PackageNewline)
    $variant = New-Dlss5PackageVariant -Bytes $script:CandidateBytes -Files ([ordered]@{ 'PROJECT.json' = $project; 'TESTS.json' = [byte[]](123, 125) })
    $framing = Get-Dlss5BootstrapIdentity -Bytes $variant
    Assert-Dlss5Equal $framing.MissionId 'dlss5' 'The framing reading lost the mission id of a later project config.'
    Assert-Dlss5Throws { $null = Get-Dlss5BootstrapIdentity -Bytes $variant -Strict } ([FormatException]) 'The strict reading accepted an unknown project key and mission file.'
}

Invoke-Dlss5Case 'package engine and mission hashes are stable across state and change with the mission' {
    $base = $script:CandidateIdentity
    $armed = Get-Dlss5BootstrapIdentity -Bytes (New-Dlss5PackageVariant -Bytes $script:CandidateBytes -State (New-Dlss5StateLines -Armed $true)) -Strict
    Assert-Dlss5Equal $armed.EngineSha256 $base.EngineSha256 'Arming changed the engine hash.'
    Assert-Dlss5Equal $armed.MissionSha256 $base.MissionSha256 'Arming changed the mission hash.'
    Assert-Dlss5Equal $armed.PublishedSha256 $base.Sha256 'The armed copy''s published form is not the release file.'
    $edited = Get-Dlss5BootstrapIdentity -Bytes (New-Dlss5PackageVariant -Bytes $script:CandidateBytes -Files ([ordered]@{ 'INSTRUCTIONS.cleanup-boundary.md' = [byte[]](65, 13, 10) })) -Strict
    Assert-Dlss5Equal $edited.EngineSha256 $base.EngineSha256 'A mission edit changed the engine hash.'
    Assert-Dlss5True ($edited.MissionSha256 -cne $base.MissionSha256) 'A mission edit kept the mission hash.'
    Assert-Dlss5True (-not (Test-Dlss5SameVersionConflict $base $armed)) 'Copies differing only in state conflict.'
    Assert-Dlss5True (-not (Test-Dlss5SameVersionConflict $base $edited)) 'Copies differing only in mission conflict.'
}

Invoke-Dlss5Case 'package mission hash follows its fixed serialization' {
    $files = [ordered]@{ 'b.md' = [byte[]](1, 2); 'a.md' = [byte[]](3) }
    $stream = [IO.MemoryStream]::new()
    foreach ($entry in @(@('a.md', [byte[]](3)), @('b.md', [byte[]](1, 2)))) {
        $name = [Text.Encoding]::UTF8.GetBytes($entry[0])
        $stream.Write([byte[]](0, 0, 0, $name.Length), 0, 4)
        $stream.Write($name, 0, $name.Length)
        $stream.Write([byte[]](0, 0, 0, 0, 0, 0, 0, $entry[1].Length), 0, 8)
        $stream.Write($entry[1], 0, $entry[1].Length)
    }
    Assert-Dlss5Equal (Get-Dlss5MissionHash $files) ([Convert]::ToHexStringLower([Security.Cryptography.SHA256]::HashData($stream.ToArray()))) 'The mission hash serialization changed.'
}

Invoke-Dlss5Case 'package state schema round trips and an empty body reads as never written' {
    $empty = ConvertFrom-Dlss5StateBody @()
    Assert-Dlss5True ($empty.Empty -and -not $empty.Armed -and -not $empty.MissionEdited -and $null -eq $empty.Update) 'An empty state body did not read as never written.'
    $update = [pscustomobject]@{ FromVersion = 49; FromMissionHash = $null; FromSha256 = ('a' * 64); ReplacedEdit = $true; BackupSha256 = ('c' * 64) }
    $lines = New-Dlss5StateLines -Armed $false -MissionEdited $true -ReplacedMissionHash ('b' * 64) -Update $update
    Assert-Dlss5Equal ($lines -join '|') ('state_schema: 1|armed: false|mission_edited: true|replaced_mission_hash: ' + ('b' * 64) + '|update_from_version: 49|update_from_sha256: ' + ('a' * 64) + '|update_replaced_edit: true|update_backup_sha256: ' + ('c' * 64)) 'State lines changed shape.'
    $read = ConvertFrom-Dlss5StateBody $lines
    Assert-Dlss5True ((-not $read.Empty) -and $read.MissionEdited -and $read.Update.FromVersion -eq 49 -and $null -eq $read.Update.FromMissionHash -and $read.Update.ReplacedEdit -and $read.Update.BackupSha256 -ceq ('c' * 64)) 'State did not round trip.'
    Assert-Dlss5Throws { ConvertFrom-Dlss5StateBody @($lines | Where-Object { -not $_.StartsWith('update_backup_sha256') }) } ([FormatException]) 'A replaced edit without its backup hash was accepted.'
    Assert-Dlss5Throws { ConvertFrom-Dlss5StateBody @(($lines | Select-Object -SkipLast 2) + 'update_replaced_edit: false' + $lines[-1]) } ([FormatException]) 'A backup hash without a replaced edit was accepted.'
    Assert-Dlss5Throws { ConvertFrom-Dlss5StateBody @('state_schema: 3', 'armed: false') } ([NotSupportedException]) 'A later state schema was not reported as unknown.'
    Assert-Dlss5Throws { ConvertFrom-Dlss5StateBody @('state_schema: 2', 'armed: false', 'mission_edited: false') } ([FormatException]) 'State schema 2 without test records was accepted.'
    Assert-Dlss5Equal ((New-Dlss5StateLines) -join '|') 'state_schema: 1|armed: false|mission_edited: false' 'A disarmed acknowledgement did not write an explicit body.'
}

Invoke-Dlss5Case 'package template validation refuses broken missions' {
    $files = $script:CandidateIdentity.MissionFiles
    $text = $script:PackageUtf8.GetString([byte[]]$files['MISSION.md'])
    $cases = [ordered]@{
        'an unknown placeholder' = $text.Replace('{{package_dir}}', '{{no_such_value}}')
        'a missing diagnosis mode' = $text.Substring(0, $text.IndexOf('@@mode diagnosis:git-unavailable', [StringComparison]::Ordinal))
        'task_text outside a request part' = $text.Replace('{{package_dir}}', '{{task_text}}')
        'a request part without task_text' = $text.Replace('USER REQUEST' + $script:PackageNewline + '{{task_text}}', 'USER REQUEST')
        'a missing notification slot' = $text.Replace('### DLSS5_NOTIFICATION_SLOT ###', '')
        'a notification slot in a mode part' = $text.Replace('USER REQUEST' + $script:PackageNewline + '{{task_text}}', 'USER REQUEST' + $script:PackageNewline + '{{task_text}}' + $script:PackageNewline + '### DLSS5_NOTIFICATION_SLOT ###')
        'a content line starting with @@' = $text.Replace('{{part:task_instructions}}', '@@ note' + $script:PackageNewline + '{{part:task_instructions}}')
        'stray placeholder braces' = $text.Replace('{{package_dir}}', '{{Package Dir}}')
        'a missing instruction file' = $text.Replace('{{instruction:cleanup-boundary}}', '{{instruction:absent}}')
    }
    foreach ($name in $cases.Keys) {
        $copy = [ordered]@{}
        foreach ($key in $files.Keys) { $copy[$key] = $files[$key] }
        $copy['MISSION.md'] = $script:PackageUtf8.GetBytes($cases[$name])
        Assert-Dlss5Throws { $null = Get-Dlss5MissionTemplate -Files $copy -MissionId 'dlss5' } ([FormatException]) "The template validation accepted $name."
    }
    Assert-Dlss5Throws { $null = Get-Dlss5MissionTemplate -Files $files -MissionId 'hello-world' } ([FormatException]) 'A plain mission accepted the DLSS placeholders and notification slot.'
}

Invoke-Dlss5Case 'package prompt rendering is single pass and keeps task text intact' {
    $files = [ordered]@{
        'MISSION.md' = $script:PackageUtf8.GetBytes(('@@template', 'host={{host}} dir={{package_dir}}', '{{part:task_instructions}}|{{part:startup_instructions}}{{part:request}}', '@@mode default', '@@part task_instructions', 'D', '@@part startup_instructions', 'S', '@@mode task', '@@part task_instructions', 'T', '@@part startup_instructions', 'U', '@@part request', '', 'REQ:{{task_text}}:END', '') -join $script:PackageNewline)
        'PROJECT.json' = $script:PackageUtf8.GetBytes('{"mission_id":"hello-world","rerun":false}')
    }
    $template = Get-Dlss5MissionTemplate -Files $files -MissionId 'hello-world'
    $values = [ordered]@{ host = '{{package_dir}}'; model = ''; effort = ''; package_path = 'p'; package_dir = 'd' }
    Assert-Dlss5Equal (Format-Dlss5MissionPrompt -Template $template -Mode 'default' -Values $values) ('host={{package_dir}} dir=d' + $script:PackageNewline + 'D|S') 'A substituted value was scanned again.'
    Assert-Dlss5Equal (Format-Dlss5MissionPrompt -Template $template -Mode 'task' -Values $values -Task 'do {{host}} now') ('host={{package_dir}} dir=d' + $script:PackageNewline + 'T|U' + $script:PackageNewline + 'REQ:do {{host}} now:END') 'Task text was not placed verbatim.'
    $game = Get-Dlss5MissionTemplate -Files $script:CandidateIdentity.MissionFiles -MissionId 'dlss5'
    Assert-Dlss5True $game.Modes['diagnosis:git-unavailable']['request'].Contains('{{task_text}}') 'The diagnosis mode cannot carry a task.'
}

Invoke-Dlss5Case 'package trust maps keep engine entries apart from v49 keys' {
    $fixture = New-Dlss5TrustFixture -Whole @{ 49 = ('a' * 64) } -Engine @{ $script:CandidateVersion = ('b' * 64) }
    Assert-Dlss5Equal $fixture.Trust.Maximum 49 'Engine entries changed the whole-file maximum.'
    Assert-Dlss5Equal $fixture.Trust.EngineMaximum $script:CandidateVersion 'The engine maximum was not read.'
    $notes = [Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
    $notes['bootstrap_engine_checksum.x'] = 'b' * 64
    Assert-Dlss5Throws { $null = Get-Dlss5TrustMap $notes } ([IO.InvalidDataException]) 'A malformed engine key was accepted.'
    $notes = [Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
    $notes['bootstrap_engine_checksum.' + $script:CandidateVersion] = 'b' * 64
    $notes['bootstrap_engine_highest_version_seen'] = [string]$script:LaterVersion
    Assert-Dlss5Throws { $null = Get-Dlss5TrustMap $notes } ([IO.InvalidDataException]) 'An engine maximum disagreeing with its map was accepted.'
    $legacyView = [Collections.Generic.List[string]]::new()
    foreach ($key in $fixture.Notes.Keys) { if ([string]$key -like 'bootstrap_checksum.*') { $legacyView.Add([string]$key) } }
    Assert-Dlss5Equal ($legacyView -join ',') 'bootstrap_checksum.49' 'An engine key matches the v49 checksum prefix.'
}

Invoke-Dlss5Case 'package engine admission follows its order' {
    $identity = $script:CandidateIdentity
    $version = [int]$identity.Version
    $edited = Get-Dlss5BootstrapIdentity -Bytes (New-Dlss5PackageVariant -Bytes $script:CandidateBytes -Files ([ordered]@{ 'INSTRUCTIONS.cleanup-boundary.md' = [byte[]](65) }) -State (New-Dlss5StateLines -MissionEdited $true)) -Strict
    $check = {
        param($Identity, $Trust, $Scope = 'full', $Canonical = $null, $Stage = $null)
        return (Get-Dlss5EngineAdmission -Identity $Identity -Trust $Trust.Trust -Canonical $Canonical -Stage $Stage -Scope $Scope).Action
    }
    Assert-Dlss5Equal (& $check $identity (New-Dlss5TrustFixture -Engine @{ $version = $identity.EngineSha256 })) 'trusted' 'An existing engine entry was not used.'
    Assert-Dlss5Throws { & $check $identity (New-Dlss5TrustFixture -Engine @{ $version = ('f' * 64) }) } ([IO.InvalidDataException]) 'An engine collision was not refused.'
    Assert-Dlss5Equal (& $check $identity (New-Dlss5TrustFixture -Engine @{ ($version + 1) = ('f' * 64) })) 'refuse' 'A version below the engine maximum was admitted.'
    Assert-Dlss5Equal (& $check $identity (New-Dlss5TrustFixture -Whole @{ $version = $identity.PublishedSha256 })) 'derive' 'An unedited published copy did not derive its entry.'
    Assert-Dlss5Equal (& $check $edited (New-Dlss5TrustFixture -Whole @{ $version = $identity.PublishedSha256 }) 'executing-only') 'refuse' 'An edited copy derived its entry from itself.'
    Assert-Dlss5Equal (& $check $edited (New-Dlss5TrustFixture -Whole @{ $version = $identity.PublishedSha256 }) 'derive' $identity) 'derive' 'The slot did not supply the entry.'
    Assert-Dlss5Equal (& $check $edited (New-Dlss5TrustFixture -Whole @{ $version = $identity.PublishedSha256 }) 'derive' $null $identity) 'derive' 'The stage did not supply the entry.'
    Assert-Dlss5Equal (& $check $edited (New-Dlss5TrustFixture)) 'first-use' 'A fresh machine did not trust on first use.'
    Assert-Dlss5Equal (& $check $edited (New-Dlss5TrustFixture) 'derive') 'refuse' 'The derive scope trusted on first use.'
    Assert-Dlss5Equal (& $check $edited (New-Dlss5TrustFixture -Whole @{ ($version + 1) = ('c' * 64) })) 'refuse' 'A version below the whole-file maximum was trusted on first use.'
    Assert-Dlss5Equal (& $check $edited (New-Dlss5TrustFixture -Whole @{ $version = ('c' * 64) })) 'refuse' 'A version with a mismatched whole-file entry was trusted on first use.'
    # Below the whole-file maximum with no entry of its own, every scope gives the remedy that can work: replace the package.
    foreach ($scope in @('full', 'derive', 'executing-only')) {
        $reason = (Get-Dlss5EngineAdmission -Identity $identity -Trust (New-Dlss5TrustFixture -Whole @{ ($version - 1) = ('a' * 64); ($version + 1) = ('c' * 64) }).Trust -Scope $scope).Reason
        Assert-Dlss5True $reason.Contains('older than this machine''s trust records') "An older package was given another remedy in the $scope scope: $reason"
    }
}

Invoke-Dlss5Case 'package machine notes rewrite keeps engine entries' {
    $root = Join-Path $script:ScratchRoot 'package-notes-engine'
    Invoke-Dlss5WithLocalAppData -Path $root -Action {
        Write-Dlss5MachineTrustFixture -MachineDirectory (Get-Dlss5StorePath) -Engine @{ $script:CandidateVersion = ('b' * 64) }
        $path = Get-Dlss5StorePath 'DLSS5_MACHINE_NOTES.md'
        $notes = Read-Dlss5NotesFile -Path $path -BeginMarker $MachineNotesBeginMarker -EndMarker $MachineNotesEndMarker
        $notes.Remove('bootstrap_engine_checksum.' + $script:CandidateVersion)
        $notes['bootstrap_engine_highest_version_seen'] = '0'
        $lock = Enter-Dlss5BootstrapLock
        try { Assert-Dlss5Throws { Write-Dlss5NotesFileAtomically -Path $path -Notes $notes -BeginMarker $MachineNotesBeginMarker -EndMarker $MachineNotesEndMarker -KnownOrder $MachineNotesOrder } ([IO.InvalidDataException]) 'A machine-notes rewrite dropped an engine entry.' }
        finally { Exit-Dlss5BootstrapLock $lock }
    }
}

Invoke-Dlss5Case 'package update sources must be clean published dlss5 packages' {
    $armed = Get-Dlss5BootstrapIdentity -Bytes (New-Dlss5PackageVariant -Bytes $script:CandidateBytes -State (New-Dlss5StateLines -Armed $true))
    $plain = Get-Dlss5BootstrapIdentity -Bytes (New-Dlss5PackageVariant -Bytes $script:CandidateBytes -Files ([ordered]@{ 'PROJECT.json' = $script:PackageUtf8.GetBytes('{"mission_id":"hello-world","rerun":false}') }))
    Assert-Dlss5True (Test-Dlss5CleanPublishedPackage $script:CandidateIdentity) 'The release file was not a clean update source.'
    Assert-Dlss5True (-not (Test-Dlss5CleanPublishedPackage $armed)) 'An armed copy was accepted as an update source.'
    Assert-Dlss5True (-not (Test-Dlss5CleanPublishedPackage $plain)) 'Another mission was accepted as an update source.'
    $trust = (New-Dlss5TrustFixture -Whole @{ $script:CandidateVersion = $script:CandidateIdentity.Sha256 }).Trust
    Assert-Dlss5True (Test-Dlss5Publishable $armed $trust) 'An armed unedited copy could not fill the slot through its published form.'
    $edited = Get-Dlss5BootstrapIdentity -Bytes (New-Dlss5PackageVariant -Bytes $script:CandidateBytes -State (New-Dlss5StateLines -MissionEdited $true))
    Assert-Dlss5True (-not (Test-Dlss5Publishable $edited $trust)) 'A copy marked mission_edited could fill the slot.'
}

Invoke-Dlss5Case 'package update record reports against the acknowledged state' {
    $trust = (New-Dlss5TrustFixture -Whole @{ $script:CandidateVersion = $script:CandidateIdentity.Sha256 }).Trust
    $local = Get-Dlss5BootstrapIdentity -Bytes (New-Dlss5PackageVariant -Bytes $script:CandidateBytes -State (New-Dlss5StateLines -Armed $true))
    $state = (Get-Dlss5BootstrapIdentity -Bytes (New-Dlss5UpdatedCopyBytes -Local $local -Chosen $script:CandidateIdentity -Trust $trust)).State
    Assert-Dlss5True (-not $state.Armed -and $state.Update.FromVersion -eq $script:CandidateVersion -and $state.Update.FromMissionHash -ceq $local.MissionSha256 -and -not $state.Update.ReplacedEdit) 'An unedited update record is wrong.'
    # From v59 an edited DLSS copy keeps its mission, its edit marker and its records, and is offered the release's mission unless it is the
    # one the edit replaced.
    $editedFiles = [ordered]@{ 'INSTRUCTIONS.cleanup-boundary.md' = [byte[]](65) }
    $editedMission = (Get-Dlss5BootstrapIdentity -Bytes (New-Dlss5PackageVariant -Bytes $script:CandidateBytes -Files $editedFiles)).MissionSha256
    $record = [pscustomobject]@{ Name = 'unit'; Verdict = 'pass'; Role = 'dev'; Mission = $editedMission; Time = '20261111T000000Z'; Machine = '00000000-0000-0000-0000-000000000001'; Location = ('1' * 16); Label = 'BOX|C:\Games\Here' }
    $recordState = ConvertTo-Dlss5StateBody ([pscustomobject]@{ Empty = $false; Armed = $true; MissionEdited = $true; ReplacedMissionHash = $local.MissionSha256; Update = $null; Records = [object[]]@($record) })
    $edited = Get-Dlss5BootstrapIdentity -Bytes (New-Dlss5PackageVariant -Bytes $script:CandidateBytes -Files $editedFiles -State $recordState)
    $updated = Get-Dlss5BootstrapIdentity -Bytes (New-Dlss5UpdatedCopyBytes -Local $edited -Chosen $script:CandidateIdentity -Trust $trust)
    $state = $updated.State
    Assert-Dlss5True ($updated.MissionSha256 -ceq $edited.MissionSha256 -and $state.MissionEdited -and $state.ReplacedMissionHash -ceq $local.MissionSha256 -and -not $state.Armed) 'An edited copy did not keep its mission and edit marker, disarmed.'
    $kept = Get-Dlss5StateRecords $state
    Assert-Dlss5True ($kept.Count -eq 1 -and $kept[0].Name -ceq 'unit' -and $kept[0].Mission -ceq $editedMission) 'An engine-only update did not keep the test records of the kept mission.'
    Assert-Dlss5True ($state.Update.KeptMission -and -not $state.Update.ReplacedEdit -and $null -eq $state.Update.BackupSha256 -and $state.Update.FromMissionHash -ceq $local.MissionSha256 -and $null -eq $state.Update.OfferedMissionHash) 'An edited copy whose replaced mission is the release''s was offered it, or its record is wrong.'
    $handEdited = Get-Dlss5BootstrapIdentity -Bytes (New-Dlss5PackageVariant -Bytes $script:CandidateBytes -Files ([ordered]@{ 'INSTRUCTIONS.cleanup-boundary.md' = [byte[]](66) }))
    $updated = Get-Dlss5BootstrapIdentity -Bytes (New-Dlss5UpdatedCopyBytes -Local $handEdited -Chosen $script:CandidateIdentity -Trust $trust)
    $state = $updated.State
    Assert-Dlss5True ($updated.MissionSha256 -ceq $handEdited.MissionSha256 -and $state.MissionEdited -and $null -eq $state.ReplacedMissionHash -and $state.Update.KeptMission -and $null -eq $state.Update.FromMissionHash -and $state.Update.OfferedMissionHash -ceq $script:CandidateIdentity.MissionSha256) 'A hand-edited copy did not keep its mission and get the release''s offered.'
    $pending = Get-Dlss5BootstrapIdentity -Bytes (New-Dlss5PackageVariant -Bytes $script:CandidateBytes -State (New-Dlss5StateLines -Update ([pscustomobject]@{ FromVersion = 48; FromMissionHash = $null; FromSha256 = ('d' * 64); ReplacedEdit = $true; BackupSha256 = ('f' * 64) })))
    $state = (Get-Dlss5BootstrapIdentity -Bytes (New-Dlss5UpdatedCopyBytes -Local $pending -Chosen $script:CandidateIdentity -Trust $trust)).State
    Assert-Dlss5True ($state.Update.FromVersion -eq 48 -and $state.Update.FromSha256 -ceq ('d' * 64) -and $state.Update.ReplacedEdit -and $state.Update.BackupSha256 -ceq ('f' * 64)) 'A second update did not merge into the pending record or dropped the backup hash of its kept .bkp.'
    $pendingUnedited = New-Dlss5PackageVariant -Bytes $script:CandidateBytes -State (New-Dlss5StateLines -Update ([pscustomobject]@{ FromVersion = 48; FromMissionHash = $null; FromSha256 = ('d' * 64); ReplacedEdit = $false }))
    $editedSince = Get-Dlss5BootstrapIdentity -Bytes (New-Dlss5PackageVariant -Bytes ([byte[]]$pendingUnedited) -Files ([ordered]@{ 'INSTRUCTIONS.cleanup-boundary.md' = [byte[]](68) }))
    $state = (Get-Dlss5BootstrapIdentity -Bytes (New-Dlss5UpdatedCopyBytes -Local $editedSince -Chosen $script:CandidateIdentity -Trust $trust)).State
    Assert-Dlss5True ($state.Update.FromSha256 -ceq ('d' * 64) -and $state.Update.KeptMission -and -not $state.Update.ReplacedEdit -and $state.Update.OfferedMissionHash -ceq $script:CandidateIdentity.MissionSha256) 'An edit made since an unedited pending update did not keep its mission against the pending record.'
    # A second engine-only update keeps the pending record's from-fields and takes the newest offer.
    $pendingKept = New-Dlss5StateLines -MissionEdited $true -Update ([pscustomobject]@{ FromVersion = 47; FromMissionHash = $null; FromSha256 = ('e' * 64); ReplacedEdit = $false; BackupSha256 = $null; KeptMission = $true; OfferedMissionHash = ('a' * 64) })
    $keptAgain = Get-Dlss5BootstrapIdentity -Bytes (New-Dlss5PackageVariant -Bytes $script:CandidateBytes -Files ([ordered]@{ 'INSTRUCTIONS.cleanup-boundary.md' = [byte[]](69) }) -State $pendingKept)
    $state = (Get-Dlss5BootstrapIdentity -Bytes (New-Dlss5UpdatedCopyBytes -Local $keptAgain -Chosen $script:CandidateIdentity -Trust $trust)).State
    Assert-Dlss5True ($state.Update.FromVersion -eq 47 -and $state.Update.FromSha256 -ceq ('e' * 64) -and $state.Update.KeptMission -and $state.Update.OfferedMissionHash -ceq $script:CandidateIdentity.MissionSha256) 'A second engine-only update did not keep the pending from-fields with the newest offer.'
}

Invoke-Dlss5Case 'package engine-only update state keys round trip and refuse other combinations' {
    $update = [pscustomobject]@{ FromVersion = 58; FromMissionHash = ('b' * 64); FromSha256 = ('a' * 64); ReplacedEdit = $false; BackupSha256 = $null; KeptMission = $true; OfferedMissionHash = ('c' * 64) }
    $lines = New-Dlss5StateLines -MissionEdited $true -ReplacedMissionHash ('b' * 64) -Update $update
    Assert-Dlss5Equal ($lines -join '|') ('state_schema: 1|armed: false|mission_edited: true|replaced_mission_hash: ' + ('b' * 64) + '|update_from_version: 58|update_from_mission_hash: ' + ('b' * 64) + '|update_from_sha256: ' + ('a' * 64) + '|update_replaced_edit: false|update_kept_mission: true|update_offered_mission_hash: ' + ('c' * 64)) 'Engine-only state lines changed shape.'
    $read = ConvertFrom-Dlss5StateBody $lines
    Assert-Dlss5True ($read.Update.KeptMission -and $read.Update.OfferedMissionHash -ceq ('c' * 64) -and -not $read.Update.ReplacedEdit) 'An engine-only record did not round trip.'
    $noOffer = @($lines | Where-Object { -not $_.StartsWith('update_offered_mission_hash') })
    Assert-Dlss5True ((ConvertFrom-Dlss5StateBody $noOffer).Update.KeptMission -and $null -eq (ConvertFrom-Dlss5StateBody $noOffer).Update.OfferedMissionHash) 'An engine-only record without an offer did not read.'
    Assert-Dlss5Throws { ConvertFrom-Dlss5StateBody @($lines | Where-Object { -not $_.StartsWith('update_kept_mission') }) } ([FormatException]) 'An offer without a kept mission was accepted.'
    $replaced = @($noOffer | ForEach-Object { if ($_ -ceq 'update_replaced_edit: false') { 'update_replaced_edit: true'; 'update_backup_sha256: ' + ('d' * 64) } else { $_ } })
    Assert-Dlss5Throws { ConvertFrom-Dlss5StateBody $replaced } ([FormatException]) 'A kept mission beside a replaced edit was accepted.'
    Assert-Dlss5Throws { ConvertFrom-Dlss5StateBody @($noOffer | ForEach-Object { if ($_ -ceq 'update_kept_mission: true') { 'update_kept_mission: false' } else { $_ } }) } ([FormatException]) 'A false kept-mission key was accepted.'
}

Invoke-Dlss5Case 'package engine-only plan checks the kept mission with the release engine and ignores a tracked .bkp' {
    $trust = (New-Dlss5TrustFixture -Whole @{ $script:CandidateVersion = $script:CandidateIdentity.Sha256 }).Trust
    $edited = Get-Dlss5BootstrapIdentity -Bytes (New-Dlss5PackageVariant -Bytes $script:CandidateBytes -Files ([ordered]@{ 'INSTRUCTIONS.cleanup-boundary.md' = [byte[]](65) }) -State (New-Dlss5StateLines -MissionEdited $true))
    # An undeclared test file passes the framing reading but not the strict one, so the release's engine refuses the kept mission.
    $refused = Get-Dlss5BootstrapIdentity -Bytes (New-Dlss5PackageVariant -Bytes $script:CandidateBytes -Files ([ordered]@{ 'TEST.stray.ps1' = [byte[]](65) }) -State (New-Dlss5StateLines -MissionEdited $true))
    $trackedBackup = [pscustomobject]@{ Tracked = $true; Backup = $false; BackupTracked = $true; State = 'x' }
    $untracked = [pscustomobject]@{ Tracked = $false; Backup = $true; BackupTracked = $false; State = 'x' }
    $savedEngine = Get-Variable -Name Dlss5ExecutingEngineSha256 -Scope Script -ValueOnly -ErrorAction SilentlyContinue
    try {
        # The candidate is the release here, so its own engine reads the kept mission in-process, as an adoption does.
        $script:Dlss5ExecutingEngineSha256 = $script:CandidateIdentity.EngineSha256
        $plan = Get-Dlss5CopyUpdatePlan -Local $edited -Gate $trackedBackup -Trust $trust -Chosen $script:CandidateIdentity
        Assert-Dlss5True ($plan.EngineOnly -and -not $plan.Skip -and -not $plan.Backup -and $null -ne $plan.Bytes) 'A tracked .bkp blocked an engine-only update, or it planned a .bkp the gate did not ask for.'
        Assert-Dlss5True (Get-Dlss5CopyUpdatePlan -Local $edited -Gate $untracked -Trust $trust -Chosen $script:CandidateIdentity).Backup 'An untracked copy got no .bkp of its previous file.'
        $plan = Get-Dlss5CopyUpdatePlan -Local $refused -Gate $untracked -Trust $trust -Chosen $script:CandidateIdentity
        Assert-Dlss5True ($plan.Skip -and $plan.Reason.Contains('engine did not accept this copy''s edited mission') -and $plan.Reason.Contains('next launch tries again')) "A kept mission the release refuses was not skipped with its reason: $($plan.Reason)"
        $published = Get-Dlss5BootstrapIdentity -Bytes (New-Dlss5PackageVariant -Bytes $script:CandidateBytes -State (New-Dlss5StateLines -Armed $true))
        Assert-Dlss5True (-not (Get-Dlss5CopyUpdatePlan -Local $published -Gate $untracked -Trust $trust -Chosen $script:CandidateIdentity).EngineOnly) 'An unedited copy was planned engine-only.'
        # A kept mission that fits the copy but makes the updated copy larger than a package may be skips the update instead of failing it.
        $limit = 4MB
        # Base64 and its line breaks grow a file by about 1.37, so the size starts below the limit and approaches it from below.
        $size = [int](($limit - $script:CandidateBytes.Length) * 0.7)
        for ($attempt = 0; $attempt -lt 12; $attempt++) {
            $bigBytes = New-Dlss5PackageVariant -Bytes $script:CandidateBytes -Files ([ordered]@{ 'INSTRUCTIONS.extra.md' = [byte[]]::new($size) }) -State (New-Dlss5StateLines -MissionEdited $true)
            $gap = ($limit - 100) - $bigBytes.Length
            if ($gap -ge 0 -and $gap -lt 60) { break }
            $size += [int]($gap * 0.72)
        }
        Assert-Dlss5True ($bigBytes.Length -le $limit - 100 -and $bigBytes.Length -gt $limit - 160) "The near-limit fixture is $($bigBytes.Length) bytes."
        $big = Get-Dlss5BootstrapIdentity -Bytes $bigBytes
        $plan = Get-Dlss5CopyUpdatePlan -Local $big -Gate $untracked -Trust $trust -Chosen $script:CandidateIdentity
        Assert-Dlss5True ($plan.Skip -and $plan.Reason.Contains('cannot be carried into version')) "An updated copy over the size limit did not skip the update: $($plan.Reason)"
    }
    finally { $script:Dlss5ExecutingEngineSha256 = $savedEngine }
}

Invoke-Dlss5Case 'package release check runs a newer engine on a scratch copy, and its command refuses what it should' {
    $root = Join-Path $script:ScratchRoot 'package-release-check'
    $later = Get-Dlss5BootstrapIdentity -Bytes (New-Dlss5LaterVersionBytes)
    $trust = (New-Dlss5TrustFixture -Whole @{ $script:CandidateVersion = $script:CandidateIdentity.Sha256 }).Trust
    $edited = Get-Dlss5BootstrapIdentity -Bytes (New-Dlss5PackageVariant -Bytes $script:CandidateBytes -Files ([ordered]@{ 'INSTRUCTIONS.cleanup-boundary.md' = [byte[]](65) }) -State (New-Dlss5StateLines -MissionEdited $true))
    $refused = Get-Dlss5BootstrapIdentity -Bytes (New-Dlss5PackageVariant -Bytes $script:CandidateBytes -Files ([ordered]@{ 'TEST.stray.ps1' = [byte[]](65) }) -State (New-Dlss5StateLines -MissionEdited $true))
    $savedEngine = Get-Variable -Name Dlss5ExecutingEngineSha256 -Scope Script -ValueOnly -ErrorAction SilentlyContinue
    try {
        $script:Dlss5ExecutingEngineSha256 = $script:CandidateIdentity.EngineSha256
        Invoke-Dlss5WithLocalAppData -Path (Join-Path $root 'localappdata') -Action {
            New-Item -ItemType Directory -Force (Get-Dlss5StorePath) | Out-Null
            $accepted = Invoke-Dlss5ReleaseCheck -Bytes (New-Dlss5UpdatedCopyBytes -Local $edited -Chosen $later -Trust $trust) -Chosen $later
            Assert-Dlss5Equal $accepted '' 'The newer engine did not accept a copy carrying its engine and an edited mission.'
            $reason = Invoke-Dlss5ReleaseCheck -Bytes (New-Dlss5UpdatedCopyBytes -Local $refused -Chosen $later -Trust $trust) -Chosen $later
            Assert-Dlss5True ($reason.Contains('engine did not accept this copy''s edited mission') -and $reason.Contains('tests are inconsistent')) "The newer engine's refusal did not come back with its reason: $reason"
            # A check that cannot finish is not a pass: with no time allowed, the process is stopped and the check reports it could not check.
            $savedTimeout = $script:Dlss5PackageCheckTimeout
            try {
                $script:Dlss5PackageCheckTimeout = [TimeSpan]::Zero
                $reason = Invoke-Dlss5ReleaseCheck -Bytes (New-Dlss5UpdatedCopyBytes -Local $edited -Chosen $later -Trust $trust) -Chosen $later
            }
            finally { $script:Dlss5PackageCheckTimeout = $savedTimeout }
            Assert-Dlss5True ($reason.Contains('could not check this copy''s edited mission') -and $reason.Contains('did not finish')) "A check that could not finish did not say so: $reason"
            Assert-Dlss5Equal @(Get-ChildItem -LiteralPath (Get-Dlss5StorePath 'updates') -Force).Count 0 'The check left scratch files in the updates folder.'
            # The command itself, run by this engine: only a copy.cmd in a package-check folder, carrying this engine, is accepted.
            $folder = Join-Path (Get-Dlss5StorePath 'updates') ('package-check-' + ('0' * 32))
            New-Item -ItemType Directory -Force $folder | Out-Null
            $copy = Join-Path $folder 'copy.cmd'
            $priorOut = [Console]::Out
            $output = [IO.StringWriter]::new()
            try {
                [Console]::SetOut($output)
                [IO.File]::WriteAllBytes($copy, [byte[]]$edited.Bytes)
                Assert-Dlss5Equal (Invoke-Dlss5PackageCheck -Path $copy) 0 'The check refused a copy carrying its engine.'
                $outside = Join-Path (Get-Dlss5StorePath) 'copy.cmd'
                [IO.File]::WriteAllBytes($outside, [byte[]]$edited.Bytes)
                Assert-Dlss5Equal (Invoke-Dlss5PackageCheck -Path $outside) 6 'The check read a file outside a package-check folder.'
                Assert-Dlss5Equal (Invoke-Dlss5PackageCheck -Path 'copy.cmd') 6 'The check read a relative path.'
                $other = Join-Path $folder 'other.cmd'
                [IO.File]::WriteAllBytes($other, [byte[]]$edited.Bytes)
                Assert-Dlss5Equal (Invoke-Dlss5PackageCheck -Path $other) 6 'The check read a file of another name in a package-check folder.'
                [IO.File]::WriteAllBytes($copy, [byte[]]$later.Bytes)
                Assert-Dlss5Equal (Invoke-Dlss5PackageCheck -Path $copy) 6 'The check accepted another engine.'
                [IO.File]::WriteAllBytes($copy, [Text.Encoding]::ASCII.GetBytes("not a package`r`n"))
                Assert-Dlss5Equal (Invoke-Dlss5PackageCheck -Path $copy) 6 'The check accepted a malformed file.'
            }
            finally { [Console]::SetOut($priorOut) }
            $lines = @($output.ToString().Split([string[]]@("`r`n", "`n"), [StringSplitOptions]::RemoveEmptyEntries))
            Assert-Dlss5True ($lines[0] -ceq 'package check: accepted' -and @($lines | Select-Object -Skip 1 | Where-Object { -not $_.StartsWith('package check: refused: ', [StringComparison]::Ordinal) }).Count -eq 0) "The check did not print one verdict line each: $output"
        }
    }
    finally { $script:Dlss5ExecutingEngineSha256 = $savedEngine }
}

Invoke-Dlss5Case 'package startup updates an edited copy engine-only once the release engine accepts it, and skips it otherwise' {
    foreach ($kind in @('accepted', 'refused')) {
        $root = Join-Path $script:ScratchRoot ('package-engine-only-' + $kind)
        $game = Join-Path $root 'game'
        New-Item -ItemType Directory -Force $game | Out-Null
        $packagePath = Join-Path $game 'DLSS5-ADDER.cmd'
        $file = if ($kind -ceq 'accepted') { 'INSTRUCTIONS.cleanup-boundary.md' } else { 'TEST.stray.ps1' }
        $editedBytes = New-Dlss5PackageVariant -Bytes $script:CandidateBytes -Files ([ordered]@{ $file = [byte[]](65) }) -State (New-Dlss5StateLines -MissionEdited $true -ReplacedMissionHash ('e' * 64))
        [IO.File]::WriteAllBytes($packagePath, $editedBytes)
        $edited = Get-Dlss5BootstrapIdentity -Bytes $editedBytes
        $localAppData = Join-Path $root 'localappdata'
        $store = Join-Path $localAppData 'DLSS5-ADDER'
        New-Item -ItemType Directory -Force $store | Out-Null
        [IO.File]::WriteAllBytes((Join-Path $store 'DLSS5-ADDER.cmd'), $script:CandidateBytes)
        Write-Dlss5MachineTrustFixture -MachineDirectory $store -Whole @{ $script:CandidateVersion = $script:CandidateIdentity.Sha256 } -Engine @{ $script:CandidateVersion = $script:CandidateIdentity.EngineSha256 }
        $laterBytes = New-Dlss5LaterVersionBytes
        $later = Get-Dlss5BootstrapIdentity -Bytes $laterBytes
        $null = Write-Dlss5StageFixture -MachineDirectory $store -Bytes $laterBytes
        $priorOut = [Console]::Out
        $output = [IO.StringWriter]::new()
        $savedEngine = Get-Variable -Name Dlss5ExecutingEngineSha256 -Scope Script -ValueOnly -ErrorAction SilentlyContinue
        try {
            [Console]::SetOut($output)
            $script:Dlss5ExecutingEngineSha256 = $script:CandidateIdentity.EngineSha256
            $result = Invoke-Dlss5WithLocalAppData -Path $localAppData -Action {
                $local = Read-Dlss5InstalledBootstrap -Path $packagePath -GamePath

                return Invoke-Dlss5StartupReconciliation -Path $packagePath -Executing $local
            }
        }
        finally { [Console]::SetOut($priorOut); $script:Dlss5ExecutingEngineSha256 = $savedEngine }
        if ($kind -ceq 'refused') {
            Assert-Dlss5True ($output.ToString().Contains('engine did not accept this copy''s edited mission') -and -not $result.Reexecute) "The refused update was not skipped with its reason: $output"
            Assert-Dlss5True (Test-Dlss5ByteEquality -Left ([IO.File]::ReadAllBytes($packagePath)) -Right $editedBytes) 'The skipped copy was changed.'
            continue
        }
        Assert-Dlss5True $result.Reexecute "The accepted update did not ask to re-execute: $output"
        $after = Get-Dlss5BootstrapIdentity -Bytes ([IO.File]::ReadAllBytes($packagePath)) -Strict
        Assert-Dlss5True ($after.Version -eq $script:LaterVersion -and $after.EngineSha256 -ceq $later.EngineSha256 -and $after.MissionSha256 -ceq $edited.MissionSha256) 'The copy did not take the release engine with its own mission.'
        Assert-Dlss5True ($after.State.MissionEdited -and $after.State.ReplacedMissionHash -ceq ('e' * 64) -and -not $after.State.Armed -and $after.State.Update.KeptMission -and $after.State.Update.OfferedMissionHash -ceq $later.MissionSha256 -and $after.State.Update.FromSha256 -ceq $edited.Sha256) 'The engine-only record is wrong.'
        Assert-Dlss5True (Test-Dlss5ByteEquality -Left ([IO.File]::ReadAllBytes($packagePath + '.bkp')) -Right $editedBytes) 'An untracked copy got no .bkp of its previous file.'
        Assert-Dlss5Equal @(Get-ChildItem -LiteralPath (Join-Path $store 'updates') -Directory -Filter 'package-check-*').Count 0 'The release check left its scratch folder.'
    }
}

Invoke-Dlss5Case 'package update plan keeps edits recoverable' {
    $trust = (New-Dlss5TrustFixture -Whole @{ $script:CandidateVersion = $script:CandidateIdentity.Sha256 }).Trust
    $clean = Get-Dlss5BootstrapIdentity -Bytes (New-Dlss5PackageVariant -Bytes $script:CandidateBytes -State (New-Dlss5StateLines -Armed $true))
    $edited = Get-Dlss5BootstrapIdentity -Bytes (New-Dlss5PackageVariant -Bytes $script:CandidateBytes -Files ([ordered]@{ 'INSTRUCTIONS.cleanup-boundary.md' = [byte[]](65) }) -State (New-Dlss5StateLines -MissionEdited $true))
    $tracked = [pscustomobject]@{ Tracked = $true; Backup = $false; BackupTracked = $false; State = 'x' }
    $trackedBackup = [pscustomobject]@{ Tracked = $true; Backup = $false; BackupTracked = $true; State = 'x' }
    Assert-Dlss5True (-not (Get-Dlss5CopyUpdatePlan -Local $clean -Gate $tracked -Trust $trust).Backup) 'A tracked unedited copy got a backup.'
    Assert-Dlss5True (Get-Dlss5CopyUpdatePlan -Local $edited -Gate $tracked -Trust $trust).Backup 'A tracked edited copy got no backup.'
    Assert-Dlss5True (Get-Dlss5CopyUpdatePlan -Local $edited -Gate $trackedBackup -Trust $trust).Skip 'An update needing a tracked backup was not skipped.'
    $pending = Get-Dlss5BootstrapIdentity -Bytes (New-Dlss5PackageVariant -Bytes $script:CandidateBytes -State (New-Dlss5StateLines -Update ([pscustomobject]@{ FromVersion = 49; FromMissionHash = $null; FromSha256 = ('d' * 64); ReplacedEdit = $true; BackupSha256 = ('f' * 64) })))
    $untracked = [pscustomobject]@{ Tracked = $false; Backup = $true; BackupTracked = $false; State = 'x' }
    Assert-Dlss5True (Get-Dlss5CopyUpdatePlan -Local $pending -Gate $untracked -Trust $trust).KeepBackup 'A pending replaced edit did not keep its backup.'
    $editedAgain = Get-Dlss5BootstrapIdentity -Bytes (New-Dlss5PackageVariant -Bytes ([byte[]](New-Dlss5PackageVariant -Bytes $script:CandidateBytes -State (New-Dlss5StateLines -Update $pending.State.Update))) -Files ([ordered]@{ 'INSTRUCTIONS.cleanup-boundary.md' = [byte[]](67) }))
    $plan = Get-Dlss5CopyUpdatePlan -Local $editedAgain -Gate $untracked -Trust $trust
    Assert-Dlss5True ($plan.Skip -and $plan.Reason.Contains('acknowledge')) 'An edit made while a replaced edit was pending could be overwritten without a backup.'
}

Invoke-Dlss5Case 'package what''s-changed box shows its record and the release notes' {
    $saved = $script:Dlss5Console
    try {
        $update = [pscustomobject]@{ FromVersion = $script:CandidateVersion; FromMissionHash = ('e' * 64); FromSha256 = ('d' * 64); ReplacedEdit = $true; BackupSha256 = ('f' * 64) }
        $identity = Get-Dlss5BootstrapIdentity -Bytes (New-Dlss5PackageVariant -Bytes $script:CandidateBytes -State (New-Dlss5StateLines -Update $update))
        $script:Dlss5Console = New-Dlss5SubstitutedConsole @()
        Write-Dlss5ChangesBox -Identity $identity -Path 'C:\Games\X\DLSS5-ADDER.cmd'
        $text = $script:Dlss5Console.Output -join "`n"
        Assert-Dlss5True $text.Contains('THE MISSION CHANGED') 'A changed mission was not called out.'
        Assert-Dlss5True $text.Contains('C:\Games\X\DLSS5-ADDER.cmd.bkp') 'The replaced edit''s backup was not named.'
        Assert-Dlss5True ($script:Dlss5ReleaseNotes.Count -gt 0) 'The package embeds no release notes.'
        foreach ($note in $script:Dlss5ReleaseNotes) { Assert-Dlss5True $text.Contains($note) "A release note was not shown: $note" }
    }
    finally { $script:Dlss5Console = $saved }
}

Invoke-Dlss5Case 'package re-execution handoff is one-use and strict' {
    $saved = @{ ARGS = $env:DLSS5_REEXEC_ARGS; PROMPT = $env:DLSS5_REEXEC_PROMPT }
    try {
        $env:DLSS5_REEXEC_ARGS = ConvertTo-Dlss5ReexecArguments @('--internal-status', 'a b & c')
        $tokens = Read-Dlss5ReexecHandoff -Tokens @() -Child $true
        Assert-Dlss5Equal ($tokens -join '|') '--internal-status|a b & c' 'Carried arguments changed.'
        Assert-Dlss5Equal ([string]$env:DLSS5_REEXEC_ARGS) '' 'The handoff was not cleared on read.'
        $env:DLSS5_REEXEC_PROMPT = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('v49 task'))
        Assert-Dlss5Equal ((Read-Dlss5ReexecHandoff -Tokens @() -Child $true) -join '|') 'v49 task' 'A v49 task handoff was not accepted.'
        $env:DLSS5_REEXEC_PROMPT = ''
        $tokens = Read-Dlss5ReexecHandoff -Tokens @() -Child $true
        Assert-Dlss5Equal $tokens.Count 0 'An empty v49 task handoff did not read as no arguments.'
        $env:DLSS5_REEXEC_ARGS = ConvertTo-Dlss5ReexecArguments @('x')
        $env:DLSS5_REEXEC_PROMPT = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('task'))
        Assert-Dlss5Throws { Read-Dlss5ReexecHandoff -Tokens @() -Child $true } ([ArgumentException]) 'Both handoffs together were accepted.'
        $env:DLSS5_REEXEC_ARGS = ConvertTo-Dlss5ReexecArguments @('x')
        Assert-Dlss5Throws { Read-Dlss5ReexecHandoff -Tokens @('real') -Child $true } ([ArgumentException]) 'A handoff beside real arguments was accepted.'
        $env:DLSS5_REEXEC_ARGS = ConvertTo-Dlss5ReexecArguments @('x')
        Assert-Dlss5Throws { Read-Dlss5ReexecHandoff -Tokens @() -Child $false } ([ArgumentException]) 'A handoff outside the re-execution guard was accepted.'
    }
    finally { $env:DLSS5_REEXEC_ARGS = $saved.ARGS; $env:DLSS5_REEXEC_PROMPT = $saved.PROMPT }
}

Invoke-Dlss5Case 'package launch requests classify drops tasks and items' {
    $drop = Resolve-Dlss5LaunchRequest -Launch (Resolve-Dlss5LaunchArguments @('C:\a\MISSION.md', 'C:\a\b.md')) -Tokens @('C:\a\MISSION.md', 'C:\a\b.md')
    Assert-Dlss5Equal $drop.Kind 'drop' 'Dropped paths were not a drop.'
    $task = Resolve-Dlss5LaunchRequest -Launch (Resolve-Dlss5LaunchArguments @('notes.txt')) -Tokens @('notes.txt')
    Assert-Dlss5Equal $task.Kind 'task' 'A relative name became a drop.'
    $promptFile = Join-Path $script:ScratchRoot 'package-task.txt'
    [IO.File]::WriteAllText($promptFile, 'a task')
    $option = Resolve-Dlss5LaunchRequest -Launch (Resolve-Dlss5LaunchArguments @('--prompt-file', $promptFile)) -Tokens @('--prompt-file', $promptFile)
    Assert-Dlss5Equal $option.Kind 'task' 'An absolute --prompt-file became a drop.'
    $drive = Resolve-Dlss5LaunchRequest -Launch (Resolve-Dlss5LaunchArguments @('C:\Games\X crashes, fix it')) -Tokens @('C:\Games\X crashes, fix it')
    Assert-Dlss5Equal $drive.Kind 'drop' 'A task starting with a drive path did not become a drop attempt.'
    Assert-Dlss5Throws { Resolve-Dlss5LaunchRequest -Launch (Resolve-Dlss5LaunchArguments @('--internal-arm', 'bad')) -Tokens @('--internal-arm', 'bad') } ([ArgumentException]) 'A state-changing item without its expectation token was accepted.'
}

Invoke-Dlss5Case 'package console input treats bursts as pasted text and acts only on enter' {
    $saved = $script:Dlss5Console
    try {
        $choices = @([pscustomobject]@{ Shortcut = 'e'; Label = 'Execute'; Value = 'execute' }, [pscustomobject]@{ Shortcut = 's'; Label = 'Disarm'; Value = 'disarm' })
        $script:Dlss5Console = New-Dlss5SubstitutedConsole (Add-Dlss5PastedText -Keys @() -Text 'C:\Users\s\MISSION.md')
        $script:Dlss5Console.Queue.Add([pscustomobject]@{ Key = 'Enter'; Char = [char]13; Delay = 1000 })
        Assert-Dlss5Equal (Read-Dlss5Choice -Prompt 'p' -Choices $choices -Initial 0).Value 'execute' 'A pasted path moved the highlight or acted.'
        Assert-Dlss5True ($script:Dlss5Console.Output -contains 'Pasted or dropped text was ignored.') 'A pasted path was not reported as ignored.'
        $script:Dlss5Console = New-Dlss5SubstitutedConsole (Add-Dlss5PastedText -Keys @() -Text 'C:\s\x.md' -Gap 60 -ChunkSize 3)
        $script:Dlss5Console.Queue.Add([pscustomobject]@{ Key = 'Escape'; Char = [char]27; Delay = 1000 })
        Assert-Dlss5Equal (Read-Dlss5Choice -Prompt 'p' -Choices $choices -Initial -1).Value 'quit' 'A chunked paste acted.'
        $script:Dlss5Console = New-Dlss5SubstitutedConsole @('s', 'Enter')
        Assert-Dlss5Equal (Read-Dlss5Choice -Prompt 'p' -Choices $choices -Initial 0).Value 'disarm' 'A shortcut did not move the highlight.'
        $script:Dlss5Console = New-Dlss5SubstitutedConsole @('Enter', 'Escape')
        Assert-Dlss5Equal (Read-Dlss5Choice -Prompt 'p' -Choices $choices -Initial -1).Value 'quit' 'Enter with nothing highlighted acted.'
        $script:Dlss5Console = New-Dlss5SubstitutedConsole @('Enter')
        Assert-Dlss5Equal (Read-Dlss5Confirmation -Question 'q') $false 'A confirmation did not default to cancel.'
        $script:Dlss5Console = New-Dlss5SubstitutedConsole @('y', 'Enter')
        Assert-Dlss5Equal (Read-Dlss5Confirmation -Question 'q') $true 'A confirmed choice was not accepted.'
        $script:Dlss5Console = New-Dlss5SubstitutedConsole @('y', 'Escape')
        Assert-Dlss5Equal (Read-Dlss5Confirmation -Question 'q') $false 'Esc did not cancel a confirmation.'
        $script:Dlss5Console = New-Dlss5SubstitutedConsole @(@{ Key = 'Y'; Char = 'y'; Delay = 0 }, 'Enter')
        Assert-Dlss5Equal (Read-Dlss5Confirmation -Question 'q') $false 'Input buffered before a confirmation answered it.'
    }
    finally { $script:Dlss5Console = $saved }
}

Invoke-Dlss5Case 'package fresh machine seeds trust and the slot then arms through the box' {
    $fixture = New-Dlss5IsolatedLaunchFixture -Name 'package-fresh' -StubBody @('exit /b 0')
    $status = Get-Dlss5LaunchStatus $fixture
    Assert-Dlss5True ($status.state_empty -and -not $status.armed) 'A fresh copy was not an unarmed new package.'
    $machine = Read-Dlss5NotesFile -Path (Join-Path $fixture.MachineDirectory 'DLSS5_MACHINE_NOTES.md') -BeginMarker $MachineNotesBeginMarker -EndMarker $MachineNotesEndMarker
    Assert-Dlss5Equal $machine['bootstrap_checksum.' + $script:CandidateVersion] $script:CandidateIdentity.PublishedSha256 'The whole-file entry is not the published form.'
    Assert-Dlss5Equal $machine['bootstrap_engine_checksum.' + $script:CandidateVersion] $script:CandidateIdentity.EngineSha256 'The engine entry was not recorded.'
    Assert-Dlss5True (Test-Dlss5ByteEquality -Left ([IO.File]::ReadAllBytes((Join-Path $fixture.MachineDirectory 'DLSS5-ADDER.cmd'))) -Right $script:CandidateIdentity.PublishedBytes) 'The slot was not seeded with the published form.'
    $refused = Invoke-Dlss5IsolatedLaunch -Fixture $fixture -Arguments @('describe it')
    Assert-Dlss5Equal $refused.ExitCode 8 'A command-line task ran on a disarmed copy.'
    Assert-Dlss5True ($refused.StandardOutput + $refused.StandardError).Contains('arm it from the menu') 'The disarmed refusal did not say how to arm.'
    $accept = Invoke-Dlss5IsolatedLaunch -Fixture $fixture -Arguments @('--internal-accept', $status.expect)
    Assert-Dlss5Equal $accept.ExitCode 0 "Accepting the new-package box failed: $($accept.StandardOutput) $($accept.StandardError)"
    $armed = Get-Dlss5LaunchStatus $fixture
    Assert-Dlss5True ($armed.armed -and -not $armed.state_empty -and -not $armed.update_pending) 'Accepting did not arm with an explicit state.'
    Assert-Dlss5True (Test-Dlss5ByteEquality -Left ([IO.File]::ReadAllBytes((Join-Path $fixture.MachineDirectory 'DLSS5-ADDER.cmd'))) -Right $script:CandidateIdentity.PublishedBytes) 'Arming changed the slot.'
    $task = Invoke-Dlss5IsolatedLaunch -Fixture $fixture -Arguments @('describe it')
    Assert-Dlss5Equal $task.ExitCode 0 "A command-line task did not run on an armed copy: $($task.StandardError)"
    Assert-Dlss5True (Get-Dlss5LaunchStatus $fixture).armed 'A successful run disarmed the rerunnable DLSS mission.'
    $menu = Invoke-Dlss5IsolatedLaunch -Fixture $fixture -Arguments @()
    Assert-Dlss5Equal $menu.ExitCode 2 'A no-argument launch without a console did not refuse.'
}

Invoke-Dlss5Case 'package expectation tokens and pending records gate headless items' {
    $fixture = New-Dlss5IsolatedLaunchFixture -Name 'package-headless' -StubBody @('exit /b 0')
    $status = Get-Dlss5LaunchStatus $fixture
    $stale = [string]$script:CandidateVersion + ':' + ('0' * 64) + ':' + ('0' * 64)
    Assert-Dlss5Equal (Invoke-Dlss5IsolatedLaunch -Fixture $fixture -Arguments @('--internal-arm', $stale)).ExitCode 8 'A stale expectation token was accepted.'
    Assert-Dlss5Equal (Invoke-Dlss5IsolatedLaunch -Fixture $fixture -Arguments @('--internal-keep-disarmed', $status.expect)).ExitCode 0 'Keeping a fresh copy disarmed failed.'
    Assert-Dlss5Equal (Invoke-Dlss5IsolatedLaunch -Fixture $fixture -Arguments @('--internal-accept', $status.expect)).ExitCode 8 'A box choice was accepted with no box due.'
    Assert-Dlss5Equal (Invoke-Dlss5IsolatedLaunch -Fixture $fixture -Arguments @('--internal-execute', $status.expect)).ExitCode 8 'Execute ran on a disarmed copy.'
    Assert-Dlss5Equal (Invoke-Dlss5IsolatedLaunch -Fixture $fixture -Arguments @('--internal-arm', $status.expect)).ExitCode 0 'Headless Arm failed.'
    $armed = Get-Dlss5LaunchStatus $fixture
    Assert-Dlss5True ($armed.armed -and $armed.expect -ceq $status.expect) 'Headless Arm did not arm, or changed the engine or mission.'
    Assert-Dlss5Equal (Invoke-Dlss5IsolatedLaunch -Fixture $fixture -Arguments @('--internal-disarm', $status.expect)).ExitCode 0 'Headless Disarm failed.'
    Assert-Dlss5True (-not (Get-Dlss5LaunchStatus $fixture).armed) 'Headless Disarm did not disarm.'
    $record = [pscustomobject]@{ FromVersion = 49; FromMissionHash = $null; FromSha256 = ('d' * 64); ReplacedEdit = $false }
    $folder = Join-Path $fixture.Root 'edits'
    New-Item -ItemType Directory -Force $folder | Out-Null
    [IO.File]::WriteAllText((Join-Path $folder 'INSTRUCTIONS.cleanup-boundary.md'), 'edited')
    # Each item is refused from the arm state where only the pending record can be the reason.
    foreach ($case in @(@('--internal-execute', $true), @('--internal-disarm', $true), @('--internal-arm', $false), @('--internal-absorb', $false))) {
        [IO.File]::WriteAllBytes($fixture.Updater, (New-Dlss5PackageVariant -Bytes ([IO.File]::ReadAllBytes($fixture.Updater)) -State (New-Dlss5StateLines -Armed $case[1] -Update $record)))
        $arguments = if ($case[0] -ceq '--internal-absorb') { @($case[0], $status.expect, $folder) } else { @($case[0], $status.expect) }
        $process = Invoke-Dlss5IsolatedLaunch -Fixture $fixture -Arguments $arguments
        Assert-Dlss5Equal $process.ExitCode 8 "$($case[0]) ran while an update record was pending."
        Assert-Dlss5True $process.StandardOutput.Contains('an update is waiting for acknowledgement') "$($case[0]) was refused for another reason: $($process.StandardOutput)"
    }
    [IO.File]::WriteAllBytes($fixture.Updater, (New-Dlss5PackageVariant -Bytes ([IO.File]::ReadAllBytes($fixture.Updater)) -State (New-Dlss5StateLines -Armed $true -Update $record)))
    Assert-Dlss5Equal (Invoke-Dlss5IsolatedLaunch -Fixture $fixture -Arguments @('describe it')).ExitCode 8 'A command-line task ran while an update record was pending.'
}

Invoke-Dlss5Case 'package headless absorb edits the mission and keeps the folder' {
    $fixture = New-Dlss5IsolatedLaunchFixture -Name 'package-absorb'
    $status = Get-Dlss5LaunchStatus $fixture
    [void](Invoke-Dlss5IsolatedLaunch -Fixture $fixture -Arguments @('--internal-accept', $status.expect))
    $status = Get-Dlss5LaunchStatus $fixture
    $folder = Join-Path $fixture.Root 'edits'
    New-Item -ItemType Directory -Force $folder | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $folder 'INSTRUCTIONS.cleanup-boundary.md'), $script:PackageUtf8.GetBytes("## Edited`r`npassword = hunter2`r`n"))
    # A hidden mission file in the folder is absorbed like any other.
    [IO.File]::SetAttributes((Join-Path $folder 'INSTRUCTIONS.cleanup-boundary.md'), [IO.FileAttributes]::Hidden)
    [IO.File]::WriteAllText((Join-Path $folder 'notes.txt'), 'not a mission file')
    $absorb = Invoke-Dlss5IsolatedLaunch -Fixture $fixture -Arguments @('--internal-absorb', $status.expect, $folder)
    Assert-Dlss5Equal $absorb.ExitCode 0 "Headless absorb failed: $($absorb.StandardOutput) $($absorb.StandardError)"
    Assert-Dlss5True $absorb.StandardOutput.Contains('Skipped, not a mission file') 'An unrecognized file was not reported as skipped.'
    Assert-Dlss5True $absorb.StandardOutput.Contains('may contain a password, secret, token or API key assignment') 'A secret-like assignment was not warned about.'
    Assert-Dlss5True (Test-Path -LiteralPath (Join-Path $folder 'INSTRUCTIONS.cleanup-boundary.md')) 'Headless absorb deleted a source file.'
    $after = Get-Dlss5BootstrapIdentity -Bytes ([IO.File]::ReadAllBytes($fixture.Updater)) -Strict
    Assert-Dlss5True ($after.State.MissionEdited -and -not $after.State.Armed -and $after.State.ReplacedMissionHash -ceq $script:CandidateIdentity.MissionSha256) 'Absorb did not disarm and mark the copy as edited against the published mission.'
    Assert-Dlss5Equal $after.EngineSha256 $script:CandidateIdentity.EngineSha256 'Absorb changed the engine.'
    Assert-Dlss5Equal (Invoke-Dlss5IsolatedLaunch -Fixture $fixture -Arguments @('--internal-absorb', $status.expect, $folder)).ExitCode 8 'Absorb ran against a mission it did not expect.'
    $explode = Invoke-Dlss5IsolatedLaunch -Fixture $fixture -Arguments @('--internal-explode')
    Assert-Dlss5Equal $explode.ExitCode 0 "Explode failed: $($explode.StandardError)"
    Assert-Dlss5Equal ([IO.File]::ReadAllText((Join-Path $fixture.Game 'INSTRUCTIONS.cleanup-boundary.md'))) "## Edited`r`npassword = hunter2`r`n" 'Explode did not write the absorbed file.'
    [IO.File]::WriteAllText((Join-Path $fixture.Game 'INSTRUCTIONS.cleanup-boundary.md'), 'my own edit')
    Assert-Dlss5Equal (Invoke-Dlss5IsolatedLaunch -Fixture $fixture -Arguments @('--internal-explode')).ExitCode 8 'Headless Explode overwrote existing files.'
    Assert-Dlss5Equal ([IO.File]::ReadAllText((Join-Path $fixture.Game 'INSTRUCTIONS.cleanup-boundary.md'))) 'my own edit' 'A refused Explode changed an existing file.'
}

Invoke-Dlss5Case 'package drop attempts refuse missing files and need a console' {
    $fixture = New-Dlss5IsolatedLaunchFixture -Name 'package-drop'
    $missing = Invoke-Dlss5IsolatedLaunch -Fixture $fixture -Arguments @((Join-Path $fixture.Root 'absent\MISSION.md'))
    Assert-Dlss5Equal $missing.ExitCode 8 'A drop with a missing file was not refused.'
    Assert-Dlss5True $missing.StandardOutput.Contains('--prompt-file') 'The drop refusal did not point to --prompt-file.'
    $folder = Join-Path $fixture.Root 'a-folder'
    New-Item -ItemType Directory -Force $folder | Out-Null
    $dropped = Invoke-Dlss5IsolatedLaunch -Fixture $fixture -Arguments @($folder)
    Assert-Dlss5True ($dropped.ExitCode -eq 8 -and $dropped.StandardOutput.Contains('are not existing files')) 'A dropped folder was not refused as a drop.'
    $file = Join-Path $fixture.Root 'MISSION.md'
    [IO.File]::WriteAllText($file, 'x')
    $noConsole = Invoke-Dlss5IsolatedLaunch -Fixture $fixture -Arguments @($file)
    Assert-Dlss5Equal $noConsole.ExitCode 8 'A drop without a console was not refused.'
    Assert-Dlss5True (Test-Path -LiteralPath $file) 'A refused drop touched its file.'
}

Invoke-Dlss5Case 'package shared AppData copy refuses arm and absorb and stays published' {
    $root = Join-Path $script:ScratchRoot 'package-slot'
    $localAppData = Join-Path $root 'localappdata'
    $store = Join-Path $localAppData 'DLSS5-ADDER'
    $fixture = New-Dlss5IsolatedLaunchFixture -Name 'package-slot' -GameDirectory $store
    $status = Get-Dlss5LaunchStatus $fixture -Environment @{ LOCALAPPDATA = $localAppData }
    Assert-Dlss5Equal (Invoke-Dlss5IsolatedLaunch -Fixture $fixture -Arguments @('--internal-arm', $status.expect) -Environment @{ LOCALAPPDATA = $localAppData }).ExitCode 8 'The shared copy was armed.'
    Assert-Dlss5Equal (Invoke-Dlss5IsolatedLaunch -Fixture $fixture -Arguments @('--internal-accept', $status.expect) -Environment @{ LOCALAPPDATA = $localAppData }).ExitCode 8 'The shared copy acknowledged a box.'
    $folder = Join-Path $root 'edits'
    New-Item -ItemType Directory -Force $folder | Out-Null
    [IO.File]::WriteAllText((Join-Path $folder 'INSTRUCTIONS.cleanup-boundary.md'), 'edited')
    Assert-Dlss5Equal (Invoke-Dlss5IsolatedLaunch -Fixture $fixture -Arguments @('--internal-absorb', $status.expect, $folder) -Environment @{ LOCALAPPDATA = $localAppData }).ExitCode 8 'The shared copy absorbed files.'
    Assert-Dlss5True (Test-Dlss5ByteEquality -Left ([IO.File]::ReadAllBytes($fixture.Updater)) -Right $script:CandidateIdentity.PublishedBytes) 'The shared copy gained state.'
}

Invoke-Dlss5Case 'package plain mission asks before trust and launches with only its own folder' {
    $fixture = New-Dlss5IsolatedLaunchFixture -Name 'package-plain' -StubBody @('echo %*> "%DLSS5_TEST_ARGS_PATH%"', 'cd> "%DLSS5_TEST_CWD_PATH%"', ('if defined DLSS5_TEST_SECTIONS_CAPTURE_PATH ' + $script:SectionCaptureStubLine), 'if defined DLSS5_TEST_READONLY_PATH attrib +r "%DLSS5_TEST_READONLY_PATH%"', 'exit /b 0')
    [IO.File]::WriteAllBytes($fixture.Updater, (New-Dlss5PlainPackageBytes))
    $refused = Invoke-Dlss5IsolatedLaunch -Fixture $fixture -Arguments @('--internal-status')
    Assert-Dlss5Equal $refused.ExitCode 4 'A plain mission was trusted on first use without asking.'
    $token = Get-Dlss5ExpectationToken (Get-Dlss5BootstrapIdentity -Bytes ([IO.File]::ReadAllBytes($fixture.Updater)))
    Assert-Dlss5Equal (Invoke-Dlss5IsolatedLaunch -Fixture $fixture -Arguments @('--internal-arm', $token)).ExitCode 4 'A state-changing item passed engine admission without trust.'
    Assert-Dlss5True (-not (Get-Dlss5BootstrapIdentity -Bytes ([IO.File]::ReadAllBytes($fixture.Updater))).State.Armed -and (Get-Dlss5BootstrapIdentity -Bytes ([IO.File]::ReadAllBytes($fixture.Updater))).State.Empty) 'A refused state-changing item changed the package.'
    Write-Dlss5MachineTrustFixture -MachineDirectory $fixture.MachineDirectory -Engine @{ $script:CandidateVersion = $script:CandidateIdentity.EngineSha256 }
    $status = Get-Dlss5LaunchStatus $fixture
    Assert-Dlss5Equal $status.mission_id 'hello-world' 'The plain mission id was not reported.'
    [void](Invoke-Dlss5IsolatedLaunch -Fixture $fixture -Arguments @('--internal-accept', $status.expect))
    $argsPath = Join-Path $fixture.Root 'args.txt'
    $cwdPath = Join-Path $fixture.Root 'cwd.txt'
    # Launched from another folder, as an absolute-path launch would be.
    $run = Invoke-Dlss5IsolatedLaunch -Fixture $fixture -Arguments @('--internal-execute', (Get-Dlss5LaunchStatus $fixture).expect) -Environment @{ DLSS5_TEST_ARGS_PATH = $argsPath; DLSS5_TEST_CWD_PATH = $cwdPath } -WorkingDirectory $fixture.Root
    Assert-Dlss5Equal $run.ExitCode 0 "The plain session failed: $($run.StandardOutput) $($run.StandardError)"
    Assert-Dlss5Equal ([IO.File]::ReadAllText($cwdPath).Trim()) ([IO.Path]::GetFullPath($fixture.Game)) 'The plain session did not start its agent in the package directory.'
    $arguments = [IO.File]::ReadAllText($argsPath)
    Assert-Dlss5True ($arguments -match '--add-dir "?([^"]*dlss5-agent-sections-[0-9a-f]{32})') 'The plain session was not granted its own launch folder.'
    Assert-Dlss5True (-not $arguments.Contains('--add-dir "' + $fixture.MachineDirectory + '"') -and -not $arguments.Contains('--add-dir ' + $fixture.MachineDirectory + ' ')) 'The plain session was granted the machine directory.'
    Assert-Dlss5True (-not (Test-Path -LiteralPath $fixture.GameNotesPath)) 'A plain session wrote game notes.'
    Assert-Dlss5True (-not (Test-Path -LiteralPath (Join-Path $fixture.MachineDirectory 'DLSS5-ADDER.cmd'))) 'A plain session wrote the shared slot.'
    Assert-Dlss5True (-not (Get-Dlss5LaunchStatus $fixture).armed) 'A successful plain run did not disarm a mission that is not rerunnable.'
    $machine = Read-Dlss5NotesFile -Path (Join-Path $fixture.MachineDirectory 'DLSS5_MACHINE_NOTES.md') -BeginMarker $MachineNotesBeginMarker -EndMarker $MachineNotesEndMarker
    Assert-Dlss5True (-not $machine.Contains('bootstrap_checksum.' + $script:CandidateVersion)) 'A plain mission recorded a whole-file entry.'
    # A command-line task reaches the plain prompt verbatim.
    Assert-Dlss5Equal (Invoke-Dlss5IsolatedLaunch -Fixture $fixture -Arguments @('--internal-arm', (Get-Dlss5LaunchStatus $fixture).expect)).ExitCode 0 'Headless Arm failed on a disarmed plain copy.'
    $capture = New-Dlss5SectionCapture $fixture
    $task = Invoke-Dlss5IsolatedLaunch -Fixture $fixture -Arguments @('say hello {{host}} now') -Environment @{ DLSS5_TEST_ARGS_PATH = $argsPath; DLSS5_TEST_CWD_PATH = $cwdPath; DLSS5_TEST_SECTIONS_CAPTURE_PATH = $capture }
    Assert-Dlss5Equal $task.ExitCode 0 "The plain task session failed: $($task.StandardOutput) $($task.StandardError)"
    $prompts = @(Get-ChildItem -LiteralPath $capture -Filter '*.md' | ForEach-Object { [IO.File]::ReadAllText($_.FullName) } | Where-Object { $_.Contains('USER REQUEST') })
    Assert-Dlss5True ($prompts.Count -eq 1 -and $prompts[0].Contains('USER REQUEST' + $script:PackageNewline + 'say hello {{host}} now')) 'The task text did not reach the plain prompt verbatim.'
    # A run whose post-run disarm fails reports the actual arm state and does not claim success.
    Assert-Dlss5Equal (Invoke-Dlss5IsolatedLaunch -Fixture $fixture -Arguments @('--internal-arm', (Get-Dlss5LaunchStatus $fixture).expect)).ExitCode 0 'Headless Arm failed before the disarm-failure run.'
    try {
        $failed = Invoke-Dlss5IsolatedLaunch -Fixture $fixture -Arguments @('--internal-execute', (Get-Dlss5LaunchStatus $fixture).expect) -Environment @{ DLSS5_TEST_ARGS_PATH = $argsPath; DLSS5_TEST_CWD_PATH = $cwdPath; DLSS5_TEST_READONLY_PATH = $fixture.Updater }
        Assert-Dlss5Equal $failed.ExitCode 4 'A failed post-run disarm did not exit with a failure.'
        Assert-Dlss5True ($failed.StandardOutput.Contains('disarming failed') -and $failed.StandardOutput.Contains('The package is still armed.')) "A failed post-run disarm was not reported with the arm state: $($failed.StandardOutput)"
    }
    finally { [IO.File]::SetAttributes($fixture.Updater, [IO.FileAttributes]::Normal) }
}

Invoke-Dlss5Case 'package stages and adopts a later version that reads the state this version wrote' {
    $fixture = New-Dlss5IsolatedLaunchFixture -Name 'package-later-version'
    $status = Get-Dlss5LaunchStatus $fixture
    [void](Invoke-Dlss5IsolatedLaunch -Fixture $fixture -Arguments @('--internal-accept', $status.expect))
    $later = New-Dlss5LaterVersionBytes
    $laterIdentity = Get-Dlss5BootstrapIdentity -Bytes $later
    $updates = Join-Path $fixture.MachineDirectory 'updates'
    New-Item -ItemType Directory -Force $updates | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $updates 'DLSS5-ADDER.staged.cmd'), $later)
    $metadata = [ordered]@{ schema_version = 1; state = 'staged'; version = $script:LaterVersion; sha256 = $laterIdentity.Sha256; source_owner = $script:Dlss5GistOwner; gist_id = $script:Dlss5GistId; gist_revision = ('a' * 40); file_name = 'DLSS5-ADDER.cmd'; fetched_at = (Get-Dlss5UtcStamp) }
    [IO.File]::WriteAllText((Join-Path $updates 'stage.json'), ($metadata | ConvertTo-Json -Compress) + "`r`n", [Text.UTF8Encoding]::new($false))
    $machinePath = Join-Path $fixture.MachineDirectory 'DLSS5_MACHINE_NOTES.md'
    $notes = Read-Dlss5NotesFile -Path $machinePath -BeginMarker $MachineNotesBeginMarker -EndMarker $MachineNotesEndMarker
    $notes['bootstrap_checksum.' + $script:LaterVersion] = $laterIdentity.Sha256
    $notes['bootstrap_highest_version_seen'] = [string]$script:LaterVersion
    [IO.File]::WriteAllText($machinePath, (ConvertTo-Dlss5NotesDocument -Notes $notes -BeginMarker $MachineNotesBeginMarker -EndMarker $MachineNotesEndMarker -KnownOrder $MachineNotesOrder), [Text.UTF8Encoding]::new($false))
    $child = Get-Dlss5LaunchStatus $fixture
    Assert-Dlss5Equal ([int]$child.version) $script:LaterVersion 'The later version was not adopted, or the re-executed child did not carry --internal-status.'
    Assert-Dlss5True ($child.update_pending -and -not $child.armed) 'The later version did not read the update record this version wrote.'
    $after = Get-Dlss5BootstrapIdentity -Bytes ([IO.File]::ReadAllBytes($fixture.Updater))
    Assert-Dlss5True ($after.State.Update.FromVersion -eq $script:CandidateVersion -and $after.State.Update.FromMissionHash -ceq $script:CandidateIdentity.MissionSha256 -and -not $after.State.Update.ReplacedEdit) 'The update record is wrong.'
    $machine = Read-Dlss5NotesFile -Path $machinePath -BeginMarker $MachineNotesBeginMarker -EndMarker $MachineNotesEndMarker
    Assert-Dlss5Equal $machine['bootstrap_engine_checksum.' + $script:LaterVersion] $laterIdentity.EngineSha256 'The later version did not derive its own engine entry.'
    Assert-Dlss5Equal $machine['bootstrap_engine_highest_version_seen'] ([string]$script:LaterVersion) 'The engine maximum did not follow.'
}

Invoke-Dlss5Case 'package concurrent writes keep each other' {
    $root = Join-Path $script:ScratchRoot 'package-concurrent'
    $game = Join-Path $root 'game'
    New-Item -ItemType Directory -Force $game | Out-Null
    $packagePath = Join-Path $game 'DLSS5-ADDER.cmd'
    [IO.File]::WriteAllBytes($packagePath, (New-Dlss5PackageVariant -Bytes $script:CandidateBytes -State (New-Dlss5StateLines -Armed $true)))
    Invoke-Dlss5WithLocalAppData -Path (Join-Path $root 'localappdata') -Action {
        # The library import does not run the entry point, so these may not exist yet.
        $saved = @{ Identity = (Get-Variable -Name Dlss5ExecutingIdentity -Scope Script -ValueOnly -ErrorAction SilentlyContinue); Startup = (Get-Variable -Name Dlss5Startup -Scope Script -ValueOnly -ErrorAction SilentlyContinue) }
        try {
            $script:Dlss5Startup = [pscustomobject]@{ Diagnosis = $null }
            $script:Dlss5ExecutingIdentity = Get-Dlss5BootstrapIdentity -Bytes ([IO.File]::ReadAllBytes($packagePath)) -Strict
            $stale = $script:Dlss5ExecutingIdentity
            # Another window absorbs an edit meanwhile.
            [IO.File]::WriteAllBytes($packagePath, (New-Dlss5PackageVariant -Bytes ([IO.File]::ReadAllBytes($packagePath)) -Files ([ordered]@{ 'INSTRUCTIONS.cleanup-boundary.md' = [byte[]](65) }) -State (New-Dlss5StateLines -MissionEdited $true)))
            $script:Dlss5ExecutingIdentity = $stale
            $written = Set-Dlss5Disarmed -Path $packagePath
            Assert-Dlss5True ($written.State.MissionEdited -and $written.MissionSha256 -cne $stale.MissionSha256) 'A state write overwrote another window''s mission edit.'
            $script:Dlss5ExecutingIdentity = $stale
            Assert-Dlss5Throws { $null = Set-Dlss5GatedArm -Path $packagePath -ExpectMission $stale.MissionSha256 } ([InvalidOperationException]) 'Arm applied to a mission the user was not shown.'
        }
        finally { $script:Dlss5ExecutingIdentity = $saved.Identity; $script:Dlss5Startup = $saved.Startup }
    }
}

Invoke-Dlss5Case 'package tracked copy with a trusted engine passes the session preflight when armed' {
    $fixture = New-Dlss5GitFixture 'package-tracked-armed'
    [IO.File]::WriteAllBytes($fixture.Updater, $script:CandidateBytes)
    [void](Invoke-Dlss5Git -Repository $fixture.Root add -- 'Game/DLSS5-ADDER.cmd')
    [void](Invoke-Dlss5Git -Repository $fixture.Root commit -m 'test: track package')
    [IO.File]::WriteAllBytes($fixture.Updater, (New-Dlss5PackageVariant -Bytes $script:CandidateBytes -State (New-Dlss5StateLines -Armed $true)))
    $localAppData = Join-Path $fixture.Root 'LocalAppData'
    Write-Dlss5MachineTrustFixture -MachineDirectory (Join-Path $localAppData 'DLSS5-ADDER') -Engine @{ $script:CandidateVersion = $script:CandidateIdentity.EngineSha256 }
    $result = Invoke-Dlss5WithLocalAppData -Path $localAppData -Action { Get-Dlss5GitProtection -GameDirectory $fixture.Game -UpdaterPath $fixture.Updater -GameNotesPath $fixture.Notes -BackupPath $fixture.Backup }
    Assert-Dlss5Equal $result.ShouldAbort $false 'An armed tracked copy with a trusted engine blocked the preflight.'
    Write-Dlss5MachineTrustFixture -MachineDirectory (Join-Path $localAppData 'DLSS5-ADDER') -Whole @{ $script:CandidateVersion = $script:CandidateIdentity.Sha256 }
    $gate = Invoke-Dlss5WithLocalAppData -Path $localAppData -Action {
        $local = Read-Dlss5InstalledBootstrap -Path $fixture.Updater -GamePath
        Get-Dlss5UpdaterGitGate -Local $local -Trust (Read-Dlss5TrustState).Trust
    }
    Assert-Dlss5True ($gate.Tracked -and -not $gate.Backup) 'A copy whose published form matches its whole-file entry did not pass the updater gate.'
}

Invoke-Dlss5Case 'package real Git gate refuses an update that needs a tracked .bkp and notices the .bkp becoming tracked' {
    $fixture = New-Dlss5GitFixture 'package-tracked-backup'
    [IO.File]::WriteAllBytes($fixture.Updater, $script:CandidateBytes)
    [void](Invoke-Dlss5Git -Repository $fixture.Root add -- 'Game/DLSS5-ADDER.cmd')
    [void](Invoke-Dlss5Git -Repository $fixture.Root commit -m 'test: track package')
    [IO.File]::WriteAllBytes($fixture.Updater, (New-Dlss5PackageVariant -Bytes $script:CandidateBytes -Files ([ordered]@{ 'INSTRUCTIONS.cleanup-boundary.md' = [byte[]](65) }) -State (New-Dlss5StateLines -MissionEdited $true)))
    $untrusted = Join-Path $fixture.Root 'LocalAppDataUntrusted'
    Write-Dlss5MachineTrustFixture -MachineDirectory (Join-Path $untrusted 'DLSS5-ADDER') -Whole @{ $script:CandidateVersion = $script:CandidateIdentity.Sha256 }
    Invoke-Dlss5WithLocalAppData -Path $untrusted -Action {
        $local = Read-Dlss5InstalledBootstrap -Path $fixture.Updater -GamePath
        Assert-Dlss5Throws { $null = Get-Dlss5UpdaterGitGate -Local $local -Trust (Read-Dlss5TrustState).Trust } ([IO.InvalidDataException]) 'A modified tracked copy without engine trust passed the gate.'
    }
    $trusted = Join-Path $fixture.Root 'LocalAppData'
    Write-Dlss5MachineTrustFixture -MachineDirectory (Join-Path $trusted 'DLSS5-ADDER') -Whole @{ $script:CandidateVersion = $script:CandidateIdentity.Sha256 } -Engine @{ $script:CandidateVersion = $script:CandidateIdentity.EngineSha256 }
    $result = Invoke-Dlss5WithLocalAppData -Path $trusted -Action {
        $trust = (Read-Dlss5TrustState).Trust
        $local = Read-Dlss5InstalledBootstrap -Path $fixture.Updater -GamePath
        $before = Get-Dlss5UpdaterGitGate -Local $local -Trust $trust
        [IO.File]::WriteAllText($fixture.Backup, "an older copy`r`n")
        [void](Invoke-Dlss5Git -Repository $fixture.Root add -- 'Game/DLSS5-ADDER.cmd.bkp')
        [void](Invoke-Dlss5Git -Repository $fixture.Root commit -m 'test: track backup')
        $after = Get-Dlss5UpdaterGitGate -Local $local -Trust $trust

        return [pscustomobject]@{ Before = $before; After = $after; Plan = Get-Dlss5CopyUpdatePlan -Local $local -Gate $after -Trust $trust }
    }
    Assert-Dlss5True ($result.Before.Tracked -and -not $result.Before.BackupTracked -and $result.After.BackupTracked) 'The gate did not report the .bkp tracking.'
    Assert-Dlss5True ($result.Before.State -cne $result.After.State) 'A .bkp becoming tracked left the gate state unchanged.'
    Assert-Dlss5True $result.Plan.Skip 'An edited tracked copy whose .bkp is tracked was not skipped.'
}

Invoke-Dlss5Case 'package update never rewrites the .bkp that a pending replaced edit owns' {
    $kept = [Text.Encoding]::ASCII.GetBytes("the replaced edit`r`n")
    $update = [pscustomobject]@{ FromVersion = 49; FromMissionHash = $null; FromSha256 = ('d' * 64); ReplacedEdit = $true; BackupSha256 = [Convert]::ToHexStringLower([Security.Cryptography.SHA256]::HashData($kept)) }
    foreach ($backupState in @('kept', 'changed', 'missing')) {
        $root = Join-Path $script:ScratchRoot ('package-keep-backup-' + $backupState)
        $game = Join-Path $root 'game'
        New-Item -ItemType Directory -Force $game | Out-Null
        $packagePath = Join-Path $game 'DLSS5-ADDER.cmd'
        $backupPath = $packagePath + '.bkp'
        [IO.File]::WriteAllBytes($packagePath, (New-Dlss5PackageVariant -Bytes $script:CandidateBytes -State (New-Dlss5StateLines -Update $update)))
        $backupBytes = switch ($backupState) { 'kept' { $kept } 'changed' { [Text.Encoding]::ASCII.GetBytes("something else`r`n") } default { $null } }
        if ($null -ne $backupBytes) { [IO.File]::WriteAllBytes($backupPath, $backupBytes) }
        Invoke-Dlss5WithLocalAppData -Path (Join-Path $root 'localappdata') -Action {
            $trust = (New-Dlss5TrustFixture -Whole @{ $script:CandidateVersion = $script:CandidateIdentity.Sha256 }).Trust
            $local = Read-Dlss5InstalledBootstrap -Path $packagePath -GamePath
            $plan = Get-Dlss5CopyUpdatePlan -Local $local -Gate ([pscustomobject]@{ Tracked = $false; Backup = $true; BackupTracked = $false; State = 'x' }) -Trust $trust
            Assert-Dlss5True ($plan.Backup -and $plan.KeepBackup) 'A pending replaced edit did not plan to keep its backup.'
            # From v52 a game copy is written only under its folder's single-instance guard, as reconciliation and adoption take it.
            $guard = if ($null -ne (Get-Command Enter-Dlss5FolderGuard -ErrorAction SilentlyContinue)) { Enter-Dlss5FolderGuard -Path $packagePath -Operation 'update' } else { $null }
            $lock = Enter-Dlss5BootstrapLock
            try { $null = Invoke-Dlss5GameCopyUpdate -Path $packagePath -Local $local -Chosen $script:CandidateIdentity -Plan $plan -Trust $trust }
            finally {
                Exit-Dlss5BootstrapLock $lock
                if ($null -ne $guard) { Exit-Dlss5FolderGuard $guard }
            }
        }
        if ($null -ne $backupBytes) { Assert-Dlss5True ([Linq.Enumerable]::SequenceEqual[byte]([IO.File]::ReadAllBytes($backupPath), [byte[]]$backupBytes)) 'The .bkp a pending replaced edit owns was rewritten.' }
        else { Assert-Dlss5True (-not (Test-Path -LiteralPath $backupPath)) 'A missing .bkp was recreated from a copy that does not hold the replaced edit.' }
        $saved = $script:Dlss5Console
        try {
            $script:Dlss5Console = New-Dlss5SubstitutedConsole @()
            Write-Dlss5ChangesBox -Identity (Get-Dlss5BootstrapIdentity -Bytes ([IO.File]::ReadAllBytes($packagePath))) -Path $packagePath
            $text = $script:Dlss5Console.Output -join "`n"
        }
        finally { $script:Dlss5Console = $saved }
        $claim = switch ($backupState) {
            'kept' { 'is kept as ' + $backupPath + '.' }
            'changed' { $backupPath + ' has changed since the update and no longer holds the previous file, so the edit survives only where you saved or committed it yourself' }
            default { 'is no longer there, so the edit survives only where you saved or committed it yourself' }
        }
        if ($backupState -cne 'kept') { Assert-Dlss5True (-not $text.Contains('is kept as')) 'The box named a .bkp that does not hold the replaced edit.' }
        Assert-Dlss5True (-not $text.Contains('Git history')) 'The box pointed to Git history, which need not hold the replaced edit.'
        Assert-Dlss5True $text.Contains($claim) "The box did not say where the replaced edit is: $text"
    }
}

Invoke-Dlss5Case 'package file roles are case-sensitive in both readings' {
    $packageText = $script:PackageUtf8.GetString($script:CandidateBytes)
    Assert-Dlss5True ($packageText.Split('@file PROJECT.json').Length -eq 2) 'The project file header is not unique.'
    $lowercase = $script:PackageUtf8.GetBytes($packageText.Replace('@file PROJECT.json', '@file project.json'))
    foreach ($strict in @($false, $true)) {
        Assert-Dlss5Throws { $null = Get-Dlss5BootstrapIdentity -Bytes $lowercase -Strict:$strict } ([FormatException]) "A lowercase project.json was taken as the project file (strict: $strict)."
    }
}

Invoke-Dlss5Case 'package adoption into the shared slot itself reports success' {
    $localAppData = Join-Path (Join-Path $script:ScratchRoot 'package-adopt-slot') 'localappdata'
    $store = Join-Path $localAppData 'DLSS5-ADDER'
    New-Item -ItemType Directory -Force $store | Out-Null
    $slot = Join-Path $store 'DLSS5-ADDER.cmd'
    # Adoption records engine trust only for the running engine, so the candidate is this package and the slot holds v49.
    $v49Bytes = [IO.File]::ReadAllBytes((Join-Path $PSScriptRoot 'fixtures\DLSS5-ADDER.v49.cmd'))
    [IO.File]::WriteAllBytes($slot, $v49Bytes)
    Write-Dlss5MachineTrustFixture -MachineDirectory $store -Whole @{ 49 = [Convert]::ToHexStringLower([Security.Cryptography.SHA256]::HashData($v49Bytes)) }
    $laterBytes = $script:CandidateBytes
    $candidatePath = Join-Path $store 'DLSS5-ADDER.candidate.cmd'
    [IO.File]::WriteAllBytes($candidatePath, $laterBytes)
    $hash = $script:CandidateIdentity.Sha256
    $priorOut = [Console]::Out
    $priorError = [Console]::Error
    $output = [IO.StringWriter]::new()
    $errors = [IO.StringWriter]::new()
    try {
        [Console]::SetOut($output)
        [Console]::SetError($errors)
        $savedEngine = Get-Variable -Name Dlss5ExecutingEngineSha256 -Scope Script -ValueOnly -ErrorAction SilentlyContinue
        $script:Dlss5ExecutingEngineSha256 = $script:CandidateIdentity.EngineSha256
        $code = Invoke-Dlss5WithLocalAppData -Path $localAppData -Action { Invoke-Dlss5BootstrapAdoption -CandidatePath $candidatePath -TargetPath $slot -ExpectedHash $hash }
    }
    finally {
        $script:Dlss5ExecutingEngineSha256 = $savedEngine
        [Console]::SetOut($priorOut)
        [Console]::SetError($priorError)
    }
    Assert-Dlss5Equal $code 0 "Adoption into the slot itself did not report success: $output $errors"
    Assert-Dlss5True (Test-Dlss5ByteEquality -Left ([IO.File]::ReadAllBytes($slot)) -Right $laterBytes) 'The slot does not hold the adopted published form.'
    Assert-Dlss5True $output.ToString().Contains('Previous version: 49.') "Adoption did not report the slot's previous version: $output"
}

Invoke-Dlss5Case 'package a skipped game-copy update still promotes the slot from a newer stage' {
    $kept = [Text.Encoding]::ASCII.GetBytes("the replaced edit`r`n")
    $update = [pscustomobject]@{ FromVersion = 49; FromMissionHash = $null; FromSha256 = ('d' * 64); ReplacedEdit = $true; BackupSha256 = [Convert]::ToHexStringLower([Security.Cryptography.SHA256]::HashData($kept)) }
    $root = Join-Path $script:ScratchRoot 'package-skip-promotes-slot'
    $game = Join-Path $root 'game'
    New-Item -ItemType Directory -Force $game | Out-Null
    $packagePath = Join-Path $game 'DLSS5-ADDER.cmd'
    $editedBytes = New-Dlss5PackageVariant -Bytes $script:CandidateBytes -Files ([ordered]@{ 'INSTRUCTIONS.cleanup-boundary.md' = [byte[]](65) }) -State (New-Dlss5StateLines -Update $update)
    [IO.File]::WriteAllBytes($packagePath, $editedBytes)
    [IO.File]::WriteAllBytes($packagePath + '.bkp', $kept)
    $localAppData = Join-Path $root 'localappdata'
    $store = Join-Path $localAppData 'DLSS5-ADDER'
    New-Item -ItemType Directory -Force $store | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $store 'DLSS5-ADDER.cmd'), $script:CandidateBytes)
    Write-Dlss5MachineTrustFixture -MachineDirectory $store -Whole @{ $script:CandidateVersion = $script:CandidateIdentity.Sha256 } -Engine @{ $script:CandidateVersion = $script:CandidateIdentity.EngineSha256 }
    $laterBytes = New-Dlss5LaterVersionBytes
    $null = Write-Dlss5StageFixture -MachineDirectory $store -Bytes $laterBytes
    $priorOut = [Console]::Out
    $output = [IO.StringWriter]::new()
    try {
        [Console]::SetOut($output)
        $result = Invoke-Dlss5WithLocalAppData -Path $localAppData -Action {
            $local = Read-Dlss5InstalledBootstrap -Path $packagePath -GamePath

            return Invoke-Dlss5StartupReconciliation -Path $packagePath -Executing $local
        }
    }
    finally { [Console]::SetOut($priorOut) }
    Assert-Dlss5True ($output.ToString().Contains('This copy was edited after an update that replaced an earlier edit') -and -not $result.Reexecute) "The game-copy update was not skipped: $output"
    Assert-Dlss5True (Test-Dlss5ByteEquality -Left ([IO.File]::ReadAllBytes($packagePath)) -Right $editedBytes) 'The skipped game copy was changed.'
    Assert-Dlss5True (Test-Dlss5ByteEquality -Left ([IO.File]::ReadAllBytes((Join-Path $store 'DLSS5-ADDER.cmd'))) -Right $laterBytes) 'The slot was not promoted from the newer trusted stage.'
}

Invoke-Dlss5Case 'package a skipped update refuses with the full admission remedy' {
    $kept = [Text.Encoding]::ASCII.GetBytes("the replaced edit`r`n")
    $update = [pscustomobject]@{ FromVersion = 49; FromMissionHash = $null; FromSha256 = ('d' * 64); ReplacedEdit = $true; BackupSha256 = [Convert]::ToHexStringLower([Security.Cryptography.SHA256]::HashData($kept)) }
    $root = Join-Path $script:ScratchRoot 'package-skip-admission'
    $game = Join-Path $root 'game'
    New-Item -ItemType Directory -Force $game | Out-Null
    $packagePath = Join-Path $game 'DLSS5-ADDER.cmd'
    # A copy edited again under a pending replaced-edit record, on a machine whose trust records already reach a newer version.
    [IO.File]::WriteAllBytes($packagePath, (New-Dlss5PackageVariant -Bytes $script:CandidateBytes -Files ([ordered]@{ 'INSTRUCTIONS.cleanup-boundary.md' = [byte[]](65) }) -State (New-Dlss5StateLines -Update $update)))
    [IO.File]::WriteAllBytes($packagePath + '.bkp', $kept)
    $laterBytes = New-Dlss5LaterVersionBytes
    $localAppData = Join-Path $root 'localappdata'
    $store = Join-Path $localAppData 'DLSS5-ADDER'
    New-Item -ItemType Directory -Force $store | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $store 'DLSS5-ADDER.cmd'), $laterBytes)
    Write-Dlss5MachineTrustFixture -MachineDirectory $store -Whole @{ $script:LaterVersion = (Get-Dlss5BootstrapIdentity -Bytes $laterBytes).Sha256 }
    $message = Invoke-Dlss5WithLocalAppData -Path $localAppData -Action {
        $local = Read-Dlss5InstalledBootstrap -Path $packagePath -GamePath
        try { $null = Invoke-Dlss5StartupReconciliation -Path $packagePath -Executing $local; return '' }
        catch [IO.InvalidDataException] { return $_.Exception.Message }
    }
    Assert-Dlss5True $message.Contains('This copy was edited after an update that replaced an earlier edit') "The skipped update did not refuse with its reason: $message"
    Assert-Dlss5True $message.Contains('older than this machine''s trust records') "The skipped update did not give the full admission remedy: $message"
}

Invoke-Dlss5Case 'package shared AppData copy never runs a diagnosis session' {
    Invoke-Dlss5WithLocalAppData -Path (Join-Path $script:ScratchRoot 'package-slot-diagnosis') -Action {
        $slot = Get-Dlss5StorePath 'DLSS5-ADDER.cmd'
        New-Item -ItemType Directory -Force (Split-Path -Parent $slot) | Out-Null
        [IO.File]::WriteAllBytes($slot, $script:CandidateBytes)
        $saved = @{ Identity = (Get-Variable -Name Dlss5ExecutingIdentity -Scope Script -ValueOnly -ErrorAction SilentlyContinue); Startup = (Get-Variable -Name Dlss5Startup -Scope Script -ValueOnly -ErrorAction SilentlyContinue); Console = $script:Dlss5Console }
        try {
            $script:Dlss5ExecutingIdentity = $script:CandidateIdentity
            $script:Dlss5Startup = [pscustomobject]@{ Diagnosis = [pscustomobject]@{ Reason = 'git-unavailable'; Evidence = 'fixture' } }
            $script:Dlss5Console = New-Dlss5SubstitutedConsole @('d', 'Enter', 'Escape')
            Assert-Dlss5Equal (Invoke-Dlss5Menu -Path $slot) 0 'The shared copy''s menu did not close on Esc.'
            Assert-Dlss5True (-not ($script:Dlss5Console.Output -join "`n").Contains('Diagnose')) 'The shared copy offered Diagnose.'
            Assert-Dlss5True ($script:Dlss5Console.Output -join "`n").Contains('Copy DLSS5-ADDER.cmd elsewhere to use it.') 'The shared copy''s menu did not say to copy the file elsewhere.'
            $script:Dlss5Console = New-Dlss5SubstitutedConsole @()
            $code = Invoke-Dlss5PackageItem -Path $slot -Request ([pscustomobject]@{ Item = '--internal-diagnose'; Expect = $null; Folder = $null })
            Assert-Dlss5Equal $code 8 'The shared copy ran a headless diagnosis session.'
        }
        finally { $script:Dlss5ExecutingIdentity = $saved.Identity; $script:Dlss5Startup = $saved.Startup; $script:Dlss5Console = $saved.Console }
    }
}

# Runs an in-process package interaction against a game-local copy under an isolated store, with the given keys on a substituted console.
function Invoke-Dlss5PackageInteraction {
    param([Parameter(Mandatory=$true)][string]$Name, [Parameter(Mandatory=$true)][byte[]]$Bytes, [Parameter(Mandatory=$true)][scriptblock]$Action, $Diagnosis = $null)

    $root = Join-Path $script:ScratchRoot $Name
    $game = Join-Path $root 'game'
    New-Item -ItemType Directory -Force $game | Out-Null
    $packagePath = Join-Path $game 'DLSS5-ADDER.cmd'
    [IO.File]::WriteAllBytes($packagePath, $Bytes)
    $saved = @{ Identity = (Get-Variable -Name Dlss5ExecutingIdentity -Scope Script -ValueOnly -ErrorAction SilentlyContinue); Startup = (Get-Variable -Name Dlss5Startup -Scope Script -ValueOnly -ErrorAction SilentlyContinue); Console = $script:Dlss5Console; Engine = (Get-Variable -Name Dlss5ExecutingEngineSha256 -Scope Script -ValueOnly -ErrorAction SilentlyContinue) }
    # Invoke-Dlss5WithLocalAppData has its own Action parameter, which would shadow this one inside the block below.
    $interaction = $Action
    try {
        return Invoke-Dlss5WithLocalAppData -Path (Join-Path $root 'localappdata') -Action {
            New-Item -ItemType Directory -Force (Get-Dlss5StorePath) | Out-Null
            $script:Dlss5ExecutingEngineSha256 = $script:CandidateIdentity.EngineSha256
            $script:Dlss5ExecutingIdentity = Get-Dlss5BootstrapIdentity -Bytes $Bytes -Strict
            $script:Dlss5Startup = [pscustomobject]@{ Diagnosis = $Diagnosis }

            return & $interaction $packagePath $game
        }
    }
    finally { $script:Dlss5ExecutingIdentity = $saved.Identity; $script:Dlss5Startup = $saved.Startup; $script:Dlss5Console = $saved.Console; $script:Dlss5ExecutingEngineSha256 = $saved.Engine }
}

Invoke-Dlss5Case 'package box offers the release''s mission after an engine-only update, and Take keeps the edit as the .bkp' {
    $edit = [ordered]@{ 'INSTRUCTIONS.cleanup-boundary.md' = [byte[]](65) }
    $offered = [pscustomobject]@{ FromVersion = $script:CandidateVersion - 1; FromMissionHash = $null; FromSha256 = ('d' * 64); ReplacedEdit = $false; BackupSha256 = $null; KeptMission = $true; OfferedMissionHash = $script:CandidateIdentity.MissionSha256 }
    $quiet = [pscustomobject]@{ FromVersion = $script:CandidateVersion - 1; FromMissionHash = ('e' * 64); FromSha256 = ('d' * 64); ReplacedEdit = $false; BackupSha256 = $null; KeptMission = $true; OfferedMissionHash = $null }
    $saved = $script:Dlss5Console
    try {
        $script:Dlss5Console = New-Dlss5SubstitutedConsole @()
        Write-Dlss5ChangesBox -Identity (Get-Dlss5BootstrapIdentity -Bytes (New-Dlss5PackageVariant -Bytes $script:CandidateBytes -Files $edit -State (New-Dlss5StateLines -MissionEdited $true -ReplacedMissionHash ('e' * 64) -Update $quiet))) -Path 'C:\Games\X\DLSS5-ADDER.cmd'
        $text = $script:Dlss5Console.Output -join "`n"
        Assert-Dlss5True ($text.Contains('Your edited mission was kept.') -and $text.Contains('The release did not change the mission your edit replaced.') -and -not $text.Contains('THE MISSION CHANGED')) "The box did not describe an engine-only update without an offer: $text"
    }
    finally { $script:Dlss5Console = $saved }
    $bytes = New-Dlss5PackageVariant -Bytes $script:CandidateBytes -Files $edit -State (New-Dlss5StateLines -MissionEdited $true -Update $offered)
    $result = Invoke-Dlss5PackageInteraction -Name 'package-take-mission' -Bytes $bytes -Action {
        param($PackagePath, $Game)
        $slot = Get-Dlss5StorePath 'DLSS5-ADDER.cmd'
        Write-Dlss5MachineTrustFixture -MachineDirectory (Get-Dlss5StorePath) -Whole @{ $script:CandidateVersion = $script:CandidateIdentity.Sha256 } -Engine @{ $script:CandidateVersion = $script:CandidateIdentity.EngineSha256 }
        # With no shared copy holding the offered mission, Take refuses and changes nothing.
        $script:Dlss5Console = New-Dlss5SubstitutedConsole @('m', 'Enter', 'q', 'Enter')
        $null = Invoke-Dlss5Menu -Path $PackagePath
        $refusal = $script:Dlss5Console.Output -join "`n"
        $unchanged = Test-Dlss5ByteEquality -Left ([IO.File]::ReadAllBytes($PackagePath)) -Right $bytes
        [IO.File]::WriteAllBytes($slot, $script:CandidateBytes)
        $script:Dlss5Console = New-Dlss5SubstitutedConsole @('m', 'Enter', 'q', 'Enter')
        $null = Invoke-Dlss5Menu -Path $PackagePath

        return [pscustomobject]@{ Refusal = $refusal; Unchanged = $unchanged; Text = ($script:Dlss5Console.Output -join "`n"); After = [IO.File]::ReadAllBytes($PackagePath); Backup = [IO.File]::ReadAllBytes($PackagePath + '.bkp'); Path = $PackagePath }
    }
    Assert-Dlss5True ($result.Refusal.Contains('Take the release''s mission') -and $result.Refusal.Contains('the mission your edit replaced is not known')) "The box did not offer the release's mission with an unknown replaced mission: $($result.Refusal)"
    Assert-Dlss5True ($result.Refusal.Contains('not available from the shared AppData copy any more') -and $result.Unchanged) "Take without the offered mission in the shared copy did not refuse, or changed the copy: $($result.Refusal)"
    $after = Get-Dlss5BootstrapIdentity -Bytes $result.After -Strict
    Assert-Dlss5True ($after.PublishedSha256 -ceq $script:CandidateIdentity.Sha256 -and -not $after.State.MissionEdited -and $null -eq $after.State.Update -and -not $after.State.Armed -and (Get-Dlss5StateRecords $after.State).Count -eq 0) 'Take did not leave the published form, disarmed, without a record.'
    Assert-Dlss5True ((Test-Dlss5ByteEquality -Left $result.Backup -Right $bytes) -and $result.Text.Contains('Took the release''s mission')) "Take did not keep the edited file as the .bkp: $($result.Text)"
}

Invoke-Dlss5Case 'package Take refuses when Git tracks the .bkp of an untracked copy' {
    $fixture = New-Dlss5GitFixture 'package-take-tracked-backup'
    $offered = [pscustomobject]@{ FromVersion = $script:CandidateVersion - 1; FromMissionHash = $null; FromSha256 = ('d' * 64); ReplacedEdit = $false; BackupSha256 = $null; KeptMission = $true; OfferedMissionHash = $script:CandidateIdentity.MissionSha256 }
    $bytes = New-Dlss5PackageVariant -Bytes $script:CandidateBytes -Files ([ordered]@{ 'INSTRUCTIONS.cleanup-boundary.md' = [byte[]](65) }) -State (New-Dlss5StateLines -MissionEdited $true -Update $offered)
    $backup = [Text.Encoding]::ASCII.GetBytes("a committed backup`r`n")
    [IO.File]::WriteAllBytes($fixture.Backup, $backup)
    [void](Invoke-Dlss5Git -Repository $fixture.Root add -- 'Game/DLSS5-ADDER.cmd.bkp')
    [void](Invoke-Dlss5Git -Repository $fixture.Root commit -m 'test: track only the backup')
    [IO.File]::WriteAllBytes($fixture.Updater, $bytes)
    $localAppData = Join-Path $fixture.Root 'LocalAppData'
    $store = Join-Path $localAppData 'DLSS5-ADDER'
    Write-Dlss5MachineTrustFixture -MachineDirectory $store -Whole @{ $script:CandidateVersion = $script:CandidateIdentity.Sha256 } -Engine @{ $script:CandidateVersion = $script:CandidateIdentity.EngineSha256 }
    [IO.File]::WriteAllBytes((Join-Path $store 'DLSS5-ADDER.cmd'), $script:CandidateBytes)
    $saved = @{ Identity = (Get-Variable -Name Dlss5ExecutingIdentity -Scope Script -ValueOnly -ErrorAction SilentlyContinue); Startup = (Get-Variable -Name Dlss5Startup -Scope Script -ValueOnly -ErrorAction SilentlyContinue); Engine = (Get-Variable -Name Dlss5ExecutingEngineSha256 -Scope Script -ValueOnly -ErrorAction SilentlyContinue) }
    try {
        $message = Invoke-Dlss5WithLocalAppData -Path $localAppData -Action {
            $script:Dlss5ExecutingEngineSha256 = $script:CandidateIdentity.EngineSha256
            $script:Dlss5ExecutingIdentity = Get-Dlss5BootstrapIdentity -Bytes $bytes -Strict
            $script:Dlss5Startup = [pscustomobject]@{ Diagnosis = $null }
            try { Invoke-Dlss5TakeReleaseMission -Path $fixture.Updater -ExpectMission $script:Dlss5ExecutingIdentity.MissionSha256 -Offered $script:CandidateIdentity.MissionSha256; return '' }
            catch [InvalidOperationException] { return $_.Exception.Message }
        }
    }
    finally { $script:Dlss5ExecutingIdentity = $saved.Identity; $script:Dlss5Startup = $saved.Startup; $script:Dlss5ExecutingEngineSha256 = $saved.Engine }
    Assert-Dlss5True $message.Contains('Git tracks that .bkp file') "Take beside a tracked .bkp did not refuse: $message"
    Assert-Dlss5True ((Test-Dlss5ByteEquality -Left ([IO.File]::ReadAllBytes($fixture.Updater)) -Right $bytes) -and (Test-Dlss5ByteEquality -Left ([IO.File]::ReadAllBytes($fixture.Backup)) -Right $backup)) 'A refused Take changed the copy or the tracked .bkp.'
}

Invoke-Dlss5Case 'package reconciliation decisions cover continue, coexistence, the malformed slot and promotion answers' {
    $published = $script:CandidateIdentity
    $trust = (New-Dlss5TrustFixture -Whole @{ $script:CandidateVersion = $published.Sha256 }).Trust
    $edited = Get-Dlss5BootstrapIdentity -Bytes (New-Dlss5PackageVariant -Bytes $script:CandidateBytes -Files ([ordered]@{ 'INSTRUCTIONS.cleanup-boundary.md' = [byte[]](65) }) -State (New-Dlss5StateLines -MissionEdited $true)) -Strict
    $armed = Get-Dlss5BootstrapIdentity -Bytes (New-Dlss5PackageVariant -Bytes $script:CandidateBytes -State (New-Dlss5StateLines -Armed $true)) -Strict
    $decide = { param($Local, $Canonical = $null, [switch]$Malformed, $Approval = $null) Get-Dlss5ReconciliationDecision -Executing $Local -Local $Local -Canonical $Canonical -Stage $null -Trust $trust -CanonicalMalformed:$Malformed -Approval $Approval }
    $decision = & $decide $edited
    Assert-Dlss5True ($decision.Action -ceq 'continue' -and -not $decision.RecordWholeFile) 'An edited copy with no slot did not continue without recording whole-file trust.'
    $decision = & $decide $published
    Assert-Dlss5True ($decision.Action -ceq 'seed' -and $decision.RecordWholeFile) 'An unedited published copy with no slot did not seed it.'
    $fresh = (New-Dlss5TrustFixture).Trust
    $decideFresh = { param($Approval) Get-Dlss5ReconciliationDecision -Executing $edited -Local $edited -Canonical $null -Stage $null -Trust $fresh -Approval $Approval }
    Assert-Dlss5Equal (& $decideFresh $null).Action 'prompt-engine' 'An edited copy on a fresh machine was trusted on first use without being asked.'
    Assert-Dlss5Throws { $null = & $decideFresh $false } ([IO.InvalidDataException]) 'A declined engine question on a fresh machine did not refuse.'
    $decision = & $decideFresh $true
    Assert-Dlss5True ($decision.Action -ceq 'continue' -and $decision.Scope -ceq 'full' -and -not $decision.RecordWholeFile) 'An approved engine question on a fresh machine did not continue to first-use admission.'
    # A slot of the same version whose trust records were lost asks the same question.
    $sameVersion = Get-Dlss5ReconciliationDecision -Executing $edited -Local $edited -Canonical $published -Stage $null -Trust $fresh -Approval $null
    Assert-Dlss5Equal $sameVersion.Action 'prompt-engine' 'An edited copy beside a same-version slot without trust records was trusted on first use without being asked.'
    Assert-Dlss5Throws { $null = Get-Dlss5ReconciliationDecision -Executing $edited -Local $edited -Canonical $published -Stage $null -Trust $fresh -Approval $false } ([IO.InvalidDataException]) 'A declined engine question beside a same-version slot did not refuse.'
    foreach ($local in @($armed, $edited)) {
        $decision = & $decide $local $published
        Assert-Dlss5Equal $decision.Action 'continue' 'An equal-version copy differing in state or mission did not coexist with the slot.'
        Assert-Dlss5Equal $decision.RecordWholeFile (-not $local.State.MissionEdited) 'Whole-file recording did not follow the copy''s published form.'
    }
    $decision = & $decide $published -Malformed
    Assert-Dlss5True ($decision.Action -ceq 'disabled' -and $decision.Scope -ceq 'executing-only') 'A malformed slot did not limit admission to the executing copy.'
    Assert-Dlss5Throws { $null = & $decide $edited -Malformed } ([IO.InvalidDataException]) 'A malformed slot authorized an edited copy without an engine entry.'
    $later = Get-Dlss5BootstrapIdentity -Bytes (New-Dlss5LaterVersionBytes)
    Assert-Dlss5Equal (& $decide $later $published).Action 'prompt' 'A newer local copy over the slot was not asked about.'
    Assert-Dlss5Throws { $null = & $decide $later $published -Approval $false } ([IO.InvalidDataException]) 'A declined promotion of a first-use copy did not refuse.'
    $decision = & $decide $later $published -Approval $true
    Assert-Dlss5True ($decision.Action -ceq 'promote-local' -and $decision.RecordWholeFile) 'An approved promotion did not promote the local copy.'
}

Invoke-Dlss5Case 'package concurrent adoption accepts a game-local file with a state section' {
    $laterBytes = New-Dlss5LaterVersionBytes
    $laterPublished = Get-Dlss5BootstrapIdentity -Bytes $laterBytes
    $laterArmed = Get-Dlss5BootstrapIdentity -Bytes (New-Dlss5PackageVariant -Bytes $laterBytes -State (New-Dlss5StateLines -Armed $true))
    $trust = (New-Dlss5TrustFixture -Whole @{ $script:CandidateVersion = $script:CandidateIdentity.Sha256; $script:LaterVersion = $laterPublished.Sha256 }).Trust
    Assert-Dlss5Equal (Assert-Dlss5ExecutingLocalIdentity -Executing $script:CandidateIdentity -Local $laterArmed -Canonical $laterPublished -Trust $trust) 'adopted' 'A newer game-local copy with a state section was not accepted as concurrently adopted.'
    $armed = Get-Dlss5BootstrapIdentity -Bytes (New-Dlss5PackageVariant -Bytes $script:CandidateBytes -State (New-Dlss5StateLines -Armed $true))
    Assert-Dlss5Equal (Assert-Dlss5ExecutingLocalIdentity -Executing $script:CandidateIdentity -Local $armed -Canonical $null -Trust $trust) 'sections' 'A section-only change by another window was not re-captured.'
    $untrusted = (New-Dlss5TrustFixture -Whole @{ $script:CandidateVersion = $script:CandidateIdentity.Sha256 }).Trust
    Assert-Dlss5Throws { $null = Assert-Dlss5ExecutingLocalIdentity -Executing $script:CandidateIdentity -Local $laterArmed -Canonical $laterPublished -Trust $untrusted } ([IO.InvalidDataException]) 'An untrusted newer game-local copy was accepted.'
}

Invoke-Dlss5Case 'package whole-file trust is recorded only for unedited DLSS packages' {
    $cases = [ordered]@{
        'published' = [pscustomobject]@{ Bytes = $script:CandidateBytes; Records = $true }
        'edited' = [pscustomobject]@{ Bytes = (New-Dlss5PackageVariant -Bytes $script:CandidateBytes -Files ([ordered]@{ 'INSTRUCTIONS.cleanup-boundary.md' = [byte[]](65) }) -State (New-Dlss5StateLines -MissionEdited $true)); Records = $false }
        'plain' = [pscustomobject]@{ Bytes = (New-Dlss5PlainPackageBytes); Records = $false }
    }
    foreach ($kind in $cases.Keys) {
        $case = $cases[$kind]
        $trust = Invoke-Dlss5PackageInteraction -Name ('package-record-' + $kind) -Bytes $case.Bytes -Action {
            param($PackagePath)
            $identity = Get-Dlss5BootstrapIdentity -Bytes ([IO.File]::ReadAllBytes($PackagePath))
            $lock = Enter-Dlss5BootstrapLock
            try { $admission = Invoke-Dlss5EngineAdmission -Identity $identity -State (Read-Dlss5SharedBootstrapState) -RecordWholeFile }
            finally { Exit-Dlss5BootstrapLock $lock }
            Assert-Dlss5Equal $admission 'first-use' "The $kind copy was not trusted on first use."

            return (Read-Dlss5TrustState).Trust
        }
        Assert-Dlss5Equal $trust.EngineEntries[$script:CandidateVersion] $script:CandidateIdentity.EngineSha256 "The $kind copy did not record its engine entry."
        Assert-Dlss5Equal $trust.Entries.ContainsKey($script:CandidateVersion) $case.Records "Whole-file recording for the $kind copy was wrong."
    }
}

Invoke-Dlss5Case 'package an open promotion question survives another window''s state write' {
    Invoke-Dlss5PackageInteraction -Name 'package-approval-stamp' -Bytes $script:CandidateBytes -Action {
        $state = Read-Dlss5SharedBootstrapState
        $laterBytes = New-Dlss5LaterVersionBytes
        $later = Get-Dlss5BootstrapIdentity -Bytes $laterBytes
        $stamp = Get-Dlss5ApprovalStamp -Local $later -State $state
        $armed = Get-Dlss5BootstrapIdentity -Bytes (New-Dlss5PackageVariant -Bytes $laterBytes -State (New-Dlss5StateLines -Armed $true))
        Assert-Dlss5Equal (Get-Dlss5ApprovalStamp -Local $armed -State $state) $stamp 'A state-only write reset an open promotion question.'
        $edited = Get-Dlss5BootstrapIdentity -Bytes (New-Dlss5PackageVariant -Bytes $laterBytes -Files ([ordered]@{ 'INSTRUCTIONS.cleanup-boundary.md' = [byte[]](65) }))
        Assert-Dlss5True ((Get-Dlss5ApprovalStamp -Local $edited -State $state) -cne $stamp) 'A mission edit kept an open promotion question.'
        Write-Dlss5MachineTrustFixture -MachineDirectory (Get-Dlss5StorePath) -Whole @{ $script:CandidateVersion = $script:CandidateIdentity.Sha256 }
        Assert-Dlss5True ((Get-Dlss5ApprovalStamp -Local $later -State (Read-Dlss5SharedBootstrapState)) -cne $stamp) 'A shared trust change kept an open promotion question.'
    }
}

Invoke-Dlss5Case 'package update record and box for a legacy predecessor and an unknown published mission' {
    $legacy = Get-Dlss5BootstrapIdentity -Bytes (New-Dlss5LegacyBytes)
    $trust = (New-Dlss5TrustFixture -Whole @{ 49 = $legacy.Sha256; $script:CandidateVersion = $script:CandidateIdentity.Sha256 }).Trust
    $updated = Get-Dlss5BootstrapIdentity -Bytes (New-Dlss5UpdatedCopyBytes -Local $legacy -Chosen $script:CandidateIdentity -Trust $trust)
    Assert-Dlss5True ($updated.State.Update.FromVersion -eq 49 -and $null -eq $updated.State.Update.FromMissionHash -and -not $updated.State.Update.ReplacedEdit -and -not $updated.State.Armed) 'A legacy predecessor''s update record is wrong.'
    $unknown = Get-Dlss5BootstrapIdentity -Bytes (New-Dlss5PackageVariant -Bytes $script:CandidateBytes -State (New-Dlss5StateLines -Update ([pscustomobject]@{ FromVersion = $script:CandidateVersion; FromMissionHash = $null; FromSha256 = ('d' * 64); ReplacedEdit = $false })))
    $saved = $script:Dlss5Console
    try {
        foreach ($case in @(@($updated, 'the previous version had none'), @($unknown, 'Whether the mission changed is unknown'))) {
            $script:Dlss5Console = New-Dlss5SubstitutedConsole @()
            Write-Dlss5ChangesBox -Identity $case[0] -Path 'C:\Games\X\DLSS5-ADDER.cmd'
            Assert-Dlss5True ($script:Dlss5Console.Output -join "`n").Contains($case[1]) "The box did not say: $($case[1])"
        }
    }
    finally { $script:Dlss5Console = $saved }
}

Invoke-Dlss5Case 'package update plan and record accept a pre-v23 adoption target' {
    $root = Join-Path $script:ScratchRoot 'package-pre-v23-target'
    $game = Join-Path $root 'game'
    New-Item -ItemType Directory -Force $game | Out-Null
    $targetPath = Join-Path $game 'DLSS5-ADDER.cmd'
    $v22Bytes = [IO.File]::ReadAllBytes((Join-Path $PSScriptRoot 'fixtures\DLSS5-ADDER.v22.cmd'))
    [IO.File]::WriteAllBytes($targetPath, $v22Bytes)
    Invoke-Dlss5WithLocalAppData -Path (Join-Path $root 'localappdata') -Action {
        $local = Read-Dlss5InstalledBootstrap -Path $targetPath -GamePath -AllowLegacy
        $v22Sha256 = [Convert]::ToHexStringLower([Security.Cryptography.SHA256]::HashData($v22Bytes))
        Assert-Dlss5True ($local.Version -eq 22 -and -not $local.Sectioned -and $local.Sha256 -ceq $v22Sha256 -and $local.PublishedSha256 -ceq $v22Sha256) 'A pre-v23 target did not read as a whole-file legacy identity.'
        Assert-Dlss5True ((Test-Dlss5ByteEquality -Left ([byte[]]$local.Bytes) -Right $v22Bytes) -and (Test-Dlss5ByteEquality -Left ([byte[]]$local.PublishedBytes) -Right $v22Bytes)) 'A pre-v23 target does not carry the file''s own bytes.'
        foreach ($trusted in @($true, $false)) {
            $whole = @{ $script:CandidateVersion = $script:CandidateIdentity.Sha256 }
            if ($trusted) { $whole[22] = $v22Sha256 }
            $trust = (New-Dlss5TrustFixture -Whole $whole).Trust
            $plan = Get-Dlss5CopyUpdatePlan -Local $local -Gate ([pscustomobject]@{ Tracked = $true; Backup = $false; BackupTracked = $false; State = 'x' }) -Trust $trust
            Assert-Dlss5True (-not $plan.Skip -and $plan.Backup -ne $trusted) "A pre-v23 target's backup plan did not follow its whole-file entry (trusted: $trusted)."
            $record = (Get-Dlss5BootstrapIdentity -Bytes (New-Dlss5UpdatedCopyBytes -Local $local -Chosen $script:CandidateIdentity -Trust $trust)).State.Update
            Assert-Dlss5True ($record.FromVersion -eq 22 -and $null -eq $record.FromMissionHash -and $record.ReplacedEdit -ne $trusted) "A pre-v23 target's update record is wrong (trusted: $trusted)."
        }
    }
}

Invoke-Dlss5Case 'package reads a v49 stage and refuses a stage that is not a clean DLSS package' {
    $legacyBytes = New-Dlss5LegacyBytes
    $laterBytes = New-Dlss5LaterVersionBytes
    $cases = [ordered]@{
        'legacy' = [pscustomobject]@{ Bytes = $legacyBytes; Kind = 'trusted' }
        'armed' = [pscustomobject]@{ Bytes = (New-Dlss5PackageVariant -Bytes $laterBytes -State (New-Dlss5StateLines -Armed $true)); Kind = 'blocked' }
        'plain' = [pscustomobject]@{ Bytes = (New-Dlss5PackageVariant -Bytes $laterBytes -Files ([ordered]@{ 'PROJECT.json' = $script:PackageUtf8.GetBytes('{"mission_id":"hello-world","rerun":false}') })); Kind = 'blocked' }
        'unknown project key' = [pscustomobject]@{ Bytes = (New-Dlss5PackageVariant -Bytes $laterBytes -Files ([ordered]@{ 'PROJECT.json' = $script:PackageUtf8.GetBytes('{"mission_id":"dlss5","rerun":true,"approval_mode":"manual"}' + $script:PackageNewline) })); Kind = 'trusted' }
    }
    foreach ($name in $cases.Keys) {
        $case = $cases[$name]
        $stage = Invoke-Dlss5PackageInteraction -Name ('package-stage-' + $name.Replace(' ', '-')) -Bytes $script:CandidateBytes -Action {
            $null = Write-Dlss5StageFixture -MachineDirectory (Get-Dlss5StorePath) -Bytes $case.Bytes

            return (Read-Dlss5SharedBootstrapState).Stage
        }
        Assert-Dlss5Equal $stage.Kind $case.Kind "The $name stage was classified wrongly."
    }
}

Invoke-Dlss5Case 'package diagnosis startup with unavailable shared paths accepts the engine entry it derives' {
    Invoke-Dlss5PackageInteraction -Name 'package-diagnosis-unavailable' -Bytes $script:CandidateBytes -Action {
        param($PackagePath)
        Write-Dlss5MachineTrustFixture -MachineDirectory (Get-Dlss5StorePath) -Whole @{ $script:CandidateVersion = $script:CandidateIdentity.Sha256 }
        # A file where the updates folder belongs makes the shared paths unavailable.
        [IO.File]::WriteAllText((Get-Dlss5StorePath 'updates'), "not a directory`r`n")
        $local = Read-Dlss5InstalledBootstrap -Path $PackagePath -GamePath
        $diagnosis = [pscustomobject]@{ Reason = 'git-unavailable'; Evidence = 'fixture' }
        $priorOut = [Console]::Out
        try {
            [Console]::SetOut([IO.StringWriter]::new())
            $started = Invoke-Dlss5DiagnosisStartup -Path $PackagePath -Executing $local -Diagnosis $diagnosis -Reexecuted $false
        }
        finally { [Console]::SetOut($priorOut) }
        Assert-Dlss5Equal $started.Diagnosis.Reason 'git-unavailable' 'A diagnosis launch refused after deriving its engine entry.'
        Assert-Dlss5Equal (Read-Dlss5TrustState).Trust.EngineEntries[$script:CandidateVersion] $script:CandidateIdentity.EngineSha256 'The diagnosis launch did not derive its engine entry.'
    }
}

Invoke-Dlss5Case 'package Execute refuses a mission id other than the one startup ran for' {
    $armed = New-Dlss5PackageVariant -Bytes $script:CandidateBytes -State (New-Dlss5StateLines -Armed $true)
    Invoke-Dlss5PackageInteraction -Name 'package-execute-mission-id' -Bytes $armed -Action {
        param($PackagePath)
        $saved = Get-Variable -Name Dlss5StartupMissionId -Scope Script -ValueOnly -ErrorAction SilentlyContinue
        try {
            # As after a plain mission's startup whose window then absorbed a DLSS mission.
            $script:Dlss5StartupMissionId = 'hello-world'
            $script:Dlss5Console = New-Dlss5SubstitutedConsole @()
            Assert-Dlss5Equal (Invoke-Dlss5Execute -Path $PackagePath) $script:Dlss5RefusedExitCode 'Execute ran a mission of another kind than startup ran for.'
            Assert-Dlss5True ($script:Dlss5Console.Output -join "`n").Contains('a different kind of mission than this window started with') 'Execute did not say why it refused.'
        }
        finally { $script:Dlss5StartupMissionId = $saved }
    }
}

Invoke-Dlss5Case 'package absorb refuses a dropped file it cannot read safely' {
    Invoke-Dlss5PackageInteraction -Name 'package-absorb-unreadable' -Bytes $script:CandidateBytes -Action {
        param($PackagePath, $Game)
        $folder = Join-Path $Game 'edited'
        New-Item -ItemType Directory -Force $folder | Out-Null
        $oversized = Join-Path $folder 'MISSION.md'
        [IO.File]::WriteAllBytes($oversized, [byte[]]::new(2MB + 1))
        $script:Dlss5Console = New-Dlss5SubstitutedConsole @()
        Assert-Dlss5Equal (Invoke-Dlss5Absorb -Path $PackagePath -Files @($oversized) -Headless) $script:Dlss5RefusedExitCode 'Absorb did not refuse an oversized dropped file.'
        Assert-Dlss5True ($script:Dlss5Console.Output -join "`n").Contains('Absorb refused: ' + $oversized + ' cannot be read safely') 'Absorb did not say which file it could not read.'
        Assert-Dlss5True (Test-Dlss5ByteEquality -Left ([IO.File]::ReadAllBytes($PackagePath)) -Right $script:CandidateBytes) 'A refused absorb changed the package.'
        Assert-Dlss5True (Test-Path -LiteralPath $oversized) 'A refused absorb removed the dropped file.'
    }
}

Invoke-Dlss5Case 'package explode never overwrites a file created after its check' {
    foreach ($kind in @('file', 'directory')) {
        Invoke-Dlss5PackageInteraction -Name ('package-explode-race-' + $kind) -Bytes $script:CandidateBytes -Action {
            param($PackagePath, $Game)
            $late = Join-Path $Game @($script:Dlss5ExecutingIdentity.MissionFiles.Keys)[-1]
            # The console output creates the last mission file, or a folder of that name, as soon as the first file is reported written, as an editor could.
            $output = [pscustomobject]@{ Lines = [Collections.Generic.List[string]]::new(); Late = $late; Kind = $kind }
            $output | Add-Member -MemberType ScriptMethod -Name Add -Value {
                param($Text)
                $this.Lines.Add($Text)
                if (-not $Text.StartsWith('Wrote ', [StringComparison]::Ordinal) -or (Test-Path -LiteralPath $this.Late)) { return }
                if ($this.Kind -ceq 'file') { [IO.File]::WriteAllText($this.Late, 'user content') } else { $null = [IO.Directory]::CreateDirectory($this.Late) }
            }
            $script:Dlss5Console = [pscustomobject]@{ Queue = [Collections.Generic.List[object]]::new(); Output = $output }
            Assert-Dlss5Equal (Invoke-Dlss5Explode -Path $PackagePath -Headless) $script:Dlss5RefusedExitCode "Explode did not refuse a $kind created after its check."
            if ($kind -ceq 'file') { Assert-Dlss5Equal ([IO.File]::ReadAllText($late)) 'user content' 'Explode overwrote a file created after its check.' }
            else { Assert-Dlss5True ([IO.Directory]::Exists($late)) 'Explode replaced a folder created after its check.' }
            Assert-Dlss5True ($output.Lines -join "`n").Contains('Explode stopped at ' + $late) "Explode did not report where it stopped for a $kind."
        }
    }
}

Invoke-Dlss5Case 'package menu and new-package box act only on Enter, and the box is modal' {
    $keys = { param($List) $script:Dlss5Console = New-Dlss5SubstitutedConsole $List }
    $read = { param($PackagePath) Get-Dlss5BootstrapIdentity -Bytes ([IO.File]::ReadAllBytes($PackagePath)) -Strict }
    Invoke-Dlss5PackageInteraction -Name 'package-menu' -Bytes $script:CandidateBytes -Action {
        param($PackagePath)
        # Enter with nothing highlighted does nothing, and a menu shortcut cannot leave the box.
        & $keys @('Enter', 'x', 'Enter', 'Escape')
        Assert-Dlss5Equal (Invoke-Dlss5Menu -Path $PackagePath) 0 'Esc did not close the box.'
        Assert-Dlss5True (& $read $PackagePath).State.Empty 'The box acted without a highlighted choice, or let a menu choice through.'
        Assert-Dlss5True (-not ($script:Dlss5Console.Output -join "`n").Contains('Wrote ')) 'Explode ran from inside the box.'
        & $keys @('k', 'Enter', 'Escape')
        Assert-Dlss5Equal (Invoke-Dlss5Menu -Path $PackagePath) 0 'Keep disarmed did not return to the menu.'
        $identity = & $read $PackagePath
        Assert-Dlss5True (-not $identity.State.Empty -and -not $identity.State.Armed) 'Keep disarmed did not write an explicit disarmed state.'
        Assert-Dlss5True ($script:Dlss5Console.Output -join "`n").Contains('[a] Arm') 'The menu after the box did not offer Arm.'
        # Arm asks for confirmation, which defaults to cancel.
        & $keys @('a', 'Enter', 'Enter', 'Escape')
        $null = Invoke-Dlss5Menu -Path $PackagePath
        Assert-Dlss5True (-not (& $read $PackagePath).State.Armed) 'Arm acted without confirmation.'
        & $keys @('a', 'Enter', 'y', 'Enter', 'Escape')
        $null = Invoke-Dlss5Menu -Path $PackagePath
        $armed = & $read $PackagePath
        Assert-Dlss5True $armed.State.Armed 'A confirmed Arm did not arm.'
        Assert-Dlss5True ($armed.EngineSha256 -ceq $script:CandidateIdentity.EngineSha256 -and $armed.MissionSha256 -ceq $script:CandidateIdentity.MissionSha256) 'Arming changed the engine or mission hash.'
        & $keys @('s', 'Enter', 'Escape')
        $null = Invoke-Dlss5Menu -Path $PackagePath
        $disarmed = & $read $PackagePath
        Assert-Dlss5True (-not $disarmed.State.Armed -and $disarmed.MissionSha256 -ceq $script:CandidateIdentity.MissionSha256) 'Disarm did not disarm, or changed the mission hash.'
    }
}

Invoke-Dlss5Case 'package box is informational and section writes refuse under the diagnosis condition' {
    $diagnosis = [pscustomobject]@{ Reason = 'git-unavailable'; Evidence = 'fixture' }
    Invoke-Dlss5PackageInteraction -Name 'package-box-diagnosis' -Bytes $script:CandidateBytes -Diagnosis $diagnosis -Action {
        param($PackagePath)
        $script:Dlss5Console = New-Dlss5SubstitutedConsole @('Escape')
        Assert-Dlss5Equal (Invoke-Dlss5Menu -Path $PackagePath) 0 'Esc did not close the menu.'
        $text = $script:Dlss5Console.Output -join "`n"
        Assert-Dlss5True ($text.Contains("What's changed") -and $text.Contains('These choices return once this is resolved') -and $text.Contains('[d] Diagnose') -and -not $text.Contains('Accept and re-arm')) "The box was not informational under the diagnosis condition: $text"
        Assert-Dlss5Throws { $null = Set-Dlss5GatedArm -Path $PackagePath } ([InvalidOperationException]) 'A section write was accepted under the diagnosis condition.'
    }
    # Headless Execute is refused in favor of Diagnose even on an armed copy.
    $armed = New-Dlss5PackageVariant -Bytes $script:CandidateBytes -State (New-Dlss5StateLines -Armed $true)
    Invoke-Dlss5PackageInteraction -Name 'package-execute-diagnosis' -Bytes $armed -Diagnosis $diagnosis -Action {
        param($PackagePath)
        $script:Dlss5Console = New-Dlss5SubstitutedConsole @()
        $code = Invoke-Dlss5PackageItem -Path $PackagePath -Request ([pscustomobject]@{ Item = '--internal-execute'; Expect = $null; Folder = $null })
        Assert-Dlss5Equal $code $script:Dlss5RefusedExitCode 'Headless Execute ran under the diagnosis condition.'
        Assert-Dlss5True ($script:Dlss5Console.Output -join "`n").Contains('only --internal-diagnose runs') 'Headless Execute did not point to Diagnose.'
    }
}

Invoke-Dlss5Case 'package section writes refuse while the Git gate refuses' {
    $fixture = New-Dlss5GitFixture 'package-gate-block'
    [IO.File]::WriteAllBytes($fixture.Updater, $script:CandidateBytes)
    [void](Invoke-Dlss5Git -Repository $fixture.Root add -- 'Game/DLSS5-ADDER.cmd')
    [void](Invoke-Dlss5Git -Repository $fixture.Root commit -m 'test: track package')
    [IO.File]::WriteAllBytes($fixture.Updater, (New-Dlss5PackageVariant -Bytes $script:CandidateBytes -Files ([ordered]@{ 'INSTRUCTIONS.cleanup-boundary.md' = [byte[]](65) }) -State (New-Dlss5StateLines -MissionEdited $true)))
    $block = Invoke-Dlss5WithLocalAppData -Path (Join-Path $fixture.Root 'LocalAppData') -Action {
        $saved = Get-Variable -Name Dlss5Startup -Scope Script -ValueOnly -ErrorAction SilentlyContinue
        try {
            $script:Dlss5Startup = [pscustomobject]@{ Diagnosis = $null }
            Write-Dlss5MachineTrustFixture -MachineDirectory (Get-Dlss5StorePath) -Whole @{ $script:CandidateVersion = $script:CandidateIdentity.Sha256 }
            Get-Dlss5SectionWriteBlock $fixture.Updater
        }
        finally { $script:Dlss5Startup = $saved }
    }
    Assert-Dlss5True $block.StartsWith('The Git check refuses changes to this package', [StringComparison]::Ordinal) "A refusing Git gate did not block section writes: [$block]"
    # Unreadable trust records also block section writes, without blaming Git.
    $block = Invoke-Dlss5PackageInteraction -Name 'package-block-notes' -Bytes $script:CandidateBytes -Action {
        param($PackagePath)
        [IO.File]::WriteAllBytes((Get-Dlss5StorePath 'DLSS5_MACHINE_NOTES.md'), [byte[]](0xFF, 0x0D, 0x0A))

        return Get-Dlss5SectionWriteBlock $PackagePath
    }
    Assert-Dlss5True $block.StartsWith('The package or this machine''s trust records cannot be read', [StringComparison]::Ordinal) "Unreadable trust records did not block section writes with their own message: [$block]"
}

Invoke-Dlss5Case 'package drop confirmation, cancellation, duplicate names, verification failure and deletion of originals' {
    Invoke-Dlss5PackageInteraction -Name 'package-drop-flow' -Bytes $script:CandidateBytes -Action {
        param($PackagePath, $Game)
        $edits = Join-Path (Split-Path -Parent $Game) 'edits'
        $other = Join-Path (Split-Path -Parent $Game) 'other'
        New-Item -ItemType Directory -Force $edits, $other | Out-Null
        $source = Join-Path $edits 'INSTRUCTIONS.cleanup-boundary.md'
        $content = $script:PackageUtf8.GetBytes("## Edited by drop`r`n")
        [IO.File]::WriteAllBytes($source, $content)
        $before = [IO.File]::ReadAllBytes($PackagePath)
        $unchanged = { Assert-Dlss5True (Test-Dlss5ByteEquality -Left ([IO.File]::ReadAllBytes($PackagePath)) -Right $before) $args[0]; Assert-Dlss5True (Test-Path -LiteralPath $source) 'A dropped file was removed.' }
        $script:Dlss5Console = New-Dlss5SubstitutedConsole @('Enter')
        Assert-Dlss5Equal (Invoke-Dlss5Absorb -Path $PackagePath -Files @($source)) 0 'A cancelled drop failed.'
        Assert-Dlss5True ($script:Dlss5Console.Output -join "`n").Contains('Absorb cancelled') 'Enter did not cancel the drop confirmation.'
        & $unchanged 'A cancelled drop changed the package.'
        $twin = Join-Path $other 'INSTRUCTIONS.cleanup-boundary.md'
        [IO.File]::WriteAllBytes($twin, $content)
        $script:Dlss5Console = New-Dlss5SubstitutedConsole @()
        Assert-Dlss5Equal (Invoke-Dlss5Absorb -Path $PackagePath -Files @($source, $twin)) 8 'Two dropped files with one name were accepted.'
        & $unchanged 'A refused duplicate drop changed the package.'
        # A verification that reads back different bytes refuses the write. Only the read-back of the new body is corrupted, so the
        # package's own identity reads stay intact.
        $script:PackageMissionReader = ${function:ConvertFrom-Dlss5MissionBody}
        $script:PackageDroppedContent = $content
        Set-Item -Path 'function:script:ConvertFrom-Dlss5MissionBody' -Value {
            param($Body)
            $files = & $script:PackageMissionReader $Body
            if ($files.Contains('INSTRUCTIONS.cleanup-boundary.md') -and (Test-Dlss5ByteEquality -Left ([byte[]]$files['INSTRUCTIONS.cleanup-boundary.md']) -Right $script:PackageDroppedContent)) { $files['INSTRUCTIONS.cleanup-boundary.md'] = [byte[]](0) }

            return $files
        }
        try {
            $script:Dlss5Console = New-Dlss5SubstitutedConsole @('y', 'Enter')
            Assert-Dlss5Equal (Invoke-Dlss5Absorb -Path $PackagePath -Files @($source)) 8 'A drop whose verification failed was accepted.'
            Assert-Dlss5True ($script:Dlss5Console.Output -join "`n").Contains('Absorb verification failed for INSTRUCTIONS.cleanup-boundary.md') "The drop was refused for another reason: $($script:Dlss5Console.Output -join ' | ')"
        }
        finally { Set-Item -Path 'function:script:ConvertFrom-Dlss5MissionBody' -Value $script:PackageMissionReader }
        & $unchanged 'A drop whose verification failed changed the package.'
        $script:Dlss5Console = New-Dlss5SubstitutedConsole @('y', 'Enter')
        $code = Invoke-Dlss5Absorb -Path $PackagePath -Files @($source)
        Assert-Dlss5Equal $code 0 "A confirmed drop failed: $($script:Dlss5Console.Output -join ' | ')"
        Assert-Dlss5True (-not (Test-Path -LiteralPath $source)) 'A confirmed drop kept its original.'
        $after = Get-Dlss5BootstrapIdentity -Bytes ([IO.File]::ReadAllBytes($PackagePath)) -Strict
        Assert-Dlss5True ((Test-Dlss5ByteEquality -Left ([byte[]]$after.MissionFiles['INSTRUCTIONS.cleanup-boundary.md']) -Right $content) -and $after.State.MissionEdited -and -not $after.State.Armed) 'The confirmed drop was not absorbed.'
        # An original changed after it was read is kept.
        $changed = Join-Path $edits 'MISSION.md'
        [IO.File]::WriteAllText($changed, 'read')
        $snapshot = Get-Dlss5PathSnapshot -Path $changed -GamePath
        $bytes = [IO.File]::ReadAllBytes($changed)
        [IO.File]::WriteAllText($changed, 'changed after reading')
        Assert-Dlss5Throws { Remove-Dlss5GuardedFile -Snapshot $snapshot -ExpectedBytes $bytes } ([Exception]) 'An original changed after reading was deleted.'
        Assert-Dlss5True (Test-Path -LiteralPath $changed) 'An original changed after reading is gone.'
    }
}

Invoke-Dlss5Case 'package first-use trust of a plain mission is asked and a decline refuses' {
    foreach ($answer in @('decline', 'accept')) {
        $result = Invoke-Dlss5PackageInteraction -Name ('package-first-use-' + $answer) -Bytes (New-Dlss5PlainPackageBytes) -Action {
            param($PackagePath)
            $script:Dlss5Console = New-Dlss5SubstitutedConsole $(if ($answer -ceq 'accept') { @('y', 'Enter') } else { @('Enter') })
            $executing = Get-Dlss5BootstrapIdentity -Bytes ([IO.File]::ReadAllBytes($PackagePath)) -Strict
            try { $startup = Invoke-Dlss5PlainStartup -Path $PackagePath -Executing $executing; $outcome = 'trusted' }
            catch [IO.InvalidDataException] { $outcome = 'refused' }

            return [pscustomobject]@{ Outcome = $outcome; Asked = ($script:Dlss5Console.Output -join "`n").Contains('Trust the engine of this hello-world package'); Trust = (Read-Dlss5TrustState).Trust }
        }
        Assert-Dlss5True $result.Asked "The $answer case was not asked about first-use trust."
        if ($answer -ceq 'accept') { Assert-Dlss5True ($result.Outcome -ceq 'trusted' -and $result.Trust.EngineEntries[$script:CandidateVersion] -ceq $script:CandidateIdentity.EngineSha256) 'An accepted first-use question did not record the engine entry.' }
        else { Assert-Dlss5True ($result.Outcome -ceq 'refused' -and -not $result.Trust.EngineEntries.ContainsKey($script:CandidateVersion)) 'A declined first-use question did not refuse, or recorded trust.' }
    }
}

Invoke-Dlss5Case 'package Execute refuses a mission changed since it was shown' {
    $edited = New-Dlss5PackageVariant -Bytes $script:CandidateBytes -Files ([ordered]@{ 'INSTRUCTIONS.cleanup-boundary.md' = [byte[]](65) }) -State (New-Dlss5StateLines -Armed $true)
    Invoke-Dlss5PackageInteraction -Name 'package-execute-stale' -Bytes $edited -Action {
        param($PackagePath)
        $script:Dlss5Console = New-Dlss5SubstitutedConsole @()
        $expect = [pscustomobject]@{ Version = $script:CandidateVersion; EngineSha256 = $script:CandidateIdentity.EngineSha256; MissionSha256 = $script:CandidateIdentity.MissionSha256 }
        Assert-Dlss5Equal (Invoke-Dlss5Execute -Path $PackagePath -Expect $expect) 8 'Execute ran a mission other than the one shown.'
        Assert-Dlss5True ($script:Dlss5Console.Output -join "`n").Contains('The mission changed in another window') 'The stale-mission refusal was not reported.'
    }
}

Invoke-Dlss5Case 'package a command-line task under the diagnosis condition starts the diagnosis session on a disarmed copy and carries the task' {
    $fixture = New-Dlss5IsolatedLaunchFixture -Name 'package-diagnosis-task' -StubBody @('if not defined DLSS5_TEST_PROMPT_CAPTURE_PATH exit /b 0', 'copy /b "%LOCALAPPDATA%\DLSS5-ADDER\prompts\dlss5-agent-prompt-*.md" "%DLSS5_TEST_PROMPT_CAPTURE_PATH%" >nul', 'exit /b 0')
    # A first normal launch records trust for the executing copy, which a diagnosis-only launch requires; the copy is then disarmed.
    [void](Invoke-Dlss5IsolatedLaunch -Fixture $fixture)
    [IO.File]::WriteAllBytes($fixture.Updater, (New-Dlss5PackageVariant -Bytes ([IO.File]::ReadAllBytes($fixture.Updater)) -State (New-Dlss5StateLines)))
    New-Item -ItemType Directory -Force (Join-Path $fixture.Game '.git') | Out-Null
    $capture = Join-Path $fixture.StubRoot 'prompt.txt'
    $process = Invoke-Dlss5IsolatedLaunch -Fixture $fixture -Arguments @('check {{host}} please') -Environment @{ PATH = (Get-Dlss5PathWithoutGit); DLSS5_TEST_PROMPT_CAPTURE_PATH = $capture }
    Assert-Dlss5Equal $process.ExitCode 0 "A diagnosis task on a disarmed copy did not run: $($process.StandardOutput) $($process.StandardError)"
    Assert-Dlss5True $process.StandardOutput.Contains('DLSS 5 ADDER diagnosis-only session:', [StringComparison]::Ordinal) 'The task did not start the diagnosis-only session.'
    $prompt = [IO.File]::ReadAllText($capture, [Text.UTF8Encoding]::new($false, $true))
    Assert-Dlss5True ($prompt.Contains('session_mode: diagnosis-only') -and $prompt.Contains('check {{host}} please')) 'The diagnosis prompt did not carry the task text verbatim.'
}

Invoke-Dlss5Case 'package a malformed executing copy refuses with recovery guidance and still dumps its mission' {
    $fixture = New-Dlss5IsolatedLaunchFixture -Name 'package-malformed'
    $project = $script:PackageUtf8.GetBytes('{"mission_id":"dlss5","rerun":true,"unknown_later_field":"manual"}' + $script:PackageNewline)
    [IO.File]::WriteAllBytes($fixture.Updater, (New-Dlss5PackageVariant -Bytes $script:CandidateBytes -Files ([ordered]@{ 'PROJECT.json' = $project })))
    $process = Invoke-Dlss5IsolatedLaunch -Fixture $fixture -Arguments @('--internal-status')
    Assert-Dlss5Equal $process.ExitCode 4 'A malformed executing copy ran.'
    Assert-Dlss5True ($process.StandardError.Contains('This DLSS5-ADDER.cmd is damaged') -and $process.StandardError.Contains('.bkp or download the published file again')) "The malformed copy did not give recovery guidance: $($process.StandardError)"
    $dump = Join-Path $fixture.Root 'dump'
    $dumped = Invoke-Dlss5IsolatedLaunch -Fixture $fixture -Arguments @('--dump-payload', $dump)
    Assert-Dlss5Equal $dumped.ExitCode 0 "The malformed copy's mission was not dumped: $($dumped.StandardError)"
    Assert-Dlss5True (Test-Dlss5ByteEquality -Left ([IO.File]::ReadAllBytes((Join-Path $dump 'PROJECT.json'))) -Right $project) 'The dumped project file differs from the embedded one.'
    # A project file that is not valid JSON is damage too, both in the executing copy and in the shared slot.
    # The package writers refuse such a file, so its base64 line is swapped in the bytes, as a hand edit would, starting from a project
    # short enough to be one base64 line.
    $shortProject = $script:PackageUtf8.GetBytes('{"mission_id":"dlss5","rerun":true}' + $script:PackageNewline)
    $packageText = $script:PackageUtf8.GetString((New-Dlss5PackageVariant -Bytes $script:CandidateBytes -Files ([ordered]@{ 'PROJECT.json' = $shortProject })))
    $projectLine = [Convert]::ToBase64String($shortProject)
    Assert-Dlss5True ($projectLine.Length -le 76 -and $packageText.Split($projectLine).Length -eq 2) 'The project file is not one unique base64 line.'
    $broken = $script:PackageUtf8.GetBytes($packageText.Replace($projectLine, [Convert]::ToBase64String($script:PackageUtf8.GetBytes('{"mission_id":'))))
    [IO.File]::WriteAllBytes($fixture.Updater, $broken)
    $process = Invoke-Dlss5IsolatedLaunch -Fixture $fixture -Arguments @('--internal-status')
    Assert-Dlss5Equal $process.ExitCode 4 'A copy with a broken project file ran.'
    Assert-Dlss5True ($process.StandardError.Contains('This DLSS5-ADDER.cmd is damaged') -and $process.StandardError.Contains('.bkp or download the published file again')) "The copy with a broken project file did not give recovery guidance: $($process.StandardError)"
    $state = Invoke-Dlss5PackageInteraction -Name 'package-malformed-slot' -Bytes $script:CandidateBytes -Action {
        [IO.File]::WriteAllBytes((Get-Dlss5StorePath 'DLSS5-ADDER.cmd'), $broken)

        return Read-Dlss5SharedBootstrapState -AllowMalformedCanonical -AllowUnavailable
    }
    Assert-Dlss5True ($state.CanonicalMalformed -and -not $state.RemoteUnavailable) 'A slot with a broken project file was not classified as malformed.'
}

Invoke-Dlss5Case 'package the shared copy updated from a newer stage stays in published form with no .bkp' {
    $localAppData = Join-Path (Join-Path $script:ScratchRoot 'package-slot-stage') 'localappdata'
    $store = Join-Path $localAppData 'DLSS5-ADDER'
    $fixture = New-Dlss5IsolatedLaunchFixture -Name 'package-slot-stage' -GameDirectory $store
    $environment = @{ LOCALAPPDATA = $localAppData }
    $null = Get-Dlss5LaunchStatus $fixture -Environment $environment
    $laterBytes = New-Dlss5LaterVersionBytes
    $null = Write-Dlss5StageFixture -MachineDirectory $store -Bytes $laterBytes
    $status = Get-Dlss5LaunchStatus $fixture -Environment $environment
    Assert-Dlss5Equal ([int]$status.version) $script:LaterVersion 'The shared copy did not take the newer stage.'
    Assert-Dlss5True (Test-Dlss5ByteEquality -Left ([IO.File]::ReadAllBytes($fixture.Updater)) -Right $laterBytes) 'The updated shared copy is not the published form.'
    Assert-Dlss5True (-not (Test-Path -LiteralPath ($fixture.Updater + '.bkp'))) 'The shared copy got a .bkp.'
}

Invoke-Dlss5Case 'package a carried state-changing argument refuses after an update' {
    $fixture = New-Dlss5IsolatedLaunchFixture -Name 'package-carried-arm'
    $status = Get-Dlss5LaunchStatus $fixture
    $null = Write-Dlss5StageFixture -MachineDirectory $fixture.MachineDirectory -Bytes (New-Dlss5LaterVersionBytes)
    $process = Invoke-Dlss5IsolatedLaunch -Fixture $fixture -Arguments @('--internal-arm', $status.expect)
    Assert-Dlss5Equal $process.ExitCode 8 "A carried Arm was not refused after the update: $($process.StandardOutput) $($process.StandardError)"
    $after = Get-Dlss5BootstrapIdentity -Bytes ([IO.File]::ReadAllBytes($fixture.Updater))
    Assert-Dlss5True ($after.Version -eq $script:LaterVersion -and -not $after.State.Armed -and $null -ne $after.State.Update) 'The update did not leave a disarmed copy with a pending record.'
}
