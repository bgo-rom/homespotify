<#
.SYNOPSIS
  Orchestrateur du déploiement shadow Phase 6. `-DryRun` par défaut sûr.

.DESCRIPTION
  Point d'entrée utilisateur. Chaque étape distante reste un script séparé et
  inspectable : cet orchestrateur les enchaîne, il ne contient aucune logique
  cachée.

  MODES ARMÉS
  -----------
  `-DryRun`         produit le PLAN et les artefacts LOCAUX sans aucune
                    connexion SSH. C'est le mode de la Phase 6.1.
  `-StageOnly`      Phase 6.2 : dépose une release COMPLÈTE dans une racine de
                    staging non privilégiée du VPS, puis s'arrête. Aucun
                    service, aucun utilisateur système, aucun listener, aucune
                    écriture sous /opt, /var/lib ou /etc.
  `-CleanupStaging` supprime intégralement cette racine de staging, et rien
                    d'autre.

  `-Deploy` et `-Rollback` restent DÉSARMÉS : ils appartiennent à la Phase 6.3
  et exigent une validation explicite du rapport 6.2.

  SECRETS
  -------
  Aucun secret ne transite par un argument. Deux sources sont acceptées :
  saisie masquée (défaut), ou lecture interne des fichiers de configuration
  Windows existants (`-SecretsFromWindowsConfig`). Les valeurs ne sont jamais
  affichées, jamais journalisées, jamais écrites ailleurs que dans le fichier
  d'environnement 0600.

  Le shadow écoutera exclusivement sur 127.0.0.1:3002 — plus tard. Caddy, DNS,
  WireGuard et le pare-feu ne sont touchés par aucun script de cette phase.
#>
[CmdletBinding()]
param(
    [string] $VpsHost = '135.125.101.79',
    [string] $VpsUser = 'debian',
    [string] $IdentityFile = "$env:USERPROFILE\.ssh\id_ed25519",
    [string] $RepoRoot = 'F:\dev\homespotify-phase6-final-c',
    [string] $StagingRoot = 'F:\dev\homespotify-phase6-staging',

    # Entrées réelles. Ce sont des CHEMINS, jamais des secrets.
    [string] $SourceDbPath = '',
    [string] $SourceCoversPath = '',
    [string] $BundleId = 'linux-x64-node22.18.0-abi127',

    # Secrets : saisie masquée par défaut, lecture de configuration sur demande.
    [switch] $SecretsFromWindowsConfig,
    [string] $ApiEnvPath = 'F:\dev\homespotify\services\api\.env',
    [string] $AgentEnvPath = 'C:\ProgramData\HomeSpotify\StorageAgent\config\agent.env',
    # Réutiliser le AUTH_TOKEN_SECRET de production est un CHOIX, jamais un
    # défaut : un shadow qui signe avec la clé de production émet des jetons
    # que la production accepte. Voir `Get-ShadowSecrets`.
    [switch] $ReuseProductionAuthSecret,

    # Secours si la sélection automatique de pistes échoue.
    [int] $TrackIdCached = 0,
    [int] $TrackIdUncached = 0,

    [switch] $SkipBuild,

    # --- Modes -------------------------------------------------------------
    [switch] $DryRun,
    [switch] $StageOnly,
    [switch] $CleanupStaging,
    # Phase 6.3 : installe le contenu qualifié, démarre le shadow, teste.
    [switch] $Activate,
    [string] $ReleaseId = '20260728T185102Z-84c0e294-768af2fe',
    # Controle de lisibilite, pas de securite : la preuve de contenu est
    # l'empreinte du manifeste, portee par le release-id lui-meme.
    [int] $ExpectedFileCount = 119,
    [int] $MonitorSeconds = 900,
    [switch] $KeepStaging,
    [switch] $RollbackInstall,
    [switch] $Deploy,
    [switch] $Rollback,
    [switch] $Cleanup
)

$ErrorActionPreference = 'Stop'
$ExpectedBranch = 'phase6/vps-final-c'
$ShadowPort = 3002
$RemoteStagingRoot = '/home/debian/homespotify-phase6-staging'
$RemoteBundleSource = '/home/debian/homespotify-phase45/api/node_modules'

$script:SshConnections = 0

# Encodage des flux envoyés aux processus natifs (python) : UTF-8 SANS BOM.
# Le défaut de Windows PowerShell 5.1 préfixe un BOM, que le lecteur prend
# pour du contenu. `phase6_env.py` décode en `utf-8-sig` par précaution ; ce
# réglage évite de compter dessus.
$OutputEncoding = New-Object System.Text.UTF8Encoding($false)

# Aucun `.pyc` produit par les outils locaux : ils saliraient l'arbre de
# travail, et le garde d'arbre propre refuserait l'activation pour un
# artefact que personne n'a écrit à la main (même raison que L-111 côté VPS).
$env:PYTHONDONTWRITEBYTECODE = '1'

function Fail([string] $Message) { throw "PHASE6: $Message" }
function Step([string] $Message) { Write-Host "[phase6] $Message" }

# --- Gardes ----------------------------------------------------------------
Set-Location -LiteralPath $RepoRoot
$worktree = (git rev-parse --show-toplevel)
if ($worktree -ne ($RepoRoot -replace '\\', '/')) { Fail "worktree inattendu : $worktree" }
$branch = (git branch --show-current)
if ($branch -ne $ExpectedBranch) { Fail "branche inattendue : $branch" }

$modes = @($DryRun, $StageOnly, $CleanupStaging, $Activate, $RollbackInstall,
           $Deploy, $Rollback, $Cleanup) | Where-Object { $_ }
if ($modes.Count -eq 0) {
    Fail 'préciser -DryRun, -StageOnly, -CleanupStaging, -Activate, -RollbackInstall, -Deploy, -Rollback ou -Cleanup'
}
if ($modes.Count -gt 1) { Fail 'un seul mode à la fois' }

$remoteScripts = @(
    'vps_phase6_preflight.sh', 'vps_phase6_install_release.sh',
    'vps_phase6_systemd_setup.sh', 'vps_phase6_rollback.sh',
    'vps_phase6_cleanup.sh', 'vps_phase6_shadow_tests.py',
    'vps_phase6_stage_preflight.sh', 'vps_phase6_staging_cleanup.sh',
    'vps_phase6_activate_shadow.sh', 'vps_phase6_start_shadow.sh',
    'vps_phase6_monitor.sh',
    'vps_phase6_preinstall_check.sh',
    'phase6_manifest.py', 'phase6_manifest_verify.py', 'phase6_paths.py',
    'phase6_staging.py', 'phase6_covers.py', 'phase6_env.py',
    'phase6_select_tracks.py', 'phase6_probe_agent.mjs',
    'phase6_shadow_token.mjs',
    'homespotify-api-shadow.service', 'api-shadow.env.template'
)

# Outils déposés sur le VPS, puis installés sous /opt par l'activation : le
# staging disparaît en fin de phase, la Phase 6.4 aura encore besoin d'eux.
$activationTools = @(
    'phase6_manifest.py', 'phase6_manifest_verify.py', 'phase6_paths.py',
    'phase6_covers.py', 'phase6_env.py', 'phase6_probe_agent.mjs',
    'phase6_shadow_token.mjs', 'vps_phase6_preflight.sh',
    'vps_phase6_shadow_tests.py', 'vps_phase6_monitor.sh',
    'vps_phase6_start_shadow.sh'
)
foreach ($name in $remoteScripts) {
    $path = Join-Path $RepoRoot "scripts\phase6\$name"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { Fail "script absent : $name" }
}

# --- Outils ----------------------------------------------------------------

function Invoke-Ssh {
    <#
      Une connexion SSH, comptée. `BatchMode=yes` : jamais de prompt
      interactif, donc jamais d'attente silencieuse sur un mot de passe.

      Le script distant voyage en BASE64 plutôt que par STDIN. Windows
      PowerShell 5.1 encode ce qu'il envoie à un processus natif avec
      l'encodage de console, BOM compris : le BOM devenait le premier
      caractère de la première ligne et `bash` refusait un script valide avec
      « set: command not found ». Le base64 rend le transport insensible à
      l'encodage, et ce qui traverse la ligne de commande distante est un
      script public — aucun secret, aucun chemin de production n'y figure.
    #>
    param([string] $ScriptText, [string[]] $Arguments = @(), [switch] $AsRoot)
    $script:SshConnections++
    # Fins de ligne normalisées en LF. `.gitattributes` extrait les `.ps1` en
    # CRLF : sans cette ligne, les here-strings de ce fichier voyageraient avec
    # des `\r`, et `bash` refuserait `set -Eeuo pipefail` par un
    # « set: pipefail\r: invalid option name » — message qui ne désigne pas sa
    # cause. La normalisation vaut aussi pour les `.sh` lus sur un poste où la
    # normalisation Git n'aurait pas eu lieu.
    $normalized = $ScriptText -replace "`r`n", "`n"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($normalized))
    $remoteArgs = if ($Arguments.Count -gt 0) { ' ' + ($Arguments -join ' ') } else { '' }
    # `-AsRoot` pour les contrôles qui LISENT des chemins privilégiés. Sans
    # lui, `readlink /opt/homespotify-api-shadow/current` échoue en
    # « permission refusée » et un `|| echo` traduit cela en « absent » : le
    # rapport affirme alors qu'il n'y a rien là où tout est installé.
    $shell = if ($AsRoot) { 'sudo -n bash -s --' } else { 'bash -s --' }
    $command = "echo $encoded | base64 -d | $shell$remoteArgs"
    $target = "$VpsUser@$VpsHost"
    $output = & ssh -o BatchMode=yes -o ConnectTimeout=15 `
        -i $IdentityFile $target $command 2>&1
    # `Out-String` replie les lignes à la largeur de la console : une ligne
    # JSON longue en ressort coupée en deux, et l'analyse échoue sur une
    # « chaîne inachevée » alors que la commande distante a parfaitement
    # réussi. Le tableau est donc joint tel quel.
    return @{ ExitCode = $LASTEXITCODE; Output = (($output | ForEach-Object { "$_" }) -join "`n") }
}

function Invoke-Scp {
    param([string[]] $LocalPaths, [string] $RemotePath)
    $script:SshConnections++
    $target = "$VpsUser@${VpsHost}:$RemotePath"
    $output = & scp -q -o BatchMode=yes -o ConnectTimeout=15 -i $IdentityFile `
        -r @LocalPaths $target 2>&1
    if ($LASTEXITCODE -ne 0) { Fail "scp échoué vers $RemotePath : $output" }
}

function Get-LastJson([string] $Text) {
    <#
      Dernier objet JSON de la sortie, RECOLLÉ s'il a été replié.

      Une ligne JSON longue peut ressortir coupée en plusieurs morceaux :
      l'hôte PowerShell replie à la largeur de la console tout ce qui transite
      par le flux d'erreur fusionné. Chercher « la dernière ligne qui commence
      par { » donnait alors un fragment, et l'analyse échouait par « chaîne
      inachevée » — sur une commande distante qui avait parfaitement réussi.
      L'outil de rapport faisait échouer ce qu'il devait constater.

      On accumule donc les lignes suivantes jusqu'à ce que l'ensemble
      s'analyse, et on retient le dernier objet valide.
    #>
    $lines = $Text -split "`r?`n"
    $result = $null
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if (-not $lines[$i].TrimStart().StartsWith('{')) { continue }
        $buffer = ''
        for ($j = $i; $j -lt $lines.Count; $j++) {
            $buffer += $lines[$j]
            try {
                $candidate = $buffer | ConvertFrom-Json -ErrorAction Stop
                $result = $candidate
                $i = $j
                break
            } catch {
                # Fragment encore incomplet : on ajoute la ligne suivante.
            }
        }
    }
    return $result
}

function ConvertFrom-SecureStringPlain([System.Security.SecureString] $Secure) {
    # Le clair n'existe que le temps du rendu, et n'est jamais affiché.
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
}

function Read-SecretFromEnvFile([string] $Path, [string] $Key) {
    <#
      Lecture INTERNE d'un fichier de configuration Windows existant. La
      valeur est convertie en SecureString immédiatement et la variable claire
      est écrasée : elle ne survit pas à cette fonction.
    #>
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Fail "configuration absente : $([IO.Path]::GetFileName($Path))"
    }
    $secure = $null
    foreach ($line in (Get-Content -LiteralPath $Path)) {
        $trimmed = $line.Trim()
        if ($trimmed.StartsWith('#') -or -not $trimmed.Contains('=')) { continue }
        $name, $value = $trimmed -split '=', 2
        if ($name.Trim() -ne $Key) { continue }
        $value = $value.Trim()
        if ($value.Length -gt 0) {
            $secure = ConvertTo-SecureString -String $value -AsPlainText -Force
        }
        $value = $null
        break
    }
    if ($null -eq $secure) { Fail "clé absente de la configuration : $Key" }
    return $secure
}

function New-ShadowAuthSecret {
    <#
      Secret de signature PROPRE au shadow, tiré du CSPRNG du système.

      Pourquoi ne pas réutiliser celui de production : `AUTH_TOKEN_SECRET` est
      la clé HMAC des access tokens. Deux instances qui la partagent acceptent
      mutuellement leurs jetons — un jeton émis par le shadow, alimenté par
      une base jetable, ouvrirait une session sur la production. Le shadow
      qualifie le stockage ; il n'a aucune raison d'hériter de cette autorité.

      Le secret n'est jamais affiché ni conservé sur ce poste : il ne vit que
      dans le fichier 0600 déposé sur le VPS.
    #>
    $bytes = New-Object byte[] 48
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $hex = -join ($bytes | ForEach-Object { $_.ToString('x2') })
    $secure = ConvertTo-SecureString -String $hex -AsPlainText -Force
    $hex = $null
    [Array]::Clear($bytes, 0, $bytes.Length)
    return $secure
}

function Get-ShadowSecrets {
    <#
      Renvoie les deux secrets en SecureString. Refuse AVANT toute connexion
      SSH si l'un manque ou est trop court : ouvrir une connexion pour
      découvrir ensuite qu'on n'a rien à déposer serait une connexion inutile
      vers la production.

      Les deux secrets n'ont pas la même nature. `AUDIO_REMOTE_SHARED_SECRET`
      est PARTAGÉ par construction : il doit être exactement celui du Storage
      Agent, sinon aucune requête n'est signée valablement.
      `AUTH_TOKEN_SECRET`, lui, est PROPRE à l'instance et généré ici par
      défaut.
    #>
    if ($SecretsFromWindowsConfig) {
        Step 'secrets : lecture interne de la configuration Windows'
        $remote = Read-SecretFromEnvFile -Path $AgentEnvPath -Key 'STORAGE_AGENT_SHARED_SECRET'
    } else {
        Step 'secrets : saisie masquée (aucune frappe affichée)'
        $remote = Read-Host -AsSecureString -Prompt 'AUDIO_REMOTE_SHARED_SECRET (Storage Agent)'
    }
    if ($ReuseProductionAuthSecret) {
        Step 'AUTH_TOKEN_SECRET : réutilisation explicite du secret de production'
        $auth = Read-SecretFromEnvFile -Path $ApiEnvPath -Key 'AUTH_TOKEN_SECRET'
    } elseif ($SecretsFromWindowsConfig) {
        Step 'AUTH_TOKEN_SECRET : généré pour le shadow (jamais celui de production)'
        $auth = New-ShadowAuthSecret
    } else {
        $auth = Read-Host -AsSecureString -Prompt 'AUTH_TOKEN_SECRET (propre au shadow, vide = généré)'
        if ($auth.Length -eq 0) {
            Step 'AUTH_TOKEN_SECRET : généré pour le shadow'
            $auth = New-ShadowAuthSecret
        }
    }
    foreach ($pair in @(@('AUDIO_REMOTE_SHARED_SECRET', $remote), @('AUTH_TOKEN_SECRET', $auth))) {
        if ($null -eq $pair[1] -or $pair[1].Length -eq 0) { Fail "secret absent : $($pair[0])" }
        if ($pair[1].Length -lt 32) { Fail "secret trop court : $($pair[0])" }
    }
    Step ('secrets : secretPresent=true longueurConforme=true (aucune valeur publiée)')
    return @{ AUDIO_REMOTE_SHARED_SECRET = $remote; AUTH_TOKEN_SECRET = $auth }
}

function New-PrivateTempFile([string] $Extension) {
    <#
      Fichier temporaire dont l'ACL est réduite au seul utilisateur courant.
      Windows n'a pas de bit 0600 : l'héritage d'ACL du dossier TEMP est donc
      coupé explicitement, sinon le fichier resterait lisible par les groupes
      hérités.
    #>
    $path = Join-Path $env:TEMP ("hs-phase62-{0}{1}" -f ([guid]::NewGuid().ToString('N')), $Extension)
    New-Item -ItemType File -Path $path -Force | Out-Null
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $acl = Get-Acl -LiteralPath $path
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($rule in @($acl.Access)) { [void]$acl.RemoveAccessRule($rule) }
    $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
        $identity, 'FullControl', 'None', 'None', 'Allow')))
    Set-Acl -LiteralPath $path -AclObject $acl
    return $path
}

# --- Plan ------------------------------------------------------------------
$plan = @(
    'A. build de l''artefact et manifeste (local)',
    'B. snapshot SQLite par VACUUM INTO (local, source jamais modifiée)',
    'C. manifeste des pochettes (local, liens symboliques refusés)',
    'D. sélection de deux pistes réelles depuis le snapshot',
    'E. rendu du fichier d''environnement 0600 (secrets par stdin)',
    'F. dépôt en staging non privilégié sur le VPS (dépendances jamais recompilées)',
    'G. préflight distant : Node/ABI/hashes/SQLite/manifeste/port/service',
    'H. [6.3] installation systemd — NON ARMÉE',
    'I. cleanup borné à la racine de staging'
)
Step 'plan de déploiement :'
$plan | ForEach-Object { Write-Host "   $_" }

# =========================================================================
# MODE DRY-RUN
# =========================================================================
if ($DryRun) {
    Step 'MODE DRY-RUN : aucune connexion SSH ne sera ouverte'

    Step 'étape A — artefact'
    $dryBuildArgs = @{ RepoRoot = $RepoRoot; StagingRoot = $StagingRoot; BundleId = $BundleId }
    if ($SkipBuild) { $dryBuildArgs['SkipBuild'] = $true }
    $build = & (Join-Path $RepoRoot 'scripts\phase6\build_shadow_artifact.ps1') @dryBuildArgs |
        Select-Object -Last 1
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

    $coversReport = $null
    if ($SourceCoversPath) {
        Step 'étape C — pochettes'
        $covers = & python (Join-Path $RepoRoot 'scripts\phase6\phase6_covers.py') `
            --root $SourceCoversPath | Select-Object -Last 1
        $coversReport = $covers | ConvertFrom-Json
    } else {
        Step 'étape C ignorée : -SourceCoversPath non fourni'
    }

    Write-Output (ConvertTo-Json -Depth 6 @{
        mode = 'dry-run'
        sshConnectionsOpened = $script:SshConnections
        branch = $branch
        commit = (git rev-parse HEAD)
        plan = $plan
        artifact = $buildReport
        sqliteSnapshot = $snapshotReport
        covers = $coversReport
        shadowPort = $ShadowPort
        secretsPrinted = 0
        caddyTouched = $false
        wireguardTouched = $false
        firewallTouched = $false
        productionModified = $false
    })
    Step 'dry-run terminé : aucun fichier envoyé, aucun service touché'
    exit 0
}

# =========================================================================
# MODE CLEANUP-STAGING
# =========================================================================
if ($CleanupStaging) {
    Step 'MODE CLEANUP-STAGING : seule la racine de staging est supprimée'
    # Le script ne prend AUCUNE cible en argument : la racine est écrite en dur
    # dans le script distant. Il est envoyé par STDIN, donc il n'a même pas
    # besoin d'exister sur le VPS pour que le nettoyage soit possible.
    $cleanupScript = Get-Content -Raw -LiteralPath `
        (Join-Path $RepoRoot 'scripts\phase6\vps_phase6_staging_cleanup.sh')
    $result = Invoke-Ssh -ScriptText $cleanupScript
    $report = Get-LastJson $result.Output
    if ($null -eq $report) { Fail "sortie de cleanup illisible : $($result.Output)" }
    if (-not $report.ok) { Fail "cleanup refusé : $($report.error) $($report.detail)" }

    Write-Output (ConvertTo-Json -Depth 6 @{
        mode = 'cleanup-staging'
        sshConnectionsOpened = $script:SshConnections
        root = $report.root
        rootRemoved = $report.rootRemoved
        remainingStagingFiles = $report.remainingStagingFiles
        remainingSecretFiles = $report.remainingSecretFiles
        remainingListeners = $report.remainingListeners
        port3002Free = $report.port3002Free
        preservedProtectedPaths = $report.preservedProtectedPaths
        bundleSourcePresent = $report.bundleSourcePresent
        shadowServiceCount = $report.shadowServiceCount
        secretsPrinted = 0
        productionModified = $false
        ok = $true
    })
    Step 'cleanup terminé : racine de staging supprimée, rien d''autre touché'
    exit 0
}

# =========================================================================
# MODE STAGE-ONLY  (Phase 6.2)
# =========================================================================
if ($StageOnly) {
    Step 'MODE STAGE-ONLY : dépôt sans activation'

    # --- 0. Entrées obligatoires, vérifiées AVANT toute connexion ----------
    if (-not $SourceDbPath) { Fail '-SourceDbPath requis en -StageOnly' }
    if (-not $SourceCoversPath) { Fail '-SourceCoversPath requis en -StageOnly' }
    if (-not (Test-Path -LiteralPath $SourceDbPath -PathType Leaf)) {
        Fail "base source introuvable : $([IO.Path]::GetFileName($SourceDbPath))"
    }
    if (-not (Test-Path -LiteralPath $SourceCoversPath -PathType Container)) {
        Fail "répertoire de pochettes introuvable : $([IO.Path]::GetFileName($SourceCoversPath))"
    }
    $dirty = (git status --porcelain --untracked-files=no)
    if ($dirty) { Fail 'arbre de travail non propre' }

    # Les secrets sont acquis MAINTENANT : si l'un manque, on échoue sans
    # avoir ouvert une seule connexion.
    $secrets = Get-ShadowSecrets

    $payload = Join-Path $StagingRoot 'payload'
    $envTemp = $null
    try {
        if (Test-Path -LiteralPath $payload) { Remove-Item -Recurse -Force -LiteralPath $payload }
        New-Item -ItemType Directory -Force -Path $payload | Out-Null

        # --- A. Artefact --------------------------------------------------
        Step 'étape A — artefact'
        $buildArgs = @{ RepoRoot = $RepoRoot; StagingRoot = $StagingRoot; BundleId = $BundleId }
        if ($SkipBuild) { $buildArgs['SkipBuild'] = $true }
        $build = & (Join-Path $RepoRoot 'scripts\phase6\build_shadow_artifact.ps1') @buildArgs |
            Select-Object -Last 1
        $buildReport = $build | ConvertFrom-Json
        if (-not $buildReport.ok) { Fail 'assemblage de l''artefact échoué' }
        $stagedReleaseId = $buildReport.releaseId

        $releaseDir = Join-Path $payload "releases\$stagedReleaseId.staging"
        New-Item -ItemType Directory -Force -Path (Join-Path $payload 'releases') | Out-Null
        Copy-Item -Recurse -Force -LiteralPath $buildReport.staging -Destination $releaseDir

        # Contrôle local du manifeste AVANT transfert : un artefact déjà faux
        # ici ne mérite pas une connexion.
        $localVerify = & python (Join-Path $RepoRoot 'scripts\phase6\phase6_manifest_verify.py') `
            $releaseDir | Select-Object -Last 1
        $localVerifyReport = $localVerify | ConvertFrom-Json
        if (-not $localVerifyReport.ok) { Fail "manifeste local divergent : $($localVerifyReport.problems)" }
        $mapCount = @(Get-ChildItem -Recurse -File -LiteralPath $releaseDir -Filter '*.map').Count
        if ($mapCount -ne 0) { Fail "source maps présentes dans l'artefact : $mapCount" }

        # --- B. Snapshot SQLite -------------------------------------------
        Step 'étape B — snapshot SQLite (VACUUM INTO, source en lecture seule)'
        $snapshot = & (Join-Path $RepoRoot 'scripts\phase6\snapshot_sqlite_shadow.ps1') `
            -SourceDbPath $SourceDbPath -StagingRoot $StagingRoot -RepoRoot $RepoRoot |
            Select-Object -Last 1
        $snapshotReport = $snapshot | ConvertFrom-Json
        if (-not $snapshotReport.ok) { Fail 'snapshot SQLite refusé' }
        New-Item -ItemType Directory -Force -Path (Join-Path $payload 'data\sqlite') | Out-Null
        Copy-Item -Force -LiteralPath $snapshotReport.snapshotPath `
            -Destination (Join-Path $payload 'data\sqlite\runtime-shadow.db')

        # --- C. Pochettes --------------------------------------------------
        Step 'étape C — pochettes'
        $coversPayload = Join-Path $payload 'data\covers'
        New-Item -ItemType Directory -Force -Path $coversPayload | Out-Null
        $coversManifestPath = Join-Path $payload 'data\covers-manifest.json'
        $coversRaw = & python (Join-Path $RepoRoot 'scripts\phase6\phase6_covers.py') `
            --root $SourceCoversPath --out $coversManifestPath 2>&1 | Select-Object -Last 1
        $coversReport = Get-LastJson ([string]$coversRaw)
        if ($null -eq $coversReport -or -not $coversReport.ok) {
            # NO-GO explicite plutôt qu'un COVERS_DIR vide non documenté : la
            # cause est nommée dans le message d'arrêt, pas déduite d'un zéro.
            $cause = if ($null -eq $coversReport) { 'inventaire illisible' } else { $coversReport.error }
            Fail ("NO-GO pochettes : {0}" -f $cause)
        }
        # Seuls les fichiers RETENUS par le manifeste sont copiés : le payload
        # est égal au manifeste par construction, pas par chance.
        $coversManifest = Get-Content -Raw -LiteralPath $coversManifestPath | ConvertFrom-Json
        foreach ($entry in $coversManifest.files) {
            $source = Join-Path $SourceCoversPath ($entry.path -replace '/', '\')
            $destination = Join-Path $coversPayload ($entry.path -replace '/', '\')
            $parent = Split-Path -Parent $destination
            if (-not (Test-Path -LiteralPath $parent)) {
                New-Item -ItemType Directory -Force -Path $parent | Out-Null
            }
            Copy-Item -Force -LiteralPath $source -Destination $destination
        }
        Step ("pochettes : {0} fichiers, {1} octets" -f `
            $coversReport.coverFileCount, $coversReport.coverBytes)

        # --- D. Sélection des pistes ---------------------------------------
        Step 'étape D — sélection de pistes réelles depuis le snapshot'
        $selectionRaw = (& python (Join-Path $RepoRoot 'scripts\phase6\phase6_select_tracks.py') `
            --db (Join-Path $payload 'data\sqlite\runtime-shadow.db') 2>&1 | ForEach-Object { "$_" }) -join "`n"
        $selection = Get-LastJson $selectionRaw
        $candidates = @()
        if ($null -ne $selection -and $selection.ok) {
            $candidates = @($selection.candidates)
        } elseif ($TrackIdCached -le 0 -or $TrackIdUncached -le 0) {
            Fail 'sélection automatique impossible : fournir -TrackIdCached et -TrackIdUncached'
        }

        # --- E. Environnement -----------------------------------------------
        Step 'étape E — fichier d''environnement (secrets par stdin, jamais argv)'
        $envTemp = New-PrivateTempFile '.env'
        $template = Join-Path $RepoRoot 'scripts\phase6\api-shadow.env.template'
        $payloadJson = ConvertTo-Json -Compress @{
            AUDIO_REMOTE_SHARED_SECRET = (ConvertFrom-SecureStringPlain $secrets.AUDIO_REMOTE_SHARED_SECRET)
            AUTH_TOKEN_SECRET = (ConvertFrom-SecureStringPlain $secrets.AUTH_TOKEN_SECRET)
        }
        $envRaw = ($payloadJson | & python (Join-Path $RepoRoot 'scripts\phase6\phase6_env.py') `
            --template $template --out $envTemp 2>&1 | ForEach-Object { "$_" }) -join "`n"
        $payloadJson = $null
        [GC]::Collect()
        $envReport = Get-LastJson $envRaw
        if ($null -eq $envReport -or -not $envReport.ok) {
            $cause = if ($null -eq $envReport) { 'rendu illisible' } else { ($envReport.problems -join ',') }
            Fail "environnement refusé : $cause"
        }

        # --- F. Dépôt en staging -------------------------------------------
        Step 'étape F — dépôt en staging (aucune écriture hors de la racine)'

        $tools = Join-Path $payload 'tools'
        New-Item -ItemType Directory -Force -Path $tools | Out-Null
        foreach ($name in @('phase6_manifest.py', 'phase6_manifest_verify.py',
                            'phase6_paths.py', 'phase6_staging.py', 'phase6_covers.py',
                            'phase6_env.py', 'phase6_select_tracks.py',
                            'phase6_probe_agent.mjs')) {
            Copy-Item -Force -LiteralPath (Join-Path $RepoRoot "scripts\phase6\$name") `
                -Destination (Join-Path $tools $name)
        }

        $prepare = @"
set -Eeuo pipefail
ROOT='$RemoteStagingRoot'
case "`$ROOT" in /home/debian/homespotify-phase6-staging) : ;; *) echo '{"ok":false,"error":"RACINE_INATTENDUE"}'; exit 1 ;; esac
mkdir -p "`$ROOT"/{releases,dependency-bundles,data/covers,data/sqlite,reports,tools}
mkdir -p "`$ROOT/secrets"
chmod 700 "`$ROOT/secrets"
CADDY_SHA="`$(sha256sum /etc/caddy/Caddyfile 2>/dev/null | cut -d' ' -f1)"
LISTEN="`$(ss -ltnH 2>/dev/null | awk '{print `$4}' | grep -c ':3002`$' || true)"
SVC="`$(systemctl list-unit-files 2>/dev/null | grep -c 'homespotify-api-shadow' || true)"
printf '{"ok":true,"caddySha256":"%s","listeners3002":%s,"shadowServiceCount":%s,"node":"%s","abi":"%s"}\n' \
  "`$CADDY_SHA" "`$LISTEN" "`$SVC" "`$(node -v)" "`$(node -p process.versions.modules)"
"@
        $prepareResult = Invoke-Ssh -ScriptText $prepare
        $baseline = Get-LastJson $prepareResult.Output
        if ($null -eq $baseline -or -not $baseline.ok) {
            Fail "préparation du staging échouée : $($prepareResult.Output)"
        }
        if ($baseline.listeners3002 -ne 0) { Fail 'le port 3002 est déjà occupé' }
        if ($baseline.shadowServiceCount -ne 0) { Fail 'un service shadow existe déjà' }

        Invoke-Scp -LocalPaths @(
            (Join-Path $payload 'releases'), (Join-Path $payload 'data'),
            (Join-Path $payload 'tools')
        ) -RemotePath "$RemoteStagingRoot/"
        Invoke-Scp -LocalPaths @($envTemp) -RemotePath "$RemoteStagingRoot/secrets/api-shadow.env"

        # Bundle : COPIE depuis l'arbre Phase 4.5, jamais un déplacement. La
        # source est ensuite re-mesurée pour prouver qu'elle est intacte.
        $finalize = @"
set -Eeuo pipefail
ROOT='$RemoteStagingRoot'
SRC='$RemoteBundleSource'
BUNDLE="`$ROOT/dependency-bundles/$BundleId"
# Le sous-répertoire DOIT s'appeler node_modules : c'est ce nom, et lui seul,
# que Node cherche en remontant l'arborescence pour résoudre les dépendances
# pairs (`bindings` pour better-sqlite3).
MODULES="`$BUNDLE/node_modules"
test -d "`$SRC" || { echo '{"ok":false,"error":"BUNDLE_SOURCE_ABSENT"}'; exit 1; }
BEFORE="`$(sha256sum "`$SRC/better-sqlite3/build/Release/better_sqlite3.node" | cut -d' ' -f1)"
if [ ! -d "`$MODULES" ]; then
  mkdir -p "`$MODULES"
  cp -a "`$SRC/." "`$MODULES/"
fi
AFTER="`$(sha256sum "`$SRC/better-sqlite3/build/Release/better_sqlite3.node" | cut -d' ' -f1)"
[ "`$BEFORE" = "`$AFTER" ] || { echo '{"ok":false,"error":"SOURCE_ALTEREE"}'; exit 1; }
chmod 600 "`$ROOT/secrets/api-shadow.env"
chmod 700 "`$ROOT/secrets"
chmod -R go-w "`$ROOT/releases" "`$ROOT/dependency-bundles"
printf '{"ok":true,"bundleBytes":%s,"bundleEntries":%s,"sourceUnchanged":true,"envMode":"%s","secretsMode":"%s"}\n' \
  "`$(du -sb "`$MODULES" | cut -f1)" "`$(ls -1 "`$MODULES" | wc -l)" \
  "`$(stat -c '%a' "`$ROOT/secrets/api-shadow.env")" "`$(stat -c '%a' "`$ROOT/secrets")"
"@
        $finalizeResult = Invoke-Ssh -ScriptText $finalize
        $bundleReport = Get-LastJson $finalizeResult.Output
        if ($null -eq $bundleReport -or -not $bundleReport.ok) {
            Fail "mise en place du bundle échouée : $($finalizeResult.Output)"
        }

        # --- D bis. Validation des pistes par HEAD réel ----------------------
        $trackReport = $null
        $selectedTracks = @()
        $probeIds = @()
        if ($candidates.Count -gt 0) { $probeIds = @($candidates | ForEach-Object { $_.trackId }) }
        if ($TrackIdCached -gt 0) { $probeIds = @($TrackIdCached, $TrackIdUncached) }
        if ($probeIds.Count -gt 0) {
            Step 'étape D bis — HEAD signés vers le Storage Agent (depuis le VPS)'
            $probe = @"
set -Eeuo pipefail
cd '$RemoteStagingRoot'
node tools/phase6_probe_agent.mjs secrets/api-shadow.env $($probeIds -join ' ')
"@
            $probeResult = Invoke-Ssh -ScriptText $probe
            $trackReport = Get-LastJson $probeResult.Output
            if ($null -ne $trackReport) {
                # Les deux premières pistes qui répondent 200 sont retenues :
                # une éligibilité en base ne prouve pas que le fichier existe
                # encore côté Storage Agent, seul le HEAD le prouve.
                $reachable = @($trackReport.results | Where-Object { $_.statusCode -eq 200 })
                $roles = @('cached-miss-then-hit', 'offline-miss')
                $index = 0
                foreach ($hit in ($reachable | Select-Object -First 2)) {
                    $probedId = $hit.trackId
                    $matched = @($candidates | Where-Object { $_.trackId -eq $probedId }) |
                        Select-Object -First 1
                    $prefix = if ($null -eq $matched) { $null } else { $matched.hashPrefix }
                    $selectedTracks += @{
                        role = $roles[$index]
                        trackId = $probedId
                        sizeBytes = $hit.sizeBytes
                        hashPrefix = $prefix
                        agentHeadStatus = $hit.statusCode
                    }
                    $index++
                }
            }
            if ($selectedTracks.Count -lt 2) {
                Fail 'moins de deux pistes réelles validées par HEAD 200 : fournir -TrackIdCached et -TrackIdUncached'
            }
        }

        # --- G. Préflight distant -------------------------------------------
        Step 'étape G — préflight distant (aucun démarrage de server.js)'
        $preflightScript = Get-Content -Raw -LiteralPath `
            (Join-Path $RepoRoot 'scripts\phase6\vps_phase6_stage_preflight.sh')
        $preflightResult = Invoke-Ssh -ScriptText $preflightScript -Arguments @(
            $RemoteStagingRoot, "$RemoteStagingRoot/releases/$stagedReleaseId.staging",
            $baseline.caddySha256
        )
        $preflight = Get-LastJson $preflightResult.Output
        if ($null -eq $preflight) { Fail "préflight illisible : $($preflightResult.Output)" }
        if (-not $preflight.ok) { Fail "préflight distant : $($preflight.error) $($preflight.detail)" }

        # --- Rapport ---------------------------------------------------------
        Write-Output (ConvertTo-Json -Depth 8 @{
            mode = 'stage-only'
            ok = $true
            releaseId = $stagedReleaseId
            commit = $buildReport.commit
            fileCount = $buildReport.fileCount
            artifactBytes = $buildReport.totalBytes
            snapshotBytes = $snapshotReport.sizeBytes
            snapshotSha256 = $snapshotReport.sha256
            snapshotMigrations = $snapshotReport.drizzleMigrations
            sourceDbUnchanged = $snapshotReport.sourceUnchanged
            coverFileCount = $coversReport.coverFileCount
            coverBytes = $coversReport.coverBytes
            bundleVerified = $true
            bundleSourceUnchanged = $preflight.bundleSourceUnchanged
            nativeModulesVerified = ($preflight.betterSqlite3Sha256.Length -eq 64 -and
                                     $preflight.argon2Sha256.Length -eq 64)
            sqliteVerified = ($preflight.smoke.integrity -eq 'ok')
            manifestVerified = $true
            environmentVerified = $preflight.env.ok
            selectedTracks = $selectedTracks
            trackProbe = $trackReport
            port3002Free = $preflight.port3002Free
            serviceAbsent = $preflight.serviceAbsent
            serverJsExecuted = $false
            sshConnectionsOpened = $script:SshConnections
            secretsPrinted = 0
            productionModified = $false
            caddyUnchanged = $preflight.caddyUnchanged
            optUntouched = $preflight.optUntouched
            varLibUntouched = $preflight.varLibUntouched
            stagingRoot = $RemoteStagingRoot
        })
        Step 'stage-only terminé : rien n''est activé, rien n''écoute'
    } finally {
        if ($envTemp -and (Test-Path -LiteralPath $envTemp)) {
            # Le fichier clair ne survit pas à l'exécution, même en cas d'échec.
            Remove-Item -Force -LiteralPath $envTemp
        }
        $secrets = $null
        [GC]::Collect()
    }
    exit 0
}

# =========================================================================
# MODE ROLLBACK-INSTALL  (Phase 6.3, chemin d'échec)
# =========================================================================
if ($RollbackInstall) {
    Step 'MODE ROLLBACK-INSTALL : désinstallation du shadow'
    # `vps_phase6_cleanup.sh` est déjà borné par `guard()` : il ne peut
    # supprimer que les racines shadow, et refuse les arbres des Phases 4.5
    # et 5. La release fautive est conservée par l'appelant si besoin.
    $cleanupText = Get-Content -Raw -LiteralPath `
        (Join-Path $RepoRoot 'scripts\phase6\vps_phase6_cleanup.sh')
    $result = Invoke-Ssh -ScriptText "sudo -n bash -c 'cat > /tmp/p6c.sh' <<'HSEOF'`n$cleanupText`nHSEOF`nsudo -n bash /tmp/p6c.sh; rc=`$?; sudo -n rm -f /tmp/p6c.sh; exit `$rc"
    Write-Output $result.Output
    Step 'rollback terminé'
    exit 0
}

# =========================================================================
# MODE ACTIVATE  (Phase 6.3)
# =========================================================================
if ($Activate) {
    Step 'MODE ACTIVATE : installation et première activation shadow'

    # --- 0. Préconditions locales, avant toute connexion -------------------
    $head = (git rev-parse HEAD)
    $dirty = (git status --porcelain)
    if ($dirty) { Fail 'arbre de travail non propre' }
    # L'invariant à protéger est « le code installé est le code qualifié »,
    # pas « rien n'a bougé dans le dépôt ». La Phase 6.3 écrit forcément son
    # propre outillage d'installation : exiger qu'il soit inchangé depuis la
    # release rendrait la phase impossible à réaliser.
    #
    # Deux contrôles, dans cet ordre :
    #   1. rien de ce qui ENTRE dans l'artefact n'a changé ;
    #   2. l'empreinte du manifeste de la release est bien celle que le HEAD
    #      courant produirait — preuve directe, indépendante des chemins.
    $releaseCommit = $ReleaseId.Split('-')[1]
    $expectedManifest = $ReleaseId.Split('-')[2]
    $artifactSources = @('services/api', 'services/storage-agent', 'packages')
    $artifactChanged = @(git diff --name-only "$releaseCommit" HEAD -- @artifactSources)
    if ($artifactChanged.Count -gt 0) {
        Fail ("changement applicatif depuis la release : {0} — refaire un -StageOnly" -f `
            ($artifactChanged -join ','))
    }
    $changed = @(git diff --name-only "$releaseCommit" HEAD)
    $toolingChanged = @($changed | Where-Object { $_ -notmatch '\.md$' })
    Step ("HEAD={0} release={1} artefact inchangé, {2} fichier(s) d'outillage 6.3" -f `
        $head, $ReleaseId, $toolingChanged.Count)

    # Empreinte de la production Windows AVANT : elle doit être identique après.
    $prodDb = Get-Item -LiteralPath $SourceDbPath -ErrorAction SilentlyContinue
    if (-not $prodDb) { Fail '-SourceDbPath requis en -Activate (preuve de non-impact)' }
    $prodBefore = @{ sizeBytes = $prodDb.Length; mtime = $prodDb.LastWriteTimeUtc.ToString('o') }
    $servicesBefore = @(Get-Service HomeSpotifyApi, HomeSpotifyStorageAgent |
        ForEach-Object { "$($_.Name)=$($_.Status)" }) -join ','

    $report = [ordered]@{}
    $tokenFile = '/run/phase6-shadow-token'

    # --- 1. Préflight distant et snapshot de sécurité ----------------------
    Step 'étape 1 — préconditions distantes et snapshot pré-installation'
    $precheckScript = Get-Content -Raw -LiteralPath `
        (Join-Path $RepoRoot 'scripts\phase6\vps_phase6_preinstall_check.sh')
    # En root : ce contrôle LIT `/opt/homespotify-api-shadow` (0750
    # root:homespotify). Lancé en `debian`, il rapporterait « absent » ce qui
    # n'est que « non autorisé ».
    $result = Invoke-Ssh -ScriptText $precheckScript -AsRoot `
        -Arguments @($RemoteStagingRoot, $ReleaseId)
    $pre = Get-LastJson $result.Output
    if ($null -eq $pre) { Fail "préflight distant illisible : $($result.Output)" }
    if ($pre.releaseId -ne $ReleaseId) { Fail "releaseId distant inattendu : $($pre.releaseId)" }
    if ($pre.fileCount -ne $ExpectedFileCount) {
        Fail "fileCount inattendu : $($pre.fileCount) (attendu $ExpectedFileCount)"
    }
    # Preuve de contenu : le manifeste ne dépend QUE de l'artefact, jamais de
    # l'horodatage ni du commit. Si son empreinte est celle attendue, le code
    # déposé est exactement celui qualifié — quel que soit l'état du dépôt.
    if ($pre.manifestSha256.Substring(0, 8) -ne $expectedManifest) {
        Fail ("empreinte de manifeste divergente : attendue {0}, trouvée {1}" -f `
            $expectedManifest, $pre.manifestSha256.Substring(0, 8))
    }
    if ($pre.commit -ne "$releaseCommit" -and -not $pre.commit.StartsWith($releaseCommit)) {
        Fail "commit de release inattendu : $($pre.commit)"
    }
    if ($pre.coverFiles -ne 156) { Fail "pochettes inattendues : $($pre.coverFiles)" }
    if ($pre.envMode -ne '600') { Fail "permissions env inattendues : $($pre.envMode)" }
    # Le port ne peut être occupé que par NOTRE shadow, sur la release visée.
    if ($pre.port3002Listeners -ne 0 -and $pre.installedRelease -ne $ReleaseId) {
        Fail 'le port 3002 est occupé par autre chose que le shadow visé'
    }
    # Idempotence EXPLICITE. Une installation déjà en place est acceptable
    # si, et seulement si, elle porte exactement la release visée : c'est le
    # cas d'une reprise après un incident d'outillage. Toute autre
    # installation est un état inconnu, et un état inconnu ne se
    # surinstalle pas.
    if ($pre.optPresent -or $pre.statePresent -or $pre.homespotifyUnits -ne 0) {
        if ($pre.installedRelease -ne $ReleaseId) {
            Fail ("installation existante non conforme : {0} (attendu {1})" -f `
                $pre.installedRelease, $ReleaseId)
        }
        Step ("installation existante conforme à {0} : reprise" -f $ReleaseId)
    }
    if ($pre.caddyActive -ne 'active') { Fail "Caddy inattendu : $($pre.caddyActive)" }
    if (-not $pre.storageAgentReachable) { Fail 'Storage Agent injoignable' }
    # Un listener PUBLIC sur le port shadow, avant meme d'installer, est
    # un etat qu'aucune installation ne doit recouvrir.
    if ($pre.port3002Public -ne 0) { Fail 'listener public déjà présent sur 3002' }
    # Sur une installation NEUVE, le cache doit être vide : un objet audio
    # préexistant serait une donnée arrivée par un chemin non documenté. Sur
    # une reprise, il vient du shadow lui-même, et l'interdire bloquerait
    # toute reprise après interruption.
    $resuming = ($pre.installedRelease -eq $ReleaseId)
    if (-not $resuming -and $pre.cacheAudioObjects -ne 0) {
        Fail "objets audio préexistants dans le cache : $($pre.cacheAudioObjects)"
    }
    $report['preInstall'] = $pre
    # Message FACTUEL : afficher « port libre » sans le mesurer est
    # exactement la classe de rapport qui a coûté trois diagnostics à cette
    # phase.
    Step ("pré-installation : listeners 3002={0} (public={1}), unités={2}, service={3}, Caddy {4}, public /health {5}" -f `
        $pre.port3002Listeners, $pre.port3002Public, $pre.homespotifyUnits, `
        $pre.serviceState, $pre.caddyActive, $pre.publicHealth)

    # --- 2. Dépôt des outils d'activation ----------------------------------
    Step 'étape 2 — dépôt des outils d''activation dans le staging'
    $toolPaths = $activationTools | ForEach-Object {
        Join-Path $RepoRoot "scripts\phase6\$_"
    }
    Invoke-Scp -LocalPaths $toolPaths -RemotePath "$RemoteStagingRoot/tools/"
    Invoke-Scp -LocalPaths @(
        (Join-Path $RepoRoot 'scripts\phase6\homespotify-api-shadow.service'),
        (Join-Path $RepoRoot 'scripts\phase6\vps_phase6_systemd_setup.sh'),
        (Join-Path $RepoRoot 'scripts\phase6\vps_phase6_activate_shadow.sh')
    ) -RemotePath "$RemoteStagingRoot/tools/"

    # --- 3. Unité systemd : vérifier AVANT d'écrire dans /etc --------------
    Step 'étape 3 — systemd-analyze verify (aucune écriture)'
    $verify = Invoke-Ssh -ScriptText @"
set -Eeuo pipefail
cd '$RemoteStagingRoot/tools'
sudo -n bash vps_phase6_systemd_setup.sh homespotify-api-shadow.service --verify-only
"@
    $verifyReport = Get-LastJson $verify.Output
    if ($null -eq $verifyReport -or -not $verifyReport.ok) {
        Fail "unité systemd invalide : $($verify.Output)"
    }
    $report['unitVerified'] = $true

    # --- 4. Utilisateur, répertoires, unité (sans enable) ------------------
    Step 'étape 4 — utilisateur, répertoires et unité (start, jamais enable)'
    $setup = Invoke-Ssh -ScriptText @"
set -Eeuo pipefail
cd '$RemoteStagingRoot/tools'
sudo -n bash vps_phase6_systemd_setup.sh homespotify-api-shadow.service
"@
    $setupReport = Get-LastJson $setup.Output
    if ($null -eq $setupReport -or -not $setupReport.ok) {
        Fail "installation systemd échouée : $($setup.Output)"
    }
    if ($setupReport.bootEnabled -ne 'disabled') {
        Fail "le service ne doit pas être activé au démarrage : $($setupReport.bootEnabled)"
    }
    $report['systemd'] = $setupReport

    # --- 5. Installation immuable de la release ----------------------------
    Step 'étape 5 — installation atomique de la release et des données'
    $activateResult = Invoke-Ssh -ScriptText @"
set -Eeuo pipefail
sudo -n bash '$RemoteStagingRoot/tools/vps_phase6_activate_shadow.sh' \
  '$RemoteStagingRoot' '$ReleaseId'
"@
    $activateReport = Get-LastJson $activateResult.Output
    if ($null -eq $activateReport -or -not $activateReport.ok) {
        Fail "installation échouée : $($activateResult.Output)"
    }
    $report['install'] = $activateReport
    Step ("release installée : {0} — SQLite {1}, {2} pochettes" -f `
        $activateReport.current, $activateReport.sqlite.integrity, $activateReport.coverFileCount)

    # --- 6. Démarrage contrôlé ---------------------------------------------
    # Une instance à nous, déjà démarrée sur la release visée, est arrêtée
    # d'abord : le script de démarrage exige un port libre, et il a raison —
    # démarrer par-dessus masquerait quelle instance répond.
    if ($pre.port3002Listeners -ne 0) {
        Step 'instance existante du shadow : arrêt avant démarrage contrôlé'
        [void](Invoke-Ssh -ScriptText 'sudo -n systemctl stop homespotify-api-shadow.service')
    }
    Step 'étape 6 — démarrage contrôlé (start, pas enable)'
    $start = Invoke-Ssh -ScriptText @"
set -Eeuo pipefail
sudo -n bash '/opt/homespotify-api-shadow/tools/vps_phase6_start_shadow.sh' 90
"@
    $startReport = Get-LastJson $start.Output
    if ($null -eq $startReport -or -not $startReport.ok) {
        $report['start'] = $startReport
        Write-Output (ConvertTo-Json -Depth 8 @{
            mode = 'activate'; ok = $false; stage = 'demarrage'
            detail = $startReport; sshConnectionsOpened = $script:SshConnections
            secretsPrinted = 0; productionModified = $false
        })
        Fail 'démarrage refusé — service arrêté, port rendu, release conservée'
    }
    $report['start'] = $startReport
    Step ("service {0}/{1}, PID {2}, listener {3}" -f `
        $startReport.activeState, $startReport.subState, $startReport.mainPid, '127.0.0.1:3002')

    # --- 7. Jeton shadow ----------------------------------------------------
    Step 'étape 7 — jeton shadow forgé avec le secret DU SHADOW'
    $mint = Invoke-Ssh -ScriptText @"
set -Eeuo pipefail
sudo -n node /opt/homespotify-api-shadow/tools/phase6_shadow_token.mjs \
  /etc/homespotify/api-shadow.env \
  /var/lib/homespotify-shadow/data/runtime.db \
  /opt/homespotify-api-shadow/dependency-bundles/linux-x64-node22.18.0-abi127/node_modules \
  '$tokenFile'
"@
    $tokenReport = Get-LastJson $mint.Output
    if ($null -eq $tokenReport -or -not $tokenReport.ok) {
        Fail "jeton shadow refusé : $($mint.Output)"
    }
    $report['token'] = $tokenReport

    # --- 8. Tests T1 à T11 --------------------------------------------------
    Step 'étape 8 — tests fonctionnels T1 à T11'
    $tests = Invoke-Ssh -ScriptText @"
set -Eeuo pipefail
sudo -n python3 /opt/homespotify-api-shadow/tools/vps_phase6_shadow_tests.py \
  --mode full --token-file '$tokenFile' --track-id 119 --uncached-track-id 120
"@
    $testReport = Get-LastJson $tests.Output
    if ($null -eq $testReport) { Fail "tests illisibles : $($tests.Output)" }
    $report['tests'] = $testReport

    # --- 9. Surveillance initiale -------------------------------------------
    Step ("étape 9 — surveillance initiale ({0} s)" -f $MonitorSeconds)
    $monitor = Invoke-Ssh -ScriptText @"
set -Eeuo pipefail
sudo -n bash /opt/homespotify-api-shadow/tools/vps_phase6_monitor.sh $MonitorSeconds 30
"@
    $monitorReport = Get-LastJson $monitor.Output
    $report['monitor'] = $monitorReport

    # --- 10. Non-impact production, et destruction du jeton -----------------
    Step 'étape 10 — preuve de non-impact et destruction du jeton'
    $post = Invoke-Ssh -ScriptText @"
set -Eeuo pipefail
sudo -n rm -f '$tokenFile'
printf '{"tokenRemoved":%s,' "`$([ -e '$tokenFile' ] && echo false || echo true)"
printf '"caddyActive":"%s","caddySha256":"%s",' "`$(systemctl is-active caddy)" "`$(sudo -n sha256sum /etc/caddy/Caddyfile | cut -d' ' -f1)"
printf '"publicHealth":"%s","publicRoot":"%s",' \
  "`$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 https://music.romainbegot.fr/health)" \
  "`$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 https://music.romainbegot.fr/)"
printf '"wireguard":"%s","storageAgentReachable":%s,' "`$(systemctl is-active wg-quick@wg0)" \
  "`$(timeout 6 bash -c 'exec 3<>/dev/tcp/10.8.0.2/3100' >/dev/null 2>&1 && echo true || echo false)"
printf '"listeners":"%s","port3002Public":%s,' \
  "`$(ss -ltnH | awk '{print `$4}' | sort -u | tr '\n' ' ')" \
  "`$(ss -ltnH | awk '{print `$4}' | grep -cE '^(0\.0\.0\.0|\*|\[::\]|10\.8\.0\.[0-9]*):3002`$' || true)"
printf '"bootEnabled":"%s","activeState":"%s"}\n' \
  "`$(systemctl is-enabled homespotify-api-shadow.service 2>/dev/null || true)" \
  "`$(systemctl show -p ActiveState --value homespotify-api-shadow.service)"
"@
    $postReport = Get-LastJson $post.Output
    if ($null -eq $postReport) { Fail "contrôles finaux illisibles : $($post.Output)" }
    if ($postReport.caddySha256 -ne $pre.caddySha256) { Fail 'Caddyfile modifié' }
    if ($postReport.port3002Public -ne 0) { Fail 'listener public sur 3002' }
    if ($postReport.bootEnabled -eq 'enabled') { Fail 'le service a été activé au démarrage' }
    $report['postChecks'] = $postReport

    # Production Windows : mesurée à nouveau, pas supposée.
    $prodDbAfter = Get-Item -LiteralPath $SourceDbPath
    $servicesAfter = @(Get-Service HomeSpotifyApi, HomeSpotifyStorageAgent |
        ForEach-Object { "$($_.Name)=$($_.Status)" }) -join ','
    $productionUnchanged = (
        $prodDbAfter.Length -eq $prodBefore.sizeBytes -and
        $prodDbAfter.LastWriteTimeUtc.ToString('o') -eq $prodBefore.mtime -and
        $servicesAfter -eq $servicesBefore
    )
    $report['production'] = @{
        dbSizeBytes = $prodDbAfter.Length
        dbUnchanged = ($prodDbAfter.Length -eq $prodBefore.sizeBytes -and
                       $prodDbAfter.LastWriteTimeUtc.ToString('o') -eq $prodBefore.mtime)
        windowsServices = $servicesAfter
        windowsServicesUnchanged = ($servicesAfter -eq $servicesBefore)
    }

    # --- 11. Verdict, puis nettoyage du staging ----------------------------
    $testsOk = ($null -ne $testReport) -and $testReport.ok
    $monitorOk = ($null -ne $monitorReport) -and $monitorReport.ok -and
                 $monitorReport.publicListenerAnomalies -eq 0 -and
                 $monitorReport.loopbackListenerAnomalies -eq 0
    $verdict = $testsOk -and $monitorOk -and $productionUnchanged -and
               $startReport.ok -and ($postReport.publicHealth -eq $pre.publicHealth)

    $stagingRemoved = $false
    if ($verdict -and -not $KeepStaging) {
        Step 'étape 11 — nettoyage du staging (installation validée)'
        $cleanupScript = Get-Content -Raw -LiteralPath `
            (Join-Path $RepoRoot 'scripts\phase6\vps_phase6_staging_cleanup.sh')
        $cleanupResult = Invoke-Ssh -ScriptText $cleanupScript
        $cleanupReport = Get-LastJson $cleanupResult.Output
        $stagingRemoved = ($null -ne $cleanupReport) -and $cleanupReport.rootRemoved
        $report['stagingCleanup'] = $cleanupReport
    } else {
        Step 'staging CONSERVÉ : verdict non vert ou -KeepStaging demandé'
    }

    Write-Output (ConvertTo-Json -Depth 12 ([ordered]@{
        mode = 'activate'
        ok = $verdict
        head = $head
        releaseId = $ReleaseId
        preInstall = $report['preInstall']
        systemd = $report['systemd']
        install = $report['install']
        start = $report['start']
        token = $report['token']
        tests = $report['tests']
        monitor = $report['monitor']
        postChecks = $report['postChecks']
        production = $report['production']
        stagingRemoved = $stagingRemoved
        stagingCleanup = $report['stagingCleanup']
        bootEnabled = $postReport.bootEnabled
        publicPortsAdded = 0
        cutoverPerformed = $false
        sshConnectionsOpened = $script:SshConnections
        secretsPrinted = 0
        tokenPrinted = 0
    }))
    Step ("activation terminée : verdict {0}" -f $(if ($verdict) { 'GO' } else { 'NO-GO' }))
    exit $(if ($verdict) { 0 } else { 1 })
}

Fail 'les modes -Deploy, -Rollback et -Cleanup appartiennent à une phase ultérieure : validation du rapport 6.3 requise'
