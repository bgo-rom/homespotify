<#
.SYNOPSIS
  Assemble l'artefact applicatif shadow, le runtime Antra et son manifeste.
  Aucun accès réseau.

.DESCRIPTION
  L'artefact contient uniquement ce qui sert au runtime :

  - `dist` et le `package.json` réduit de l'API ;
  - les migrations Drizzle ;
  - les 69 fichiers Antra suivis et qualifiés ;
  - un descripteur immuable du runtime Python ;
  - un lanceur qui cible le futur bundle Python Linux ;
  - le manifeste complet.

  Le dépôt Antra est imbriqué, ignoré par HomeSpotify et non déclaré comme
  submodule. Son commit, son état propre, son profil de dépendances et chaque
  fichier copié sont donc contrôlés explicitement avant l'assemblage.

  Aucun `.env`, cache, journal, base SQLite, audio, test Antra, `.git`,
  `node_modules` Windows ou venv Windows n'est copié.

  Le `node_modules` Linux reste un bundle immuable séparé. Le runtime Python
  est lui aussi préparé séparément sur Debian avant toute bascule de `current`.
#>
[CmdletBinding()]
param(
    [string] $RepoRoot = 'F:\dev\homespotify-phase6-final-c2',
    [string] $StagingRoot = 'F:\dev\homespotify-phase6-staging',
    [string] $BundleId = 'linux-x64-node22.18.0-abi127',
    [string] $AntraRoot = '',
    [switch] $SkipBuild
)

$ErrorActionPreference = 'Stop'

$ExpectedBranch = 'phase6/vps-final-c2'
$ExpectedAntraBranch = 'homespotify/vps-linux-runtime'
$ExpectedAntraCommit = 'dbce23c5960af504d672cc28c7c51ece0bea8e68'
$ExpectedRequirementsSha256 = '6d0ced20523398f2d2b24d849588957006b4d721130989c9fd40c7a588e8a589'
$ExpectedRuntimeFileCount = 69
$PythonRuntimeId = 'py311-antra-dbce23c5-6d0ced20'

function Fail([string] $Message) {
    throw "PHASE6_BUILD: $Message"
}

function Step([string] $Message) {
    Write-Host "[phase6-build] $Message"
}

if ([string]::IsNullOrWhiteSpace($AntraRoot)) {
    $AntraRoot = Join-Path $RepoRoot 'tools\antra'
}

$RepoGit = $RepoRoot.Replace('\', '/')
$AntraGit = $AntraRoot.Replace('\', '/')

Set-Location -LiteralPath $RepoRoot

$branch = (
    git `
        -c "safe.directory=$RepoGit" `
        -C "$RepoRoot" `
        branch --show-current
).Trim()

if ($branch -ne $ExpectedBranch) {
    Fail "branche HomeSpotify inattendue : $branch"
}

if (-not (Test-Path -LiteralPath $AntraRoot -PathType Container)) {
    Fail 'dépôt Antra absent'
}

$antraBranch = (
    git `
        -c "safe.directory=$AntraGit" `
        -C "$AntraRoot" `
        branch --show-current
).Trim()

$antraCommit = (
    git `
        -c "safe.directory=$AntraGit" `
        -C "$AntraRoot" `
        rev-parse HEAD
).Trim()

$antraStatus = @(
    git `
        -c "safe.directory=$AntraGit" `
        -C "$AntraRoot" `
        status `
        --porcelain `
        --untracked-files=all
)

if ($antraBranch -ne $ExpectedAntraBranch) {
    Fail "branche Antra inattendue : $antraBranch"
}

if ($antraCommit -ne $ExpectedAntraCommit) {
    Fail "commit Antra inattendu : $antraCommit"
}

if ($antraStatus.Count -ne 0) {
    Fail 'worktree Antra non propre'
}

$requirementsPath = Join-Path `
    $AntraRoot `
    'requirements-homespotify-vps.txt'

if (-not (
    Test-Path -LiteralPath $requirementsPath -PathType Leaf
)) {
    Fail 'profil Python HomeSpotify VPS absent'
}

$requirementsSha256 = (
    Get-FileHash `
        -LiteralPath $requirementsPath `
        -Algorithm SHA256
).Hash.ToLowerInvariant()

if ($requirementsSha256 -ne $ExpectedRequirementsSha256) {
    Fail "empreinte du profil Python inattendue : $requirementsSha256"
}

$runtimeFiles = @(
    git `
        -c "safe.directory=$AntraGit" `
        -C "$AntraRoot" `
        ls-files `
        -- `
        'antra' `
        'antra_shared' `
        'requirements-homespotify-vps.txt'
)

if ($LASTEXITCODE -ne 0) {
    Fail 'inventaire Git Antra échoué'
}

if ($runtimeFiles.Count -ne $ExpectedRuntimeFileCount) {
    Fail (
        "nombre de fichiers runtime Antra inattendu : " +
        "$($runtimeFiles.Count)"
    )
}

foreach ($relative in $runtimeFiles) {
    $normalized = $relative.Replace('\', '/').ToLowerInvariant()

    if (
        $normalized -match '(^|/)\.env($|\.)' -or
        $normalized -match '(^|/)endpoint_manifest_cache\.json$' -or
        $normalized -match '(^|/)provider_stats\.db$' -or
        $normalized -match '(^|/)(tests?|docs?|music|antra-wails|api-mirrors)(/|$)' -or
        $normalized -match '(^|/)(\.git|\.venv|__pycache__|node_modules)(/|$)' -or
        $normalized -match '\.(db|sqlite|sqlite3|log|tmp|bak|exe|dll|pdb)$'
    ) {
        Fail "fichier Antra interdit dans le runtime : $relative"
    }

    $sourcePath = Join-Path `
        $AntraRoot `
        ($relative -replace '/', '\')

    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        Fail "fichier Antra suivi mais absent : $relative"
    }
}

if (-not $SkipBuild) {
    Step 'build API'

    & pnpm.cmd `
        --filter `
        '@homespotify/api' `
        build

    if ($LASTEXITCODE -ne 0) {
        Fail 'build API échoué'
    }
}

$dist = Join-Path $RepoRoot 'services\api\dist'

if (-not (
    Test-Path `
        -LiteralPath (Join-Path $dist 'server.js') `
        -PathType Leaf
)) {
    Fail 'dist/server.js absent'
}

$staging = Join-Path $StagingRoot 'artifact'

if (Test-Path -LiteralPath $staging) {
    Remove-Item `
        -Recurse `
        -Force `
        -LiteralPath $staging
}

New-Item `
    -ItemType Directory `
    -Force `
    -Path $staging |
Out-Null

Step 'copie de dist'

Copy-Item `
    -Recurse `
    -Force `
    -LiteralPath $dist `
    -Destination (Join-Path $staging 'dist')

Step 'copie des migrations Drizzle'

$migrations = Join-Path $RepoRoot 'services\api\drizzle'

if (Test-Path -LiteralPath $migrations) {
    Copy-Item `
        -Recurse `
        -Force `
        -LiteralPath $migrations `
        -Destination (Join-Path $staging 'drizzle')
}
else {
    Step 'aucun dossier drizzle/ : migrations portées par le code'
}

Step 'copie contrôlée du runtime Antra'

$antraDestination = Join-Path $staging 'antra-runtime'

New-Item `
    -ItemType Directory `
    -Force `
    -Path $antraDestination |
Out-Null

foreach ($relative in $runtimeFiles) {
    $sourcePath = Join-Path `
        $AntraRoot `
        ($relative -replace '/', '\')

    $destinationPath = Join-Path `
        $antraDestination `
        ($relative -replace '/', '\')

    $destinationParent = Split-Path `
        -Parent `
        $destinationPath

    if (-not (Test-Path -LiteralPath $destinationParent)) {
        New-Item `
            -ItemType Directory `
            -Force `
            -Path $destinationParent |
        Out-Null
    }

    Copy-Item `
        -Force `
        -LiteralPath $sourcePath `
        -Destination $destinationPath
}

foreach ($relative in $runtimeFiles) {
    $sourcePath = Join-Path `
        $AntraRoot `
        ($relative -replace '/', '\')

    $destinationPath = Join-Path `
        $antraDestination `
        ($relative -replace '/', '\')

    $sourceHash = (
        Get-FileHash `
            -LiteralPath $sourcePath `
            -Algorithm SHA256
    ).Hash

    $destinationHash = (
        Get-FileHash `
            -LiteralPath $destinationPath `
            -Algorithm SHA256
    ).Hash

    if ($sourceHash -ne $destinationHash) {
        Fail "copie Antra divergente : $relative"
    }
}

Step 'descripteur immuable du runtime Antra'

$runtimeDescriptor = [ordered]@{
    schemaVersion = 1
    antraCommit = $antraCommit
    requirementsFile = 'requirements-homespotify-vps.txt'
    requirementsSha256 = $requirementsSha256
    runtimeId = $PythonRuntimeId
    trackedRuntimeFileCount = $runtimeFiles.Count
    requiredPythonVersion = '3.11'
    requiredSystemCommands = @(
        'ffmpeg',
        'ffprobe'
    )
} | ConvertTo-Json -Depth 8

[IO.File]::WriteAllText(
    (Join-Path $antraDestination 'runtime.json'),
    $runtimeDescriptor,
    (New-Object System.Text.UTF8Encoding($false))
)

Step 'lanceur Python lié au bundle Linux immuable'

$binDirectory = Join-Path $staging 'bin'

New-Item `
    -ItemType Directory `
    -Force `
    -Path $binDirectory |
Out-Null

# Aucun here-string imbriqué : le précédent bloc cassait le parseur PowerShell.
$launcher = @(
    '#!/usr/bin/env bash',
    'set -Eeuo pipefail',
    'exec "/opt/homespotify-api-shadow/python-runtimes/py311-antra-dbce23c5-6d0ced20/venv/bin/python" "$@"',
    ''
) -join "`n"

[IO.File]::WriteAllText(
    (Join-Path $binDirectory 'antra-python'),
    $launcher,
    (New-Object System.Text.UTF8Encoding($false))
)

Step 'package.json réduit au runtime'

$source = Get-Content `
    -Raw `
    -LiteralPath (Join-Path $RepoRoot 'services\api\package.json') |
ConvertFrom-Json

$manifestJson = [ordered]@{
    name = $source.name
    version = $source.version
    private = $true
    type = $source.type
    scripts = [ordered]@{
        start = 'node dist/server.js'
    }
    dependencies = $source.dependencies
} | ConvertTo-Json -Depth 8

[IO.File]::WriteAllText(
    (Join-Path $staging 'package.json'),
    $manifestJson,
    (New-Object System.Text.UTF8Encoding($false))
)

$commit = (
    git `
        -c "safe.directory=$RepoGit" `
        -C "$RepoRoot" `
        rev-parse HEAD
).Trim()

$builtAt = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')

Step 'manifeste'

$python = 'python'

& $python `
    (Join-Path $RepoRoot 'scripts\phase6\phase6_build_manifest.py') `
    --root $staging `
    --commit $commit `
    --built-at $builtAt `
    --bundle-id $BundleId `
    --antra-commit $antraCommit `
    --antra-requirements-sha256 $requirementsSha256 `
    --antra-runtime-id $PythonRuntimeId

if ($LASTEXITCODE -ne 0) {
    Fail 'manifeste échoué'
}

$manifest = Get-Content `
    -Raw `
    -LiteralPath (Join-Path $staging 'manifest.json') |
ConvertFrom-Json

Step (
    "releaseId={0} fichiers={1} octets={2} antra={3}" -f `
        $manifest.releaseId,
        $manifest.fileCount,
        $manifest.totalBytes,
        $manifest.antraCommit.Substring(0, 8)
)

Write-Output (
    ConvertTo-Json `
        -Compress `
        @{
            ok = $true
            releaseId = $manifest.releaseId
            staging = $staging
            fileCount = $manifest.fileCount
            totalBytes = $manifest.totalBytes
            manifestSha256 = $manifest.manifestSha256
            commit = $commit
            antraCommit = $antraCommit
            antraRequirementsSha256 = $requirementsSha256
            antraRuntimeId = $PythonRuntimeId
            antraRuntimeFileCount = $runtimeFiles.Count
        }
)
