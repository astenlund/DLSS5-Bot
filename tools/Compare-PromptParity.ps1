param([Parameter(Mandatory)][string]$Baseline, [string]$Candidate = (Join-Path $PSScriptRoot '..\build\DLSS5-ADDER.cmd'), [Parameter(Mandatory)][string]$PairsFile)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Renders the baseline's and the candidate's DLSS mission prompts from identical inputs in every mode, with and without a task, each in its own process,
# and requires them to match after normalizing exactly the per-release identity (bootstrap_version, the bootstrap_engine_sha256 and
# mission_sha256 lines, and the per-launch prompt id in the section folder name) and the before/after pairs in prompt-changes.json.
# The instruction files are compared the same way.
$work = Join-Path $PSScriptRoot '..\.tmp\parity'
$null = New-Item -ItemType Directory -Force -Path $work
$renders = @{}
foreach ($side in @(@('baseline', $Baseline), @('candidate', $Candidate))) {
    $output = Join-Path $work ($side[0] + '.json')
    & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'Render-MissionPrompts.ps1') -Package $side[1] -OutputPath $output
    if ($LASTEXITCODE -ne 0) { throw "Rendering failed for $($side[1])." }
    $renders[$side[0]] = Get-Content -Raw -LiteralPath $output | ConvertFrom-Json -AsHashtable
}
$newline = [string][char]13 + [char]10
$pairs = if (Test-Path -LiteralPath $PairsFile) { @((Get-Content -Raw -LiteralPath $PairsFile | ConvertFrom-Json).pairs) } else { @() }
$appliedPairs = @{}

function Get-Normalized([string]$Text, [bool]$IsCandidate) {
    $result = $Text
    if ($IsCandidate) {
        foreach ($pair in $pairs) {
            $after = $pair.after.Replace("`n", $newline)
            if ($result.Contains($after)) {
                $result = $result.Replace($after, $pair.before.Replace("`n", $newline))
                $script:appliedPairs[$pair.where] = $true
            }
        }
    }
    $result = [regex]::Replace($result, 'bootstrap_engine_sha256: [0-9a-f]{64}\r\nmission_sha256: [0-9a-f]{64}', 'BOOTSTRAP-IDENTITY')
    $result = [regex]::Replace($result, 'bootstrap_version: [0-9]+', 'bootstrap_version: VERSION')

    return [regex]::Replace($result, 'dlss5-agent-sections-[0-9a-f]{32}', 'dlss5-agent-sections-ID')
}

$failures = 0
$keys = @($renders['baseline'].Keys) + @($renders['candidate'].Keys) | Sort-Object -Unique
foreach ($key in $keys) {
    if (-not $renders['baseline'].ContainsKey($key) -or -not $renders['candidate'].ContainsKey($key)) { $failures++; "FAIL $key is rendered by only one release"; continue }
    $left = Get-Normalized $renders['baseline'][$key] $false
    $right = Get-Normalized $renders['candidate'][$key] $true
    if ($left -cne $right) {
        $failures++
        $index = 0
        while ($index -lt [Math]::Min($left.Length, $right.Length) -and $left[$index] -ceq $right[$index]) { $index++ }
        "FAIL $key first difference at $index"
        '  baseline: ' + $left.Substring([Math]::Max(0, $index - 80), [Math]::Min(240, $left.Length - [Math]::Max(0, $index - 80)))
        '  candidate: ' + $right.Substring([Math]::Max(0, $index - 80), [Math]::Min(240, $right.Length - [Math]::Max(0, $index - 80)))
    }
    else { "PASS $key" }
}
# A recorded pair whose after text never appears would let a reverted change pass, so every pair must be applied somewhere.
foreach ($pair in $pairs) { if (-not $appliedPairs.ContainsKey($pair.where)) { $failures++; "FAIL recorded change not found: $($pair.where)" } }
if ($failures -gt 0) { throw "$failures parity checks failed." }
'ALL PARITY CHECKS PASSED'
