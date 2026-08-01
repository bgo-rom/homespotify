<#
.SYNOPSIS
  Copie SQLite cohérente par VACUUM INTO, pour le shadow Phase 6.

.DESCRIPTION
  La source n'est JAMAIS modifiée : elle est ouverte en lecture seule et
  `VACUUM INTO` écrit une base neuve. Le chemin source n'est jamais publié en
  entier dans les journaux — seul son nom de fichier apparaît, parce qu'un
  chemin complet révèle l'organisation du disque de production.

  La destination est refusée si elle existe déjà : un fichier présent peut
  être une copie en cours d'usage, ou la trace d'un échec qu'il faut examiner.
  En cas d'échec de contrôle, la copie est supprimée — une base non validée ne
  doit jamais pouvoir être promue par erreur.

  `user_version = 0` est ATTENDU : Drizzle suit les migrations dans
  `__drizzle_migrations`, et c'est ce compteur qui fait foi.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $SourceDbPath,
    [string] $StagingRoot = 'F:\dev\homespotify-phase6-staging',
    [string] $RepoRoot = 'F:\dev\homespotify-phase6-final-c'
)

$ErrorActionPreference = 'Stop'
function Fail([string] $Message) { throw "PHASE6_SNAPSHOT: $Message" }
function Step([string] $Message) { Write-Host "[phase6-snapshot] $Message" }

if (-not (Test-Path -LiteralPath $SourceDbPath -PathType Leaf)) {
    Fail "base source introuvable : $([IO.Path]::GetFileName($SourceDbPath))"
}
# Le staging vit hors de la production et hors du dépôt applicatif.
$staging = Join-Path $StagingRoot 'sqlite'
New-Item -ItemType Directory -Force -Path $staging | Out-Null
$stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
$target = Join-Path $staging "runtime-shadow-$stamp.db"
if (Test-Path -LiteralPath $target) { Fail 'destination déjà existante' }

# better-sqlite3 Windows déjà installé localement : aucune compilation, aucun
# téléchargement. Le module natif Windows ne part JAMAIS sur le VPS.
$module = Join-Path $RepoRoot 'services\api\node_modules\better-sqlite3'
if (-not (Test-Path -LiteralPath $module)) { Fail 'better-sqlite3 local introuvable' }

Step "VACUUM INTO vers $([IO.Path]::GetFileName($target))"
$script = Join-Path $RepoRoot 'scripts\phase6\phase6_sqlite_snapshot.mjs'
$raw = & node $script $SourceDbPath $target $module 2>&1
$exit = $LASTEXITCODE
$report = $null
foreach ($line in @($raw)) {
    $text = [string]$line
    if ($text.TrimStart().StartsWith('{')) { $report = $text | ConvertFrom-Json }
}
if ($null -eq $report) { Fail "sortie illisible : $raw" }
if ($exit -ne 0 -or -not $report.ok) {
    Fail ("contrôles échoués : {0} (copie supprimée : {1})" -f $report.error, $report.targetRemoved)
}

Step ("integrity={0} fkViolations={1} migrations={2} tables={3}" -f `
    $report.integrityCheck, $report.foreignKeyViolations, $report.drizzleMigrations, $report.tableCount)
Step ("user_version={0} (0 attendu : la version est suivie par __drizzle_migrations)" -f $report.sourceUserVersion)
Step ("source inchangée : {0}" -f $report.sourceUnchanged)

Write-Output (ConvertTo-Json -Compress @{
    ok = $true
    snapshotPath = $target
    sizeBytes = $report.targetSizeBytes
    sha256 = $report.targetSha256
    integrityCheck = $report.integrityCheck
    foreignKeyViolations = $report.foreignKeyViolations
    drizzleMigrations = $report.drizzleMigrations
    userVersion = $report.sourceUserVersion
    userVersionExpectedZero = $report.userVersionExpectedZero
    sourceUnchanged = $report.sourceUnchanged
})
