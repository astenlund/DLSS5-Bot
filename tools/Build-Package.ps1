param(
    [string]$PluriBotTree,
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '..\build')
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Builds the DLSS package from the mission and an engine. By default the engine is the vendored engine file, which must match its pin.
# With -PluriBotTree the engine is joined from that Pluri-Bot working tree instead, for building and testing an unreleased engine, and the
# build record names the tree's commit and whether it was clean. Publication accepts only a build from the pinned engine.
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
$null = New-Item -ItemType Directory -Force -Path $OutputDirectory
$pin = Get-Content -LiteralPath (Join-Path $repository 'engine\pin.json') -Raw | ConvertFrom-Json
$engine = Join-Path $OutputDirectory 'engine.cmd'
if ([string]::IsNullOrEmpty($PluriBotTree)) {
    $source = [ordered]@{ kind = 'pin'; tag = $pin.pluri_bot_tag; commit = $pin.pluri_bot_commit }
    [IO.File]::WriteAllBytes($engine, [IO.File]::ReadAllBytes((Join-Path $repository 'engine\engine.cmd')))
    $engineSha256 = [Convert]::ToHexStringLower([Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($engine)))
    if ($engineSha256 -cne $pin.engine_sha256) { throw "The vendored engine $engineSha256 does not match its pin $($pin.engine_sha256)." }
}
else {
    $PluriBotTree = [IO.Path]::GetFullPath($PluriBotTree)
    $commit = (& git -C $PluriBotTree rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0) { throw "Not a Git working tree: $PluriBotTree" }
    $status = @(& git -C $PluriBotTree status --porcelain)
    if ($LASTEXITCODE -ne 0) { throw "Git cannot read the status of $PluriBotTree" }
    $source = [ordered]@{ kind = 'tree'; path = $PluriBotTree; commit = $commit; clean = ($status.Count -eq 0) }
    & (Join-Path $PluriBotTree 'tools\Join-Engine.ps1') -Output $engine
    $engineSha256 = [Convert]::ToHexStringLower([Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($engine)))
}
$package = Join-Path $OutputDirectory 'DLSS5-ADDER.cmd'
[IO.File]::WriteAllBytes($package, [IO.File]::ReadAllBytes($engine))
$null = & (Join-Path $PSScriptRoot 'Assemble-Package.ps1') -Package $package -Mission (Join-Path $repository 'mission-dlss5')
. ([scriptblock]::Create((& (Join-Path $PSScriptRoot 'Get-PayloadDefinitions.ps1') -Path $engine))) -SelfPath $engine
$identity = Get-Dlss5BootstrapIdentity -Bytes ([IO.File]::ReadAllBytes($package)) -Strict
if ($identity.EngineSha256 -cne $engineSha256) { throw "The package engine $($identity.EngineSha256) differs from the engine file $engineSha256." }
if ($identity.Sha256 -cne $identity.PublishedSha256 -or $identity.MissionId -cne 'dlss5') { throw 'The package is not a published DLSS package.' }
if ($source.kind -ceq 'pin' -and $identity.Version -ne [int]$pin.engine_version) { throw "The vendored engine is version $($identity.Version), but its pin names $($pin.engine_version)." }
# Assembly embeds every file in the mission folder, so the record says whether that folder matched this repository's HEAD.
$missionStatus = @(& git -C $repository status --porcelain --untracked-files=all --ignored -- mission-dlss5)
if ($LASTEXITCODE -ne 0) { throw "Git cannot read the status of $repository" }
$utf8 = [Text.UTF8Encoding]::new($false)
[IO.File]::WriteAllText($package + '.sha256', $identity.Sha256 + '  DLSS5-ADDER.cmd' + "`n", $utf8)
$record = [ordered]@{ engine_version = $identity.Version; engine_sha256 = $engineSha256; mission_sha256 = $identity.MissionSha256; package_sha256 = $identity.Sha256; mission_clean = ($missionStatus.Count -eq 0); engine_source = $source }
[IO.File]::WriteAllText((Join-Path $OutputDirectory 'build-record.json'), ($record | ConvertTo-Json) + "`n", $utf8)
"engine version $($identity.Version) sha256 $engineSha256 from $($source.kind)"
"package sha256 $($identity.Sha256)"
