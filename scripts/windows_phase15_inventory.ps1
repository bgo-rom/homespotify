<#
.SYNOPSIS
    Inventaire Windows STRICTEMENT EN LECTURE SEULE — Phase 1.5 (migration VPS).

.DESCRIPTION
    Collecte l'état du service HomeSpotifyApi, du processus Node, du port 3000,
    des règles de pare-feu pertinentes et de l'interface WireGuard, puis écrit
    un rapport texte sur le Bureau.

    Ce script N'EFFECTUE AUCUNE ÉCRITURE SYSTÈME :
    - aucune règle de pare-feu créée, modifiée ou supprimée ;
    - aucun service démarré, arrêté ou redémarré ;
    - aucun processus tué ;
    - aucune modification de WireGuard, de la base ou des fichiers audio.

    Toute valeur ressemblant à une clé ou à un secret est caviardée avant
    écriture (voir Protect-Secrets).

.NOTES
    Certaines informations (chemin exact de l'exécutable, ligne de commande,
    heure de démarrage, CPU cumulé) appartiennent à un processus LocalSystem :
    elles ne sont lisibles que depuis une console PowerShell ADMINISTRATEUR.
    Le rapport indique explicitement « ADMIN REQUIS » quand c'est le cas.
#>

[CmdletBinding()]
param(
    [string] $OutputPath
)

$ErrorActionPreference = 'Continue'

if (-not $OutputPath) {
    $desktop = [Environment]::GetFolderPath('Desktop')
    $OutputPath = Join-Path $desktop 'HomeSpotify-Windows-Phase15.txt'
}

$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

$lines = New-Object System.Collections.Generic.List[string]

function Add-Line { param([string] $Text = '') $lines.Add($Text) }

function Add-Section {
    param([string] $Title)
    Add-Line ''
    Add-Line ('=' * 74)
    Add-Line $Title
    Add-Line ('=' * 74)
}

# Caviardage : clés WireGuard/base64 longues, tokens, secrets nommés.
function Protect-Secrets {
    param([string] $Text)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    $out = $Text
    $out = [regex]::Replace($out, '(?i)(private|preshared|public)key\s*[:=]\s*\S+', '$1Key = [CAVIARDE]')
    $out = [regex]::Replace($out, '(?i)\b(secret|token|password|apikey|api_key)\b\s*[:=]\s*\S+', '$1 = [CAVIARDE]')
    $out = [regex]::Replace($out, '[A-Za-z0-9+/]{43}=', '[CAVIARDE-CLE-BASE64]')
    return $out
}

function Add-Object {
    param($InputObject, [string] $Empty = '(aucun résultat)')
    if ($null -eq $InputObject) { Add-Line $Empty; return }
    $rendered = $InputObject | Format-List | Out-String -Width 200
    if ([string]::IsNullOrWhiteSpace($rendered)) { Add-Line $Empty; return }
    foreach ($l in ($rendered -split "`r?`n")) {
        if (-not [string]::IsNullOrWhiteSpace($l)) { Add-Line (Protect-Secrets $l.TrimEnd()) }
    }
}

Add-Line 'HomeSpotify — Inventaire Windows Phase 1.5 (lecture seule)'
Add-Line ("Généré le      : " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
Add-Line ("Machine        : " + $env:COMPUTERNAME)
Add-Line ("Console admin  : " + $(if ($isAdmin) { 'OUI' } else { 'NON (certaines valeurs seront marquées ADMIN REQUIS)' }))

# ---------------------------------------------------------------------------
Add-Section '1. SERVICE WINDOWS HomeSpotifyApi'
# ---------------------------------------------------------------------------
$svc = Get-CimInstance Win32_Service -Filter "Name='HomeSpotifyApi'" -ErrorAction SilentlyContinue
if ($null -eq $svc) {
    Add-Line 'Service HomeSpotifyApi INTROUVABLE.'
} else {
    Add-Object ($svc | Select-Object Name, DisplayName, State, Status, StartMode, StartName,
        ProcessId, PathName, ServiceType, ExitCode)
}

# ---------------------------------------------------------------------------
Add-Section '2. PROCESSUS (wrapper WinSW + enfant Node)'
# ---------------------------------------------------------------------------
if ($null -ne $svc -and $svc.ProcessId -gt 0) {
    $wrapper = Get-CimInstance Win32_Process -Filter "ProcessId=$($svc.ProcessId)" -ErrorAction SilentlyContinue
    Add-Line "--- Wrapper (PID $($svc.ProcessId)) ---"
    Add-Object ($wrapper | Select-Object ProcessId, Name, CreationDate, HandleCount,
        @{n = 'WorkingSetMB'; e = { [math]::Round($_.WorkingSetSize / 1MB, 1) } },
        ExecutablePath, CommandLine)

    $children = Get-CimInstance Win32_Process -Filter "ParentProcessId=$($svc.ProcessId)" -ErrorAction SilentlyContinue
    foreach ($child in $children) {
        Add-Line ''
        Add-Line "--- Enfant : $($child.Name) (PID $($child.ProcessId)) ---"
        Add-Line ("CreationDate    : " + $child.CreationDate)
        Add-Line ("HandleCount     : " + $child.HandleCount)
        Add-Line ("WorkingSet (MB) : " + [math]::Round($child.WorkingSetSize / 1MB, 1))
        Add-Line ("KernelModeTime  : " + $child.KernelModeTime + " (100 ns)")
        Add-Line ("UserModeTime    : " + $child.UserModeTime + " (100 ns)")
        $cpuSeconds = [math]::Round((($child.KernelModeTime + $child.UserModeTime) / 10000000), 1)
        Add-Line ("CPU cumulé (s)  : " + $cpuSeconds)
        if ([string]::IsNullOrWhiteSpace($child.ExecutablePath)) {
            Add-Line 'ExecutablePath  : ADMIN REQUIS (processus LocalSystem)'
        } else {
            Add-Line ("ExecutablePath  : " + $child.ExecutablePath)
        }
        if ([string]::IsNullOrWhiteSpace($child.CommandLine)) {
            Add-Line 'CommandLine     : ADMIN REQUIS (processus LocalSystem)'
        } else {
            Add-Line ("CommandLine     : " + (Protect-Secrets $child.CommandLine))
        }

        $proc = Get-Process -Id $child.ProcessId -ErrorAction SilentlyContinue
        if ($null -ne $proc) {
            Add-Line ("PrivateBytes MB : " + [math]::Round($proc.PrivateMemorySize64 / 1MB, 1))
            Add-Line ("WorkingSet64 MB : " + [math]::Round($proc.WorkingSet64 / 1MB, 1))
            $start = try { $proc.StartTime } catch { $null }
            if ($null -eq $start) {
                Add-Line 'StartTime       : ADMIN REQUIS (voir CreationDate ci-dessus)'
            } else {
                Add-Line ("StartTime       : " + $start)
            }
        }
    }
}

# Répertoire de travail déclaré : lu dans la configuration WinSW, jamais deviné.
$winswXml = 'F:\dev\homespotify\infra\windows-service\homespotify-api\HomeSpotifyApi.xml'
Add-Line ''
Add-Line "--- Configuration WinSW ($winswXml) ---"
if (Test-Path $winswXml) {
    # -Encoding UTF8 : le XML est en UTF-8 sans BOM, la lecture ANSI par défaut
    # de PowerShell 5.1 corromprait les accents.
    foreach ($l in (Get-Content -LiteralPath $winswXml -Encoding UTF8)) { Add-Line (Protect-Secrets $l) }
} else {
    Add-Line 'Fichier de configuration WinSW introuvable.'
}

# ---------------------------------------------------------------------------
Add-Section '3. PORT 3000 — ÉCOUTE ET CONNEXIONS'
# ---------------------------------------------------------------------------
Add-Line '--- Sockets en écoute ---'
Add-Object (Get-NetTCPConnection -LocalPort 3000 -State Listen -ErrorAction SilentlyContinue |
    Select-Object LocalAddress, LocalPort, State, OwningProcess) '(aucune écoute sur 3000)'

Add-Line ''
Add-Line '--- Connexions actives (hors écoute) ---'
Add-Object (Get-NetTCPConnection -LocalPort 3000 -ErrorAction SilentlyContinue |
    Where-Object { $_.State -ne 'Listen' } |
    Select-Object LocalAddress, LocalPort, RemoteAddress, RemotePort, State, OwningProcess) '(aucune connexion active)'

Add-Line ''
Add-Line '--- Adresses IPv4 de la machine ---'
Add-Object (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Select-Object InterfaceAlias, IPAddress, PrefixLength)

Add-Line ''
Add-Line '--- Profils réseau par interface ---'
Add-Object (Get-NetConnectionProfile -ErrorAction SilentlyContinue |
    Select-Object InterfaceAlias, NetworkCategory, IPv4Connectivity)

# ---------------------------------------------------------------------------
Add-Section '4. PARE-FEU (LECTURE SEULE)'
# ---------------------------------------------------------------------------
Add-Line '--- Profils ---'
Add-Object (Get-NetFirewallProfile -ErrorAction SilentlyContinue |
    Select-Object Name, Enabled, DefaultInboundAction, DefaultOutboundAction)

Add-Line ''
Add-Line '--- Règles pertinentes (HomeSpotify / WinSW / node / WireGuard) ---'
$rules = Get-NetFirewallRule -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -match 'HomeSpotify|WinSW|node|WireGuard' }
if ($null -eq $rules -or @($rules).Count -eq 0) {
    Add-Line '(aucune règle correspondante)'
} else {
    foreach ($r in $rules) {
        $pf = $r | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue
        $af = $r | Get-NetFirewallAddressFilter -ErrorAction SilentlyContinue
        $ap = $r | Get-NetFirewallApplicationFilter -ErrorAction SilentlyContinue
        $sf = $r | Get-NetFirewallServiceFilter -ErrorAction SilentlyContinue
        Add-Line ''
        Add-Line ("Nom            : " + $r.DisplayName)
        Add-Line ("Activée        : " + $r.Enabled)
        Add-Line ("Direction      : " + $r.Direction)
        Add-Line ("Action         : " + $r.Action)
        Add-Line ("Profil         : " + $r.Profile)
        Add-Line ("Protocole      : " + $pf.Protocol)
        Add-Line ("Port local     : " + ($pf.LocalPort -join ','))
        Add-Line ("Port distant   : " + ($pf.RemotePort -join ','))
        Add-Line ("Adresse locale : " + ($af.LocalAddress -join ','))
        Add-Line ("Adresse dist.  : " + ($af.RemoteAddress -join ','))
        Add-Line ("Programme      : " + $ap.Program)
        Add-Line ("Service        : " + $sf.Service)
    }
}

# ---------------------------------------------------------------------------
Add-Section '5. WIREGUARD (AUCUNE CLÉ AFFICHÉE)'
# ---------------------------------------------------------------------------
$wgAlias = 'HomeSpotify-VPS'
Add-Line '--- Adaptateur ---'
Add-Object (Get-NetAdapter -Name $wgAlias -ErrorAction SilentlyContinue |
    Select-Object Name, InterfaceDescription, Status, ifIndex, LinkSpeed, MtuSize) "(interface $wgAlias absente)"

Add-Line ''
Add-Line '--- Adresses ---'
Add-Object (Get-NetIPAddress -InterfaceAlias $wgAlias -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Select-Object InterfaceAlias, IPAddress, PrefixLength, AddressState)

Add-Line ''
Add-Line '--- Routes ---'
Add-Object (Get-NetRoute -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.InterfaceAlias -eq $wgAlias } |
    Select-Object DestinationPrefix, NextHop, RouteMetric, InterfaceMetric)

Add-Line ''
Add-Line '--- Latence vers 10.8.0.1 (10 pings, aucune écriture) ---'
$replies = Test-Connection -ComputerName '10.8.0.1' -Count 10 -ErrorAction SilentlyContinue
if ($null -eq $replies) {
    Add-Line 'Aucune réponse (tunnel bas, ICMP filtré ou pair injoignable).'
} else {
    $times = @($replies | ForEach-Object { $_.ResponseTime })
    $stats = $times | Measure-Object -Minimum -Maximum -Average
    Add-Line ("Réponses     : " + $times.Count + "/10")
    Add-Line ("Perte        : " + (10 - $times.Count) * 10 + " %")
    Add-Line ("Latence (ms) : min=" + $stats.Minimum + " avg=" + [math]::Round($stats.Average, 1) + " max=" + $stats.Maximum)
    Add-Line ("Échantillons : " + ($times -join ', '))
}
Add-Line ''
# Attention : l'apostrophe typographique est un délimiteur de chaîne valide en
# PowerShell — n'utiliser que l'apostrophe droite dans les littéraux.
Add-Line "Note : aucune cle WireGuard (PrivateKey/PresharedKey/PublicKey) n'est lue"
Add-Line 'ni écrite par ce script.'

# ---------------------------------------------------------------------------
Add-Section '6. FIN'
# ---------------------------------------------------------------------------
Add-Line 'Aucune modification système effectuée : ce script est en lecture seule.'

$content = ($lines -join [Environment]::NewLine)
Set-Content -LiteralPath $OutputPath -Value $content -Encoding utf8
Write-Output "Rapport écrit : $OutputPath"
