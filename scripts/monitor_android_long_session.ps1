param(
    [Parameter(Mandatory = $true)]
    [string]$AdbPath,

    [Parameter(Mandatory = $true)]
    [string]$Serial,

    [ValidateRange(1, 1440)]
    [int]$DurationMinutes = 240,

    [ValidateRange(15, 300)]
    [int]$CheckpointSeconds = 60,

    [string]$OutputDirectory,

    [switch]$SimulateUnplugged,

    [switch]$PutDeviceToSleep,

    [switch]$ExerciseNetworkTransitions,

    [switch]$PauseAtEnd
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$projectRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $OutputDirectory = Join-Path $projectRoot "logs\long-session\$stamp"
}
$resolvedProjectRoot = [System.IO.Path]::GetFullPath($projectRoot)
$resolvedOutput = [System.IO.Path]::GetFullPath($OutputDirectory)
if (-not $resolvedOutput.StartsWith($resolvedProjectRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'Le dossier de sortie doit rester dans le projet HomeSpotify.'
}
if (-not (Test-Path -LiteralPath $AdbPath -PathType Leaf)) {
    throw "adb introuvable : $AdbPath"
}

New-Item -ItemType Directory -Force -Path $resolvedOutput | Out-Null
$checkpointPath = Join-Path $resolvedOutput 'checkpoints.jsonl'
$incidentPath = Join-Path $resolvedOutput 'incidents.jsonl'
$summaryPath = Join-Path $resolvedOutput 'summary.json'
$logcatPath = Join-Path $resolvedOutput 'android-logcat.txt'
$backendLogPath = Join-Path $projectRoot 'infra\windows-service\homespotify-api\logs\HomeSpotifyApi.out.log'
$backendTailPath = Join-Path $resolvedOutput 'backend-tail.txt'

function Invoke-Adb {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
    $output = & $AdbPath -s $Serial @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "adb a échoué ($LASTEXITCODE) : $($Arguments -join ' ')"
    }
    return ($output -join "`n")
}

function Write-JsonLine {
    param([string]$Path, [hashtable]$Data)
    Add-Content -LiteralPath $Path -Value ($Data | ConvertTo-Json -Compress -Depth 5) -Encoding UTF8
}

function Read-PlaybackSnapshot {
    $media = Invoke-Adb shell dumpsys media_session
    $mediaLines = $media -split "`r?`n"
    $homeSessionStart = -1
    for ($index = 0; $index -lt $mediaLines.Count; $index++) {
        if ($mediaLines[$index] -match '^\s*media-session com\.homespotify\.homespotify_mobile/') {
            $homeSessionStart = $index
            break
        }
    }
    $homeSessionLines = if ($homeSessionStart -ge 0) {
        $collected = [System.Collections.Generic.List[string]]::new()
        for ($index = $homeSessionStart; $index -lt $mediaLines.Count; $index++) {
            $line = $mediaLines[$index]
            if ($index -gt $homeSessionStart -and
                ($line -match '^ {4}\S.*session .*\(userId=' -or $line -match '^Audio playback')) {
                break
            }
            $collected.Add($line)
        }
        $collected -join "`n"
    } else {
        ''
    }
    $states = [regex]::Matches(
        $homeSessionLines,
        'state=PlaybackState \{state=([A-Z_]+)\(\d+\), position=(\d+).*?active item id=(-?\d+)',
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
    $metadata = [regex]::Matches($homeSessionLines, 'metadata: size=\d+, description=(.+)')
    $state = if ($states.Count -gt 0) { $states[$states.Count - 1] } else { $null }
    $description = if ($metadata.Count -gt 0) { $metadata[$metadata.Count - 1].Groups[1].Value.Trim() } else { $null }
    $services = Invoke-Adb shell dumpsys activity services com.homespotify.homespotify_mobile
    $battery = Invoke-Adb shell dumpsys battery
    $connectivity = Invoke-Adb shell dumpsys connectivity
    $foreground = $services -match 'isForeground=true'
    $network = if ($connectivity -match '(?m)^\s*NetworkAgentInfo\{[^\r\n]+') {
        $Matches[0].Trim()
    } else {
        'indéterminé'
    }
    return @{
        utc = [DateTime]::UtcNow.ToString('o')
        state = if ($null -ne $state) { $state.Groups[1].Value.ToUpperInvariant() } else { 'UNKNOWN' }
        positionMs = if ($null -ne $state) { [long]$state.Groups[2].Value } else { -1 }
        activeItemId = if ($null -ne $state) { [long]$state.Groups[3].Value } else { -1 }
        description = $description
        foregroundService = $foreground
        network = $network
        batteryPlugged = if ($battery -match '(?m)^\s*plugged:\s*(\d+)') { [int]$Matches[1] } else { -1 }
    }
}

$startedAt = Get-Date
$endedAt = $startedAt.AddMinutes($DurationMinutes)
$transitions = 0
$incidents = 0
$consecutiveNonPlaying = 0
$consecutiveStalled = 0
$previous = $null
$wifiDisabled = $false
$mobileWindows = if ($ExerciseNetworkTransitions) { @(20, 120) } else { @() }
$restoredWindows = @{}

try {
    if ($SimulateUnplugged) {
        Invoke-Adb shell dumpsys battery unplug | Out-Null
    }
    if ($PutDeviceToSleep) {
        Invoke-Adb shell input keyevent KEYCODE_SLEEP | Out-Null
    }

    while ((Get-Date) -lt $endedAt) {
        $elapsedMinutes = [int][Math]::Floor(((Get-Date) - $startedAt).TotalMinutes)
        foreach ($startMinute in $mobileWindows) {
            if ($elapsedMinutes -ge $startMinute -and $elapsedMinutes -lt ($startMinute + 3) -and -not $restoredWindows.ContainsKey("off-$startMinute")) {
                Invoke-Adb shell svc wifi disable | Out-Null
                $wifiDisabled = $true
                $restoredWindows["off-$startMinute"] = $true
                Write-JsonLine $incidentPath @{
                    utc = [DateTime]::UtcNow.ToString('o')
                    kind = 'NETWORK_SWITCH'
                    detail = 'Wi-Fi désactivé, bascule cellulaire attendue.'
                }
            }
            if ($elapsedMinutes -ge ($startMinute + 3) -and -not $restoredWindows.ContainsKey("on-$startMinute")) {
                Invoke-Adb shell svc wifi enable | Out-Null
                $wifiDisabled = $false
                $restoredWindows["on-$startMinute"] = $true
                Write-JsonLine $incidentPath @{
                    utc = [DateTime]::UtcNow.ToString('o')
                    kind = 'NETWORK_SWITCH'
                    detail = 'Wi-Fi réactivé.'
                }
            }
        }

        try {
            $snapshot = Read-PlaybackSnapshot
            $snapshot.elapsedMinutes = $elapsedMinutes
            Write-JsonLine $checkpointPath $snapshot

            if ($null -ne $previous -and $snapshot.activeItemId -ne $previous.activeItemId) {
                $transitions++
            }
            if ($snapshot.state -eq 'PLAYING') {
                $consecutiveNonPlaying = 0
            } else {
                $consecutiveNonPlaying++
            }
            $advanced = $null -eq $previous -or
                $snapshot.activeItemId -ne $previous.activeItemId -or
                $snapshot.positionMs -ge ($previous.positionMs + 1000)
            if ($snapshot.state -eq 'PLAYING' -and -not $advanced) {
                $consecutiveStalled++
            } else {
                $consecutiveStalled = 0
            }
            if ($consecutiveNonPlaying -eq 3) {
                $incidents++
                Write-JsonLine $incidentPath @{
                    utc = $snapshot.utc
                    kind = 'NOT_PLAYING_3_MINUTES'
                    detail = $snapshot.description
                    state = $snapshot.state
                }
            }
            if ($consecutiveStalled -eq 3) {
                $incidents++
                Write-JsonLine $incidentPath @{
                    utc = $snapshot.utc
                    kind = 'PLAYING_POSITION_STALLED_3_MINUTES'
                    detail = $snapshot.description
                    positionMs = $snapshot.positionMs
                }
            }
            if (-not $snapshot.foregroundService) {
                $incidents++
                Write-JsonLine $incidentPath @{
                    utc = $snapshot.utc
                    kind = 'FOREGROUND_SERVICE_MISSING'
                    detail = $snapshot.description
                }
            }
            $previous = $snapshot
        } catch {
            $incidents++
            Write-JsonLine $incidentPath @{
                utc = [DateTime]::UtcNow.ToString('o')
                kind = 'CHECKPOINT_ERROR'
                detail = $_.Exception.Message
            }
        }
        Start-Sleep -Seconds $CheckpointSeconds
    }
} finally {
    if ($wifiDisabled) {
        try { Invoke-Adb shell svc wifi enable | Out-Null } catch {}
    }
    if ($SimulateUnplugged) {
        try { Invoke-Adb shell dumpsys battery reset | Out-Null } catch {}
    }
    if ($PauseAtEnd) {
        try { Invoke-Adb shell input keyevent KEYCODE_MEDIA_PAUSE | Out-Null } catch {}
    }
    try { Invoke-Adb logcat -d -v threadtime | Set-Content -LiteralPath $logcatPath -Encoding UTF8 } catch {}
    if (Test-Path -LiteralPath $backendLogPath) {
        Get-Content -LiteralPath $backendLogPath -Tail 3000 | Set-Content -LiteralPath $backendTailPath -Encoding UTF8
    }
    $finishedAt = Get-Date
    @{
        startedAt = $startedAt.ToString('o')
        finishedAt = $finishedAt.ToString('o')
        requestedMinutes = $DurationMinutes
        actualMinutes = [Math]::Round(($finishedAt - $startedAt).TotalMinutes, 2)
        transitions = $transitions
        incidents = $incidents
        finalTrack = if ($null -ne $previous) { $previous.description } else { $null }
        finalState = if ($null -ne $previous) { $previous.state } else { 'UNKNOWN' }
        simulateUnplugged = [bool]$SimulateUnplugged
        devicePutToSleep = [bool]$PutDeviceToSleep
        networkTransitionsExercised = [bool]$ExerciseNetworkTransitions
        pausedAtEnd = [bool]$PauseAtEnd
        outputDirectory = $resolvedOutput
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $summaryPath -Encoding UTF8
}
