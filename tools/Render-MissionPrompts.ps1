param([Parameter(Mandatory)][string]$Package, [Parameter(Mandatory)][string]$OutputPath)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Renders a package's DLSS mission prompt in every mode, with and without a task, plus its instruction files, from fixed inputs,
# and writes them as one JSON object, so two packages can be compared in separate processes without their definitions colliding.
. ([scriptblock]::Create((& (Join-Path $PSScriptRoot 'Get-PayloadDefinitions.ps1') -Path $Package))) -SelfPath $Package
$utf8 = [Text.UTF8Encoding]::new($false, $true)
$identity = Get-Dlss5BootstrapIdentity -Bytes ([IO.File]::ReadAllBytes($Package)) -Strict
$template = Get-Dlss5MissionTemplate -Files $identity.MissionFiles -MissionId $identity.MissionId
$result = [ordered]@{}
foreach ($case in @(
    @{ Mode = 'default'; Task = ''; Diagnosis = $null },
    @{ Mode = 'task'; Task = 'fix the ### DLSS5_NOTIFICATION_SLOT ### {{host}} thing'; Diagnosis = $null },
    @{ Mode = 'diagnosis:git-unavailable'; Task = ''; Diagnosis = 'git-unavailable' },
    @{ Mode = 'diagnosis:git-unavailable'; Task = 'also check PATH'; Diagnosis = 'git-unavailable' },
    @{ Mode = 'diagnosis:git-inspection-failed'; Task = ''; Diagnosis = 'git-inspection-failed' },
    @{ Mode = 'diagnosis:git-inspection-failed'; Task = 'why'; Diagnosis = 'git-inspection-failed' }
)) {
    $diagnosis = $null -ne $case.Diagnosis
    $values = [ordered]@{ 'host' = 'claude'; 'model' = 'claude-opus-5-5'; 'effort' = 'medium'; 'package_path' = 'C:\Games\Some Game\DLSS5-ADDER.cmd'; 'package_dir' = 'C:\Games\Some Game'; 'game_notes_path' = 'C:\Games\Some Game\DLSS5-ADDER.md'; 'machine_notes_path' = 'C:\Store\DLSS5_MACHINE_NOTES.md'; 'project_knowledge_path' = 'C:\Store\DLSS5_PROJECT_KNOWLEDGE.md'; 'shared_agent_context_path' = 'C:\Store\AGENTS.md'; 'game_notes_begin_marker' = $GameNotesBeginMarker; 'game_notes_end_marker' = $GameNotesEndMarker; 'project_knowledge_begin_marker' = $ProjectKnowledgeBeginMarker; 'project_knowledge_end_marker' = $ProjectKnowledgeEndMarker; 'game_fingerprint' = 'fp-123'; 'game_name' = 'Some Game'; 'steam_appid' = '12345'; 'main_executables' = 'game.exe'; 'dlssnr_patcher_store' = 'C:\Store\dlssnr-patcher'; 'project_knowledge_status' = 'empty'; 'probe_status' = 'complete'; 'gpu_probe_status' = 'verified'; 'gpu_probe_path' = 'C:\Windows\System32\nvidia-smi.exe'; 'gpu_probe_evidence' = 'ok {{not a placeholder}}'; 'gpu' = 'NVIDIA GeForce RTX 5090'; 'gpu_generation' = 'RTX 50'; 'driver_version' = '600.10'; 'vram' = '32607 MiB'; 'cpu' = 'AMD Ryzen'; 'ram_mib' = '65536'; 'os' = 'Windows build 26300'; 'display_count' = '2'; 'display_topology_status' = 'verified'; 'display_facts' = 'active_display.1: test display'; 'bootstrap_version' = [string]$identity.Version; 'bootstrap_engine_sha256' = $identity.EngineSha256; 'mission_sha256' = $identity.MissionSha256; 'session_mode' = $(if ($diagnosis) { 'diagnosis-only' } else { 'normal' }); 'diagnosis_reason' = $(if ($diagnosis) { $case.Diagnosis } else { '' }); 'diagnosis_evidence' = $(if ($diagnosis) { 'evidence text' } else { '' }); 'transaction_preflight' = $(if ($diagnosis) { 'skipped: diagnosis-only' } else { 'passed' }); 'git_repository' = $(if ($diagnosis) { 'unavailable' } else { 'True' }); 'updater_tracked' = 'False'; 'session_snapshot_status' = 'captured'; 'session_snapshot_id' = 'b' * 32; 'expected_post_preflight_change' = $(if ($diagnosis) { 'external game notes only; no installation in this session' } else { 'external game notes only until installation begins' }) }
    # The engine store placeholders v53 adds; a package whose mission does not name them ignores the values.
    $values['engine_file_path'] = Join-Path 'C:\Store' 'engine' 'ENGINE.md'
    $values['location_record_path'] = Join-Path 'C:\Store' 'engine' 'locations' 'C-Games-Some-Game-0123456789abcdef' 'LOCATION.md'
    $values['transaction_status'] = ''
    $values['legacy_transaction_status'] = 'none'
    $values['orphaned_transaction_markers'] = 'none'
    # The generated store rules v57 added; an earlier package has no such function and its template names no such placeholder.
    if ($null -ne (Get-Command Get-Dlss5KeyedStoreRules -ErrorAction SilentlyContinue)) { $values['stores'] = Get-Dlss5KeyedStoreRules -Slots @('target', 'machine', 'knowledge') -EngineFilePath $values['engine_file_path'] }
    $promptId = [Guid]::NewGuid().ToString('N')
    foreach ($name in $template.Instructions) { $values['instruction:' + $name] = 'C:\Store\prompts\dlss5-agent-sections-' + $promptId + '\' + $name + '.md' }
    $result[$case.Mode + '|' + $case.Task] = Format-Dlss5MissionPrompt -Template $template -Mode $case.Mode -Values $values -Task $case.Task -NotificationBlock 'NOTIFICATION BLOCK'
}
foreach ($name in $identity.MissionFiles.Keys) { if ($name.StartsWith('INSTRUCTIONS.', [StringComparison]::Ordinal)) { $result['file|' + $name] = $utf8.GetString([byte[]]$identity.MissionFiles[$name]) } }
[IO.File]::WriteAllText($OutputPath, (ConvertTo-Json -InputObject $result -Depth 3), $utf8)
