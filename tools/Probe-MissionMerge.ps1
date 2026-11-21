param([string]$Candidate = (Join-Path $PSScriptRoot '..\build\DLSS5-ADDER.cmd'), [string]$RecordDirectory = (Join-Path $env:LOCALAPPDATA 'DLSS5-ADDER\release-records\probes'), [string[]]$Hosts = @('claude', 'codex'))
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Live probe of the mission merge, run by the user: for each installed host, a scratch store and game folder hold an edited copy of the
# candidate whose what's-changed box offers the candidate's mission, with the ancestor kept. The engine's own merge runs with the real
# host in its own window; the user lets the host merge, exits it and answers Apply. The probe's checks of the result and the user's
# answer are recorded in the release folder. The host keeps the user's real LOCALAPPDATA; only the engine's store is redirected.
. ([scriptblock]::Create((& (Join-Path $PSScriptRoot 'Get-PayloadDefinitions.ps1') -Path $Candidate))) -SelfPath $Candidate
$realLocalAppData = $env:LOCALAPPDATA
$utf8 = [Text.UTF8Encoding]::new($false, $true)
$candidateBytes = [IO.File]::ReadAllBytes($Candidate)
$release = Get-Dlss5BootstrapIdentity -Bytes $candidateBytes -Strict
$editLine = 'Probe edit: the user added this line, and the merge must keep it.'
$obsoleteLine = 'Obsolete probe rule: the release removed this line, and the merge must drop it.'

function Start-Dlss5AgentProcess {
    param([Parameter(Mandatory)][Diagnostics.ProcessStartInfo]$Info)

    # The engine's start, with the user's own LOCALAPPDATA for the host while it is created.
    $redirected = $env:LOCALAPPDATA
    $env:LOCALAPPDATA = $realLocalAppData
    try { return [Diagnostics.Process]::Start($Info) }
    finally { $env:LOCALAPPDATA = $redirected }
}

function Join-ProbeText([byte[]]$Bytes, [string]$Line) {
    return $utf8.GetBytes($utf8.GetString($Bytes).TrimEnd([char]13, [char]10) + "`r`n`r`n" + $Line + "`r`n")
}

$records = [Collections.Generic.List[object]]::new()
$scratchRoot = Join-Path $PSScriptRoot '..\.tmp\probe-merge-scratch'
foreach ($hostName in $Hosts) {
    $commands = @(Get-Command $hostName -CommandType Application -ErrorAction SilentlyContinue)
    if ($commands.Count -lt 1) { $records.Add([ordered]@{ host = $hostName; result = 'host not installed' }); continue }
    $root = Join-Path $scratchRoot $hostName
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    $game = Join-Path $root 'game'
    $null = New-Item -ItemType Directory -Force -Path (Join-Path $root 'localappdata\DLSS5-ADDER'), $game
    $packagePath = Join-Path $game 'DLSS5-ADDER.cmd'
    $env:LOCALAPPDATA = Join-Path $root 'localappdata'
    $env:DLSS5_AGENT_HOST = $commands[0].Source
    try {
        # The ancestor is the candidate's mission with one extra line the release removed; the edit adds a line to another file.
        $ancestor = [Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
        foreach ($name in $release.MissionFiles.Keys) { $ancestor[$name] = [byte[]]$release.MissionFiles[$name] }
        $ancestor['INSTRUCTIONS.settings-optimization.md'] = Join-ProbeText $ancestor['INSTRUCTIONS.settings-optimization.md'] $obsoleteLine
        $ancestorHash = Get-Dlss5MissionHash $ancestor
        $edited = [Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
        foreach ($name in $ancestor.Keys) { $edited[$name] = [byte[]]$ancestor[$name] }
        $edited['INSTRUCTIONS.cleanup-boundary.md'] = Join-ProbeText $edited['INSTRUCTIONS.cleanup-boundary.md'] $editLine
        $update = [pscustomobject]@{ FromVersion = $release.Version - 1; FromMissionHash = $ancestorHash; FromSha256 = ('d' * 64); ReplacedEdit = $false; BackupSha256 = $null; KeptMission = $true; OfferedMissionHash = $release.MissionSha256 }
        $state = [pscustomobject]@{ Empty = $false; Armed = $false; MissionEdited = $true; ReplacedMissionHash = $ancestorHash; Update = $update; Records = [object[]]@() }
        $copy = Set-Dlss5PackageSections -Bytes $candidateBytes -Bodies ([ordered]@{ MISSION = (ConvertTo-Dlss5MissionBody $edited); STATE = (ConvertTo-Dlss5StateBody $state) })
        [IO.File]::WriteAllBytes($packagePath, $copy)
        [IO.File]::WriteAllBytes((Get-Dlss5StorePath 'DLSS5-ADDER.cmd'), $candidateBytes)
        $lock = Enter-Dlss5BootstrapLock
        try {
            Write-Dlss5ImmutableTrust ([pscustomobject]@{ Version = $release.Version; PublishedSha256 = $release.Sha256; Sectioned = $false })
        }
        finally { Exit-Dlss5BootstrapLock $lock }
        Save-Dlss5MissionAncestor -Files $ancestor -MissionHash $ancestorHash
        $script:Dlss5ExecutingIdentity = Get-Dlss5BootstrapIdentity -Bytes $copy -Strict
        $script:Dlss5ExecutingEngineSha256 = $release.EngineSha256
        Write-Host ''
        Write-Host "Host: $hostName ($($commands[0].Source))"
        Write-Host 'The engine now starts the merge. Let the host write the merged mission, read its conflict report, exit the host, then choose Apply.'
        $message = ''
        try { Invoke-Dlss5MissionMerge -Path $packagePath -ExpectMission $script:Dlss5ExecutingIdentity.MissionSha256 -Offered $release.MissionSha256 }
        catch { $message = $_.Exception.Message }
        $after = Get-Dlss5BootstrapIdentity -Bytes ([IO.File]::ReadAllBytes($packagePath)) -Strict
        $cleanup = $utf8.GetString([byte[]]$after.MissionFiles['INSTRUCTIONS.cleanup-boundary.md'])
        $settings = [byte[]]$after.MissionFiles['INSTRUCTIONS.settings-optimization.md']
        $checks = [ordered]@{
            refusal = $message
            applied = ($after.State.ReplacedMissionHash -ceq $release.MissionSha256 -and $null -eq $after.State.Update -and $after.State.MissionEdited)
            edit_kept = $cleanup.Contains($editLine)
            release_change_taken = [Linq.Enumerable]::SequenceEqual[byte]($settings, [byte[]]$release.MissionFiles['INSTRUCTIONS.settings-optimization.md'])
            # MISSION.md is the same in every input, so the merged copy must hold it byte for byte.
            mission_md_exact = [Linq.Enumerable]::SequenceEqual[byte]([byte[]]$after.MissionFiles['MISSION.md'], [byte[]]$release.MissionFiles['MISSION.md'])
            backup_kept = (Test-Path -LiteralPath ($packagePath + '.bkp'))
            scratch_removed = (@(Get-ChildItem -LiteralPath (Get-Dlss5StorePath 'updates') -Directory -Filter 'mission-merge-*' -ErrorAction SilentlyContinue).Count -eq 0)
            ancestor_kept = ($null -ne (Read-Dlss5MissionAncestor $release.MissionSha256).Files)
        }
        $checks.GetEnumerator() | ForEach-Object { Write-Host ('  {0}: {1}' -f $_.Key, $_.Value) }
        $answer = Read-Host 'Did the host merge in its own window, report the conflicts and stay inside the scratch folder? (y/n, or a note)'
        $version = (& $commands[0].Source --version 2>&1 | Out-String).Trim()
        $records.Add([ordered]@{ host = $hostName; host_version = $version; checks = $checks; answer = $answer })
    }
    finally {
        $env:LOCALAPPDATA = $realLocalAppData
        Remove-Item Env:DLSS5_AGENT_HOST -ErrorAction SilentlyContinue
    }
}
$null = New-Item -ItemType Directory -Force -Path $RecordDirectory
$path = Join-Path $RecordDirectory ('probe-merge-' + (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ') + '.json')
[IO.File]::WriteAllText($path, (ConvertTo-Json -InputObject ([ordered]@{ probed_at = (Get-Date).ToUniversalTime().ToString('o'); candidate_sha256 = $release.Sha256; hosts = $records }) -Depth 5) + "`r`n", [Text.UTF8Encoding]::new($false))
if (Test-Path -LiteralPath $scratchRoot) { Remove-Item -LiteralPath $scratchRoot -Recurse -Force }
"recorded $path"
