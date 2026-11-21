param(
    [Parameter(Mandatory)][string]$OutputPath,
    [Parameter(Mandatory)][string]$RecordedPath,
    [Parameter(Mandatory)][string]$ExpectedPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Compares a finished suite output with a recorded per-case result set. Every recorded passing case must pass again, and no case may fail,
# apart from the differences the expected file names: each of its lines is "absent <case name>" for a recorded case that no longer runs
# (retired or moved elsewhere) or "added <case name>" for a case the record does not hold. A listed difference that does not occur also fails,
# so the list stays exact.
$results = @{}
foreach ($line in [IO.File]::ReadAllLines($OutputPath)) {
    if ($line -match '^TIME \d+ (PASS|FAIL) (\S+) (.+)$') { $results[$Matches[3]] = $Matches[1] }
}
$summary = @([IO.File]::ReadAllLines($OutputPath) | Where-Object { $_ -match '^(ALL TESTS PASSED \(\d+\)|\d+ FAILED, \d+ PASSED)$' })
if ($summary.Count -ne 1) { throw 'The suite output has no final summary, so the run did not finish.' }
$recorded = @{}
foreach ($case in (Get-Content -LiteralPath $RecordedPath -Raw | ConvertFrom-Json).cases) { $recorded[$case.name] = $case.outcome }
$absent = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$added = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($line in [IO.File]::ReadAllLines($ExpectedPath)) {
    if ($line -match '^absent (.+)$') { [void]$absent.Add($Matches[1]) }
    elseif ($line -match '^added (.+)$') { [void]$added.Add($Matches[1]) }
    elseif ($line.Trim().Length -gt 0 -and -not $line.StartsWith('#', [StringComparison]::Ordinal)) { throw "Unreadable expected line: $line" }
}
$problems = [Collections.Generic.List[string]]::new()
foreach ($name in $recorded.Keys) {
    if ($absent.Contains($name)) {
        if ($results.ContainsKey($name)) { $problems.Add("listed as absent but ran: $name") }
        continue
    }
    if (-not $results.ContainsKey($name)) { $problems.Add("recorded case did not run: $name"); continue }
    if ($recorded[$name] -ceq 'PASS' -and $results[$name] -cne 'PASS') { $problems.Add("recorded pass now fails: $name") }
}
foreach ($name in $absent) { if (-not $recorded.ContainsKey($name)) { $problems.Add("listed as absent but not recorded: $name") } }
foreach ($name in $results.Keys) {
    if ($results[$name] -cne 'PASS') { $problems.Add("case failed: $name") }
    if (-not $recorded.ContainsKey($name) -and -not $added.Contains($name)) { $problems.Add("case not in the record and not listed as added: $name") }
}
foreach ($name in $added) { if (-not $results.ContainsKey($name)) { $problems.Add("listed as added but did not run: $name") } }
"recorded $($recorded.Count), ran $($results.Count), absent $($absent.Count), added $($added.Count)"
if ($problems.Count -gt 0) {
    $problems | Sort-Object
    exit 1
}
'MATCH: the run agrees with the record apart from the listed differences.'
