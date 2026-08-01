<#
.SYNOPSIS
    Régénère l'index de production du HomeSpotify Storage Agent.

.DESCRIPTION
    Phase 3, procédure MANUELLE et TEMPORAIRE.

    La synchronisation automatique VPS -> PC est hors périmètre. Tant qu'elle
    n'existe pas, ce script doit être exécuté APRÈS CHAQUE NOUVEL IMPORT, sinon
    les pistes nouvellement importées restent invisibles pour le Storage Agent
    (404 TRACK_NOT_INDEXED) alors qu'elles sont lisibles par l'API locale.

    Ce que fait le script :
      1. vérifie que l'API actuelle répond et que la base SQLite est présente ;
      2. lance l'export en LECTURE SEULE (la base est ouverte readonly par le CLI) ;
      3. écrit atomiquement dans le chemin de production (tmp + rename, fait par le CLI) ;
      4. vérifie le résumé (aucun chemin invalide, aucun fichier absent) ;
      5. vérifie que l'agent a rechargé le nouvel index, SANS le redémarrer.

    Ce que le script ne fait JAMAIS :
      - modifier la base, la bibliothèque musicale ou un fichier audio ;
      - afficher un chemin de la bibliothèque ;
      - lire ou afficher le secret partagé ;
      - redémarrer le service si le rechargement à chaud fonctionne ;
      - créer une tâche planifiée.

    La vérification du rechargement se fait sur le JOURNAL LOCAL de l'agent, pas
    par une requête HTTP : l'agent filtre l'IP source et n'accepte que 10.8.0.1,
    donc une requête émise depuis le PC recevrait 403 même correctement signée.
    Ce choix évite en outre que ce script ait besoin du secret.

.PARAMETER IndexPath
    Chemin de l'index de production.

.PARAMETER ApiHealthUrl
    URL de contrôle de l'API locale.

.PARAMETER ReloadTimeoutSeconds
    Attente maximale du rechargement à chaud. L'agent scrute l'index toutes les
    STORAGE_AGENT_INDEX_POLL_INTERVAL_MS (5 s par défaut).

.NOTES
    Ne requiert PAS de privilèges administrateur si l'utilisateur a accès en
    écriture au répertoire data et en lecture au journal de l'agent.
    Code de sortie 0 = succès, non nul = échec.
#>
[CmdletBinding()]
param(
    [string] $IndexPath            = 'C:\ProgramData\HomeSpotify\StorageAgent\data\index.json',
    [string] $LogDir               = 'C:\ProgramData\HomeSpotify\StorageAgent\logs',
    [string] $ApiHealthUrl         = 'http://127.0.0.1:3000/health',
    [int]    $ReloadTimeoutSeconds = 45
)

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$DbPath   = Join-Path $RepoRoot 'services\api\data\homespotify.db'

function Step { param([string] $m) Write-Host "[index] $m" }
function Fail { param([string] $m) Write-Host "[index] ECHEC : $m"; exit 1 }

# --- 1. Préconditions -------------------------------------------------------
Step 'contrôle de l''API locale'
try {
    $health = Invoke-WebRequest -Uri $ApiHealthUrl -UseBasicParsing -TimeoutSec 10
    if ($health.StatusCode -ne 200) { Fail "l'API répond $($health.StatusCode)" }
} catch {
    Fail "l'API locale ne répond pas — index non régénéré"
}
Step 'API : 200'

if (-not (Test-Path $DbPath)) { Fail 'base SQLite introuvable' }
Step "base SQLite présente ($([math]::Round((Get-Item $DbPath).Length / 1MB, 1)) Mo)"

# Pas de comparaison d'empreinte de la base : elle est ouverte en écriture par
# l'API en production (historique de lecture, favoris...), donc son contenu
# change légitimement pendant l'export et une comparaison produirait de fausses
# alertes. La garantie de non-écriture vient d'ailleurs, et elle est plus forte :
# le CLI d'export ouvre SQLite en `readonly` + `fileMustExist`, et
# services\api\src\storage\storage-index-export.test.ts vérifie que la base est
# inchangée octet à octet après un export.
$dbSizeBefore = (Get-Item $DbPath).Length

$previousGeneratedAt = $null
if (Test-Path $IndexPath) {
    try { $previousGeneratedAt = (Get-Content $IndexPath -Raw | ConvertFrom-Json).generatedAt } catch { }
    Step "index actuel généré le $previousGeneratedAt"
}

# --- 2. Export --------------------------------------------------------------
Step 'export en lecture seule'
Push-Location $RepoRoot
try {
    $output = pnpm --filter '@homespotify/api' storage-index:export -- --out $IndexPath | Out-String
    if ($LASTEXITCODE -ne 0) { Fail "l'export a échoué (code $LASTEXITCODE)" }
} finally {
    Pop-Location
}

# --- 3. La base doit rester présente et exploitable ------------------------
if (-not (Test-Path $DbPath)) { Fail 'la base SQLite a disparu pendant l''export — anomalie grave' }
$dbSizeAfter = (Get-Item $DbPath).Length
if ($dbSizeAfter -lt $dbSizeBefore) {
    Fail "la base SQLite a rétréci pendant l'export ($dbSizeBefore -> $dbSizeAfter octets) — anomalie grave"
}
Step 'base SQLite toujours présente, aucune troncature'

# --- 4. Résumé --------------------------------------------------------------
# Le CLI n'affiche que des compteurs, jamais un chemin. On les relaie tels quels.
$exported = [regex]::Match($output, '(\d+)\s+pistes exportées').Groups[1].Value
$valid    = [regex]::Match($output, '(\d+)\s+fichiers valides').Groups[1].Value
$invalid  = [regex]::Match($output, '(\d+)\s+chemin\(s\) invalide').Groups[1].Value
$missing  = [regex]::Match($output, '(\d+)\s+fichier\(s\) absent').Groups[1].Value

if ([string]::IsNullOrEmpty($exported)) { Fail 'résumé d''export illisible' }
Step "résumé : $exported exportées / $valid valides / $invalid invalides / $missing absentes"

if ($invalid -ne '0') { Fail "$invalid chemin(s) invalide(s) — index de production suspect" }
if ($missing -ne '0') { Fail "$missing fichier(s) absent(s) — index de production suspect" }
if ($exported -ne $valid) { Fail 'incohérence entre pistes exportées et fichiers valides' }

$newIndex = Get-Content $IndexPath -Raw | ConvertFrom-Json
if ($newIndex.version -ne 1) { Fail "version d'index inattendue : $($newIndex.version)" }
$entryCount = ($newIndex.entries.PSObject.Properties | Measure-Object).Count
if ($entryCount -ne [int]$exported) { Fail 'nombre d''entrées incohérent avec le résumé' }
Step "index écrit : version 1, $entryCount entrées, généré le $($newIndex.generatedAt)"

if ($previousGeneratedAt -and $newIndex.generatedAt -eq $previousGeneratedAt) {
    Fail 'l''horodatage de génération n''a pas changé — écriture douteuse'
}

# --- 5. Rechargement à chaud, sans redémarrage ------------------------------
$service = Get-Service -Name 'HomeSpotifyStorageAgent' -ErrorAction SilentlyContinue
if ($null -eq $service -or $service.Status -ne 'Running') {
    Step 'service HomeSpotifyStorageAgent non démarré — rechargement non vérifiable'
    Step 'index de production à jour ; il sera chargé au prochain démarrage'
    exit 0
}

$logFile = Join-Path $LogDir 'HomeSpotifyStorageAgent.out.log'
if (-not (Test-Path $logFile)) { Fail 'journal de l''agent introuvable — rechargement non vérifiable' }

Step "attente du rechargement à chaud (max $ReloadTimeoutSeconds s, aucun redémarrage)"
$deadline = (Get-Date).AddSeconds($ReloadTimeoutSeconds)
$reloaded = $false
while ((Get-Date) -lt $deadline) {
    $tail = Get-Content $logFile -Tail 200 -ErrorAction SilentlyContinue
    foreach ($line in $tail) {
        if ($line -match 'STORAGE_AGENT_INDEX_LOADED' -and $line -match [regex]::Escape($newIndex.generatedAt)) {
            $reloaded = $true
            break
        }
        if ($line -match 'STORAGE_AGENT_INDEX_REJECTED') {
            Fail 'l''agent a REJETÉ le nouvel index — l''index précédent reste en place, voir le journal'
        }
    }
    if ($reloaded) { break }
    Start-Sleep -Seconds 2
}

if (-not $reloaded) {
    Fail "l'agent n'a pas rechargé l'index en $ReloadTimeoutSeconds s — ne PAS redémarrer à l'aveugle, consulter le journal"
}

Step 'agent : nouvel index rechargé à chaud, aucun redémarrage effectué'
exit 0
