param(
    [Parameter(Mandatory)][string]$Tag,
    [string]$Repository = 'astenlund/Pluri-Bot',
    # A folder already holding the release's engine.cmd and engine.cmd.sha256, as a download writes them, with -Commit naming the tag's commit:
    # checks and pins those files without calling the network.
    [string]$FromDirectory = '',
    [string]$Commit = ''
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Pins the engine of a published Pluri-Bot release: downloads its engine file and the SHA-256 the release publishes for it, requires them
# to match and the file to be an engine form, reads the engine version from it and the commit from the tag, and rewrites the vendored
# engine and its pin together, so an engine update is one reviewable commit. Nothing is written until every check has passed.
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$work = Join-Path $root ('.tmp\pin-' + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Force -Path $work
try {
    if ($FromDirectory.Length -gt 0) {
        if ($Commit -notmatch '^[0-9a-f]{40}$') { throw '-FromDirectory needs -Commit, the full commit hash the tag marks.' }
        foreach ($name in @('engine.cmd', 'engine.cmd.sha256')) { Copy-Item -LiteralPath (Join-Path $FromDirectory $name) -Destination (Join-Path $work $name) }
    }
    else {
        & gh release download $Tag --repo $Repository --pattern 'engine.cmd' --pattern 'engine.cmd.sha256' --dir $work
        if ($LASTEXITCODE -ne 0) { throw "Downloading release $Tag of $Repository failed." }
        $Commit = (& gh api ('repos/' + $Repository + '/commits/' + $Tag) --jq '.sha' | Out-String).Trim()
        if ($LASTEXITCODE -ne 0 -or $Commit -notmatch '^[0-9a-f]{40}$') { throw "The commit of tag $Tag could not be read." }
    }
    $engine = Join-Path $work 'engine.cmd'
    $published = (([IO.File]::ReadAllText((Join-Path $work 'engine.cmd.sha256'))).Trim() -split '\s+')[0].ToLowerInvariant()
    $actual = [Convert]::ToHexStringLower([Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($engine)))
    if ($actual -cne $published) { throw "The engine file $actual does not match the SHA-256 release $Tag publishes, $published." }
    # The engine's own identity check refuses a file without a mission, so the engine form is proven by assembling this repository's
    # mission into a copy of it: the result's engine hash must be the engine file's SHA-256.
    $probe = Join-Path $work 'probe.cmd'
    [IO.File]::WriteAllBytes($probe, [IO.File]::ReadAllBytes($engine))
    $null = & (Join-Path $PSScriptRoot 'Assemble-Package.ps1') -Package $probe -Mission (Join-Path $root 'mission-dlss5')
    . ([scriptblock]::Create((& (Join-Path $PSScriptRoot 'Get-PayloadDefinitions.ps1') -Path $engine))) -SelfPath $engine
    $identity = Get-Dlss5BootstrapIdentity -Bytes ([IO.File]::ReadAllBytes($probe)) -Strict
    if ($identity.EngineSha256 -cne $actual) { throw "The release's engine file is not an engine form: a package assembled from it has engine $($identity.EngineSha256)." }
    $newline = [string][char]13 + [char]10
    $pin = '{' + $newline + '  "engine_version": ' + $identity.Version + ',' + $newline + '  "pluri_bot_tag": "' + $Tag + '",' + $newline + '  "pluri_bot_commit": "' + $Commit + '",' + $newline + '  "engine_sha256": "' + $actual + '"' + $newline + '}' + $newline
    [IO.File]::WriteAllBytes((Join-Path $root 'engine\engine.cmd'), [IO.File]::ReadAllBytes($engine))
    [IO.File]::WriteAllBytes((Join-Path $root 'engine\pin.json'), [Text.UTF8Encoding]::new($false).GetBytes($pin))
    "pinned engine version $($identity.Version) from $Repository $Tag ($Commit), sha256 $actual"
}
finally { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
