param([Parameter(Mandatory)][string]$Tag, [string]$Repository = 'astenlund/Pluri-Bot')
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Pins the engine of a published Pluri-Bot release: downloads its engine file and the SHA-256 the release publishes for it, requires them
# to match, reads the engine version from the file and the commit from the tag, and rewrites the vendored engine and its pin together,
# so an engine update is one reviewable commit. Reads only; nothing is written until every check has passed.
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$download = Join-Path $root ('.tmp\pin-' + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Force -Path $download
try {
    & gh release download $Tag --repo $Repository --pattern 'engine.cmd' --pattern 'engine.cmd.sha256' --dir $download
    if ($LASTEXITCODE -ne 0) { throw "Downloading release $Tag of $Repository failed." }
    $engine = Join-Path $download 'engine.cmd'
    $published = (([IO.File]::ReadAllText((Join-Path $download 'engine.cmd.sha256'))).Trim() -split '\s+')[0].ToLowerInvariant()
    $actual = [Convert]::ToHexStringLower([Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($engine)))
    if ($actual -cne $published) { throw "The engine file $actual does not match the SHA-256 release $Tag publishes, $published." }
    . ([scriptblock]::Create((& (Join-Path $PSScriptRoot 'Get-PayloadDefinitions.ps1') -Path $engine))) -SelfPath $engine
    $identity = Get-Dlss5BootstrapIdentity -Bytes ([IO.File]::ReadAllBytes($engine))
    if ($identity.EngineSha256 -cne $actual) { throw 'The release''s engine file is not an engine form: its engine hash differs from its SHA-256.' }
    $commit = (& gh api ('repos/' + $Repository + '/commits/' + $Tag) --jq '.sha').Trim()
    if ($LASTEXITCODE -ne 0 -or $commit -notmatch '^[0-9a-f]{40}$') { throw "The commit of tag $Tag could not be read." }
    $pin = [ordered]@{ engine_version = $identity.Version; pluri_bot_tag = $Tag; pluri_bot_commit = $commit; engine_sha256 = $actual }
    [IO.File]::WriteAllBytes((Join-Path $root 'engine\engine.cmd'), [IO.File]::ReadAllBytes($engine))
    $newline = [string][char]13 + [char]10
    [IO.File]::WriteAllText((Join-Path $root 'engine\pin.json'), (($pin | ConvertTo-Json) -replace "`r?`n", $newline) + $newline, [Text.UTF8Encoding]::new($false))
    "pinned engine version $($identity.Version) from $Repository $Tag ($commit), sha256 $actual"
}
finally { Remove-Item -LiteralPath $download -Recurse -Force -ErrorAction SilentlyContinue }
