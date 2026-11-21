param([string]$Candidate = (Join-Path $PSScriptRoot '..\build\DLSS5-ADDER.cmd'))
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$text = [Text.UTF8Encoding]::new($false, $true).GetString([IO.File]::ReadAllBytes($Candidate))
$begin = '### === POWERSHELL_PAYLOAD_BEGIN ==='
$start = $text.IndexOf($begin, [StringComparison]::Ordinal) + $begin.Length
$stop = $text.IndexOf('# Load and normalize persistent state', [StringComparison]::Ordinal)
. ([scriptblock]::Create($text.Substring($start, $stop - $start))) -SelfPath $Candidate

$knowledge = Read-Dlss5NotesFile -Path (Get-Dlss5ProjectKnowledgePath) -BeginMarker $ProjectKnowledgeBeginMarker -EndMarker $ProjectKnowledgeEndMarker
"project knowledge parsed: $($knowledge.Count) records; dlssnr_patcher present: $($knowledge.Contains('dlssnr_patcher'))"
$machine = Read-Dlss5NotesFile -Path (Get-Dlss5MachineNotesPath) -BeginMarker $MachineNotesBeginMarker -EndMarker $MachineNotesEndMarker
"machine notes parsed: $($machine.Count) records"
