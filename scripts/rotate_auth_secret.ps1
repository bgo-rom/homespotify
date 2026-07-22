[CmdletBinding()]
param(
    [string]$EnvPath = ''
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($EnvPath)) {
    $EnvPath = Join-Path $PSScriptRoot '..\services\api\.env'
}
$resolvedEnvPath = [System.IO.Path]::GetFullPath($EnvPath)
$projectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$projectPrefix = $projectRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
if (-not $resolvedEnvPath.StartsWith($projectPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'Le fichier .env doit rester dans le projet HomeSpotify.'
}

$bytes = New-Object byte[] 48
$random = [System.Security.Cryptography.RandomNumberGenerator]::Create()
try {
    $random.GetBytes($bytes)
} finally {
    $random.Dispose()
}
$secret = ([System.BitConverter]::ToString($bytes) -replace '-', '').ToLowerInvariant()
$lines = if ([System.IO.File]::Exists($resolvedEnvPath)) {
    [System.IO.File]::ReadAllLines($resolvedEnvPath)
} else {
    @()
}

$replaced = $false
$updated = foreach ($line in $lines) {
    if ($line -match '^\s*AUTH_TOKEN_SECRET\s*=') {
        $replaced = $true
        "AUTH_TOKEN_SECRET=$secret"
    } else {
        $line
    }
}
if (-not $replaced) {
    $updated = @($updated) + "AUTH_TOKEN_SECRET=$secret"
}

$directory = [System.IO.Path]::GetDirectoryName($resolvedEnvPath)
[System.IO.Directory]::CreateDirectory($directory) | Out-Null
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllLines($resolvedEnvPath, $updated, $utf8NoBom)

$sha256 = [System.Security.Cryptography.SHA256]::Create()
try {
    $fingerprintBytes = $sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($secret))
} finally {
    $sha256.Dispose()
}
$fingerprint = (([System.BitConverter]::ToString($fingerprintBytes) -replace '-', '').Substring(0, 12)).ToLowerInvariant()
Write-Host "Secret JWT renouvelé dans le .env gitignoré (empreinte $fingerprint)."
