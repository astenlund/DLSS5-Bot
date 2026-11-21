param([string]$Candidate = (Join-Path $PSScriptRoot '..\build\DLSS5-ADDER.cmd'), [string]$RecordDirectory = (Join-Path $env:LOCALAPPDATA 'DLSS5-ADDER\release-records\probes'))
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Live probe of the five launching approval-mode cells, run by the user: each cell opens the installed host in its own console window with
# the engine's mapped arguments, in a scratch folder, touching no store. The user checks that the host started, accepted the flags and shows
# the expected mode, and answers here. Answers and the exact arguments are recorded in the release folder. A failed cell stops the release
# for the user's decision.
. ([scriptblock]::Create((& (Join-Path $PSScriptRoot 'Get-PayloadDefinitions.ps1') -Path $Candidate))) -SelfPath $Candidate
$scratch = Join-Path $PSScriptRoot '..\.tmp\probe-scratch'
$null = New-Item -ItemType Directory -Force -Path $scratch
$task = 'This is a launch probe. Reply with the single word OK and do nothing else.'
$cells = @(
    @{ Host = 'claude'; Mode = 'default'; Expect = 'starts in its own configured permission mode' },
    @{ Host = 'claude'; Mode = 'manual'; Expect = 'shows the manual permission mode' },
    @{ Host = 'claude'; Mode = 'auto'; Expect = 'shows the auto permission mode' },
    @{ Host = 'codex'; Mode = 'default'; Expect = 'starts with its own configured approval policy' },
    @{ Host = 'codex'; Mode = 'auto'; Expect = 'shows approvals routed through automatic review (--approve-for-me)' }
)
$records = [Collections.Generic.List[object]]::new()
foreach ($cell in $cells) {
    $commands = @(Get-Command $cell.Host -CommandType Application -ErrorAction SilentlyContinue)
    if ($commands.Count -lt 1) { $records.Add([ordered]@{ host = $cell.Host; mode = $cell.Mode; result = 'host not installed' }); continue }
    $command = $commands[0].Source
    $json = '{"mission_id":"probe","rerun":false,"approval_mode":"' + $cell.Mode + '"}'
    $project = ConvertFrom-Dlss5ProjectConfig -Bytes ([Text.UTF8Encoding]::new($false, $true).GetBytes($json)) -Strict
    $script:Dlss5ExecutingIdentity = [pscustomobject]@{ Project = $project; Seed = $null; State = $null }
    $script:Dlss5SelectedAgent = [pscustomobject]@{ Kind = $cell.Host; Command = $command; Model = ''; Effort = 'medium' }
    $arguments = @(Get-Dlss5AgentPrefixArguments -Agent $command -GameDirectory $scratch -MachineDirectory $scratch) + @($task)
    Write-Host ''
    Write-Host ("Cell: {0} {1}" -f $cell.Host, $cell.Mode)
    Write-Host ('Arguments: ' + ($arguments -join ' | '))
    Write-Host ('Expect: the host ' + $cell.Expect + '. Close its window when done.')
    $info = [Diagnostics.ProcessStartInfo]::new($command)
    $info.UseShellExecute = $command.EndsWith('.cmd', [StringComparison]::OrdinalIgnoreCase)
    $info.WorkingDirectory = $scratch
    foreach ($argument in $arguments) { $info.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::Start($info)
    $process.WaitForExit()
    $answer = Read-Host 'Did the host start, accept the flags and show the expected mode? (y/n, or a note)'
    $records.Add([ordered]@{ host = $cell.Host; mode = $cell.Mode; arguments = $arguments; exit_code = $process.ExitCode; answer = $answer })
}
$versions = [ordered]@{}
foreach ($name in @('claude', 'codex')) { $found = @(Get-Command $name -CommandType Application -ErrorAction SilentlyContinue); if ($found.Count -gt 0) { $versions[$name] = (& $found[0].Source --version 2>&1 | Out-String).Trim() } }
$null = New-Item -ItemType Directory -Force -Path $RecordDirectory
$path = Join-Path $RecordDirectory ('probe-approval-' + (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ') + '.json')
[IO.File]::WriteAllText($path, (ConvertTo-Json -InputObject ([ordered]@{ probed_at = (Get-Date).ToUniversalTime().ToString('o'); versions = $versions; cells = $records }) -Depth 4) + "`r`n", [Text.UTF8Encoding]::new($false))
Remove-Item -Recurse -Force $scratch
"recorded $path"
