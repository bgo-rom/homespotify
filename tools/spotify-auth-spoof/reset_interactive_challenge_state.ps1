[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$service = Get-Service -Name 'HomeSpotifyApi' -ErrorAction SilentlyContinue
if ($null -eq $service) {
    throw 'Le service HomeSpotifyApi est introuvable.'
}
if ($service.Status -ne [System.ServiceProcess.ServiceControllerStatus]::Stopped) {
    throw 'Le service HomeSpotifyApi doit être arrêté avant cette maintenance.'
}

$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$apiRoot = Join-Path $projectRoot 'services\api'
$envPath = Join-Path $apiRoot '.env'
$databaseValue = './data/homespotify.db'
if (Test-Path -LiteralPath $envPath -PathType Leaf) {
    foreach ($line in Get-Content -LiteralPath $envPath -Encoding UTF8) {
        if ($line -match '^\s*DB_PATH\s*=\s*(.*)\s*$') {
            $databaseValue = $Matches[1].Trim().Trim('"').Trim("'")
            break
        }
    }
}
if ([IO.Path]::IsPathRooted($databaseValue)) {
    $databasePath = [IO.Path]::GetFullPath($databaseValue)
}
else {
    $databasePath = [IO.Path]::GetFullPath((Join-Path $apiRoot $databaseValue))
}
if (-not (Test-Path -LiteralPath $databasePath -PathType Leaf)) {
    throw 'La base HomeSpotify configurée est introuvable.'
}

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backupPath = "$databasePath.pre-interactive-reset-$timestamp.bak"
Copy-Item -LiteralPath $databasePath -Destination $backupPath -ErrorAction Stop
Write-Host "Sauvegarde créée : $backupPath"

Push-Location $apiRoot
try {
    pnpm run db:migrate
    if ($LASTEXITCODE -ne 0) {
        throw 'La migration du schéma a échoué.'
    }
    $output = pnpm exec tsx `
        src/scripts/reset-interactive-challenge-state-cli.ts `
        --db-path $databasePath
    if ($LASTEXITCODE -ne 0) {
        throw 'La conversion transactionnelle a échoué.'
    }
    $result = ($output | Select-Object -Last 1) | ConvertFrom-Json
    Write-Host "États fournisseur convertis : $($result.providerStatesConverted)"
    Write-Host "Jobs convertis : $($result.jobsConverted)"
}
finally {
    Pop-Location
}
