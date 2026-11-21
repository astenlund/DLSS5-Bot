param([Parameter(Mandatory)][string[]]$Paths)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Converts LF-only text files to CRLF and refuses mixed endings; files already uniform CRLF are left untouched.
foreach ($path in $Paths) {
    foreach ($file in @(if (Test-Path -LiteralPath $path -PathType Container) { Get-ChildItem -LiteralPath $path -File -Recurse | Where-Object { $_.Extension -in @('.ps1', '.md', '.json', '.cmd', '.txt') -and $_.Name -notlike 'spec-review*' -and $_.Name -notlike 'suite-*' } } else { Get-Item -LiteralPath $path })) {
        $bytes = [IO.File]::ReadAllBytes($file.FullName)
        $crlf = 0
        $lf = 0
        for ($index = 0; $index -lt $bytes.Length; $index++) {
            if ($bytes[$index] -eq 10) { if ($index -gt 0 -and $bytes[$index - 1] -eq 13) { $crlf++ } else { $lf++ } }
        }
        if ($lf -eq 0) { continue }
        if ($crlf -gt 0) { throw "Mixed line endings: $($file.FullName)" }
        $text = [IO.File]::ReadAllText($file.FullName, [Text.UTF8Encoding]::new($false, $true))
        [IO.File]::WriteAllText($file.FullName, $text.Replace("`n", "`r`n"), [Text.UTF8Encoding]::new($false))
        "converted $($file.FullName)"
    }
}
