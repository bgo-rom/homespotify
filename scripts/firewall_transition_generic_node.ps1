<#
.SYNOPSIS
    Désactive les règles de pare-feu génériques « Node.js JavaScript Runtime »,
    avec annulation AUTOMATIQUE si le moindre contrôle échoue.

.DESCRIPTION
    Phase 3F. NÉCESSITE DES PRIVILÈGES ADMINISTRATEUR.

    Situation traitée : deux règles « Node.js JavaScript Runtime » (une TCP, une
    UDP) autorisent node.exe en entrée sur TOUS les ports, TOUTES les adresses
    distantes, profils Private ET Public. C'est la surface d'exposition la plus
    large de la machine, et la dernière chose que la Phase 3 doit refermer.

    Elles ne sont désactivées qu'APRÈS que les règles précises créées par
    install_storage_agent_service.ps1 aient été constatées actives et
    fonctionnelles.

    VALIDATION DU CHEMIN VPS SANS SSH
    ---------------------------------
    Caddy, sur le VPS, sert https://music.romainbegot.fr en proxy vers
    10.8.0.2:3000 à travers WireGuard. Un 200 sur ce domaine prouve donc
    TRANSITIVEMENT que le chemin VPS -> WireGuard -> backend Windows fonctionne.
    C'est le contrôle d'acceptation le plus fort exécutable depuis le PC.

    ANNULATION AUTOMATIQUE
    ----------------------
    Après désactivation, une batterie complète de contrôles est exécutée. Si
    UN SEUL échoue, les règles génériques sont réactivées immédiatement, l'état
    rétabli est revérifié, un journal de diagnostic est écrit, et le script sort
    en erreur sans rien improviser.

    EFFET DE BORD À CONNAÎTRE
    -------------------------
    L'interface « Ethernet 3 » est en profil Public. C'est aujourd'hui la règle
    générique qui rend le port 3000 joignable depuis le LAN sur cette interface.
    Après désactivation, 3000 ne sera plus joignable que depuis 10.8.0.1 et, en
    profil Private, via la règle préexistante « HomeSpotify API 3000 ». Tout
    client qui attaque directement l'IP LAN du PC en profil Public cessera de
    fonctionner — c'est l'objectif, mais il faut l'avoir voulu.

    Note sur le contrôle « 10.8.0.2:3000 depuis le PC » : Windows exempte du
    filtrage WFP le trafic dont la source et la destination sont deux adresses
    de la même machine. Ce contrôle ne prouve donc PAS le chemin distant — le
    domaine public s'en charge — mais une régression y serait anormale et
    déclenche l'annulation, conformément aux critères demandés.

    Ce script ne touche JAMAIS : Caddy, WireGuard, le service HomeSpotifyApi,
    le service HomeSpotifyStorageAgent, les règles précises Phase 3, la règle
    « WireGuard - Ping depuis VPS », ni les règles préexistantes du port 3000.
    Aucun reset global du pare-feu n'est effectué, en aucune circonstance.

.NOTES
    Rollback manuel : scripts\rollback_storage_agent.ps1 -FirewallOnly
#>
[CmdletBinding()]
param(
    [string] $BackupDir = "C:\ProgramData\HomeSpotify\StorageAgent\backup\firewall-$(Get-Date -Format 'yyyyMMdd-HHmmss')",
    [string] $PublicUrl = 'https://music.romainbegot.fr/health',
    [int]    $Probes    = 5,
    [string] $ServiceName  = 'HomeSpotifyStorageAgent',
    [string] $LocalAddress = '10.8.0.2'
)

$ErrorActionPreference = 'Stop'

$RuleName3000 = 'HomeSpotify-API-3000-WireGuard-VPS'
$RuleName3100 = 'HomeSpotify-StorageAgent-3100-WireGuard-VPS'

function Step { param([string] $m) Write-Host "[firewall] $m" }
function Warn { param([string] $m) Write-Host "[firewall] AVERTISSEMENT : $m" }
function Fail { param([string] $m) Write-Host "[firewall] ECHEC : $m"; exit 1 }

function Test-Url {
    param([string] $Url, [int] $Attempts = 1, [int] $TimeoutSec = 20)
    for ($i = 1; $i -le $Attempts; $i++) {
        try {
            $r = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec $TimeoutSec
            if ($r.StatusCode -ne 200) { return $false }
        } catch { return $false }
        if ($i -lt $Attempts) { Start-Sleep -Seconds 2 }
    }
    return $true
}

# ===========================================================================
# 0. Élévation
# ===========================================================================
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Fail 'console non élevée'
}
Step "console élevée ($([Security.Principal.WindowsIdentity]::GetCurrent().Name))"

# ===========================================================================
# 1. Ligne de base, capturée AVANT toute modification
# ===========================================================================
$apiBefore = Get-CimInstance Win32_Service -Filter "Name='HomeSpotifyApi'" -ErrorAction SilentlyContinue
if (-not $apiBefore) { Fail 'service HomeSpotifyApi introuvable' }
$ApiPidBefore = $apiBefore.ProcessId
Step "ligne de base — HomeSpotifyApi : $($apiBefore.State), PID $ApiPidBefore"

$agentBefore = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if (-not $agentBefore) { Fail "service $ServiceName introuvable — exécuter d'abord install_storage_agent_service.ps1" }
Step "ligne de base — $ServiceName : $($agentBefore.Status)"

# ===========================================================================
# 2. Contrôles PRÉALABLES — tous bloquants
# ===========================================================================
Step 'contrôles préalables'

foreach ($name in @($RuleName3000, $RuleName3100)) {
    $rule = Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue
    if (-not $rule)               { Fail "règle « $name » absente — exécuter d'abord install_storage_agent_service.ps1" }
    if ($rule.Enabled -ne 'True') { Fail "règle « $name » désactivée" }
    $pf = $rule | Get-NetFirewallPortFilter
    $af = $rule | Get-NetFirewallAddressFilter
    if ($pf.LocalPort -contains 'Any')      { Fail "règle « $name » trop large : port Any" }
    if ($af.RemoteAddress -contains 'Any')  { Fail "règle « $name » trop large : distant Any" }
    Step "  OK règle « $name » active, TCP $($pf.LocalPort), distant $($af.RemoteAddress)"
}

if ($agentBefore.Status -ne 'Running') { Fail "$ServiceName n'est pas Running" }
Step "  OK $ServiceName Running"

$listeners = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object LocalPort -eq 3100)
if ($listeners.Count -ne 1 -or $listeners[0].LocalAddress -ne $LocalAddress) {
    Fail "listener 3100 inattendu : $(($listeners | ForEach-Object { "$($_.LocalAddress):$($_.LocalPort)" }) -join ', ')"
}
Step "  OK listener unique ${LocalAddress}:3100"

if (-not (Test-Url 'http://127.0.0.1:3000/health' -TimeoutSec 10)) { Fail 'backend local 127.0.0.1:3000 ne répond pas 200 AVANT modification' }
Step '  OK backend local 127.0.0.1:3000 = 200'

if (-not (Test-Url "http://${LocalAddress}:3000/health" -TimeoutSec 10)) { Fail "backend WireGuard ${LocalAddress}:3000 ne répond pas 200 AVANT modification" }
Step "  OK backend WireGuard ${LocalAddress}:3000 = 200"

if (-not (Test-Url $PublicUrl -Attempts 2)) { Fail 'le domaine public ne répond pas déjà AVANT modification — ne rien changer' }
Step '  OK domaine public = 200 (chemin VPS -> WireGuard -> 3000 opérationnel)'

# ===========================================================================
# 3. Identification des règles génériques, sur critère STRUCTUREL
#    Jamais sur le seul DisplayName : c'est la forme de la règle qui compte.
# ===========================================================================
$generic = @()
foreach ($rule in (Get-NetFirewallRule -Direction Inbound -Enabled True -Action Allow)) {
    $app = $rule | Get-NetFirewallApplicationFilter -ErrorAction SilentlyContinue
    if (-not $app -or $app.Program -notmatch 'node\.exe$') { continue }
    $pf = $rule | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue
    $af = $rule | Get-NetFirewallAddressFilter -ErrorAction SilentlyContinue
    if (($pf.LocalPort -contains 'Any') -and ($af.RemoteAddress -contains 'Any')) { $generic += $rule }
}

if ($generic.Count -eq 0) {
    Step 'aucune règle générique node.exe trop large — rien à faire'
    exit 0
}

Step "$($generic.Count) règle(s) générique(s) ciblée(s) :"
foreach ($rule in $generic) {
    $pf = $rule | Get-NetFirewallPortFilter
    $af = $rule | Get-NetFirewallApplicationFilter
    Step "  - $($rule.DisplayName)"
    Step "    Name    = $($rule.Name)"
    Step "    $($pf.Protocol) ports=$($pf.LocalPort -join ',') profils=$($rule.Profile) programme=$($af.Program)"
}

# ===========================================================================
# 4. Export de leur état
# ===========================================================================
New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
$snapshot = foreach ($rule in $generic) {
    $pf = $rule | Get-NetFirewallPortFilter
    $af = $rule | Get-NetFirewallApplicationFilter
    $ad = $rule | Get-NetFirewallAddressFilter
    [PSCustomObject]@{
        Name = $rule.Name; DisplayName = $rule.DisplayName
        EnabledBefore = [string]$rule.Enabled; Profile = [string]$rule.Profile
        Action = [string]$rule.Action; Protocol = [string]$pf.Protocol
        LocalPort = ($pf.LocalPort -join ','); Program = [string]$af.Program
        RemoteAddress = ($ad.RemoteAddress -join ',')
    }
}
$snapshotFile = Join-Path $BackupDir 'generic-node-rules-before.json'
$snapshot | ConvertTo-Json -Depth 4 | Out-File $snapshotFile -Encoding utf8
Step "état exporté : $snapshotFile"

# ===========================================================================
# 5. Batterie de contrôles post-transition
#    Retourne la liste des échecs. Vide = tout va bien.
# ===========================================================================
function Invoke-PostChecks {
    $failures = @()

    if (Test-Url $PublicUrl -Attempts $Probes) { Step "  OK domaine public = 200 ($Probes/$Probes)" }
    else { $failures += "domaine public != 200 sur $Probes tentatives" }

    if (Test-Url 'http://127.0.0.1:3000/health' -TimeoutSec 10) { Step '  OK backend local 127.0.0.1:3000 = 200' }
    else { $failures += 'backend local 127.0.0.1:3000 != 200' }

    if (Test-Url "http://${LocalAddress}:3000/health" -TimeoutSec 10) { Step "  OK backend WireGuard ${LocalAddress}:3000 = 200" }
    else { $failures += "backend WireGuard ${LocalAddress}:3000 != 200" }

    $agent = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($agent -and $agent.Status -eq 'Running') { Step "  OK $ServiceName Running" }
    else { $failures += "$ServiceName n'est plus Running (état : $($agent.Status))" }

    $lis = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object LocalPort -eq 3100)
    if ($lis.Count -eq 1 -and $lis[0].LocalAddress -eq $LocalAddress) { Step "  OK listener unique ${LocalAddress}:3100" }
    else { $failures += "listener 3100 inattendu : $(($lis | ForEach-Object { "$($_.LocalAddress):$($_.LocalPort)" }) -join ', ')" }

    foreach ($name in @($RuleName3000, $RuleName3100)) {
        $r = Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue
        if ($r -and $r.Enabled -eq 'True') { Step "  OK règle « $name » toujours active" }
        else { $failures += "règle « $name » absente ou désactivée" }
    }

    foreach ($g in $generic) {
        $r = Get-NetFirewallRule -Name $g.Name -ErrorAction SilentlyContinue
        if ($r -and $r.Enabled -eq 'False') { Step "  OK « $($g.DisplayName) » ($($g.Name.Substring(0, [Math]::Min(24, $g.Name.Length)))…) désactivée" }
        else { $failures += "règle générique $($g.Name) toujours active" }
    }

    $api = Get-CimInstance Win32_Service -Filter "Name='HomeSpotifyApi'" -ErrorAction SilentlyContinue
    if ($api -and $api.State -eq 'Running') { Step "  OK HomeSpotifyApi Running (PID $($api.ProcessId))" }
    else { $failures += "HomeSpotifyApi n'est plus Running (état : $($api.State))" }
    if ($api -and $api.ProcessId -ne $ApiPidBefore) {
        # Non bloquant : demandé « si possible ». Un redémarrage inopiné du
        # service est une information, pas une régression du pare-feu.
        Warn "PID de HomeSpotifyApi changé ($ApiPidBefore -> $($api.ProcessId))"
    }

    return $failures
}

# ===========================================================================
# 6. Désactivation
# ===========================================================================
Step 'désactivation des règles génériques'
foreach ($rule in $generic) { Disable-NetFirewallRule -Name $rule.Name }
Start-Sleep -Seconds 3

Step 'revalidation complète après désactivation'
$failures = Invoke-PostChecks

# ===========================================================================
# 7. Annulation automatique si le moindre contrôle a échoué
# ===========================================================================
if ($failures.Count -gt 0) {
    Write-Host ''
    Write-Host '[firewall] ECHEC DE VALIDATION — REACTIVATION IMMEDIATE DES REGLES GENERIQUES'
    foreach ($f in $failures) { Write-Host "[firewall]   - $f" }

    foreach ($rule in $generic) {
        try { Enable-NetFirewallRule -Name $rule.Name } catch { Warn "réactivation impossible de $($rule.Name) : $_" }
    }
    Start-Sleep -Seconds 3

    $publicRestored = Test-Url $PublicUrl -Attempts 3
    $localRestored  = Test-Url 'http://127.0.0.1:3000/health' -TimeoutSec 10
    $wgRestored     = Test-Url "http://${LocalAddress}:3000/health" -TimeoutSec 10
    $stillDisabled  = @($generic | ForEach-Object { Get-NetFirewallRule -Name $_.Name -ErrorAction SilentlyContinue } |
                        Where-Object { $_.Enabled -ne 'True' })

    $diag = Join-Path $BackupDir 'transition-failure.txt'
    @(
        "Transition interrompue le $(Get-Date -Format 'o')"
        ''
        'Echecs constates apres desactivation :'
        ($failures | ForEach-Object { "  - $_" })
        ''
        'Etat apres reactivation :'
        "  domaine public retabli        : $publicRestored"
        "  backend local retabli         : $localRestored"
        "  backend WireGuard retabli     : $wgRestored"
        "  regles generiques encore OFF  : $($stillDisabled.Count)"
        "  HomeSpotifyApi PID avant      : $ApiPidBefore"
        "  HomeSpotifyApi PID apres      : $((Get-CimInstance Win32_Service -Filter "Name='HomeSpotifyApi'").ProcessId)"
        ''
        "Export des regles generiques : $snapshotFile"
    ) | ForEach-Object { $_ } | Out-File $diag -Encoding utf8

    Write-Host ''
    Write-Host "[firewall] règles génériques réactivées."
    Write-Host "[firewall]   domaine public rétabli    : $publicRestored"
    Write-Host "[firewall]   backend local rétabli     : $localRestored"
    Write-Host "[firewall]   backend WireGuard rétabli : $wgRestored"
    if ($stillDisabled.Count -gt 0) {
        Write-Host "[firewall]   ATTENTION : $($stillDisabled.Count) règle(s) générique(s) n'ont PAS pu être réactivées"
    }
    Write-Host "[firewall] diagnostic : $diag"
    Write-Host '[firewall] MISSION INTERROMPUE — ne pas improviser d''autres règles larges.'
    exit 1
}

# ===========================================================================
# 8. Succès
# ===========================================================================
Write-Host ''
Step 'tous les contrôles sont passés — transition confirmée'
Step "export conservé : $snapshotFile"
Step 'Caddy, WireGuard, HomeSpotifyApi et HomeSpotifyStorageAgent sont inchangés'
Write-Host ''
Write-Host '[firewall] Pour annuler manuellement :'
Write-Host '[firewall]   powershell -NoProfile -ExecutionPolicy Bypass -File F:\dev\homespotify\scripts\rollback_storage_agent.ps1 -FirewallOnly'
exit 0
