param([string]$Candidate = (Join-Path $PSScriptRoot '..\build\DLSS5-ADDER.cmd'), [string]$RecordDirectory = (Join-Path $env:LOCALAPPDATA 'DLSS5-ADDER\release-records\probes'))
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Live probe of the account check's host contract: runs the real claude auth status --json the way the engine does (no window, no input,
# 30-second bound), directly and through a .cmd shim, against a scratch folder, touching no store. The record keeps the field shape and
# whether the engine's parser accepts it, with the email reduced to its domain.
. ([scriptblock]::Create((& (Join-Path $PSScriptRoot 'Get-PayloadDefinitions.ps1') -Path $Candidate))) -SelfPath $Candidate
$commands = @(Get-Command claude -CommandType Application -ErrorAction SilentlyContinue)
if ($commands.Count -lt 1) { throw 'Claude Code is not installed, so the account probe cannot run.' }
$direct = $commands[0].Source
$scratch = Join-Path $PSScriptRoot '..\.tmp\probe-scratch'
$null = New-Item -ItemType Directory -Force -Path $scratch
$shim = Join-Path $scratch 'claude.cmd'
[IO.File]::WriteAllText($shim, "@echo off`r`n`"$direct`" %*`r`nexit /b %ERRORLEVEL%`r`n", [Text.ASCIIEncoding]::new())
$records = [Collections.Generic.List[object]]::new()
foreach ($route in @(@('direct', $direct), @('cmd shim', $shim))) {
    $result = Invoke-Dlss5BoundedCapture -FilePath $route[1] -Arguments @('auth', 'status', '--json') -TimeoutMilliseconds 30000 -NoInput
    $record = [ordered]@{ route = $route[0]; command = [IO.Path]::GetFileName($route[1]); timed_out = $result.TimedOut; exit_code = $result.ExitCode; parsed = $false; fields = @(); logged_in_kind = $null; email_kind = $null; email_domain = $null }
    if (-not $result.TimedOut) {
        try {
            $fields = ConvertFrom-Dlss5JsonObject -Bytes ([Text.UTF8Encoding]::new($false, $true).GetBytes($result.Output.Trim())) -Limit $script:Dlss5ConfigByteLimit
            $record.parsed = $true
            $record.fields = @($fields.Keys | Sort-Object)
            if ($fields.ContainsKey('loggedIn')) { $record.logged_in_kind = [string]$fields['loggedIn'].ValueKind }
            if ($fields.ContainsKey('email')) {
                $record.email_kind = [string]$fields['email'].ValueKind
                if ($fields['email'].ValueKind -eq [Text.Json.JsonValueKind]::String) { $record.email_domain = $fields['email'].GetString().Split('@')[-1] }
            }
        }
        catch { $record.parse_error = $_.Exception.Message }
    }
    $records.Add($record)
}
$version = (& $direct --version 2>&1 | Out-String).Trim()
$contractMatches = @($records | Where-Object { -not $_.timed_out -and $_.exit_code -eq 0 -and $_.parsed -and $_.logged_in_kind -ceq 'True' -and $_.email_kind -ceq 'String' }).Count -eq $records.Count
$output = [ordered]@{ probed_at = (Get-Date).ToUniversalTime().ToString('o'); claude_version = $version; routes = $records; contract_matches_engine = $contractMatches }
$null = New-Item -ItemType Directory -Force -Path $RecordDirectory
$path = Join-Path $RecordDirectory ('probe-account-' + (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ') + '.json')
[IO.File]::WriteAllText($path, (ConvertTo-Json -InputObject $output -Depth 4) + "`r`n", [Text.UTF8Encoding]::new($false))
Remove-Item -Recurse -Force $scratch
"recorded $path"
"contract matches the engine's parser: $contractMatches"
