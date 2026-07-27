<#
.SYNOPSIS
  Validation réelle Phase 5 sur une API VPS localhost isolée.

.DESCRIPTION
  ISOLATION DES SCÉNARIOS — correction du 2026-07-27 (4e exécution réelle)

  Les trois scénarios utilisaient la MÊME racine de cache et la MÊME limite
  `AUDIO_CACHE_MAX_BYTES = max(small, second) + 1`, calibrée pour garantir
  l'éviction. Séquence observée : la piste 78 était promue
  (`contentHashPrefix=cf43ef5cb02c`, `objectCount=1`, `indexEntryCount=1`),
  puis le scénario d'abandon sur la piste 79 déclenchait
  `CACHE_EVICTION_STARTED` puis `CACHE_EVICTED … sizeBytes=9165881`, laissant
  `objectCount=0`. Le test hors ligne qui suivait ne pouvait alors QUE
  répondre `CACHE_MISS` → `REMOTE_STORAGE_AGENT_UNAVAILABLE` → 503. Verdict
  correct du provider, précondition détruite par le harnais.

  Désormais : une racine de cache et une capacité PAR scénario
  (`runtime/cache-finalize-offline`, `cache-abort`, `cache-eviction`), le mode
  hors ligne exécuté immédiatement après la finalisation pendant que l'objet
  existe, et un `offline-precheck` bloquant — le Storage Agent n'est JAMAIS
  arrêté sans précondition prouvée. Une seule API à la fois, toujours sur
  127.0.0.1:3001. Caddy, WireGuard et le pare-feu ne sont pas touchés.
#>
[CmdletBinding()]
param(
    [string] $VpsHost = '135.125.101.79',
    [string] $VpsUser = 'debian',
    [string] $IdentityFile = "$env:USERPROFILE\.ssh\id_ed25519",
    [string] $RepoRoot = 'F:\dev\homespotify',
    [string] $AgentRoot = 'C:\ProgramData\HomeSpotify\StorageAgent',

    # Mode ciblé : n'exécute QUE le scénario d'abandon, sur une API cached
    # parallèle neuve et un cache temporaire vide. N'arrête jamais le Storage
    # Agent — donc aucune fenêtre d'indisponibilité, et une itération rapide
    # quand seul l'abandon est en cause.
    [switch] $AbortOnly,

    # Mode ciblé : un seul GET MISS complet, attente bornée de la condition
    # terminale, preuve de l'objet final et de l'index, puis HIT / HEAD HIT /
    # Range HIT prouvés par événement. N'arrête jamais le Storage Agent et
    # ne teste ni l'éviction ni le mode hors ligne.
    [switch] $FinalizeOnly,

    # Mode ciblé : remplissage, promotion et HIT prouvés sur une racine de
    # cache dédiée, PUIS mode hors ligne immédiat pendant que l'objet existe
    # encore. Le Storage Agent n'est arrêté qu'après un `offline-precheck`
    # vert, et il est toujours redémarré — y compris sur échec.
    [switch] $OfflineOnly
)

$ErrorActionPreference = 'Stop'
$ServiceName = 'HomeSpotifyStorageAgent'
$RemoteRoot = '/home/debian/homespotify-phase5'
$agentWasStopped = $false
$remotePrepared = $false

function Fail([string] $Message) { throw $Message }
function Step([string] $Message) { Write-Host "[phase5-vps] $Message" }
function Public-Health {
    [int](Invoke-WebRequest -Uri 'https://music.romainbegot.fr/health' `
        -UseBasicParsing -TimeoutSec 20).StatusCode
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Fail 'PowerShell administrateur requis'
}
Set-Location -LiteralPath $RepoRoot
if ((git rev-parse HEAD) -ne 'c1384cf3149d1248cb4df6fe2f0422589a5410e2') {
    Fail 'HEAD inattendu'
}
if (-not (Test-Path -LiteralPath $IdentityFile -PathType Leaf)) {
    Fail 'clé SSH absente ; son contenu ne sera jamais lu'
}
$required = @(
    'scripts\vps_phase5_setup.sh',
    'scripts\vps_phase5_cleanup.sh',
    'scripts\vps_phase5_restart_api.sh',
    # Bascule de scénario : une racine de cache et une capacité par scénario.
    'scripts\vps_phase5_switch_scenario.sh',
    'scripts\vps_phase5_write_env.py',
    'scripts\vps_phase5_cache_test.py',
    # Sélection de piste partagée par write_env et cache_test : les deux
    # l'importent depuis le même répertoire sur le VPS.
    'scripts\phase5_track_selection.py',
    # Lecteur de journaux robuste, importé par cache_test.
    'scripts\phase5_log_reader.py'
)
foreach ($path in $required) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { Fail "absent : $path" }
}
$apiBefore = Get-CimInstance Win32_Service -Filter "Name='HomeSpotifyApi'"
if ($apiBefore.State -ne 'Running') { Fail 'HomeSpotifyApi non Running' }
if ((Get-Service $ServiceName).Status -ne 'Running') { Fail 'agent non Running' }
if ((Public-Health) -ne 200) { Fail 'domaine public non sain' }

$secretPath = Join-Path $AgentRoot 'config\agent.env'
$secretLines = @([IO.File]::ReadLines($secretPath) |
    Where-Object { $_.StartsWith('STORAGE_AGENT_SHARED_SECRET=') })
if ($secretLines.Count -ne 1) { Fail 'secret agent absent ou ambigu' }
$sharedSecret = $secretLines[0].Substring('STORAGE_AGENT_SHARED_SECRET='.Length).Trim()
$secretLines = $null
if ($sharedSecret.Length -lt 32) { Fail 'secret agent invalide' }

$ssh = @('-o','BatchMode=yes','-o','IdentitiesOnly=yes','-o','ConnectTimeout=15',
    '-o','ServerAliveInterval=15','-o','ServerAliveCountMax=4',
    '-i',$IdentityFile,"$VpsUser@$VpsHost")
$scp = @('-q','-o','BatchMode=yes','-o','IdentitiesOnly=yes','-o','ConnectTimeout=15',
    '-i',$IdentityFile)
function Invoke-Ssh([string] $Command) {
    # `-n` redirige stdin depuis /dev/null. Sans lui, ces commandes héritent du
    # stdin déjà consommé par le transfert du secret (`$sharedSecret | ssh`),
    # ce qui produit le bruit « channel_by_id: 0: bad id: channel free » et
    # « client_input_channel_req: channel 0: unknown channel ». Sans effet sur
    # le résultat des commandes, qui ne lisent rien sur stdin.
    & ssh.exe -n @ssh $Command
    if ($LASTEXITCODE -ne 0) { Fail "SSH échoué ($LASTEXITCODE)" }
}
function Stop-StorageAgent {
    Stop-Service $ServiceName
    $deadline = (Get-Date).AddSeconds(60)
    while ((Get-Service $ServiceName).Status -ne 'Stopped' -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
    }
    if ((Get-Service $ServiceName).Status -ne 'Stopped') { Fail 'agent non arrêté' }
}

function Restore-StorageAgent {
    # Idempotent : appelable dans le `finally` même si l'agent tourne déjà.
    if ((Get-Service $ServiceName).Status -ne 'Running') { Start-Service $ServiceName }
    $deadline = (Get-Date).AddSeconds(60)
    $found = @()
    do {
        $found = @(Get-NetTCPConnection -State Listen |
            Where-Object { $_.LocalPort -eq 3100 -and $_.LocalAddress -eq '10.8.0.2' })
        if ($found.Count -eq 1) { break }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)
    return ($found.Count -eq 1)
}

function Invoke-OfflineScenario {
    <#
      Étape B du mode complet, et corps du mode `-OfflineOnly`.

      L'ordre est le point corrigé : la fenêtre hors ligne s'ouvre
      IMMÉDIATEMENT après la finalisation, pendant que l'objet est encore en
      cache, et jamais après un scénario capable de l'évincer. Le
      `offline-precheck` est bloquant : il échoue si `objectCount != 1`,
      `indexEntryCount != 1`, si l'objet ou son empreinte manquent, ou si le
      `CACHE_HIT` n'est pas prouvé. `Invoke-Ssh` lève sur code non nul, donc
      l'agent n'est pas arrêté dans ce cas.
    #>
    Step 'étape A — MISS, promotion et HIT prouvés (cache finalize-offline)'
    Invoke-Ssh 'timeout --signal=TERM --kill-after=10s 240s python3 -u "$HOME/homespotify-phase5/incoming/vps_phase5_cache_test.py" --root "$HOME/homespotify-phase5" --mode finalize'

    Step 'précondition hors ligne : objet, index, empreinte et CACHE_HIT'
    Invoke-Ssh 'timeout --signal=TERM --kill-after=10s 240s python3 -u "$HOME/homespotify-phase5/incoming/vps_phase5_cache_test.py" --root "$HOME/homespotify-phase5" --mode offline-precheck'

    Step 'étape B — agent brièvement arrêté : HIT offline et MISS 503'
    Stop-StorageAgent
    $script:agentWasStopped = $true
    if ((Public-Health) -ne 200) { Fail 'production affectée par arrêt agent' }
    try {
        Invoke-Ssh 'timeout --signal=TERM --kill-after=10s 120s python3 -u "$HOME/homespotify-phase5/incoming/vps_phase5_cache_test.py" --root "$HOME/homespotify-phase5" --mode offline'
    } finally {
        # Redémarrage garanti, y compris si le mode hors ligne échoue.
        $restored = Restore-StorageAgent
        $script:agentWasStopped = $false
        Write-Host ('[phase5-vps] {0}' -f (ConvertTo-Json -Compress @{
            status = 'phase5-offline-host-summary'
            agentStopped = $true
            agentRestarted = ((Get-Service $ServiceName).Status -eq 'Running')
            listenerRestored = $restored
            publicDomainHealthy = ((Public-Health) -eq 200)
        }))
        if (-not $restored) { Fail 'agent non revenu sain (listener 10.8.0.2:3100)' }
    }
}

function Copy-ToVps([string] $Local, [string] $Remote, [switch] $Recursive) {
    $args = @($scp)
    if ($Recursive) { $args += '-r' }
    $args += @($Local, "$VpsUser@$VpsHost`:$Remote")
    & scp.exe @args
    if ($LASTEXITCODE -ne 0) { Fail "SCP échoué : $Local" }
}

try {
    Step 'build API local'
    & pnpm.cmd --filter @homespotify/api build
    if ($LASTEXITCODE -ne 0) { Fail 'build API échoué' }

    Step 'préparation VPS isolée'
    Invoke-Ssh 'set -eu; ROOT="$HOME/homespotify-phase5"; test "$ROOT" = "/home/debian/homespotify-phase5"; if test -x "$ROOT/incoming/vps_phase5_cleanup.sh"; then bash "$ROOT/incoming/vps_phase5_cleanup.sh"; fi; rm -rf -- "$ROOT"; mkdir -p "$ROOT/incoming"'
    Copy-ToVps 'services\api\dist' "$RemoteRoot/incoming" -Recursive
    foreach ($script in $required) {
        Copy-ToVps $script "$RemoteRoot/incoming/$([IO.Path]::GetFileName($script))"
    }
    $remotePrepared = $true
    $sharedSecret | & ssh.exe @ssh 'set -eu; umask 077; ROOT="$HOME/homespotify-phase5"; IFS= read -r VALUE; printf %s "$VALUE" > "$ROOT/.hmac-secret"; chmod 600 "$ROOT/.hmac-secret"'
    if ($LASTEXITCODE -ne 0) { Fail 'transfert secret échoué' }
    $sharedSecret = $null

    Invoke-Ssh 'set -eu; ROOT="$HOME/homespotify-phase5"; chmod 700 "$ROOT/incoming/"*.sh; for file in "$ROOT/incoming/"*.sh; do bash -n "$file"; done; python3 -m py_compile "$ROOT/incoming/"*.py'
    Step 'démarrage API cached 127.0.0.1:3001'
    # Scénario de départ : celui qui doit CONSERVER son objet (finalisation,
    # HIT, hors ligne). Capacité large, aucune éviction attendue.
    $startScenario = if ($AbortOnly) { 'abort' } else { 'finalize-offline' }
    Invoke-Ssh "timeout --signal=TERM --kill-after=10s 120s bash `"`$HOME/homespotify-phase5/incoming/vps_phase5_setup.sh`" $startScenario"

    if ($FinalizeOnly) {
        Step 'mode ciblé : MISS, promotion et HIT prouvés, agent laissé actif'
        Invoke-Ssh 'timeout --signal=TERM --kill-after=10s 240s python3 -u "$HOME/homespotify-phase5/incoming/vps_phase5_cache_test.py" --root "$HOME/homespotify-phase5" --mode finalize'
        Step 'finalisation vérifiée'
    }
    elseif ($AbortOnly) {
        Step 'mode ciblé : scénario d''abandon uniquement, agent laissé actif'
        Invoke-Ssh 'timeout --signal=TERM --kill-after=10s 240s python3 -u "$HOME/homespotify-phase5/incoming/vps_phase5_cache_test.py" --root "$HOME/homespotify-phase5" --mode abort'
        Step 'scénario d''abandon terminé'
    }
    elseif ($OfflineOnly) {
        Step 'mode ciblé : finalisation puis hors ligne, cache dédié'
        Invoke-OfflineScenario
        Step 'mode hors ligne vérifié, agent redémarré'
    }
    else {
        # Étapes A et B : finalisation, HIT, puis hors ligne IMMÉDIAT pendant
        # que l'objet existe. Aucun scénario évinçant ne s'intercale.
        Invoke-OfflineScenario

        Step 'redémarrage API parallèle et récupération du HIT'
        Invoke-Ssh 'timeout --signal=TERM --kill-after=10s 90s bash "$HOME/homespotify-phase5/incoming/vps_phase5_restart_api.sh"'
        Invoke-Ssh 'timeout --signal=TERM --kill-after=10s 60s python3 -u "$HOME/homespotify-phase5/incoming/vps_phase5_cache_test.py" --root "$HOME/homespotify-phase5" --mode restart'

        Step 'étape C — abandon isolé, cache vide dédié'
        Invoke-Ssh 'timeout --signal=TERM --kill-after=10s 120s bash "$HOME/homespotify-phase5/incoming/vps_phase5_switch_scenario.sh" abort'
        Invoke-Ssh 'timeout --signal=TERM --kill-after=10s 240s python3 -u "$HOME/homespotify-phase5/incoming/vps_phase5_cache_test.py" --root "$HOME/homespotify-phase5" --mode abort'

        Step 'étape D — éviction LRU isolée, limite volontairement serrée'
        Invoke-Ssh 'timeout --signal=TERM --kill-after=10s 120s bash "$HOME/homespotify-phase5/incoming/vps_phase5_switch_scenario.sh" eviction'
        Invoke-Ssh 'timeout --signal=TERM --kill-after=10s 300s python3 -u "$HOME/homespotify-phase5/incoming/vps_phase5_cache_test.py" --root "$HOME/homespotify-phase5" --mode eviction'
    }
} finally {
    if ($agentWasStopped) {
        # Filet de sécurité : `Invoke-OfflineScenario` redémarre déjà l'agent
        # dans son propre `finally`. Ce bloc couvre une interruption survenue
        # entre l'arrêt et l'entrée dans ce `try`.
        [void](Restore-StorageAgent)
    }
    if ($remotePrepared) {
        Step 'cleanup VPS'
        & ssh.exe @ssh 'timeout --signal=TERM --kill-after=10s 60s bash "$HOME/homespotify-phase5/incoming/vps_phase5_cleanup.sh"'
        if ($LASTEXITCODE -ne 0) { throw 'cleanup Phase 5 échoué' }
    }
    $sharedSecret = $null
}

$apiAfter = Get-CimInstance Win32_Service -Filter "Name='HomeSpotifyApi'"
if ($apiAfter.State -ne 'Running' -or $apiAfter.ProcessId -ne $apiBefore.ProcessId) {
    Fail 'HomeSpotifyApi Windows modifiée'
}
if ((Public-Health) -ne 200) { Fail 'domaine public non sain après test' }
if ((Get-Service $ServiceName).Status -ne 'Running') { Fail 'agent non Running après test' }
Step 'validation Phase 5 réelle terminée, production intacte'
