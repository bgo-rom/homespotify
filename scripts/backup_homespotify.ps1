[CmdletBinding()]
param(
    [string]$BackupRoot,
    [switch]$IncludeMedia
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$OutputEncoding = [Console]::OutputEncoding

$repositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$apiDirectory = Join-Path $repositoryRoot 'services\api'
if ([string]::IsNullOrWhiteSpace($BackupRoot)) {
    $BackupRoot = Join-Path $repositoryRoot 'backups\server'
}
$resolvedBackupRoot = [System.IO.Path]::GetFullPath($BackupRoot)
if ($resolvedBackupRoot -eq $repositoryRoot -or $resolvedBackupRoot -eq $apiDirectory) {
    throw 'Le répertoire de sauvegarde doit être un sous-répertoire dédié ou un disque externe.'
}

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$destination = Join-Path $resolvedBackupRoot "homespotify-$timestamp"
New-Item -ItemType Directory -Path $resolvedBackupRoot -Force | Out-Null

Push-Location $apiDirectory
try {
    $arguments = @(
        'run',
        'backup',
        '--',
        '--destination',
        $destination
    )
    if ($IncludeMedia) { $arguments += '--include-media' }
    & pnpm.cmd @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "La sauvegarde a échoué avec le code $LASTEXITCODE."
    }
}
finally {
    Pop-Location
}

$manifestPath = Join-Path $destination 'manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw 'La sauvegarde ne contient pas de manifest vérifiable.'
}
$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding utf8 | ConvertFrom-Json
Write-Output "Sauvegarde vérifiée : $destination"
Write-Output "Base SQLite : $($manifest.database.bytes) octets"
Write-Output "Pochettes : $($manifest.covers.included)"
Write-Output "Fichiers audio : $($manifest.media.included)"
