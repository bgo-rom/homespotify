<#
.SYNOPSIS
  Orchestrateur du déploiement shadow Phase 6. `-DryRun` par défaut sûr.

.DESCRIPTION
  Point d'entrée utilisateur. Chaque étape distante reste un script séparé et
  inspectable : cet orchestrateur les enchaîne, il ne contient aucune logique
  cachée.

  `-DryRun` produit le PLAN et les artefacts LOCAUX (build, manifeste,
  snapshot SQLite) sans ouvrir la moindre connexion SSH. C'est le mode dans
  lequel la Phase 6.1 a été validée : rien n'a jamais été transféré.

  Le shadow écoute exclusivement sur 127.0.0.1:3002. Caddy, DNS, WireGuard et
  le pare-feu ne sont touchés par aucun script de cette phase.
#>
[CmdletBinding()]
param(
    [string] $VpsHost = '135.125.101.79',
    [string] $VpsUser = 'debian',
    [string] $IdentityFile = "$env:USERPROFILE\.ssh\id_ed25519",
    [string] $RepoRoot = 'F:\dev\homespotify-phase6-shadow',
    [string] $StagingRoot = 'F:\dev\homespotify-phase6-staging',
    [string] $SourceDbPath = '',
    [string] $BundleId = 'linux-x64-node22.18.0-abi127',

    # Produit le plan et les fichiers locaux, SANS aucune connexion SSH.
    [switch] $DryRun,
    # Étapes réelles, à n'utiliser qu'après validation explicite du rapport.
    [switch] $Deploy,
    [switch] $Rollback,
    [switch] $Cleanup
)

$ErrorActionPreference = 'Stop'
$ExpectedBranch = 'phase6/vps-shadow-deployment'
$ShadowPort = 3002
function Fail([string] $Message) { throw "PHASE6: $Message" }
function Step([string] $Message) { Write-Host "[phase6] $Message" }

# --- Gardes ----------------------------------------------------------------
Set-Location -LiteralPath $RepoRoot
$worktree = (git rev-parse --show-toplevel)
if ($worktree -ne ($RepoRoot -replace '\\', '/')) { Fail "worktree inattendu : $worktree" }
$branch = (git branch --show-current)
if ($branch -ne $ExpectedBranch) { Fail "branche inattendue : $branch" }

if (-not ($DryRun -or $Deploy -or $Rollback -or $Cleanup)) {
    Fail 'préciser -DryRun, -Deploy, -Rollback ou -Cleanup'
}

$remoteScripts = @(
    'vps_phase6_preflight.sh', 'vps_phase6_install_release.sh',
    'vps_phase6_systemd_setup.sh', 'vps_phase6_rollback.sh',
    'vps_phase6_cleanup.sh', 'vps_phase6_shadow_tests.py',
    'phase6_manifest.py', 'phase6_manifest_verify.py', 'phase6_paths.py',
    'homespotify-api-shadow.service', 'api-shadow.env.template'
)
foreach ($name in $remoteScripts) {
    $path = Join-Path $RepoRoot "scripts\phase6\$name"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { Fail "script absent : $name" }
}

# --- Plan ------------------------------------------------------------------
$plan = @(
    'A. build de l''artefact et manifeste (local)',
    'B. snapshot SQLite par VACUUM INTO (local, source jamais modifiée)',
    'C. transfert du staging vers le VPS (aucun npm install)',
    'D. préflight : Node v22.18.0, ABI 127, x64, hashes natifs, smoke better-sqlite3',
    'E. installation atomique : staging -> releases/<id> -> bascule de current',
    'F. systemd : systemd-analyze verify puis activation',
    'G. tests shadow sur 127.0.0.1:3002',
    'H. rollback vers previous si health échoue',
    'I. cleanup borné aux racines shadow'
)
Step 'plan de déploiement :'
$plan | ForEach-Object { Write-Host "   $_" }

if ($DryRun) {
    Step 'MODE DRY-RUN : aucune connexion SSH ne sera ouverte'

    Step 'étape A — artefact'
    $build = & (Join-Path $RepoRoot 'scripts\phase6\build_shadow_artifact.ps1') `
        -RepoRoot $RepoRoot -StagingRoot $StagingRoot -BundleId $BundleId | Select-Object -Last 1
    $buildReport = $build | ConvertFrom-Json

    $snapshotReport = $null
    if ($SourceDbPath) {
        Step 'étape B — snapshot SQLite'
        $snapshot = & (Join-Path $RepoRoot 'scripts\phase6\snapshot_sqlite_shadow.ps1') `
            -SourceDbPath $SourceDbPath -StagingRoot $StagingRoot -RepoRoot $RepoRoot | Select-Object -Last 1
        $snapshotReport = $snapshot | ConvertFrom-Json
    } else {
        Step 'étape B ignorée : -SourceDbPath non fourni'
    }

    Write-Output (ConvertTo-Json -Depth 6 @{
        mode = 'dry-run'
        sshConnectionsOpened = 0
        branch = $branch
        commit = (git rev-parse HEAD)
        plan = $plan
        artifact = $buildReport
        sqliteSnapshot = $snapshotReport
        shadowPort = $ShadowPort
        caddyTouched = $false
        wireguardTouched = $false
        firewallTouched = $false
    })
    Step 'dry-run terminé : aucun fichier envoyé, aucun service touché'
    exit 0
}

Fail 'les modes -Deploy, -Rollback et -Cleanup ne sont pas armés en Phase 6.1 : validation du rapport requise'
