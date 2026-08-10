<#
.SYNOPSIS
  Construit, vérifie et publie une mise à jour Android HomeSpotify.

.DESCRIPTION
  Chaîne officielle du projet (cf. docs/ANDROID_SELF_UPDATE.md) :

    flutter pub get → flutter analyze → flutter test → versionCode suivant
    → build APK release → lecture des métadonnées réelles de l'APK
    → contrôle du paquet et du CERTIFICAT → SHA-256 → publication atomique VPS
    → vérification distante

  FAIL-CLOSED. Une seule étape en échec et `latest.json` n'est PAS modifié :
  le téléphone continue de voir la version précédente, ce qui est toujours un
  état sain.

  BUILD et PUBLISH sont distincts : `-BuildOnly` produit et vérifie une APK
  sans rien publier. Le versionCode reste réservé (journal local), donc deux
  builds successives ne peuvent jamais partager le même numéro.

.PARAMETER ReleaseNotes
  Notes de version affichées dans l'application. Une entrée par ligne.

.EXAMPLE
  ./scripts/publish_android_update.ps1 -ReleaseNotes 'Recherche Deezer','Corrections du lecteur'
#>
[CmdletBinding()]
param(
    [string[]] $ReleaseNotes = @(),
    [string]   $VersionName,
    [int]      $VersionCode = 0,
    [switch]   $Required,
    [int]      $MinSupportedVersionCode = 1,
    [switch]   $BuildOnly,
    [switch]   $AllowDirty,
    [string]   $RepoRoot,
    [string]   $VpsHost = 'debian@135.125.101.79',
    [string]   $PublicBaseUrl = 'https://music.romainbegot.fr',
    [string]   $ApiBaseUrl = 'https://music.romainbegot.fr',
    [string]   $RemoteRoot = '/var/lib/homespotify-shadow/mobile-updates/android',
    [string]   $KeyPropertiesPath,
    [string]   $StatePath,
    [string]   $ExpectedPackageName = 'com.homespotify.homespotify_mobile',
    [string]   $ExpectedCertSha256 = '9d461189865d0d1f3774ae06a4bbf84f13c890c471b3e8d2082887006a5a78d6',
    [string]   $JdkHome,
    [string]   $AndroidSdkRoot = 'F:\Android\Sdk'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Step([string] $Message) { Write-Host "[android-update] $Message" }
function Fail([string] $Message) { throw "ANDROID_UPDATE_ABORT: $Message" }

function Invoke-Checked {
    param([string] $Label, [scriptblock] $Action)
    & $Action
    if ($LASTEXITCODE -ne 0) { Fail "$Label a échoué (code $LASTEXITCODE)" }
}

# --- 1. Racine du dépôt et arborescence ------------------------------------
if (-not $RepoRoot) {
    $RepoRoot = (git rev-parse --show-toplevel 2>$null)
    if (-not $RepoRoot) { Fail 'racine du dépôt introuvable (lancer depuis un worktree Git)' }
    $RepoRoot = $RepoRoot.Trim().Replace('/', '\')
}
$FlutterRoot = Join-Path $RepoRoot 'apps\mobile\homespotify_mobile'
if (-not (Test-Path -LiteralPath $FlutterRoot -PathType Container)) {
    Fail "module Flutter introuvable : $FlutterRoot"
}
Step "dépôt   : $RepoRoot"

# --- 2. Secrets de signature et journal local ------------------------------
# Le keystore et le journal des versions vivent HORS de tout arbre Git : on
# remonte depuis la racine du dépôt jusqu'à trouver `homespotify-secrets`.
function Resolve-SecretsDir {
    $current = Get-Item -LiteralPath $RepoRoot
    while ($null -ne $current) {
        $candidate = Join-Path $current.FullName 'homespotify-secrets\android'
        if (Test-Path -LiteralPath $candidate -PathType Container) { return $candidate }
        $sibling = Join-Path (Split-Path $current.FullName -Parent) 'homespotify-secrets\android'
        if ($sibling -and (Test-Path -LiteralPath $sibling -PathType Container)) { return $sibling }
        $current = $current.Parent
    }
    return $null
}
$secretsDir = Resolve-SecretsDir
if (-not $KeyPropertiesPath) {
    if (-not $secretsDir) { Fail 'dossier homespotify-secrets\android introuvable (cf. docs/ANDROID_SELF_UPDATE.md)' }
    $KeyPropertiesPath = Join-Path $secretsDir 'key.properties'
}
if (-not (Test-Path -LiteralPath $KeyPropertiesPath -PathType Leaf)) {
    Fail "key.properties introuvable : $KeyPropertiesPath"
}
if (-not $StatePath) {
    $StatePath = Join-Path (Split-Path $KeyPropertiesPath -Parent) 'publish-state.json'
}

# --- 3. Outils --------------------------------------------------------------
if (-not $JdkHome) {
    $JdkHome = @('C:\Program Files\Java\jdk-21', 'C:\Program Files\Java\jdk-17') |
        Where-Object { Test-Path -LiteralPath $_ -PathType Container } |
        Select-Object -First 1
}
if (-not $JdkHome) { Fail 'aucun JDK 17+ trouvé (paramètre -JdkHome)' }

$buildTools = Get-ChildItem -LiteralPath (Join-Path $AndroidSdkRoot 'build-tools') -Directory -ErrorAction SilentlyContinue |
    Sort-Object { [version]($_.Name -replace '[^\d.]', '') } -Descending |
    Select-Object -First 1
if (-not $buildTools) { Fail "build-tools Android introuvables sous $AndroidSdkRoot" }
$aapt2 = Join-Path $buildTools.FullName 'aapt2.exe'
$apksigner = Join-Path $buildTools.FullName 'apksigner.bat'
foreach ($tool in @($aapt2, $apksigner)) {
    if (-not (Test-Path -LiteralPath $tool -PathType Leaf)) { Fail "outil manquant : $tool" }
}
Step "outils  : JDK=$JdkHome build-tools=$($buildTools.Name)"

$env:JAVA_HOME = $JdkHome
$env:HOMESPOTIFY_ANDROID_KEY_PROPERTIES = $KeyPropertiesPath

# --- 4. État Git ------------------------------------------------------------
$gitStatus = @(git -C $RepoRoot status --porcelain)
$gitCommit = (git -C $RepoRoot rev-parse HEAD).Trim()
$gitBranch = (git -C $RepoRoot branch --show-current).Trim()
if ($gitStatus.Count -gt 0 -and -not $AllowDirty) {
    Fail "worktree non propre ($($gitStatus.Count) entrées) — committer d'abord, ou -AllowDirty"
}
Step "git     : $gitBranch @ $($gitCommit.Substring(0,8))$(if ($gitStatus.Count -gt 0) { ' (SALE)' })"

# --- 5. Qualité : analyse et tests ------------------------------------------
Push-Location $FlutterRoot
try {
    Step 'flutter pub get'
    Invoke-Checked 'flutter pub get' { flutter pub get | Out-Null }

    Step 'flutter analyze'
    $analyze = @(flutter analyze --no-fatal-infos 2>&1)
    if ($LASTEXITCODE -ne 0) {
        $analyze | ForEach-Object { Write-Host $_ }
        Fail 'flutter analyze a signalé des avertissements ou des erreurs'
    }

    Step 'flutter test'
    Invoke-Checked 'flutter test' { flutter test }
}
finally { Pop-Location }

# --- 6. versionCode suivant -------------------------------------------------
# Source de vérité PRÉFÉRÉE : le manifeste réellement publié. Le journal local
# ne sert qu'à ne jamais réutiliser un numéro déjà construit localement.
$publishedVersionCode = 0
$publishedProbe = "$PublicBaseUrl/api/app-update/android/latest"
try {
    $published = Invoke-RestMethod -Uri $publishedProbe -TimeoutSec 20
    if ($published.latest) { $publishedVersionCode = [int] $published.latest.versionCode }
}
catch {
    Step "avertissement : manifeste publié illisible ($($_.Exception.Message))"
}

$reservedVersionCode = 0
if (Test-Path -LiteralPath $StatePath -PathType Leaf) {
    $state = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
    if ($state.PSObject.Properties.Name -contains 'lastBuiltVersionCode') {
        $reservedVersionCode = [int] $state.lastBuiltVersionCode
    }
}

$floor = [Math]::Max($publishedVersionCode, $reservedVersionCode)
if ($VersionCode -eq 0) { $VersionCode = $floor + 1 }
if ($VersionCode -le $publishedVersionCode) {
    Fail "versionCode $VersionCode <= version publiée $publishedVersionCode (Android refuserait la mise à jour)"
}
if ($VersionCode -le $reservedVersionCode) {
    Fail "versionCode $VersionCode déjà construit localement ($reservedVersionCode)"
}

if (-not $VersionName) {
    $pubspec = Get-Content -LiteralPath (Join-Path $FlutterRoot 'pubspec.yaml')
    $versionLine = $pubspec | Where-Object { $_ -match '^version:\s*(.+)$' } | Select-Object -First 1
    if (-not $versionLine) { Fail 'version absente de pubspec.yaml' }
    $VersionName = ($versionLine -replace '^version:\s*', '').Split('+')[0].Trim()
}
if ($MinSupportedVersionCode -gt $VersionCode) {
    Fail "minSupportedVersionCode ($MinSupportedVersionCode) > versionCode ($VersionCode)"
}
Step "version : $VersionName ($VersionCode) — publiée=$publishedVersionCode réservée=$reservedVersionCode"

# --- 7. Build release -------------------------------------------------------
Push-Location $FlutterRoot
try {
    Step 'flutter build apk --release'
    Invoke-Checked 'flutter build apk' {
        flutter build apk --release `
            --build-name=$VersionName `
            --build-number=$VersionCode `
            --dart-define=HOMESPOTIFY_API_BASE_URL=$ApiBaseUrl
    }
}
finally { Pop-Location }

$apkPath = Join-Path $FlutterRoot 'build\app\outputs\flutter-apk\app-release.apk'
if (-not (Test-Path -LiteralPath $apkPath -PathType Leaf)) { Fail "APK introuvable : $apkPath" }

# Le numéro est réservé DÈS que l'APK existe : même sans publication, il ne
# sera jamais réutilisé pour une autre build.
$newState = [ordered]@{
    lastBuiltVersionCode = $VersionCode
    lastBuiltAt          = (Get-Date).ToUniversalTime().ToString('o')
    lastBuiltCommit      = $gitCommit
}
$newState | ConvertTo-Json | Set-Content -LiteralPath $StatePath -Encoding utf8

# --- 8. Contrôle de l'APK produite -----------------------------------------
Step 'lecture des métadonnées réelles de l’APK'
$badging = & $aapt2 dump badging $apkPath 2>&1
if ($LASTEXITCODE -ne 0) { Fail 'aapt2 n’a pas pu lire l’APK' }
$packageLine = $badging | Where-Object { $_ -like 'package:*' } | Select-Object -First 1
if ($packageLine -notmatch "name='([^']+)'\s+versionCode='(\d+)'\s+versionName='([^']*)'") {
    Fail 'ligne package illisible dans aapt2 badging'
}
$apkPackage = $Matches[1]
$apkVersionCode = [int] $Matches[2]
$apkVersionName = $Matches[3]

if ($apkPackage -ne $ExpectedPackageName) { Fail "packageName inattendu : $apkPackage" }
if ($apkVersionCode -ne $VersionCode) { Fail "versionCode de l’APK ($apkVersionCode) != demandé ($VersionCode)" }
if ($apkVersionName -ne $VersionName) { Fail "versionName de l’APK ($apkVersionName) != demandé ($VersionName)" }

Step 'contrôle du certificat de signature'
$certs = & $apksigner verify --print-certs -v $apkPath 2>&1
if ($LASTEXITCODE -ne 0) {
    $certs | ForEach-Object { Write-Host $_ }
    Fail 'apksigner refuse l’APK'
}
$certLine = $certs | Where-Object { $_ -match 'Signer #1 certificate SHA-256 digest:\s*([0-9a-fA-F]{64})' } | Select-Object -First 1
if (-not $certLine) { Fail 'empreinte de certificat introuvable' }
$null = $certLine -match 'Signer #1 certificate SHA-256 digest:\s*([0-9a-fA-F]{64})'
$apkCert = $Matches[1].ToLowerInvariant()
if ($apkCert -ne $ExpectedCertSha256.ToLowerInvariant()) {
    Fail "CERTIFICAT INATTENDU ($apkCert). Android refuserait la mise à jour par-dessus l’application installée."
}

$apkItem = Get-Item -LiteralPath $apkPath
$apkSha256 = (Get-FileHash -LiteralPath $apkPath -Algorithm SHA256).Hash.ToLowerInvariant()
Step "APK     : $($apkItem.Length) octets · sha256=$($apkSha256.Substring(0,12))… · cert OK"

# --- 9. Manifeste -----------------------------------------------------------
$notes = @($ReleaseNotes | Where-Object { $_ -and $_.Trim().Length -gt 0 } | ForEach-Object { $_.Trim() })
$manifest = [ordered]@{
    platform                = 'android'
    packageName             = $apkPackage
    versionCode             = $apkVersionCode
    versionName             = $apkVersionName
    required                = [bool] $Required
    minSupportedVersionCode = $MinSupportedVersionCode
    sizeBytes               = [int] $apkItem.Length
    sha256                  = $apkSha256
    signingCertSha256       = $apkCert
    releaseNotes            = $notes
    publishedAt             = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    sourceCommit            = $gitCommit
}
$stagingDir = Join-Path $FlutterRoot 'build\android-update'
New-Item -ItemType Directory -Force -Path $stagingDir | Out-Null
$manifestPath = Join-Path $stagingDir "$VersionCode.json"
# JSON en UTF-8 SANS BOM : le serveur le relit tel quel.
[System.IO.File]::WriteAllText(
    $manifestPath,
    ($manifest | ConvertTo-Json -Depth 4),
    (New-Object System.Text.UTF8Encoding($false))
)

if ($BuildOnly) {
    Step 'BuildOnly : rien n’est publié.'
    [pscustomobject]@{
        published   = $false
        apkPath     = $apkPath
        versionCode = $apkVersionCode
        versionName = $apkVersionName
        sizeBytes   = $apkItem.Length
        sha256      = $apkSha256
        certSha256  = $apkCert
        manifest    = $manifestPath
    } | Format-List
    return
}

# --- 10. Publication atomique sur le VPS ------------------------------------
$remoteStage = "/tmp/homespotify-update-$VersionCode"
$publisher = Join-Path $RepoRoot 'scripts\android-update\vps_publish_android_update.sh'
if (-not (Test-Path -LiteralPath $publisher -PathType Leaf)) { Fail "script serveur introuvable : $publisher" }

Step "transfert vers $VpsHost"
Invoke-Checked 'ssh mkdir' { ssh -o BatchMode=yes $VpsHost "rm -rf $remoteStage && mkdir -p $remoteStage" }
Invoke-Checked 'scp apk' { scp -o BatchMode=yes -q $apkPath "${VpsHost}:$remoteStage/app.apk" }
Invoke-Checked 'scp manifest' { scp -o BatchMode=yes -q $manifestPath "${VpsHost}:$remoteStage/manifest.json" }
Invoke-Checked 'scp publisher' { scp -o BatchMode=yes -q $publisher "${VpsHost}:$remoteStage/publish.sh" }

Step 'publication atomique côté serveur'
$publishOutput = ssh -o BatchMode=yes $VpsHost "sudo -n bash $remoteStage/publish.sh $remoteStage/app.apk $remoteStage/manifest.json $RemoteRoot"
if ($LASTEXITCODE -ne 0) {
    $publishOutput | ForEach-Object { Write-Host $_ }
    Fail 'publication serveur refusée — latest.json inchangé'
}
ssh -o BatchMode=yes $VpsHost "rm -rf $remoteStage" | Out-Null

# --- 11. Vérification distante, en lecture seule ----------------------------
Step 'vérification du manifeste publié'
$check = Invoke-RestMethod -Uri "$PublicBaseUrl/api/app-update/android/latest?currentVersionCode=1" -TimeoutSec 30
if (-not $check.latest) { Fail 'le serveur ne publie aucun manifeste après publication' }
if ([int] $check.latest.versionCode -ne $VersionCode) {
    Fail "manifeste publié incohérent : $($check.latest.versionCode) != $VersionCode"
}
if ($check.latest.sha256 -ne $apkSha256) { Fail 'sha256 publié incohérent' }
if ([int] $check.latest.sizeBytes -ne $apkItem.Length) { Fail 'taille publiée incohérente' }
if (-not $check.updateAvailable) { Fail 'updateAvailable=false pour un client en version 1' }

Step 'vérification du téléchargement (1 Ko, lecture seule)'
$probe = Invoke-WebRequest -Uri "$PublicBaseUrl$($check.latest.downloadPath)" -Headers @{ Range = 'bytes=0-1023' } -TimeoutSec 30
if ($probe.StatusCode -ne 206) { Fail "téléchargement partiel refusé (HTTP $($probe.StatusCode))" }
if ($probe.Headers['Content-Type'] -notlike 'application/vnd.android.package-archive*') {
    Fail "Content-Type inattendu : $($probe.Headers['Content-Type'])"
}

Step 'PUBLIÉ.'
[pscustomobject]@{
    published    = $true
    versionCode  = $apkVersionCode
    versionName  = $apkVersionName
    required     = [bool] $Required
    sizeBytes    = $apkItem.Length
    sha256       = $apkSha256
    certSha256   = $apkCert
    releaseNotes = ($notes -join ' | ')
    downloadUrl  = "$PublicBaseUrl$($check.latest.downloadPath)"
    sourceCommit = $gitCommit
    apkPath      = $apkPath
} | Format-List
