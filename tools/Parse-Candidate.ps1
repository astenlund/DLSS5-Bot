param([string]$Path = (Join-Path $PSScriptRoot '..\build\DLSS5-ADDER.cmd'))
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Parses the payload and reports syntax errors, Dlss5 commands that are called but never defined, and defined functions nobody calls.
$text = [IO.File]::ReadAllText($Path, [Text.UTF8Encoding]::new($false, $true))
$begin = '### === POWERSHELL_PAYLOAD_' + 'BEGIN ==='
$end = '### === POWERSHELL_PAYLOAD_' + 'END ==='
$payload = $text.Substring($text.IndexOf($begin) + $begin.Length, $text.LastIndexOf($end) - $text.IndexOf($begin) - $begin.Length)
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput($payload, [ref]$tokens, [ref]$errors)
foreach ($problem in $errors) { 'PARSE {0}:{1} {2}' -f $problem.Extent.StartLineNumber, $problem.Extent.StartColumnNumber, $problem.Message }
$defined = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($function in $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $true)) { $null = $defined.Add($function.Name) }
$called = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($command in $ast.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] }, $true)) {
    $name = $command.GetCommandName()
    if ($null -eq $name) { continue }
    $null = $called.Add($name)
    if ($name -match '-Dlss5|Dlss5' -and -not $defined.Contains($name)) { 'UNDEFINED {0} at line {1}' -f $name, $command.Extent.StartLineNumber }
}
foreach ($name in $defined) { if (-not $called.Contains($name) -and -not $payload.Contains('${function:' + $name + '}')) { 'UNCALLED {0}' -f $name } }
if ($errors.Count -eq 0) { 'PARSE OK' }
