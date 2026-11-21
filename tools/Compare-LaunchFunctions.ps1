param([Parameter(Mandatory)][string]$Baseline, [string]$Candidate = (Join-Path $PSScriptRoot '..\build\DLSS5-ADDER.cmd'))
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Compares the host launch functions of the baseline and the candidate by their exact text, the evidence that a release changes no
# host launch behavior and may carry the live probe records forward.
$names = @('Resolve-Dlss5AgentCommand', 'Get-Dlss5ModelConfiguration', 'Resolve-Dlss5LaunchConfiguration', 'Assert-Dlss5ApprovalModeSupported', 'Assert-Dlss5ClaudeAccount', 'Select-Dlss5Agent', 'Get-Dlss5ApprovalArguments', 'Get-Dlss5AgentPrefixArguments', 'Start-Dlss5AgentProcess', 'Get-Dlss5AgentInstruction', 'Invoke-Dlss5InteractiveAgent', 'ConvertTo-Dlss5BatchArgument')
# From v62 Invoke-Dlss5InteractiveAgent holds these whole status lines, which record for its caller whether the prompt files were written
# and the failure message; none feeds the host's arguments, environment, working directory or start. Each must occur exactly once in the
# candidate, between lines starting with its Above and Below prefixes, and the same in the baseline wherever the baseline has it (v61 has
# none, v62 and later all). They are removed from both sides, and what remains must be equal, so any other difference fails.
$statusLines = [ordered]@{
    'Invoke-Dlss5InteractiveAgent' = @(
        [pscustomobject]@{ Line = '    $script:Dlss5AgentPromptWritten = $false'; Above = '    $script:Dlss5AgentStarted = $false'; Below = '    $script:Dlss5AgentFailure = $null' },
        [pscustomobject]@{ Line = '    $script:Dlss5AgentFailure = $null'; Above = '    $script:Dlss5AgentPromptWritten = $false'; Below = '    if ($PromptId -cnotmatch ' },
        [pscustomobject]@{ Line = '        $script:Dlss5AgentPromptWritten = $true'; Above = '        $written.Add([pscustomobject]@{ Snapshot = (Write-Dlss5GuardedNewFile -Path $promptPath '; Below = '        $batchAgent = ' },
        [pscustomobject]@{ Line = '        $script:Dlss5AgentFailure = Get-Dlss5InnermostMessage $_.Exception'; Above = '    catch {'; Below = '        # Only a failed create-new write carries an owned snapshot' }
    )
}

function Get-FunctionTexts([string]$Path) {
    $text = [IO.File]::ReadAllText($Path, [Text.UTF8Encoding]::new($false, $true))
    $begin = '### === POWERSHELL_PAYLOAD_' + 'BEGIN ==='
    $end = '### === POWERSHELL_PAYLOAD_' + 'END ==='
    $payload = $text.Substring($text.IndexOf($begin) + $begin.Length, $text.LastIndexOf($end) - $text.IndexOf($begin) - $begin.Length)
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput($payload, [ref]$tokens, [ref]$errors)
    $map = @{}
    foreach ($function in $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $true)) { $map[$function.Name] = $function.Extent.Text }

    return $map
}

function Remove-StatusLines([string]$Name, [string]$Text, [string]$Side, [switch]$Required) {
    # Checks every listed status line in place on the original text, then removes those present; returns the remaining text.
    $lines = [string[]]($Text -split "`r`n")
    $drop = [Collections.Generic.HashSet[int]]::new()
    foreach ($entry in $statusLines[$Name]) {
        $at = @(for ($index = 0; $index -lt $lines.Length; $index++) { if ($lines[$index] -ceq $entry.Line) { $index } })
        if ($at.Count -eq 0 -and -not $Required) { continue }
        if ($at.Count -ne 1) { throw "Status line occurs $($at.Count) times in $Name ($Side): $($entry.Line)" }
        $index = $at[0]
        if ($index -eq 0 -or -not $lines[$index - 1].StartsWith($entry.Above, [StringComparison]::Ordinal)) { throw "Status line is not below its anchor in $Name ($Side): $($entry.Line)" }
        if ($index + 1 -ge $lines.Length -or -not $lines[$index + 1].StartsWith($entry.Below, [StringComparison]::Ordinal)) { throw "Status line is not above its anchor in $Name ($Side): $($entry.Line)" }
        $null = $drop.Add($index)
    }

    return [string]::Join("`r`n", @(for ($index = 0; $index -lt $lines.Length; $index++) { if (-not $drop.Contains($index)) { $lines[$index] } }))
}

$left = Get-FunctionTexts $Baseline
$right = Get-FunctionTexts $Candidate
$changed = @($names | Where-Object {
        if (-not $left.ContainsKey($_) -or -not $right.ContainsKey($_)) { return $true }
        if (-not $statusLines.Contains($_)) { return $left[$_] -cne $right[$_] }
        (Remove-StatusLines $_ $left[$_] 'baseline') -cne (Remove-StatusLines $_ $right[$_] 'candidate' -Required)
    })
if ($changed.Count -gt 0) { throw ('Host launch functions changed: ' + ($changed -join ', ')) }
$listed = 0
foreach ($name in $statusLines.Keys) { $listed += $statusLines[$name].Count }
'host launch functions unchanged from the baseline: ' + $names.Count + ', apart from ' + $listed + ' status lines in Invoke-Dlss5InteractiveAgent'
