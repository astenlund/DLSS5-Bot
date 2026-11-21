param(
    [Parameter(Mandatory)][string]$OutputPath,
    [string]$UpdaterPath = (Join-Path $PSScriptRoot '..\build\DLSS5-ADDER.cmd'),
    [string]$Filter = '',
    [string]$TestFile = ''
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Runs the release suite against a package on the off-screen runner: every case, or only those -Filter (a regular expression over case names)
# and -TestFile (semicolon-separated test file names) select, a case matching both when both are given. Only a finished run that selected
# something replaces the output; an interrupted run stays in the .partial file beside it.
$suite = Join-Path $PSScriptRoot '..\tests\Test-DLSS5Adder.ps1'
if ($TestFile.Length -gt 0) {
    # A name the suite does not load would select nothing from that file while the other names still ran and passed.
    $loaded = @('Test-DLSS5Adder.ps1') + @([regex]::Matches([IO.File]::ReadAllText($suite), "(?m)^\s*\. \(Join-Path \`$PSScriptRoot '([^']+)'\)") | ForEach-Object { $_.Groups[1].Value })
    foreach ($name in @($TestFile.Split(';', [StringSplitOptions]::RemoveEmptyEntries))) {
        if ($name -cnotin $loaded) { throw "The suite does not load a test file named $name." }
    }
}
$OutputPath = [IO.Path]::GetFullPath($OutputPath)
$null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $OutputPath)
$partial = "$OutputPath.partial"
if ([IO.File]::Exists($partial)) { [IO.File]::Delete($partial) }
$env:DLSS5_TEST_CASE_FILTER = $Filter
$env:DLSS5_TEST_FILE_FILTER = $TestFile
& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'Invoke-SuiteOffscreen.ps1') -UpdaterPath ([IO.Path]::GetFullPath($UpdaterPath)) -OutputPath $partial
$code = $LASTEXITCODE
$summaries = @(if ([IO.File]::Exists($partial)) { [IO.File]::ReadAllLines($partial) | Where-Object { $_ -match '^(ALL TESTS PASSED \([1-9]\d*\)|\d+ FAILED, \d+ PASSED)$' } })
if ($summaries.Count -ne 1) {
    "The run did not finish or selected nothing; see $partial"
    exit $(if ($code -ne 0) { $code } else { 1 })
}
[IO.File]::Move($partial, $OutputPath, $true)
$summaries[0]
exit $code
