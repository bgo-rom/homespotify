[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$BackupPath,

    [Parameter(Mandatory = $true)]
    [ValidateSet('RESTORE')]
    [string]$Confirm,

    [string]$ServiceName = 'HomeSpotifyApi',
    [switch]$RestoreMedia
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$OutputEncoding = [Console]::OutputEncoding

$repositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$apiDirectory = Join-Path $repositoryRoot 'services\api'
$resolvedBackup = [System.IO.Path]::GetFullPath($BackupPath)
$manifestPath = Join-Path $resolvedBackup 'manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "Manifest introuvable : $manifestPath"
}

$service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($null -ne $service -and $service.Status -ne 'Stopped') {
    throw "Le service $ServiceName doit être arrêté avant la restauration. État actuel : $($service.Status)."
}

Push-Location $apiDirectory
try {
    $arguments = @(
        'run',
        'restore',
        '--',
        '--backup',
        $resolvedBackup,
        '--confirm',
        $Confirm
    )
    if ($RestoreMedia) { $arguments += '--restore-media' }
    & pnpm.cmd @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "La restauration a échoué avec le code $LASTEXITCODE."
    }
}
finally {
    Pop-Location
}

Write-Output 'Restauration vérifiée. Une copie .pre-restore de la base précédente a été conservée.'
Write-Output "Redémarrez ensuite le service : Start-Service -Name $ServiceName"
