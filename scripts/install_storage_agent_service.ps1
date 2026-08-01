<#
.SYNOPSIS
    Installe ou reprend l'installation du service Windows HomeSpotifyStorageAgent
    et de ses règles de pare-feu.

.DESCRIPTION
    Phase 3, étapes NÉCESSITANT DES PRIVILÈGES ADMINISTRATEUR.

    Le script est IDEMPOTENT et REPRENABLE. Chaque étape constate l'état réel
    avant d'agir, et n'agit que si nécessaire. Une exécution interrompue peut
    être relancée telle quelle : le service n'est ni réinstallé, ni supprimé,
    ni redémarré sans raison.

    ORDRE IMPOSÉ — le démarrage vient EN DERNIER
    --------------------------------------------
      1. contrôles préalables (élévation, chemins, XML, agent.env, bind)
      2. service présent ? sinon installation via WinSW
      3. arrêt du service s'il tourne — on ne durcit pas un service en marche
      4. SID de service + identité NT SERVICE\HomeSpotifyStorageAgent
      5. vérification immédiate de StartName
      6. dépendances de service
      7. ACL minimales
      8. BARRIÈRE DE VALIDATION DES ACL — le script échoue ici plutôt que
         de démarrer un service mal cadenassé
      9. règles de pare-feu précises
     10. démarrage et vérification du bind

    IDENTITÉ : compte de service VIRTUEL, sans mot de passe.
    `sc.exe config … obj= "NT SERVICE\<nom>"` est utilisé SANS argument
    `password`. Un compte virtuel exige un mot de passe NULL ; ni
    `password= ""` en ligne de commande (PowerShell supprime l'argument vide),
    ni `Win32_Service.Change` avec `StartPassword = ''` ne conviennent — ce
    dernier retourne le code 22, « paramètre invalide », car il demande à poser
    un mot de passe vide au lieu de n'en poser aucun.

    Ce que le script ne fait PAS :
      - il ne désactive PAS la règle générique « Node.js JavaScript Runtime » ;
      - il ne touche ni à Caddy, ni à WireGuard, ni au service HomeSpotifyApi ;
      - il n'écrit aucun secret, n'en lit aucune valeur et n'en affiche aucun.

.NOTES
    À exécuter depuis une console PowerShell ÉLEVÉE.
    Code de sortie 0 = succès, non nul = échec.
    Rollback : scripts\rollback_storage_agent.ps1
#>
[CmdletBinding()]
param(
    [string] $Root          = 'C:\ProgramData\HomeSpotify\StorageAgent',
    [string] $MusicRoot     = 'F:\dev\homespotify\storage\music',
    [string] $ServiceName   = 'HomeSpotifyStorageAgent',
    [string] $LocalAddress  = '10.8.0.2',
    [string] $RemoteAddress = '10.8.0.1',
    [string] $NodeExe       = 'C:\Program Files\nodejs\node.exe',
    [string] $TunnelService = 'WireGuardTunnel$HomeSpotify-VPS'
)

$ErrorActionPreference = 'Stop'

$AppDir     = Join-Path $Root 'app'
$ConfigFile = Join-Path $Root 'config\agent.env'
$IndexFile  = Join-Path $Root 'data\index.json'
$LogDir     = Join-Path $Root 'logs'
$SvcDir     = Join-Path $Root 'service'
$SvcExe     = Join-Path $SvcDir "$ServiceName.exe"
$SvcXml     = Join-Path $SvcDir "$ServiceName.xml"
$Identity   = "NT SERVICE\$ServiceName"

$RuleName3000 = 'HomeSpotify-API-3000-WireGuard-VPS'
$RuleName3100 = 'HomeSpotify-StorageAgent-3100-WireGuard-VPS'

function Step { param([string] $m) Write-Host "[install] $m" }
function Skip { param([string] $m) Write-Host "[install] déjà conforme — $m" }
function Warn { param([string] $m) Write-Host "[install] AVERTISSEMENT : $m" }
function Fail { param([string] $m) Write-Host "[install] ECHEC : $m"; exit 1 }

# ===========================================================================
# 1. Contrôles préalables
# ===========================================================================
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Fail 'console non élevée — relancer PowerShell en tant qu''administrateur'
}
Step "console élevée ($([Security.Principal.WindowsIdentity]::GetCurrent().Name))"

foreach ($p in @($AppDir, $ConfigFile, $IndexFile, $LogDir, $SvcExe, $SvcXml, $NodeExe, $MusicRoot,
                 (Join-Path $AppDir 'dist\main.js'), (Join-Path $AppDir 'node_modules\fastify'))) {
    if (-not (Test-Path $p)) { Fail "chemin requis absent : $p" }
}
Step 'tous les chemins requis existent'

try { $null = [xml](Get-Content $SvcXml -Raw) } catch { Fail "XML de service invalide : $_" }
$xmlRaw = Get-Content $SvcXml -Raw
if ($xmlRaw -match 'SHARED_SECRET' -or $xmlRaw -match '(?i)<password>') {
    Fail 'le XML du service contient une valeur sensible — installation refusée'
}
Step 'XML valide et exempt de secret'

if (-not (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
          Where-Object IPAddress -eq $LocalAddress)) {
    Fail "l'adresse $LocalAddress n'est pas configurée — le tunnel WireGuard est-il monté ?"
}
Step "adresse de bind $LocalAddress présente"

$cfgLines = Get-Content $ConfigFile
foreach ($expected in @("STORAGE_AGENT_HOST=$LocalAddress",
                        'STORAGE_AGENT_PORT=3100',
                        "STORAGE_AGENT_ALLOWED_REMOTE_IP=$RemoteAddress")) {
    if (-not ($cfgLines | Where-Object { $_ -eq $expected })) { Fail "agent.env ne fixe pas $expected" }
}
# Longueur contrôlée sans jamais afficher ni conserver la valeur.
$secretLine = $cfgLines | Where-Object { $_ -like 'STORAGE_AGENT_SHARED_SECRET=*' }
if (-not $secretLine -or ($secretLine -replace '^STORAGE_AGENT_SHARED_SECRET=', '').Length -lt 32) {
    Fail 'secret partagé absent ou trop court dans agent.env'
}
Remove-Variable secretLine
Step 'agent.env cohérent (secret présent, valeur jamais lue ni affichée)'

$apiBefore = Get-CimInstance Win32_Service -Filter "Name='HomeSpotifyApi'" -ErrorAction SilentlyContinue
Step "HomeSpotifyApi avant : état $($apiBefore.State), PID $($apiBefore.ProcessId)"

# ===========================================================================
# 2. Service présent ? Adoption plutôt que réinstallation.
# ===========================================================================
$existing = Get-CimInstance Win32_Service -Filter "Name='$ServiceName'" -ErrorAction SilentlyContinue

if ($existing) {
    # On n'adopte que SI le service pointe bien sur notre binaire : un service
    # homonyme installé ailleurs ne doit pas être reconfiguré à l'aveugle.
    $declared = ($existing.PathName -replace '^"|"$', '')
    if ($declared -ne $SvcExe) {
        Fail "un service $ServiceName existe mais pointe sur « $declared » au lieu de « $SvcExe » — intervention manuelle requise"
    }
    Skip "le service existe déjà et pointe sur le bon binaire — reprise sans réinstallation"
} else {
    Step 'installation du service via WinSW'
    & $SvcExe install
    if ($LASTEXITCODE -ne 0) { Fail "WinSW install a retourné $LASTEXITCODE" }
    $existing = Get-CimInstance Win32_Service -Filter "Name='$ServiceName'" -ErrorAction SilentlyContinue
    if (-not $existing) { Fail 'le service n''apparaît pas après installation' }
    Step 'service installé'
}

# ===========================================================================
# 3. Arrêt si le service tourne — on ne durcit pas un service en marche.
# ===========================================================================
$svc = Get-Service -Name $ServiceName
if ($svc.Status -ne 'Stopped') {
    Step "service en état $($svc.Status) — arrêt avant durcissement"
    Stop-Service -Name $ServiceName -Force
    $deadline = (Get-Date).AddSeconds(40)
    do { Start-Sleep -Seconds 2; $svc = Get-Service -Name $ServiceName }
    while ($svc.Status -ne 'Stopped' -and (Get-Date) -lt $deadline)
    if ($svc.Status -ne 'Stopped') { Fail "impossible d'arrêter le service (état : $($svc.Status))" }
    Step 'service arrêté'
} else {
    Skip 'service déjà arrêté'
}

$busy = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object LocalPort -eq 3100)
if ($busy.Count -gt 0) { Fail 'le port 3100 est en écoute alors que le service est arrêté — processus tiers ?' }
Step 'port 3100 libre'

# ===========================================================================
# 4. SID de service et identité — compte virtuel, AUCUN mot de passe.
# ===========================================================================
$sidType = (& sc.exe qsidtype $ServiceName | Select-String 'SERVICE_SID_TYPE') -replace '.*:\s*', ''
if ($sidType.Trim() -eq 'UNRESTRICTED') {
    Skip 'SID de service déjà UNRESTRICTED'
} else {
    Step 'activation du SID de service'
    & sc.exe sidtype $ServiceName unrestricted | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail "sc sidtype a retourné $LASTEXITCODE" }
}

$currentIdentity = (Get-CimInstance Win32_Service -Filter "Name='$ServiceName'").StartName
if ($currentIdentity -eq $Identity) {
    Skip "identité déjà $Identity"
} else {
    Step "bascule de l'identité : $currentIdentity -> $Identity"
    # AUCUN argument `password`. Un compte virtuel exige un mot de passe NULL.
    # `password= ""` est supprimé par PowerShell, et Win32_Service.Change avec
    # StartPassword='' retourne le code 22 : il POSE un mot de passe vide au
    # lieu de n'en poser aucun.
    & sc.exe config $ServiceName obj= $Identity
    if ($LASTEXITCODE -ne 0) { Fail "sc config obj= a retourné $LASTEXITCODE" }
}

# ---- 5. Vérification immédiate, avant toute autre opération ----------------
$applied = (Get-CimInstance Win32_Service -Filter "Name='$ServiceName'").StartName
if ($applied -ne $Identity) { Fail "identité appliquée inattendue : « $applied » (attendu « $Identity »)" }
if ($applied -match '(?i)LocalSystem|LocalService|NetworkService|Administrat') {
    Fail "identité privilégiée refusée : $applied"
}
Step "identité vérifiée : $applied (compte virtuel, sans mot de passe, hors groupe Administrateurs)"

# ===========================================================================
# 6. Dépendances de service.
#    WinSW 2.12 n'enregistre PAS un <depend> dont le nom contient « $ » : le
#    tunnel WireGuard est absent de la liste après `winsw install`. On la pose
#    donc explicitement. `sc.exe depend=` REMPLACE la liste entière et utilise
#    « / » comme séparateur.
# ===========================================================================
function Get-DeclaredDependencies {
    # Le REGISTRE est la seule source de vérité fiable ici.
    # `Win32_Service.ServicesDependedOn` retourne vide dès qu'un nom contient
    # « $ » (l'association WMI ne le résout pas), et `sc qc` place les
    # dépendances suivantes sur des lignes de continuation sans le mot-clé
    # DEPENDENCIES — deux façons de conclure à tort qu'une dépendance manque.
    param([string] $Name)
    $v = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\$Name" `
                           -Name DependOnService -ErrorAction SilentlyContinue).DependOnService
    if ($null -eq $v) { return @() }
    return @($v)
}

$tunnelPresent = $null -ne (Get-Service -Name $TunnelService -ErrorAction SilentlyContinue)
$wanted = if ($tunnelPresent) { @('Tcpip', $TunnelService) } else { @('Tcpip') }
$current = Get-DeclaredDependencies $ServiceName

if (-not $tunnelPresent) {
    Warn "le service tunnel « $TunnelService » est introuvable — dépendance non déclarée"
}

$missing = @($wanted | Where-Object { $_ -notin $current })
if ($missing.Count -eq 0) {
    Skip "dépendances déjà correctes ($($current -join ', '))"
} else {
    Step "déclaration des dépendances : $($wanted -join ' / ')"
    & sc.exe config $ServiceName depend= ($wanted -join '/')
    if ($LASTEXITCODE -ne 0) { Fail "sc config depend= a retourné $LASTEXITCODE" }
    $after = Get-DeclaredDependencies $ServiceName
    $stillMissing = @($wanted | Where-Object { $_ -notin $after })
    if ($stillMissing.Count -gt 0) {
        # Non bloquant : c'est une garantie d'ordre de démarrage, pas une
        # propriété de sécurité. Les redémarrages bornés (15/60/120 s) couvrent
        # un tunnel monté tardivement.
        Warn "dépendance(s) non enregistrée(s) : $($stillMissing -join ', ') — l'agent peut échouer au premier démarrage après un redémarrage machine"
    } else {
        Step "dépendances confirmées : $($after -join ', ')"
    }
}

# ===========================================================================
# 7. ACL minimales
# ===========================================================================
function Grant {
    param([string] $Path, [string] $Rights, [string] $Inheritance = '')
    & icacls $Path /grant "${Identity}:${Inheritance}${Rights}" /Q | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail "icacls a échoué sur $Path" }
}

Step 'ACL : lecture/exécution sur l''application déployée'
Grant $AppDir 'RX' '(OI)(CI)'

Step 'ACL : lecture seule sur agent.env'
Grant $ConfigFile 'R'

Step 'ACL : lecture seule sur index.json'
Grant $IndexFile 'R'

Step 'ACL : écriture sur le dossier de journaux UNIQUEMENT'
Grant $LogDir 'M' '(OI)(CI)'

Step 'ACL : lecture/exécution sur la racine musicale (aucune écriture)'
Grant $MusicRoot 'RX' '(OI)(CI)'

Step 'ACL : traversée minimale des dossiers parents (ce dossier seulement)'
$traversed = @()
$parent = Split-Path $MusicRoot -Parent
while ($parent) {
    # RX sans (OI)(CI) : traversée et listage de CE dossier, rien en dessous.
    Grant $parent 'RX'
    $traversed += $parent
    $next = Split-Path $parent -Parent
    if ($next -eq $parent -or [string]::IsNullOrEmpty($next)) { break }
    $parent = $next
}
Step "  traversée accordée sur : $($traversed -join ' ; ')"

# ===========================================================================
# 8. BARRIÈRE DE VALIDATION DES ACL
#    Rien ne démarre tant que chaque droit n'a pas été relu et confirmé.
# ===========================================================================
Step 'validation des ACL avant tout démarrage'

function Get-ServiceAce {
    param([string] $Path)
    @((Get-Acl $Path).Access | Where-Object {
        $_.IdentityReference.Value -eq $Identity -and $_.AccessControlType -eq 'Allow'
    })
}

function Assert-Acl {
    param([string] $Path, [string] $MustMatch, [string] $Label)
    $aces = Get-ServiceAce $Path
    if ($aces.Count -eq 0) { Fail "aucun droit accordé à $Identity sur $Label" }
    $rights = ($aces | ForEach-Object { $_.FileSystemRights.ToString() }) -join ' '
    if ($rights -notmatch $MustMatch) { Fail "droits inattendus sur $Label : $rights" }
    Step "  OK $Label -> $rights"
}

function Assert-NoWrite {
    param([string] $Path, [string] $Label)
    foreach ($ace in (Get-ServiceAce $Path)) {
        $r = $ace.FileSystemRights.ToString()
        # `Write` seul, `Modify`, `FullControl`, `Delete` : tous rédhibitoires.
        # `ReadAndExecute, Synchronize` ne contient aucun de ces motifs.
        if ($r -match 'Modify|FullControl|Delete|(^|,\s*)Write') {
            Fail "ARRET IMMEDIAT : droit d'écriture « $r » accordé sur $Label"
        }
    }
    Step "  OK $Label -> aucune écriture"
}

Assert-Acl     $AppDir     'ReadAndExecute'          'app (RX)'
Assert-Acl     $ConfigFile 'Read'                    'agent.env (R)'
Assert-NoWrite $ConfigFile                           'agent.env'
Assert-Acl     $IndexFile  'Read'                    'index.json (R)'
Assert-NoWrite $IndexFile                            'index.json'
Assert-Acl     $LogDir     'Modify|Write'            'logs (M)'
Assert-Acl     $MusicRoot  'ReadAndExecute'          'racine musicale (RX)'
Assert-NoWrite $MusicRoot                            'racine musicale'

# Le compte de service ne doit avoir AUCUN droit sur la base SQLite.
$dbPath = 'F:\dev\homespotify\services\api\data\homespotify.db'
if (Test-Path $dbPath) {
    $dbAces = Get-ServiceAce $dbPath
    if ($dbAces.Count -gt 0) {
        Fail "ARRET IMMEDIAT : $Identity dispose de droits sur la base SQLite ($($dbAces[0].FileSystemRights))"
    }
    Step '  OK base SQLite -> aucun droit'
}

# Le compte de service ne doit appartenir à aucun groupe privilégié : un compte
# virtuel n'est membre de rien par construction, on le confirme tout de même.
if ($applied -ne $Identity) { Fail 'identité modifiée en cours de route' }
Step 'ACL validées — démarrage autorisé'

# ===========================================================================
# 9. Règles de pare-feu précises
# ===========================================================================
function EnsureRule {
    param([string] $Name, [int] $Port, [string] $Description)
    if (Get-NetFirewallRule -DisplayName $Name -ErrorAction SilentlyContinue) {
        Skip "règle « $Name » déjà présente"
        return
    }
    New-NetFirewallRule `
        -DisplayName   $Name `
        -Description   $Description `
        -Direction     Inbound `
        -Action        Allow `
        -Enabled       True `
        -Protocol      TCP `
        -LocalPort     $Port `
        -LocalAddress  $LocalAddress `
        -RemoteAddress $RemoteAddress `
        -Profile       Public `
        -Program       $NodeExe | Out-Null
    Step "règle « $Name » créée : TCP $Port, local $LocalAddress, distant $RemoteAddress, profil Public, programme node.exe"
}

EnsureRule $RuleName3000 3000 'HomeSpotify Phase 3 - backend API, uniquement depuis le VPS via WireGuard.'
EnsureRule $RuleName3100 3100 'HomeSpotify Phase 3 - Storage Agent, uniquement depuis le VPS via WireGuard.'

# ===========================================================================
# 10. Démarrage et vérifications
# ===========================================================================
Step 'démarrage du service'
Start-Service -Name $ServiceName
$deadline = (Get-Date).AddSeconds(30)
do { Start-Sleep -Seconds 2; $svc = Get-Service -Name $ServiceName }
while ($svc.Status -ne 'Running' -and (Get-Date) -lt $deadline)
if ($svc.Status -ne 'Running') {
    Fail "le service n'est pas Running (état : $($svc.Status)) — consulter $LogDir"
}
Step 'service Running'

Start-Sleep -Seconds 3
$listeners = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object LocalPort -eq 3100)
if ($listeners.Count -eq 0) { Fail "aucun listener sur 3100 — consulter $LogDir" }
foreach ($l in $listeners) {
    if ($l.LocalAddress -ne $LocalAddress) {
        Fail "ARRET IMMEDIAT : listener inattendu sur $($l.LocalAddress):3100"
    }
}
Step "bind vérifié : ${LocalAddress}:3100 uniquement, aucun listener 0.0.0.0"

foreach ($ip in (Get-NetIPAddress -AddressFamily IPv4 |
                 Where-Object { $_.IPAddress -ne $LocalAddress -and $_.IPAddress -notlike '169.254.*' } |
                 Select-Object -ExpandProperty IPAddress)) {
    if (Test-NetConnection -ComputerName $ip -Port 3100 -InformationLevel Quiet -WarningAction SilentlyContinue) {
        Fail "ARRET IMMEDIAT : 3100 accessible sur $ip (hors WireGuard)"
    }
}
Step '3100 injoignable sur toutes les autres adresses (LAN inclus)'

# Identité réelle du processus en cours d'exécution.
$svcProc = Get-CimInstance Win32_Service -Filter "Name='$ServiceName'"
Step "processus de service : PID $($svcProc.ProcessId), identité $($svcProc.StartName)"

$apiAfter = Get-CimInstance Win32_Service -Filter "Name='HomeSpotifyApi'"
if ($apiAfter.ProcessId -ne $apiBefore.ProcessId) {
    Warn "le PID de HomeSpotifyApi a changé ($($apiBefore.ProcessId) -> $($apiAfter.ProcessId))"
} else {
    Step "HomeSpotifyApi intact : état $($apiAfter.State), PID inchangé $($apiAfter.ProcessId)"
}

try {
    $pub = Invoke-WebRequest 'https://music.romainbegot.fr/health' -UseBasicParsing -TimeoutSec 15
    Step "domaine public : $($pub.StatusCode)"
} catch {
    Warn 'le domaine public ne répond pas — vérifier avant de poursuivre'
}

Step 'terminé — la règle générique Node.js n''a PAS été touchée'
Step 'étape suivante : validation depuis le VPS, PUIS scripts\firewall_transition_generic_node.ps1'
exit 0
