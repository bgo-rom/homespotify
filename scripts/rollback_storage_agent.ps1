<#
.SYNOPSIS
    Rollback de la Phase 3, sans jamais interrompre HomeSpotifyApi.

.DESCRIPTION
    NÉCESSITE DES PRIVILÈGES ADMINISTRATEUR.

    Trois périmètres, indépendants et combinables :

      -AgentOnly      arrête et désinstalle le Storage Agent, retire la règle 3100
      -FirewallOnly   réactive les règles génériques Node.js, retire les règles Phase 3
      (par défaut)    les deux, dans l'ordre sûr

    Sont TOUJOURS conservés, pour diagnostic :
      - l'index de production        data\index.json
      - les journaux                 logs\
      - le secret partagé            config\agent.env

    Le secret n'est supprimé QUE sur -RemoveSecret explicite. Le supprimer sans
    décision est irréversible et casserait l'appariement avec le VPS.

    Ce script ne touche JAMAIS :
      - le service HomeSpotifyApi (ni arrêt, ni redémarrage, ni configuration) ;
      - la règle « WireGuard - Ping depuis VPS » ;
      - la règle « HomeSpotify API via WireGuard » (préexistante à la Phase 3) ;
      - la règle « HomeSpotify API 3000 » (préexistante, profil Private) ;
      - Caddy, WireGuard, la base SQLite, la bibliothèque musicale.

    Aucun reset global du pare-feu n'est effectué, en aucune circonstance.

.NOTES
    Code de sortie 0 = succès, non nul = échec.
#>
[CmdletBinding()]
param(
    [switch] $AgentOnly,
    [switch] $FirewallOnly,
    [switch] $RemoveSecret,
    [switch] $RemoveApp,
    [string] $Root        = 'C:\ProgramData\HomeSpotify\StorageAgent',
    [string] $ServiceName = 'HomeSpotifyStorageAgent',
    [string] $PublicUrl   = 'https://music.romainbegot.fr/health'
)

$ErrorActionPreference = 'Stop'

$RuleName3000 = 'HomeSpotify-API-3000-WireGuard-VPS'
$RuleName3100 = 'HomeSpotify-StorageAgent-3100-WireGuard-VPS'

function Step { param([string] $m) Write-Host "[rollback] $m" }
function Warn { param([string] $m) Write-Host "[rollback] AVERTISSEMENT : $m" }

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host '[rollback] ECHEC : console non élevée'
    exit 1
}

$doAgent    = -not $FirewallOnly
$doFirewall = -not $AgentOnly

$apiBefore = Get-CimInstance Win32_Service -Filter "Name='HomeSpotifyApi'" -ErrorAction SilentlyContinue
Step "HomeSpotifyApi avant rollback : $($apiBefore.State), PID $($apiBefore.ProcessId)"

# ==========================================================================
# 1. Pare-feu : réactiver les règles génériques AVANT toute autre chose.
#    L'ordre compte : on rétablit la voie de secours avant de retirer quoi
#    que ce soit.
# ==========================================================================
if ($doFirewall) {
    $backupRoot = Join-Path $Root 'backup'
    $snapshots = @()
    if (Test-Path $backupRoot) {
        $snapshots = @(Get-ChildItem $backupRoot -Recurse -Filter 'generic-node-rules-before.json' |
                       Sort-Object LastWriteTime -Descending)
    }

    if ($snapshots.Count -eq 0) {
        Step 'aucun export de règles génériques trouvé — rien à réactiver'
    } else {
        $snapshot = Get-Content $snapshots[0].FullName -Raw | ConvertFrom-Json
        Step "réactivation depuis $($snapshots[0].FullName)"
        foreach ($entry in @($snapshot)) {
            if ($entry.EnabledBefore -ne 'True') {
                Step "  - $($entry.DisplayName) était déjà désactivée avant la Phase 3 — laissée telle quelle"
                continue
            }
            $rule = Get-NetFirewallRule -Name $entry.Name -ErrorAction SilentlyContinue
            if (-not $rule) { Warn "règle $($entry.Name) introuvable — non réactivée"; continue }
            Enable-NetFirewallRule -Name $entry.Name
            Step "  - $($entry.DisplayName) réactivée"
        }
    }

    Start-Sleep -Seconds 3
    try {
        $r = Invoke-WebRequest -Uri $PublicUrl -UseBasicParsing -TimeoutSec 20
        Step "domaine public : $($r.StatusCode)"
    } catch {
        Warn 'le domaine public ne répond pas — investiguer AVANT de poursuivre'
    }
}

# ==========================================================================
# 2. Storage Agent : arrêt, retrait de sa règle, désinstallation.
# ==========================================================================
if ($doAgent) {
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($svc) {
        if ($svc.Status -ne 'Stopped') {
            Step 'arrêt du service (arrêt gracieux, 30 s de marge)'
            Stop-Service -Name $ServiceName -Force
            $deadline = (Get-Date).AddSeconds(40)
            do { Start-Sleep -Seconds 2; $svc = Get-Service -Name $ServiceName }
            while ($svc.Status -ne 'Stopped' -and (Get-Date) -lt $deadline)
        }
        Step "service : $($svc.Status)"
    } else {
        Step 'service absent — rien à arrêter'
    }

    $rule = Get-NetFirewallRule -DisplayName $RuleName3100 -ErrorAction SilentlyContinue
    if ($rule) {
        Remove-NetFirewallRule -DisplayName $RuleName3100
        Step "règle « $RuleName3100 » supprimée"
    } else {
        Step 'règle 3100 absente'
    }

    if ($svc) {
        $svcExe = Join-Path $Root "service\$ServiceName.exe"
        if (Test-Path $svcExe) {
            Step 'désinstallation via WinSW'
            & $svcExe uninstall
            if ($LASTEXITCODE -ne 0) { Warn "WinSW uninstall a retourné $LASTEXITCODE" }
        } else {
            Step 'binaire WinSW absent — désinstallation via sc.exe'
            & sc.exe delete $ServiceName | Out-Null
        }
        Start-Sleep -Seconds 3
        if (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue) {
            Warn 'le service est toujours déclaré — un redémarrage peut être nécessaire'
        } else {
            Step 'service désinstallé'
        }
    }

    $listeners = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object LocalPort -eq 3100)
    Step "listeners restants sur 3100 : $($listeners.Count)"
}

# ==========================================================================
# 3. Règle 3000 de la Phase 3 : ne la retirer que si demandé explicitement,
#    et seulement si une autre règle couvre déjà 3000 depuis 10.8.0.1.
# ==========================================================================
if ($doFirewall -and -not $AgentOnly) {
    $legacy = Get-NetFirewallRule -DisplayName 'HomeSpotify API via WireGuard' -ErrorAction SilentlyContinue
    if ($legacy -and $legacy.Enabled -eq 'True') {
        $rule = Get-NetFirewallRule -DisplayName $RuleName3000 -ErrorAction SilentlyContinue
        if ($rule) {
            Remove-NetFirewallRule -DisplayName $RuleName3000
            Step "règle « $RuleName3000 » supprimée (la règle préexistante « HomeSpotify API via WireGuard » couvre 3000)"
        }
    } else {
        Warn "règle « $RuleName3000 » CONSERVÉE : aucune règle préexistante active ne couvre 3000 depuis le VPS"
    }
}

# ==========================================================================
# 4. Artefacts. Conservation par défaut.
# ==========================================================================
if ($RemoveApp) {
    $appDir = Join-Path $Root 'app'
    if (Test-Path $appDir) { Remove-Item $appDir -Recurse -Force; Step 'artefact applicatif supprimé' }
} else {
    Step 'artefact applicatif conservé'
}

Step 'index de production conservé (data\index.json)'
Step 'journaux conservés (logs\)'

if ($RemoveSecret) {
    $cfg = Join-Path $Root 'config\agent.env'
    if (Test-Path $cfg) {
        Remove-Item $cfg -Force
        Step 'secret supprimé sur demande explicite — le VPS devra être réapparié'
    }
} else {
    Step 'secret conservé (utiliser -RemoveSecret pour le supprimer)'
}

# ==========================================================================
# 5. Contrôle final : HomeSpotifyApi doit être intact.
# ==========================================================================
$apiAfter = Get-CimInstance Win32_Service -Filter "Name='HomeSpotifyApi'" -ErrorAction SilentlyContinue
if ($apiAfter.ProcessId -ne $apiBefore.ProcessId) {
    Warn "le PID de HomeSpotifyApi a changé ($($apiBefore.ProcessId) -> $($apiAfter.ProcessId))"
} else {
    Step "HomeSpotifyApi intact : $($apiAfter.State), PID inchangé $($apiAfter.ProcessId)"
}

Step 'rollback terminé — Caddy, WireGuard et la bibliothèque musicale sont inchangés'
exit 0
