<#
.SYNOPSIS
  Assemble l'artefact applicatif shadow et son manifeste. Aucun accès réseau.

.DESCRIPTION
  L'artefact ne contient QUE ce qui sert au runtime : `dist`, un
  `package.json` réduit, les migrations Drizzle et le manifeste. Il ne
  contient jamais de sources de test, de `.env`, de base SQLite, d'audio, de
  `node_modules` Windows, de journal, de cache ni de donnée utilisateur —
  l'exclusion est appliquée par `phase6_manifest.py` et vérifiée par les
  tests.

  Le `node_modules` Linux n'est PAS assemblé ici : il est fourni séparément
  comme bundle immuable (voir la procédure). Embarquer le `node_modules`
  Windows produirait un artefact qui ne démarre pas sur Debian — les binaires
  natifs sont spécifiques à la plateforme et à l'ABI.
#>
[CmdletBinding()]
param(
    [string] $RepoRoot = 'F:\dev\homespotify-phase6-shadow',
    [string] $StagingRoot = 'F:\dev\homespotify-phase6-staging',
    [string] $BundleId = 'linux-x64-node22.18.0-abi127',
    [switch] $SkipBuild
)

$ErrorActionPreference = 'Stop'
function Fail([string] $Message) { throw "PHASE6_BUILD: $Message" }
function Step([string] $Message) { Write-Host "[phase6-build] $Message" }

Set-Location -LiteralPath $RepoRoot
$branch = (git branch --show-current)
if ($branch -ne 'phase6/vps-shadow-deployment') { Fail "branche inattendue : $branch" }

if (-not $SkipBuild) {
    Step 'build API'
    & pnpm.cmd --filter @homespotify/api build
    if ($LASTEXITCODE -ne 0) { Fail 'build API échoué' }
}
$dist = Join-Path $RepoRoot 'services\api\dist'
if (-not (Test-Path -LiteralPath (Join-Path $dist 'server.js'))) { Fail 'dist/server.js absent' }

# Staging neuf : un résidu d'assemblage précédent fausserait le manifeste.
$staging = Join-Path $StagingRoot 'artifact'
if (Test-Path -LiteralPath $staging) { Remove-Item -Recurse -Force -LiteralPath $staging }
New-Item -ItemType Directory -Force -Path $staging | Out-Null

Step 'copie de dist'
Copy-Item -Recurse -Force -LiteralPath $dist -Destination (Join-Path $staging 'dist')

Step 'copie des migrations Drizzle'
$migrations = Join-Path $RepoRoot 'services\api\drizzle'
if (Test-Path -LiteralPath $migrations) {
    Copy-Item -Recurse -Force -LiteralPath $migrations -Destination (Join-Path $staging 'drizzle')
} else {
    # `migrate.ts` porte le SQL en dur : l'absence de dossier n'est pas une
    # erreur, mais elle doit être visible dans le rapport.
    Step 'aucun dossier drizzle/ : migrations portées par le code'
}

Step 'package.json réduit au runtime'
$source = Get-Content -Raw -LiteralPath (Join-Path $RepoRoot 'services\api\package.json') | ConvertFrom-Json
$manifestJson = [ordered]@{
    name         = $source.name
    version      = $source.version
    private      = $true
    type         = $source.type
    scripts      = [ordered]@{ start = 'node dist/server.js' }
    dependencies = $source.dependencies
} | ConvertTo-Json -Depth 8

# UTF-8 SANS BOM, ecrit explicitement. `Set-Content -Encoding utf8` sous
# Windows PowerShell 5.1 ajoute un BOM, et `dist/routes/admin.js` fait un
# `JSON.parse` de ce fichier au chargement : l'API refusait de demarrer sur
# « Unexpected token ... is not valid JSON ». Le defaut ne pouvait apparaitre
# qu'au premier demarrage reel, jamais dans un controle de manifeste.
[IO.File]::WriteAllText(
    (Join-Path $staging 'package.json'),
    $manifestJson,
    (New-Object System.Text.UTF8Encoding($false))
)

$commit = (git rev-parse HEAD)
$builtAt = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')

Step 'manifeste'
$python = 'python'
& $python (Join-Path $RepoRoot 'scripts\phase6\phase6_build_manifest.py') `
    --root $staging --commit $commit --built-at $builtAt --bundle-id $BundleId
if ($LASTEXITCODE -ne 0) { Fail 'manifeste échoué' }

$manifest = Get-Content -Raw -LiteralPath (Join-Path $staging 'manifest.json') | ConvertFrom-Json
Step ("releaseId={0} fichiers={1} octets={2}" -f $manifest.releaseId, $manifest.fileCount, $manifest.totalBytes)
Write-Output (ConvertTo-Json -Compress @{
    ok = $true; releaseId = $manifest.releaseId; staging = $staging
    fileCount = $manifest.fileCount; totalBytes = $manifest.totalBytes
    manifestSha256 = $manifest.manifestSha256; commit = $commit
})
