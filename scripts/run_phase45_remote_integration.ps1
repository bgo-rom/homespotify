<#
.SYNOPSIS
    Orchestre la validation réelle Phase 4.5 depuis la session Windows.

.DESCRIPTION
    À exécuter dans un PowerShell administrateur appartenant à l'utilisateur
    qui possède déjà l'accès SSH par clé au VPS.

    Le script ne lit jamais la clé privée. Il lit le secret HMAC depuis
    agent.env uniquement en mémoire, le pousse par stdin SSH (jamais par
    argument), puis le supprime du VPS dans un finally.

    Modifications autorisées et bornées :
      - fichiers temporaires sous ~/homespotify-phase45 sur le VPS ;
      - arrêt bref puis redémarrage de HomeSpotifyStorageAgent pour le test 503.

    HomeSpotifyApi, Caddy, WireGuard, le pare-feu, la base et les fichiers
    musicaux de production ne sont jamais modifiés.
#>
[CmdletBinding()]
param(
    [string] $VpsHost = '135.125.101.79',
    [string] $VpsUser = 'debian',
    [string] $IdentityFile = "$env:USERPROFILE\.ssh\id_ed25519",
    [string] $RepoRoot = 'F:\dev\homespotify',
    [string] $AgentRoot = 'C:\ProgramData\HomeSpotify\StorageAgent',
    [switch] $RequestIdOnly
)

$ErrorActionPreference = 'Stop'
$ServiceName = 'HomeSpotifyStorageAgent'
$RemoteRoot = '/home/debian/homespotify-phase45'
$RemoteIncoming = "$RemoteRoot/incoming"
$RemoteSecret = "$RemoteRoot/.hmac-secret"

function Step { param([string] $Message) Write-Host "[phase45-vps] $Message" }
function Fail { param([string] $Message) throw $Message }

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Fail 'console non élevée : aucun test lancé'
    }
}

function Wait-ServiceState {
    param([string] $Expected, [int] $TimeoutSeconds = 60)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $state = (Get-Service -Name $ServiceName).Status.ToString()
        if ($state -eq $Expected) { return }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)
    Fail "service $ServiceName non $Expected après ${TimeoutSeconds}s"
}

function Wait-AgentListener {
    $deadline = (Get-Date).AddSeconds(60)
    do {
        $listeners = @(Get-NetTCPConnection -State Listen |
            Where-Object LocalPort -eq 3100)
        if ($listeners.Count -eq 1 -and $listeners[0].LocalAddress -eq '10.8.0.2') {
            return
        }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)
    Fail 'listener agent non conforme après redémarrage'
}

function Public-Health {
    return [int] (Invoke-WebRequest `
        -Uri 'https://music.romainbegot.fr/health' `
        -UseBasicParsing `
        -TimeoutSec 20).StatusCode
}

Assert-Administrator
Set-Location -LiteralPath $RepoRoot

$expectedRepo = 'F:\dev\homespotify'
if ([IO.Path]::GetFullPath($RepoRoot).TrimEnd('\') -ne $expectedRepo) {
    Fail 'RepoRoot inattendu'
}
if (-not (Test-Path -LiteralPath $IdentityFile -PathType Leaf)) {
    Fail 'clé SSH privée absente ou inaccessible — son contenu ne sera pas lu'
}

$required = @(
    'storage\phase45-api-artifact\dist\server.js',
    'storage\phase45-api-artifact\package.json',
    'storage\phase45-api-artifact\drizzle\meta\_journal.json',
    'storage\phase45-sqlite-backup-20260726-1545\homespotify.db',
    'scripts\vps_storage_agent_smoke_test.py',
    'scripts\vps_phase45_setup.sh',
    'scripts\vps_phase45_cleanup.sh',
    'scripts\vps_phase45_state_value.py',
    'scripts\vps_phase45_run_smoke.sh',
    'scripts\vps_phase45_run_provider_test.sh',
    'scripts\vps_phase45_write_request_id_env.py',
    'scripts\vps_phase45_request_id_setup.sh',
    'scripts\phase45_request_id_log_parser.py',
    'scripts\vps_phase45_remote_provider_test.py'
)
foreach ($path in $required) {
    if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot $path))) {
        Fail "prérequis local absent : $path"
    }
}

$apiBefore = Get-CimInstance Win32_Service -Filter "Name='HomeSpotifyApi'"
$agentBefore = Get-CimInstance Win32_Service -Filter "Name='$ServiceName'"
$wireGuard = Get-CimInstance Win32_Service -Filter "Name='WireGuardTunnel`$HomeSpotify-VPS'"
if ($apiBefore.State -ne 'Running') { Fail 'HomeSpotifyApi non Running' }
if ($agentBefore.State -ne 'Running') { Fail 'Storage Agent non Running' }
if ($wireGuard.State -ne 'Running') { Fail 'WireGuard non Running' }
if ((Public-Health) -ne 200) { Fail 'domaine public non sain avant tests' }

$installedHash = (Get-FileHash `
    -LiteralPath (Join-Path $AgentRoot 'app\dist\server.js') `
    -Algorithm SHA256).Hash
$candidateHash = (Get-FileHash `
    -LiteralPath (Join-Path $RepoRoot 'storage\phase45-artifact\dist\server.js') `
    -Algorithm SHA256).Hash
if ($installedHash -ne $candidateHash) { Fail 'agent installé non synchronisé' }

$agentEnv = Join-Path $AgentRoot 'config\agent.env'
$secretLines = @([IO.File]::ReadLines($agentEnv) |
    Where-Object { $_.StartsWith('STORAGE_AGENT_SHARED_SECRET=') })
if ($secretLines.Count -ne 1) { Fail 'secret HMAC absent ou ambigu dans agent.env' }
$sharedSecret = $secretLines[0].Substring('STORAGE_AGENT_SHARED_SECRET='.Length).Trim()
$secretLines = $null
if ($sharedSecret.Length -lt 32) { Fail 'secret HMAC trop court' }

$ssh = @(
    '-o', 'BatchMode=yes',
    '-o', 'IdentitiesOnly=yes',
    '-o', 'ConnectTimeout=15',
    '-o', 'ServerAliveInterval=15',
    '-o', 'ServerAliveCountMax=4',
    '-i', $IdentityFile,
    "$VpsUser@$VpsHost"
)
$scp = @(
    '-q',
    '-o', 'BatchMode=yes',
    '-o', 'IdentitiesOnly=yes',
    '-o', 'ConnectTimeout=15',
    '-o', 'ServerAliveInterval=15',
    '-o', 'ServerAliveCountMax=4',
    '-i', $IdentityFile
)

function Invoke-Ssh {
    param([string] $Command)
    & ssh.exe @ssh $Command
    if ($LASTEXITCODE -ne 0) { Fail "commande SSH échouée ($LASTEXITCODE)" }
}

function Copy-ToVps {
    param([string] $LocalPath, [string] $RemotePath, [switch] $Recursive)
    $arguments = @($scp)
    if ($Recursive) { $arguments += '-r' }
    $arguments += @($LocalPath, "$VpsUser@$VpsHost`:$RemotePath")
    & scp.exe @arguments
    if ($LASTEXITCODE -ne 0) { Fail "copie SCP échouée : $LocalPath" }
}

function Copy-SanitizedDiagnostics {
    $remoteDiagnosticRoot = "$RemoteRoot/diagnostics"
    $allowedPattern = '^api-300[12]\.(stdout|stderr)\.log$|^api-300[12]\.metadata\.txt$'
    $remoteNames = @(& ssh.exe @ssh "timeout 20s find '$remoteDiagnosticRoot' -maxdepth 1 -type f -printf '%f\n' 2>/dev/null")
    if ($LASTEXITCODE -ne 0 -or $remoteNames.Count -eq 0) {
        Step 'aucun diagnostic distant disponible à rapatrier'
        return
    }
    $unexpected = @($remoteNames | Where-Object { $_ -notmatch $allowedPattern })
    if ($unexpected.Count -gt 0) {
        Fail 'diagnostic distant refusé : nom de fichier hors liste blanche'
    }

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $localRoot = Join-Path $RepoRoot ".phase45-diagnostics\$timestamp"
    New-Item -ItemType Directory -Path $localRoot -Force | Out-Null
    & scp.exe @scp -r "$VpsUser@$VpsHost`:$remoteDiagnosticRoot" $localRoot
    if ($LASTEXITCODE -ne 0) {
        Fail 'rapatriement des diagnostics expurgés en échec'
    }
    $copiedForbidden = @(Get-ChildItem -LiteralPath $localRoot -Recurse -File |
        Where-Object {
            $_.Name -notmatch $allowedPattern -or
            $_.Extension -in @('.env', '.db', '.sqlite', '.sqlite3')
        })
    if ($copiedForbidden.Count -gt 0) {
        Fail 'diagnostic local refusé : contenu hors liste blanche'
    }
    Step "diagnostics expurgés rapatriés : $localRoot"
}

function Wait-RequestIdInAgentLogs {
    param([string] $RequestId)
    $parser = Join-Path $RepoRoot 'scripts\phase45_request_id_log_parser.py'
    $logRoot = Join-Path $AgentRoot 'logs'
    for ($attempt = 1; $attempt -le 10; $attempt++) {
        $result = @(& python.exe $parser `
            --log-root $logRoot `
            --request-id $RequestId `
            --tail 5000)
        $parserExit = $LASTEXITCODE
        if ($parserExit -eq 0) {
            Step "corrélation agent JSON confirmée à la tentative $attempt"
            $result | Write-Host
            return
        }
        if ($parserExit -ne 1) {
            Fail "parseur de journaux agent en échec ($parserExit)"
        }
        Start-Sleep -Milliseconds 500
    }
    Fail 'requestId ciblé absent des événements JSON réussis après 10 tentatives'
}

if ($RequestIdOnly) {
    $targetedCleanupAvailable = $false
    try {
        Step 'mode ciblé requestId : validation SSH'
        Invoke-Ssh 'timeout 30s test "$(id -un)" = debian'
        Invoke-Ssh 'timeout 30s test -f "$HOME/homespotify-phase45/api/dist/server.js" -a -d "$HOME/homespotify-phase45/api/node_modules/better-sqlite3" -a -f "$HOME/homespotify-phase45/data/runtime.db" -a -f "$HOME/homespotify-phase45/runtime/phase45.json"'
        Invoke-Ssh 'timeout 30s mkdir -p "$HOME/homespotify-phase45/incoming"'

        foreach ($script in @(
            'vps_phase45_cleanup.sh',
            'vps_phase45_remote_provider_test.py',
            'vps_phase45_run_provider_test.sh',
            'vps_phase45_write_request_id_env.py',
            'vps_phase45_request_id_setup.sh'
        )) {
            Copy-ToVps `
                -LocalPath (Join-Path $RepoRoot "scripts\$script") `
                -RemotePath "$RemoteIncoming/$script"
        }
        $targetedCleanupAvailable = $true

        Step 'mode ciblé requestId : transfert HMAC protégé'
        $sharedSecret | & ssh.exe @ssh 'set -eu; umask 077; ROOT="$HOME/homespotify-phase45"; IFS= read -r HS_SECRET; printf %s "$HS_SECRET" > "$ROOT/.hmac-secret"; chmod 600 "$ROOT/.hmac-secret"'
        if ($LASTEXITCODE -ne 0) { Fail 'transfert protégé du secret échoué' }
        $sharedSecret = $null

        Invoke-Ssh 'set -eu; ROOT="$HOME/homespotify-phase45"; chmod 700 "$ROOT/incoming/"*.sh; for SCRIPT in "$ROOT/incoming/"*.sh; do bash -n "$SCRIPT"; done'
        Step 'mode ciblé requestId : démarrage API 127.0.0.1:3001 sans npm install'
        Invoke-Ssh 'timeout --signal=TERM --kill-after=10s 120s bash "$HOME/homespotify-phase45/incoming/vps_phase45_request_id_setup.sh"'

        $targetRequestId = 'phase45-requestid-' +
            (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfff') + '-' +
            ([guid]::NewGuid().ToString('N').Substring(0, 8))
        Step 'mode ciblé requestId : une requête HEAD via le provider distant'
        Invoke-Ssh "bash `"`$HOME/homespotify-phase45/incoming/vps_phase45_run_provider_test.sh`" request-id $targetRequestId"
        Wait-RequestIdInAgentLogs -RequestId $targetRequestId
    } finally {
        if ($targetedCleanupAvailable) {
            Step 'mode ciblé requestId : cleanup'
            & ssh.exe @ssh 'timeout --signal=TERM --kill-after=10s 60s bash "$HOME/homespotify-phase45/incoming/vps_phase45_cleanup.sh"'
            if ($LASTEXITCODE -ne 0) {
                throw 'cleanup ciblé en échec : état NO-GO'
            }
        }
        $sharedSecret = $null
    }

    $targetedApiAfter = Get-CimInstance Win32_Service -Filter "Name='HomeSpotifyApi'"
    $targetedAgentAfter = Get-CimInstance Win32_Service -Filter "Name='$ServiceName'"
    $targetedListeners = @(Get-NetTCPConnection -State Listen | Where-Object LocalPort -eq 3100)
    if (
        $targetedApiAfter.State -ne 'Running' -or
        $targetedApiAfter.ProcessId -ne $apiBefore.ProcessId -or
        $targetedAgentAfter.State -ne 'Running' -or
        $targetedListeners.Count -ne 1 -or
        $targetedListeners[0].LocalAddress -ne '10.8.0.2' -or
        (Public-Health) -ne 200
    ) {
        Fail 'contrôle final ciblé Windows non conforme'
    }
    Step 'FIN ciblée : requestId prouvé dans un événement JSON agent, production intacte'
    return
}

$remoteReady = $false
$remoteCleanupAvailable = $false
$agentWasStopped = $false
$monitorJob = $null
try {
    Step 'validation SSH non interactive'
    Invoke-Ssh 'test "$(id -un)" = debian; python3 --version; node --version; npm --version'

    Step 'préparation du répertoire temporaire VPS'
    Invoke-Ssh 'set -eu; ROOT="$HOME/homespotify-phase45"; test "$ROOT" = "/home/debian/homespotify-phase45"; mkdir -p "$ROOT/incoming"; rm -rf -- "$ROOT/incoming/api-artifact"; rm -f -- "$ROOT/incoming/homespotify.db" "$ROOT/incoming/"*.py "$ROOT/incoming/"*.sh'

    Copy-ToVps `
        -LocalPath (Join-Path $RepoRoot 'storage\phase45-api-artifact') `
        -RemotePath "$RemoteIncoming/api-artifact" `
        -Recursive
    Copy-ToVps `
        -LocalPath (Join-Path $RepoRoot 'storage\phase45-sqlite-backup-20260726-1545\homespotify.db') `
        -RemotePath "$RemoteIncoming/homespotify.db"
    foreach ($script in @(
        'vps_storage_agent_smoke_test.py',
        'vps_phase45_setup.sh',
        'vps_phase45_cleanup.sh',
        'vps_phase45_state_value.py',
        'vps_phase45_run_smoke.sh',
        'vps_phase45_run_provider_test.sh',
        'vps_phase45_remote_provider_test.py'
    )) {
        Copy-ToVps `
            -LocalPath (Join-Path $RepoRoot "scripts\$script") `
            -RemotePath "$RemoteIncoming/$script"
    }
    $remoteCleanupAvailable = $true

    Step 'transfert HMAC par stdin vers un fichier 0600'
    $sharedSecret | & ssh.exe @ssh 'set -eu; umask 077; ROOT="$HOME/homespotify-phase45"; IFS= read -r HS_SECRET; printf %s "$HS_SECRET" > "$ROOT/.hmac-secret"; chmod 600 "$ROOT/.hmac-secret"'
    if ($LASTEXITCODE -ne 0) { Fail 'transfert protégé du secret échoué' }
    $sharedSecret = $null

    Invoke-Ssh 'set -eu; ROOT="$HOME/homespotify-phase45"; chmod 700 "$ROOT/incoming/"*.sh; chmod 600 "$ROOT/.hmac-secret"; for SCRIPT in "$ROOT/incoming/"*.sh; do bash -n "$SCRIPT"; done; stat -c "SECRET_MODE=%a" "$ROOT/.hmac-secret"'

    Step 'installation et démarrage des API parallèles localhost'
    Invoke-Ssh 'timeout --signal=TERM --kill-after=10s 300s bash "$HOME/homespotify-phase45/incoming/vps_phase45_setup.sh"'
    $remoteReady = $true

    Step 'smoke test réel agent 23/23'
    Invoke-Ssh 'bash "$HOME/homespotify-phase45/incoming/vps_phase45_run_smoke.sh"'

    Step 'tests réels du provider distant'
    $monitorJob = Start-Job -ScriptBlock {
        while ($true) {
            try {
                $listener = Get-NetTCPConnection -State Listen |
                    Where-Object LocalPort -eq 3100 |
                    Select-Object -First 1
                if ($listener) {
                    (Get-Process -Id $listener.OwningProcess).WorkingSet64
                }
            } catch {}
            Start-Sleep -Milliseconds 250
        }
    }
    $fullRequestId = 'phase45-requestid-' +
        (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfff') + '-' +
        ([guid]::NewGuid().ToString('N').Substring(0, 8))
    Invoke-Ssh "bash `"`$HOME/homespotify-phase45/incoming/vps_phase45_run_provider_test.sh`" full $fullRequestId"
    Stop-Job $monitorJob
    $agentMemorySamples = @(Receive-Job $monitorJob | Where-Object { $_ -is [long] -or $_ -is [int] })
    Remove-Job $monitorJob
    $monitorJob = $null
    if ($agentMemorySamples.Count -gt 0) {
        $peakMiB = [math]::Round((($agentMemorySamples | Measure-Object -Maximum).Maximum) / 1MB, 1)
        Step "mémoire Storage Agent maximale observée : $peakMiB Mio"
    }

    Wait-RequestIdInAgentLogs -RequestId $fullRequestId

    Step 'test contrôlé agent indisponible -> 503 public parallèle'
    if ((Public-Health) -ne 200) { Fail 'production non saine avant arrêt agent' }
    Stop-Service -Name $ServiceName
    Wait-ServiceState -Expected 'Stopped'
    $agentWasStopped = $true
    if ((Public-Health) -ne 200) { Fail 'production affectée par l’arrêt de l’agent' }
    Invoke-Ssh 'bash "$HOME/homespotify-phase45/incoming/vps_phase45_run_provider_test.sh" offline'

    Start-Service -Name $ServiceName
    Wait-ServiceState -Expected 'Running'
    Wait-AgentListener
    $agentWasStopped = $false
    if ((Public-Health) -ne 200) { Fail 'production non saine après retour agent' }

    Step 'smoke test après retour de l’agent'
    Invoke-Ssh 'bash "$HOME/homespotify-phase45/incoming/vps_phase45_run_smoke.sh"'

    $apiAfter = Get-CimInstance Win32_Service -Filter "Name='HomeSpotifyApi'"
    if ($apiAfter.State -ne 'Running' -or $apiAfter.ProcessId -ne $apiBefore.ProcessId) {
        Fail "HomeSpotifyApi a changé : $($apiBefore.ProcessId) -> $($apiAfter.ProcessId)"
    }
    Step 'tous les contrôles réels sont verts'
} catch {
    if ($remoteCleanupAvailable) {
        Copy-SanitizedDiagnostics
    }
    throw
} finally {
    if ($monitorJob) {
        Stop-Job $monitorJob -ErrorAction SilentlyContinue
        Remove-Job $monitorJob -Force -ErrorAction SilentlyContinue
    }
    if ($agentWasStopped) {
        Step 'finally : redémarrage obligatoire du Storage Agent'
        Start-Service -Name $ServiceName -ErrorAction SilentlyContinue
        Wait-ServiceState -Expected 'Running'
        Wait-AgentListener
    }
    if ($remoteCleanupAvailable) {
        Step 'arrêt des API parallèles et suppression des secrets VPS'
        & ssh.exe @ssh 'timeout --signal=TERM --kill-after=10s 60s bash "$HOME/homespotify-phase45/incoming/vps_phase45_cleanup.sh"'
        if ($LASTEXITCODE -ne 0) {
            throw 'nettoyage distant en échec : état NO-GO, vérification immédiate requise'
        }
    } else {
        & ssh.exe @ssh 'set -eu; ROOT="$HOME/homespotify-phase45"; rm -f -- "$ROOT/.hmac-secret" "$ROOT/api/.env" "$ROOT/api-bad-auth/.env"'
        if ($LASTEXITCODE -ne 0) {
            throw 'suppression de secours des secrets en échec : état NO-GO'
        }
    }
    $sharedSecret = $null
}

$apiFinal = Get-CimInstance Win32_Service -Filter "Name='HomeSpotifyApi'"
$agentFinal = Get-CimInstance Win32_Service -Filter "Name='$ServiceName'"
$listenersFinal = @(Get-NetTCPConnection -State Listen | Where-Object LocalPort -eq 3100)
if (
    $apiFinal.State -ne 'Running' -or
    $apiFinal.ProcessId -ne $apiBefore.ProcessId -or
    $agentFinal.State -ne 'Running' -or
    $listenersFinal.Count -ne 1 -or
    $listenersFinal[0].LocalAddress -ne '10.8.0.2' -or
    (Public-Health) -ne 200
) {
    Fail 'contrôle final Windows non conforme'
}

Step 'FIN : production intacte, agent sain, API parallèles arrêtées, secrets VPS supprimés'
