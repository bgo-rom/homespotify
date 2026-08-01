<#
.SYNOPSIS
    Construit et déploie l'artefact de production du HomeSpotify Storage Agent.

.DESCRIPTION
    Phase 3. Produit un artefact ISOLÉ et REPRODUCTIBLE dans
    C:\ProgramData\HomeSpotify\StorageAgent\app.

    Pourquoi pas `pnpm deploy --prod` : à partir de pnpm 10, `deploy` exige
    `inject-workspace-packages=true` (refusé : cela changerait la configuration
    du monorepo) ou `--legacy`, et dans les deux cas l'arborescence produite est
    liée par liens durs au store pnpm GLOBAL de l'utilisateur interactif. Un
    service Windows tournant sous une identité dédiée ne doit dépendre ni du
    profil ni du store d'un utilisateur. On produit donc un `node_modules` de
    production réellement autonome avec `npm install --omit=dev`.

    Le script NE touche pas : la base SQLite, la bibliothèque musicale,
    l'index de production, le secret, le service, le pare-feu.

.PARAMETER Target
    Répertoire de l'application déployée.

.PARAMETER SkipTests
    Saute la suite de tests du Storage Agent (déconseillé).

.NOTES
    Ne requiert PAS de privilèges administrateur.
    Code de sortie 0 = succès, non nul = échec.
#>
[CmdletBinding()]
param(
    [string] $Target = 'C:\ProgramData\HomeSpotify\StorageAgent\app',
    [switch] $SkipTests
)

# Pas de Set-StrictMode : les shims PowerShell de pnpm/npm déclenchent des
# PropertyNotFoundStrict sur des objets internes qui n'ont rien à voir avec ce
# script. Les vérifications sont faites explicitement à chaque étape.
$ErrorActionPreference = 'Stop'

$RepoRoot   = Split-Path -Parent $PSScriptRoot
$AgentDir   = Join-Path $RepoRoot 'services\storage-agent'
$StagingDir = Join-Path $env:TEMP 'homespotify-storage-agent-staging'

function Step { param([string] $Message) Write-Host "[deploy] $Message" }
function Fail { param([string] $Message) Write-Host "[deploy] ECHEC : $Message"; exit 1 }

if (-not (Test-Path $AgentDir)) { Fail "workspace introuvable : $AgentDir" }

# --- 1. Build + tests -------------------------------------------------------
Step 'compilation TypeScript'
Push-Location $RepoRoot
try {
    pnpm --filter '@homespotify/storage-agent' build | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail 'la compilation a échoué' }

    if (-not $SkipTests) {
        Step 'suite de tests du Storage Agent'
        pnpm --filter '@homespotify/storage-agent' test | Out-Null
        if ($LASTEXITCODE -ne 0) { Fail 'des tests échouent — déploiement interrompu' }
    }
} finally {
    Pop-Location
}

$DistDir = Join-Path $AgentDir 'dist'
if (-not (Test-Path (Join-Path $DistDir 'main.js'))) { Fail 'dist\main.js absent après compilation' }

# --- 2. Version exacte de fastify, lue depuis la résolution du workspace -----
Step 'résolution de la version de production de fastify'
Push-Location $AgentDir
try {
    # Pas de redirection `2>` : en PowerShell 5.1 elle transforme la moindre
    # ligne de stderr de pnpm en NativeCommandError terminante.
    $listed = (pnpm list fastify --depth 0 --json | Out-String) | ConvertFrom-Json
    $FastifyVersion = $listed.dependencies.fastify.version
} finally {
    Pop-Location
}
if ([string]::IsNullOrWhiteSpace($FastifyVersion)) { Fail 'version de fastify non résolue' }
Step "fastify $FastifyVersion (épinglée exactement)"

# --- 3. Staging isolé -------------------------------------------------------
Step "staging : $StagingDir"
if (Test-Path $StagingDir) { Remove-Item $StagingDir -Recurse -Force }
New-Item -ItemType Directory -Path $StagingDir -Force | Out-Null
Copy-Item $DistDir (Join-Path $StagingDir 'dist') -Recurse

$pkg = [ordered]@{
    name         = '@homespotify/storage-agent'
    version      = (Get-Content (Join-Path $AgentDir 'package.json') -Raw | ConvertFrom-Json).version
    private      = $true
    type         = 'module'
    description  = 'HomeSpotify Storage Agent - artefact de deploiement Phase 3'
    main         = 'dist/main.js'
    dependencies = [ordered]@{ fastify = $FastifyVersion }
}
$pkg | ConvertTo-Json -Depth 5 | Out-File (Join-Path $StagingDir 'package.json') -Encoding utf8

Step 'installation des dépendances de production (autonomes, hors store pnpm)'
Push-Location $StagingDir
try {
    npm install --omit=dev --no-audit --no-fund | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail 'npm install a échoué' }
} finally {
    Pop-Location
}

$links = @(Get-ChildItem (Join-Path $StagingDir 'node_modules') -Recurse -Force |
           Where-Object { $_.LinkType })
if ($links.Count -gt 0) { Fail "$($links.Count) lien(s) résiduel(s) dans node_modules — artefact non autonome" }

# --- 4. Publication atomique-par-miroir ------------------------------------
Step "publication vers $Target"
New-Item -ItemType Directory -Path $Target -Force | Out-Null
robocopy $StagingDir $Target /MIR /NFL /NDL /NJH /NJS /NP | Out-Null
# robocopy : 0-7 = succès, >= 8 = erreur
if ($LASTEXITCODE -ge 8) { Fail "robocopy a échoué (code $LASTEXITCODE)" }

if (-not (Test-Path (Join-Path $Target 'dist\main.js')))        { Fail 'dist\main.js absent de la cible' }
if (-not (Test-Path (Join-Path $Target 'node_modules\fastify'))) { Fail 'fastify absent de la cible' }

$files = @(Get-ChildItem $Target -Recurse -File)
$sizeMb = [math]::Round((($files | Measure-Object Length -Sum).Sum) / 1MB, 1)
Step "artefact publié : $($files.Count) fichiers, $sizeMb Mo"

Remove-Item $StagingDir -Recurse -Force
Step 'terminé'
exit 0
