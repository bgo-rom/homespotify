[CmdletBinding()]
param(
    [string]$ServiceDirectory = 'F:\dev\homespotify\infra\windows-service\homespotify-api'
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$outputDirectory = Join-Path $projectRoot 'diagnostics\backend'
$resolvedServiceDirectory = (Resolve-Path -LiteralPath $ServiceDirectory).Path
$logsDirectory = Join-Path $resolvedServiceDirectory 'logs'
if (-not (Test-Path -LiteralPath $logsDirectory -PathType Container)) {
    throw "Répertoire de logs introuvable: $logsDirectory"
}

$sourceLogs = @(
    Join-Path $logsDirectory 'HomeSpotifyApi.out.log'
    Join-Path $logsDirectory 'HomeSpotifyApi.err.log'
    Join-Path $logsDirectory 'HomeSpotifyApi.wrapper.log'
) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }
if ($sourceLogs.Count -eq 0) { throw 'Aucun log du service HomeSpotifyApi trouvé.' }

New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$capturePath = Join-Path $outputDirectory "backend-audio-$timestamp.log"
$important = [regex]'STREAM_|requestId|\b401\b|\b403\b|\b416\b|Range|timeout|ECONNRESET|aborted|restart|stopped|started|fatal|error'
$bearer = [regex]'(?i)Bearer\s+[A-Za-z0-9._~+\-/]+=*'
$sensitiveUrl = [regex]'(?i)(https?://[^\s?"<>]+)\?[^\s"<>]+'
$windowsPath = [regex]'[A-Za-z]:\\[^\s"<>]+'

$writer = [System.IO.StreamWriter]::new($capturePath, $false, [System.Text.UTF8Encoding]::new($false))
$writer.AutoFlush = $true
try {
    $service = Get-Service -Name 'HomeSpotifyApi' -ErrorAction SilentlyContinue
    $writer.WriteLine("capturedAtUtc=$([DateTime]::UtcNow.ToString('o')) serviceStatus=$($service.Status)")
    Write-Host "Capture backend active: $capturePath"
    Write-Host 'Arrêt propre: Ctrl+C'
    Get-Content -LiteralPath $sourceLogs -Tail 200 -Wait -Encoding utf8 |
        ForEach-Object {
            $line = [string]$_
            if (-not $important.IsMatch($line)) { return }
            $safe = $bearer.Replace($line, 'Bearer [redacted]')
            $safe = $sensitiveUrl.Replace($safe, '$1?[redacted]')
            $safe = $windowsPath.Replace($safe, '[path-redacted]')
            $writer.WriteLine($safe)
            Write-Host $safe
        }
} finally {
    $writer.Flush()
    $writer.Dispose()
    Write-Host "Capture enregistrée: $capturePath"
}
