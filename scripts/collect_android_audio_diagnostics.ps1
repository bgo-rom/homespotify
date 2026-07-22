[CmdletBinding()]
param(
    [string]$AdbPath,
    [switch]$ClearLogcat
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$outputDirectory = Join-Path $projectRoot 'diagnostics\android'
$knownAdbPaths = @(
    $AdbPath,
    'F:\Android\Sdk\platform-tools\adb.exe',
    $(if ($env:ANDROID_HOME) { Join-Path $env:ANDROID_HOME 'platform-tools\adb.exe' }),
    $(if ($env:ANDROID_SDK_ROOT) { Join-Path $env:ANDROID_SDK_ROOT 'platform-tools\adb.exe' }),
    $(if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe' })
) | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) }

if ($knownAdbPaths.Count -eq 0) {
    throw 'adb.exe introuvable. Utilisez -AdbPath ou installez Android platform-tools.'
}
$resolvedAdb = (Resolve-Path -LiteralPath $knownAdbPaths[0]).Path

$devices = & $resolvedAdb devices
$connected = @(
    $devices | Where-Object { $_ -match '^([^\s]+)\s+device$' } | ForEach-Object {
        ($_ -split '\s+')[0]
    }
)
if ($connected.Count -ne 1) {
    throw "Un téléphone Android exactement doit être connecté (détectés: $($connected.Count))."
}
$serial = $connected[0]

New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$capturePath = Join-Path $outputDirectory "android-audio-$timestamp.log"
$devicePath = Join-Path $outputDirectory "android-device-$timestamp.txt"

if ($ClearLogcat) {
    & $resolvedAdb -s $serial logcat -c
    if ($LASTEXITCODE -ne 0) { throw 'Impossible de vider logcat.' }
}

@(
    "capturedAtUtc=$([DateTime]::UtcNow.ToString('o'))"
    "serial=$serial"
    "adb=$resolvedAdb"
    (& $resolvedAdb -s $serial shell getprop ro.build.version.release)
    (& $resolvedAdb -s $serial shell getprop ro.build.version.sdk)
    (& $resolvedAdb -s $serial shell dumpsys deviceidle whitelist)
    (& $resolvedAdb -s $serial shell dumpsys connectivity)
) | Set-Content -LiteralPath $devicePath -Encoding utf8

$important = [regex]'HomeSpotify|\[AUDIO\]|AudioPlayer|ExoPlayer|Media3|AndroidRuntime|FATAL EXCEPTION|ANR in |ActivityManager|ConnectivityService|NetworkMonitor|MediaCodec|AudioTrack|AudioFlinger|SocketTimeout|UnknownHost|SSL|HTTP|Response code'
$bearer = [regex]'(?i)Bearer\s+[A-Za-z0-9._~+\-/]+=*'
$sensitiveUrl = [regex]'(?i)(https?://[^\s?"<>]+)\?[^\s"<>]+'

$writer = [System.IO.StreamWriter]::new($capturePath, $false, [System.Text.UTF8Encoding]::new($false))
$writer.AutoFlush = $false
$lineCount = 0
try {
    Write-Host "Capture Android active: $capturePath"
    Write-Host 'Arrêt propre: Ctrl+C'
    & $resolvedAdb -s $serial logcat -b main -b system -b crash -v threadtime '*:V' 2>&1 |
        ForEach-Object {
            $line = [string]$_
            if (-not $important.IsMatch($line)) { return }
            $safe = $bearer.Replace($line, 'Bearer [redacted]')
            $safe = $sensitiveUrl.Replace($safe, '$1?[redacted]')
            $writer.WriteLine($safe)
            $lineCount += 1
            if (($lineCount % 50) -eq 0) { $writer.Flush() }
            Write-Host $safe
        }
} finally {
    $writer.Flush()
    $writer.Dispose()
    Write-Host "Capture enregistrée: $capturePath"
}

