[CmdletBinding()]
param(
    [string] $VpsHost = '135.125.101.79',
    [string] $VpsUser = 'debian',
    [Parameter(Mandatory = $true)]
    [string] $SshKeyPath,
    [ValidateRange(120, 10080)]
    [int] $DurationMinutes = 120,
    [ValidateRange(10, 3600)]
    [int] $SampleIntervalSeconds = 60,
    [ValidateRange(1, 1440)]
    [int] $LoadIntervalMinutes = 5,
    [ValidateRange(1, 1440)]
    [int] $FullGetIntervalMinutes = 30,
    [Parameter(Mandatory = $true)]
    [string] $OutputDirectory,
    [switch] $ValidateOnly,
    [switch] $SelfTest,
    [ValidateSet('Healthy', 'PublicListener', 'PidChanged', 'Restarted', 'Interrupted')]
    [string] $SelfTestScenario = 'Healthy'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ExpectedReleaseId = '20260728T185714Z-88a6d12f-f09a54cf'
$ExpectedTrackId = 119
$ExpectedTrackSize = 18619182
$ExpectedTrackSha256 = 'b953fbe920f69b9e9b36ef2fe72ede2d863cd5e1868e501d740411e181d174a4'
$QualifiedCaddySha256Prefix = 'a3b4ca2b441f311a9970'
$PublicHealthUrl = 'https://music.romainbegot.fr/health'
$ServiceName = 'homespotify-api-shadow.service'
$script:StartedAtUtc = $null
$script:EndedAtUtc = $null
$script:Verdict = 'INCOMPLETE_RESTART_REQUIRED'
$script:FailureReason = $null
$script:RemoteHelperPath = $null
$script:RemoteTokenPath = $null
$script:SshWasUsed = $false
$script:Baseline = $null
$script:FinalState = $null
$script:Samples = [System.Collections.Generic.List[object]]::new()
$script:RequestRecords = [System.Collections.Generic.List[object]]::new()
$script:SanitizedEvents = [System.Collections.Generic.List[object]]::new()
$script:LoadCycleCount = 0
$script:RequestSuccessCount = 0
$script:RequestTotalCount = 0
$script:StorageAgentInitialStatus = $null
$script:StorageAgentFinalStatus = $null
$script:ServiceEnabledObserved = $null
$script:JournalSummary = $null

function Fail([string] $Message) {
    throw [System.InvalidOperationException]::new($Message)
}

function Get-UtcIso {
    return [DateTimeOffset]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
}

function ConvertTo-JsonLine([object] $Value) {
    return ($Value | ConvertTo-Json -Depth 20 -Compress)
}

function Get-LastJson([object[]] $Lines) {
    for ($index = $Lines.Count - 1; $index -ge 0; $index--) {
        $candidate = "$($Lines[$index])".Trim()
        if (-not $candidate.StartsWith('{')) { continue }
        try {
            return ($candidate | ConvertFrom-Json -ErrorAction Stop)
        } catch {
            continue
        }
    }
    Fail 'Remote output did not contain a readable JSON object.'
}

function Assert-LocalArguments {
    if ($DurationMinutes -lt 120) {
        Fail 'DurationMinutes must be at least 120.'
    }
    if ($LoadIntervalMinutes * 60 -lt $SampleIntervalSeconds) {
        Fail 'LoadIntervalMinutes must not be shorter than SampleIntervalSeconds.'
    }
    if ($FullGetIntervalMinutes -lt $LoadIntervalMinutes) {
        Fail 'FullGetIntervalMinutes must not be shorter than LoadIntervalMinutes.'
    }
    if ([string]::IsNullOrWhiteSpace($VpsHost) -or
        [string]::IsNullOrWhiteSpace($VpsUser) -or
        [string]::IsNullOrWhiteSpace($OutputDirectory)) {
        Fail 'VpsHost, VpsUser and OutputDirectory are required.'
    }
    if (-not $ValidateOnly -and -not $SelfTest) {
        if (-not (Test-Path -LiteralPath $SshKeyPath -PathType Leaf)) {
            Fail 'SshKeyPath does not identify an existing local file.'
        }
    }
}

function Initialize-Output {
    [void](New-Item -ItemType Directory -Force -Path $OutputDirectory)
    $script:SamplesPath = Join-Path $OutputDirectory 'samples.csv'
    $script:RequestsPath = Join-Path $OutputDirectory 'requests.jsonl'
    $script:EventsPath = Join-Path $OutputDirectory 'events-sanitized.jsonl'
    $script:SummaryPath = Join-Path $OutputDirectory 'phase64a-summary.json'
    $script:ReportPath = Join-Path $OutputDirectory 'PHASE64A_SOAK_REPORT.md'
    'timestampUtc,mainPid,activeState,subState,nRestarts,rssKiB,cpuSeconds,fileDescriptors,threads,cacheBytes,objectCount,partCount,sqliteBytes,walBytes,shmBytes,freeBytes,listenerCount,publicListenerCount,shadowHealth,publicHealth' |
        Set-Content -LiteralPath $script:SamplesPath -Encoding ascii
    [void](New-Item -ItemType File -Force -Path $script:RequestsPath)
    [void](New-Item -ItemType File -Force -Path $script:EventsPath)
}

function Get-SshBaseArguments {
    return @(
        '-o', 'BatchMode=yes',
        '-o', 'ConnectTimeout=15',
        '-o', 'ConnectionAttempts=1',
        '-o', 'ServerAliveInterval=20',
        '-o', 'ServerAliveCountMax=3',
        '-i', $SshKeyPath,
        "$VpsUser@$VpsHost"
    )
}

function Invoke-SshText {
    param(
        [Parameter(Mandatory = $true)]
        [string] $RemoteCommand,
        [string] $InputText = ''
    )
    $script:SshWasUsed = $true
    $arguments = @(Get-SshBaseArguments) + @($RemoteCommand)
    if ($InputText.Length -gt 0) {
        $output = $InputText | & ssh.exe @arguments 2>&1
    } else {
        $output = & ssh.exe @arguments 2>&1
    }
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        $safe = (($output | ForEach-Object { "$_" }) -join "`n")
        if ($safe.Length -gt 800) { $safe = $safe.Substring(0, 800) }
        Fail "SSH command failed with exit code $exitCode. $safe"
    }
    return @($output)
}

function Invoke-SshJson {
    param(
        [Parameter(Mandatory = $true)]
        [string] $RemoteCommand
    )
    return Get-LastJson @(Invoke-SshText -RemoteCommand $RemoteCommand)
}

function Install-RemoteHelper {
    $runId = [Guid]::NewGuid().ToString('N')
    $script:RemoteHelperPath = "/run/phase64a-$runId.py"
    $script:RemoteTokenPath = "/run/phase64a-$runId.token"
    $installCommand = "sudo -n install -o root -g root -m 0700 /dev/stdin '$($script:RemoteHelperPath)'"
    [void](Invoke-SshText -RemoteCommand $installCommand -InputText $script:RemoteHelperSource)
}

function New-ShadowToken {
    $command = @(
        'sudo -n node /opt/homespotify-api-shadow/tools/phase6_shadow_token.mjs',
        '/etc/homespotify/api-shadow.env',
        '/var/lib/homespotify-shadow/data/runtime.db',
        '/opt/homespotify-api-shadow/dependency-bundles/linux-x64-node22.18.0-abi127/node_modules',
        "'$($script:RemoteTokenPath)'"
    ) -join ' '
    $result = Invoke-SshJson -RemoteCommand $command
    if (-not $result.ok -or $result.tokenPrinted -ne $false -or $result.secretPrinted -ne $false) {
        Fail 'Shadow token generation did not satisfy the Phase 6.3 contract.'
    }
}

function Invoke-RemoteMode {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('preflight', 'sample', 'load', 'full', 'integrity', 'journal')]
        [string] $Mode
    )
    $since = if ($null -eq $script:StartedAtUtc) { '-' } else { $script:StartedAtUtc }
    $command = @(
        'sudo -n python3',
        "'$($script:RemoteHelperPath)'",
        '--mode', $Mode,
        '--token-file', "'$($script:RemoteTokenPath)'",
        '--since', "'$since'"
    ) -join ' '
    return Invoke-SshJson -RemoteCommand $command
}

function Get-WindowsStorageAgentStatus {
    try {
        return (Get-Service -Name 'HomeSpotifyStorageAgent' -ErrorAction Stop).Status.ToString()
    } catch {
        return 'Unavailable'
    }
}

function Assert-Preflight([object] $State) {
    $failures = [System.Collections.Generic.List[string]]::new()
    if ($State.activeState -ne 'active' -or $State.subState -ne 'running') {
        $failures.Add('shadow service is not active/running')
    }
    if ($State.serviceEnabled -ne 'disabled') { $failures.Add('service is not disabled') }
    if ([int64]$State.nRestarts -ne 0) { $failures.Add('NRestarts is not zero') }
    if ([int64]$State.listenerCount -ne 1 -or
        [int64]$State.publicListenerCount -ne 0 -or
        $State.listenerAddresses[0] -ne '127.0.0.1:3002') {
        $failures.Add('listener is not exactly 127.0.0.1:3002')
    }
    if ([int]$State.shadowHealth -ne 200) { $failures.Add('shadow health is not 200') }
    if ([int]$State.publicHealth -ne 200) { $failures.Add('public health is not 200') }
    if ($State.caddyActive -ne 'active') { $failures.Add('Caddy is not active') }
    if (-not "$($State.caddySha256)".StartsWith($QualifiedCaddySha256Prefix)) {
        $failures.Add('Caddy fingerprint differs from the qualified Phase 6.3 fingerprint')
    }
    if ($State.releaseId -ne $ExpectedReleaseId) { $failures.Add('installed release differs') }
    if ([int64]$State.partCount -ne 0) { $failures.Add('persistent .part file exists') }
    if ($State.wireguardActive -ne 'active') { $failures.Add('WireGuard is not active') }
    if (-not $State.storageAgentReachable) { $failures.Add('Storage Agent is not reachable') }
    if ([int64]$State.incomingCount -ne 0) { $failures.Add('incoming is not empty') }
    if ([int64]$State.unexpectedVariantCount -ne 0) {
        $failures.Add('unexpected offline variant exists')
    }
    if ($null -eq $State.minFreeBytes -or [int64]$State.minFreeBytes -le 0) {
        $failures.Add('AUDIO_CACHE_MIN_FREE_BYTES is absent or invalid')
    } elseif ([int64]$State.freeBytes -lt [int64]$State.minFreeBytes) {
        $failures.Add('free space is below AUDIO_CACHE_MIN_FREE_BYTES')
    }
    if ($State.sqliteIntegrity -ne 'ok' -or [int64]$State.foreignKeyViolations -ne 0) {
        $failures.Add('SQLite integrity preflight failed')
    }
    if ($State.cacheIndexIntegrity -ne 'ok') { $failures.Add('cache index integrity failed') }
    if ($State.phase63FavoritePresent) {
        $failures.Add('Phase 6.3 disposable favorite is still present')
    }
    if ($script:StorageAgentInitialStatus -ne 'Running') {
        $failures.Add('Windows Storage Agent is not Running')
    }
    if ($failures.Count -gt 0) {
        Fail ("Preflight refused: " + ($failures -join '; '))
    }
    $script:ServiceEnabledObserved = $State.serviceEnabled
}

function Add-Sample([object] $Sample) {
    $script:Samples.Add($Sample)
    $values = @(
        $Sample.timestampUtc, $Sample.mainPid, $Sample.activeState, $Sample.subState,
        $Sample.nRestarts, $Sample.rssKiB, $Sample.cpuSeconds,
        $Sample.fileDescriptors, $Sample.threads, $Sample.cacheBytes,
        $Sample.objectCount, $Sample.partCount, $Sample.sqliteBytes,
        $Sample.walBytes, $Sample.shmBytes, $Sample.freeBytes,
        $Sample.listenerCount, $Sample.publicListenerCount,
        $Sample.shadowHealth, $Sample.publicHealth
    )
    ($values -join ',') | Add-Content -LiteralPath $script:SamplesPath -Encoding ascii
    $script:RequestTotalCount += 2
    if ([int]$Sample.shadowHealth -eq 200) { $script:RequestSuccessCount++ }
    if ([int]$Sample.publicHealth -eq 200) { $script:RequestSuccessCount++ }
}

function Add-RequestRecord([object] $Record) {
    $script:RequestRecords.Add($Record)
    ConvertTo-JsonLine $Record | Add-Content -LiteralPath $script:RequestsPath -Encoding ascii
    foreach ($operation in @($Record.operations)) {
        $script:RequestTotalCount++
        if ($operation.ok) { $script:RequestSuccessCount++ }
    }
}

function Assert-Sample([object] $Sample) {
    if ($null -ne $script:Baseline -and "$($Sample.mainPid)" -ne "$($script:Baseline.mainPid)") {
        Fail 'NO-GO: MainPID changed.'
    }
    if ([int64]$Sample.nRestarts -ne 0) { Fail 'NO-GO: NRestarts increased.' }
    if ($Sample.activeState -ne 'active' -or $Sample.subState -ne 'running') {
        Fail 'NO-GO: service left active/running.'
    }
    if ([int]$Sample.shadowHealth -ne 200) { Fail 'NO-GO: shadow health failed.' }
    if ([int]$Sample.publicHealth -ne 200) { Fail 'NO-GO: public health failed.' }
    if ([int64]$Sample.listenerCount -ne 1 -or [int64]$Sample.publicListenerCount -ne 0) {
        Fail 'NO-GO: listener anomaly detected.'
    }
    if ([int64]$Sample.partCount -ne 0) { Fail 'NO-GO: persistent .part detected.' }
    if ([int64]$Sample.freeBytes -lt [int64]$Sample.minFreeBytes) {
        Fail 'NO-GO: free space below AUDIO_CACHE_MIN_FREE_BYTES.'
    }
    if ($Sample.sqliteIntegrity -ne 'ok' -or [int64]$Sample.foreignKeyViolations -ne 0) {
        Fail 'NO-GO: SQLite corruption detected.'
    }
    if ($Sample.cacheIndexIntegrity -ne 'ok') {
        Fail 'NO-GO: cache index corruption detected.'
    }
    if ([int64]$Sample.criticalEventCount -gt 0 -or $Sample.secretLeakSuspected) {
        Fail 'NO-GO: critical or sensitive journald event detected.'
    }
    if ($script:Samples.Count -ge 10) {
        $recent = @($script:Samples | Select-Object -Last 10)
        $fdValues = @($recent | ForEach-Object { [int64]$_.fileDescriptors })
        $threadValues = @($recent | ForEach-Object { [int64]$_.threads })
        $fdMonotone = $true
        $threadMonotone = $true
        for ($i = 1; $i -lt $recent.Count; $i++) {
            if ($fdValues[$i] -lt $fdValues[$i - 1]) { $fdMonotone = $false }
            if ($threadValues[$i] -lt $threadValues[$i - 1]) { $threadMonotone = $false }
        }
        if ($fdMonotone -and
            $fdValues[-1] -gt ($fdValues[0] + [Math]::Max(16, [Math]::Ceiling($fdValues[0] * 0.5)))) {
            Fail 'NO-GO: uncontrolled monotone file descriptor growth.'
        }
        if ($threadMonotone -and $threadValues[-1] -gt ($threadValues[0] + 8)) {
            Fail 'NO-GO: uncontrolled monotone thread growth.'
        }
    }
    if ($script:Samples.Count -ge 30) {
        $recentRss = @($script:Samples | Select-Object -Last 30 |
            ForEach-Object { [int64]$_.rssKiB })
        $recentWal = @($script:Samples | Select-Object -Last 30 |
            ForEach-Object { [int64]$_.walBytes })
        $rssMonotone = $true
        $walMonotone = $true
        for ($i = 1; $i -lt $recentRss.Count; $i++) {
            if ($recentRss[$i] -lt $recentRss[$i - 1]) { $rssMonotone = $false }
            if ($recentWal[$i] -lt $recentWal[$i - 1]) { $walMonotone = $false }
        }
        if ($rssMonotone -and
            $recentRss[-1] -gt ($recentRss[0] + [Math]::Max(32768, [Math]::Ceiling($recentRss[0] * 0.25)))) {
            Fail 'NO-GO: continuous RSS growth without stabilization.'
        }
        if ($walMonotone -and $recentWal[-1] -gt ($recentWal[0] + 67108864)) {
            Fail 'NO-GO: uncontrolled monotone SQLite WAL growth.'
        }
    }
}

function Assert-RequestRecord([object] $Record) {
    foreach ($operation in @($Record.operations)) {
        if (-not $operation.ok) {
            Fail "NO-GO: request check failed for $($operation.name)."
        }
        if ($operation.requiresCacheHit -and -not $operation.cacheHit) {
            Fail "NO-GO: CACHE_HIT missing for $($operation.name)."
        }
        if ($operation.remoteStorageStarted) {
            Fail "NO-GO: remote storage contacted for HIT $($operation.name)."
        }
        if ($operation.name -eq 'fullGet') {
            if ([int64]$operation.sizeBytes -ne $ExpectedTrackSize -or
                $operation.sha256 -ne $ExpectedTrackSha256) {
                Fail 'NO-GO: full GET size or SHA-256 mismatch.'
            }
        }
    }
}

function Get-Stats {
    param([string] $Property)
    if ($script:Samples.Count -eq 0) {
        return [ordered]@{ first = $null; min = $null; max = $null; last = $null; delta = $null }
    }
    $values = @($script:Samples | ForEach-Object { [double]($_.$Property) })
    return [ordered]@{
        first = $values[0]
        min = ($values | Measure-Object -Minimum).Minimum
        max = ($values | Measure-Object -Maximum).Maximum
        last = $values[-1]
        delta = $values[-1] - $values[0]
    }
}

function Get-MemoryRecommendation {
    $rss = Get-Stats -Property 'rssKiB'
    if ($null -eq $rss.max) {
        return [ordered]@{ peakRssKiB = $null; marginX2MiB = $null; marginX3MiB = $null; finalMiB = $null }
    }
    $peakMiB = [Math]::Ceiling([double]$rss.max / 1024)
    $x2 = [Math]::Ceiling(($peakMiB * 2) / 64) * 64
    $x3 = [Math]::Ceiling(($peakMiB * 3) / 64) * 64
    $final = [Math]::Max(384, $x3)
    $final = [Math]::Ceiling($final / 128) * 128
    return [ordered]@{
        peakRssKiB = [int64]$rss.max
        marginX2MiB = [int64]$x2
        marginX3MiB = [int64]$x3
        finalMiB = [int64]$final
    }
}

function Write-Reports {
    $duration = if ($null -ne $script:StartedAtUtc -and $null -ne $script:EndedAtUtc) {
        [Math]::Round(([DateTimeOffset]::Parse($script:EndedAtUtc) -
                       [DateTimeOffset]::Parse($script:StartedAtUtc)).TotalMinutes, 3)
    } else { 0 }
    $successRate = if ($script:RequestTotalCount -eq 0) {
        0
    } else {
        [Math]::Round(100.0 * $script:RequestSuccessCount / $script:RequestTotalCount, 3)
    }
    $memory = Get-MemoryRecommendation
    $summary = [ordered]@{
        verdict = $script:Verdict
        failureReason = $script:FailureReason
        releaseId = $ExpectedReleaseId
        startedAtUtc = $script:StartedAtUtc
        endedAtUtc = $script:EndedAtUtc
        durationMinutes = $duration
        sampleCount = $script:Samples.Count
        loadCycleCount = $script:LoadCycleCount
        requestSuccessCount = $script:RequestSuccessCount
        requestTotalCount = $script:RequestTotalCount
        requestSuccessRatePercent = $successRate
        rssKiB = Get-Stats 'rssKiB'
        fileDescriptors = Get-Stats 'fileDescriptors'
        threads = Get-Stats 'threads'
        cacheBytes = Get-Stats 'cacheBytes'
        sqliteBytes = Get-Stats 'sqliteBytes'
        walBytes = Get-Stats 'walBytes'
        shmBytes = Get-Stats 'shmBytes'
        freeBytes = Get-Stats 'freeBytes'
        mainPid = [ordered]@{
            first = if ($script:Samples.Count) { $script:Samples[0].mainPid } else { $null }
            last = if ($script:Samples.Count) { $script:Samples[-1].mainPid } else { $null }
        }
        nRestarts = [ordered]@{
            first = if ($script:Samples.Count) { $script:Samples[0].nRestarts } else { $null }
            last = if ($script:Samples.Count) { $script:Samples[-1].nRestarts } else { $null }
        }
        errorsAndWarningsSanitized = $script:SanitizedEvents.Count
        journalErrors = if ($null -ne $script:JournalSummary) {
            $script:JournalSummary.errorCount
        } else { $null }
        journalWarnings = if ($null -ne $script:JournalSummary) {
            $script:JournalSummary.warningCount
        } else { $null }
        memoryMaxRecommendation = $memory
        serviceEnabled = ($script:ServiceEnabledObserved -ne 'disabled')
        rebootPerformed = $false
        storageAgentStopped = $false
        storageAgentInitialStatus = $script:StorageAgentInitialStatus
        storageAgentFinalStatus = $script:StorageAgentFinalStatus
        publicCutoverPerformed = $false
        caddyQualifiedSha256Prefix = $QualifiedCaddySha256Prefix
        sshHostKeyVerificationDisabled = $false
        tokenPrinted = $false
        secretsPrinted = $false
    }
    ConvertTo-JsonLine $summary | Set-Content -LiteralPath $script:SummaryPath -Encoding ascii

    $report = @"
# Phase 6.4A - Shadow soak report

- Verdict: **$($summary.verdict)**
- Failure reason: $($summary.failureReason)
- Release: ``$ExpectedReleaseId``
- Started UTC: $($summary.startedAtUtc)
- Ended UTC: $($summary.endedAtUtc)
- Actual duration: $($summary.durationMinutes) minutes
- Samples: $($summary.sampleCount)
- Load cycles: $($summary.loadCycleCount)
- Request success rate: $($summary.requestSuccessRatePercent)%

## Runtime trends

| Metric | First | Min | Max | Last | Delta |
| --- | ---: | ---: | ---: | ---: | ---: |
| RSS KiB | $($summary.rssKiB.first) | $($summary.rssKiB.min) | $($summary.rssKiB.max) | $($summary.rssKiB.last) | $($summary.rssKiB.delta) |
| File descriptors | $($summary.fileDescriptors.first) | $($summary.fileDescriptors.min) | $($summary.fileDescriptors.max) | $($summary.fileDescriptors.last) | $($summary.fileDescriptors.delta) |
| Threads | $($summary.threads.first) | $($summary.threads.min) | $($summary.threads.max) | $($summary.threads.last) | $($summary.threads.delta) |
| Cache bytes | $($summary.cacheBytes.first) | $($summary.cacheBytes.min) | $($summary.cacheBytes.max) | $($summary.cacheBytes.last) | $($summary.cacheBytes.delta) |
| SQLite bytes | $($summary.sqliteBytes.first) | $($summary.sqliteBytes.min) | $($summary.sqliteBytes.max) | $($summary.sqliteBytes.last) | $($summary.sqliteBytes.delta) |
| WAL bytes | $($summary.walBytes.first) | $($summary.walBytes.min) | $($summary.walBytes.max) | $($summary.walBytes.last) | $($summary.walBytes.delta) |
| SHM bytes | $($summary.shmBytes.first) | $($summary.shmBytes.min) | $($summary.shmBytes.max) | $($summary.shmBytes.last) | $($summary.shmBytes.delta) |
| Free bytes | $($summary.freeBytes.first) | $($summary.freeBytes.min) | $($summary.freeBytes.max) | $($summary.freeBytes.last) | $($summary.freeBytes.delta) |

## MemoryMax proposal

- Observed peak RSS: $($memory.peakRssKiB) KiB
- Margin x2: $($memory.marginX2MiB) MiB
- Margin x3: $($memory.marginX3MiB) MiB
- Future recommendation: $($memory.finalMiB) MiB

## Safety confirmations

- serviceEnabled=$($summary.serviceEnabled.ToString().ToLowerInvariant())
- rebootPerformed=false
- storageAgentStopped=false
- publicCutoverPerformed=false
- Shadow service was not stopped or restarted by this script.
- Caddy was not reloaded or restarted.
- Offline test: NOT_RUN_REQUIRES_EXPLICIT_PRODUCTION_SERVICE_APPROVAL
"@
    $report | Set-Content -LiteralPath $script:ReportPath -Encoding ascii
}

function Invoke-SelfTest {
    $script:StartedAtUtc = '2026-07-28T20:00:00.000Z'
    $script:StorageAgentInitialStatus = 'Running'
    $base = [pscustomobject]@{
        timestampUtc = '2026-07-28T20:00:00.000Z'; mainPid = 64749
        activeState = 'active'; subState = 'running'; nRestarts = 0
        rssKiB = 100000; cpuSeconds = 2.0; fileDescriptors = 29; threads = 11
        cacheBytes = 18705326; objectCount = 1; partCount = 0
        sqliteBytes = 3436544; walBytes = 12392; shmBytes = 32768
        freeBytes = 20000000000; minFreeBytes = 1000000000
        listenerCount = 1; publicListenerCount = 0
        shadowHealth = 200; publicHealth = 200; sqliteIntegrity = 'ok'
        foreignKeyViolations = 0; cacheIndexIntegrity = 'ok'
        criticalEventCount = 0; secretLeakSuspected = $false
    }
    if ($SelfTestScenario -eq 'PublicListener') { $base.publicListenerCount = 1 }
    if ($SelfTestScenario -eq 'Restarted') { $base.nRestarts = 1 }
    $script:Baseline = $base
    $script:ServiceEnabledObserved = 'disabled'
    Add-Sample $base
    try {
        Assert-Sample $base
        $second = $base.PSObject.Copy()
        $second.timestampUtc = '2026-07-28T22:00:01.000Z'
        $second.rssKiB = 126224
        if ($SelfTestScenario -eq 'PidChanged') { $second.mainPid = 64750 }
        Add-Sample $second
        Assert-Sample $second
        if ($SelfTestScenario -eq 'Interrupted') {
            Fail 'Simulated interruption.'
        }
        $script:Verdict = 'SELF_TEST'
    } catch {
        if ($SelfTestScenario -eq 'Interrupted') {
            $script:Verdict = 'INCOMPLETE_RESTART_REQUIRED'
        } else {
            $script:Verdict = 'NO_GO'
        }
        $script:FailureReason = $_.Exception.Message
    }
    $script:StorageAgentFinalStatus = 'Running'
    $script:EndedAtUtc = '2026-07-28T22:00:01.000Z'
    Write-Reports
}

$script:RemoteHelperSource = @'
#!/usr/bin/env python3
import argparse
import hashlib
import http.client
import json
import os
import re
import socket
import ssl
import subprocess
import time
import uuid
from pathlib import Path

SERVICE = "homespotify-api-shadow.service"
STATE = Path("/var/lib/homespotify-shadow")
DB = STATE / "data/runtime.db"
CACHE = STATE / "cache/audio"
INCOMING = STATE / "imports/incoming"
VARIANTS = STATE / "offline-variants"
ENV_FILE = Path("/etc/homespotify/api-shadow.env")
CURRENT = Path("/opt/homespotify-api-shadow/current")
BUNDLE = Path("/opt/homespotify-api-shadow/dependency-bundles/linux-x64-node22.18.0-abi127/node_modules")
PUBLIC_HOST = "music.romainbegot.fr"
TRACK_ID = 119
EXPECTED_SIZE = 18619182
EXPECTED_SHA256 = "b953fbe920f69b9e9b36ef2fe72ede2d863cd5e1868e501d740411e181d174a4"
CRITICAL = re.compile(
    r"(unhandled|uncaught|rejected|sqlite.*(?:busy|locked|corrupt)|cache.*(?:fail|error)|"
    r"hash mismatch|remote.*timeout|restart loop|acquisition.*started|import.*started)",
    re.IGNORECASE,
)
SENSITIVE = re.compile(
    r"(authorization|bearer\s+|AUTH_TOKEN_SECRET|AUDIO_REMOTE_SHARED_SECRET)",
    re.IGNORECASE,
)

def run(args, timeout=30):
    result = subprocess.run(args, capture_output=True, text=True, timeout=timeout, check=False)
    return result.returncode, result.stdout, result.stderr

def systemd_properties():
    keys = ["MainPID", "ActiveState", "SubState", "NRestarts", "CPUUsageNSec"]
    _, stdout, _ = run(["systemctl", "show", SERVICE] + [f"-p{x}" for x in keys])
    values = {}
    for line in stdout.splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            values[key] = value
    return values

def enabled():
    _, stdout, _ = run(["systemctl", "is-enabled", SERVICE])
    return stdout.strip() or "unknown"

def listener_addresses():
    _, stdout, _ = run(["ss", "-ltnH"])
    found = []
    for line in stdout.splitlines():
        fields = line.split()
        if len(fields) >= 4 and re.search(r":3002$", fields[3]):
            found.append(fields[3])
    return sorted(set(found))

def http_request(method, path, token="", range_value=None):
    request_id = f"phase64a-{uuid.uuid4().hex}"
    headers = {"X-Request-Id": request_id}
    if token:
        headers["Authorization"] = "Bearer " + token
    if range_value:
        headers["Range"] = range_value
    connection = http.client.HTTPConnection("127.0.0.1", 3002, timeout=30)
    started = time.perf_counter()
    connection.request(method, path, headers=headers)
    response = connection.getresponse()
    digest = hashlib.sha256()
    size = 0
    while True:
        chunk = response.read(256 * 1024)
        if not chunk:
            break
        digest.update(chunk)
        size += len(chunk)
    status = response.status
    content_range = response.getheader("Content-Range")
    connection.close()
    return {
        "status": status,
        "sizeBytes": size,
        "sha256": digest.hexdigest(),
        "requestId": request_id,
        "contentRange": content_range,
        "elapsedMs": round((time.perf_counter() - started) * 1000, 1),
    }

def public_health():
    context = ssl.create_default_context()
    connection = http.client.HTTPSConnection(PUBLIC_HOST, 443, timeout=15, context=context)
    try:
        connection.request("GET", "/health", headers={"X-Request-Id": f"phase64a-{uuid.uuid4().hex}"})
        response = connection.getresponse()
        response.read()
        return response.status
    except OSError:
        return 0
    finally:
        connection.close()

def journal_lines(since):
    args = ["journalctl", "-u", SERVICE, "-o", "cat", "--no-pager"]
    if since and since != "-":
        args += ["--since", since]
    _, stdout, _ = run(args, timeout=45)
    return stdout.splitlines()

def journal_events(request_id, since):
    for attempt in range(20):
        names = []
        for line in journal_lines(since):
            if request_id not in line:
                continue
            start = line.find("{")
            if start < 0:
                continue
            try:
                record = json.loads(line[start:])
            except ValueError:
                continue
            if record.get("requestId") == request_id and isinstance(record.get("event"), str):
                names.append(record["event"])
        if "CACHE_HIT" in names or "REMOTE_STORAGE_REQUEST_STARTED" in names:
            return names
        if attempt < 19:
            time.sleep(0.5)
    return names

def priority_lines(priority, since):
    args = ["journalctl", "-u", SERVICE, "-p", priority, "-o", "cat", "--no-pager"]
    if since and since != "-":
        args += ["--since", since]
    _, stdout, _ = run(args, timeout=45)
    return [line for line in stdout.splitlines() if line.strip()]

def count_files(root, suffix=None, exclude_metadata=False):
    count = 0
    if not root.exists():
        return 0
    for path in root.rglob("*"):
        if not path.is_file():
            continue
        if exclude_metadata and "metadata" in path.parts:
            continue
        if suffix is None or path.name.endswith(suffix):
            count += 1
    return count

def directory_bytes(root):
    total = 0
    if root.exists():
        for path in root.rglob("*"):
            if path.is_file():
                try:
                    total += path.stat().st_size
                except OSError:
                    pass
    return total

def min_free_bytes():
    for line in ENV_FILE.read_text(encoding="utf-8").splitlines():
        if line.startswith("AUDIO_CACHE_MIN_FREE_BYTES="):
            try:
                return int(line.split("=", 1)[1].strip())
            except ValueError:
                return None
    return None

def sqlite_state():
    code = (
        'const Database=require(process.env.HS_BUNDLE+"/better-sqlite3");'
        'const db=new Database(process.env.HS_DB,{readonly:true,fileMustExist:true});'
        'const out={integrity:db.pragma("integrity_check",{simple:true}),'
        'foreignKeyViolations:db.pragma("foreign_key_check").length,'
        'migrations:db.prepare("SELECT count(*) AS n FROM __drizzle_migrations").get().n,'
        'phase63FavoritePresent:db.prepare("SELECT count(*) AS n FROM favorites WHERE track_id=119").get().n>0};'
        'db.close();console.log(JSON.stringify(out));'
    )
    environment = dict(os.environ, HS_BUNDLE=str(BUNDLE), HS_DB=str(DB))
    result = subprocess.run(
        ["node", "--input-type=commonjs", "-e", code],
        capture_output=True, text=True, timeout=30, check=False, env=environment,
    )
    try:
        return json.loads(result.stdout.strip().splitlines()[-1])
    except (ValueError, IndexError):
        return {
            "integrity": "error", "foreignKeyViolations": -1,
            "migrations": -1, "phase63FavoritePresent": True,
        }

def cache_index_integrity():
    index_path = CACHE / "metadata/cache-index.sqlite"
    if not index_path.exists():
        return "missing"
    code = (
        'const Database=require(process.env.HS_BUNDLE+"/better-sqlite3");'
        'const db=new Database(process.env.HS_CACHE_INDEX,{readonly:true,fileMustExist:true});'
        'const out=db.pragma("integrity_check",{simple:true});'
        'db.close();console.log(JSON.stringify({integrity:out}));'
    )
    environment = dict(
        os.environ, HS_BUNDLE=str(BUNDLE), HS_CACHE_INDEX=str(index_path)
    )
    result = subprocess.run(
        ["node", "--input-type=commonjs", "-e", code],
        capture_output=True, text=True, timeout=30, check=False, env=environment,
    )
    try:
        return json.loads(result.stdout.strip().splitlines()[-1])["integrity"]
    except (ValueError, IndexError, KeyError):
        return "error"

def caddy_hash():
    digest = hashlib.sha256()
    with open("/etc/caddy/Caddyfile", "rb") as handle:
        for chunk in iter(lambda: handle.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()

def service_sample(since):
    props = systemd_properties()
    pid = int(props.get("MainPID", "0") or 0)
    status_text = ""
    rss = threads = fd_count = 0
    if pid > 0:
        status_text = Path(f"/proc/{pid}/status").read_text(encoding="ascii")
        match = re.search(r"^VmRSS:\s+(\d+)", status_text, re.MULTILINE)
        rss = int(match.group(1)) if match else 0
        match = re.search(r"^Threads:\s+(\d+)", status_text, re.MULTILINE)
        threads = int(match.group(1)) if match else 0
        fd_count = len(list(Path(f"/proc/{pid}/fd").iterdir()))
    addresses = listener_addresses()
    public = [address for address in addresses if address != "127.0.0.1:3002"]
    sqlite = sqlite_state()
    lines = journal_lines(since)
    priority_errors = priority_lines("err", since)
    critical_count = len(priority_errors) + sum(1 for line in lines if CRITICAL.search(line))
    leak = any(SENSITIVE.search(line) for line in lines)
    statvfs = os.statvfs(CACHE)
    return {
        "timestampUtc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "mainPid": pid,
        "activeState": props.get("ActiveState", "unknown"),
        "subState": props.get("SubState", "unknown"),
        "nRestarts": int(props.get("NRestarts", "-1") or -1),
        "rssKiB": rss,
        "cpuSeconds": round(int(props.get("CPUUsageNSec", "0") or 0) / 1_000_000_000, 3),
        "fileDescriptors": fd_count,
        "threads": threads,
        "cacheBytes": directory_bytes(CACHE),
        "objectCount": count_files(CACHE, exclude_metadata=True) - count_files(CACHE, ".part", True),
        "partCount": count_files(CACHE, ".part"),
        "sqliteBytes": DB.stat().st_size if DB.exists() else 0,
        "walBytes": Path(str(DB) + "-wal").stat().st_size if Path(str(DB) + "-wal").exists() else 0,
        "shmBytes": Path(str(DB) + "-shm").stat().st_size if Path(str(DB) + "-shm").exists() else 0,
        "freeBytes": statvfs.f_bavail * statvfs.f_frsize,
        "minFreeBytes": min_free_bytes(),
        "listenerCount": len(addresses),
        "publicListenerCount": len(public),
        "listenerAddresses": addresses,
        "shadowHealth": http_request("GET", "/health")["status"],
        "publicHealth": public_health(),
        "sqliteIntegrity": sqlite["integrity"],
        "foreignKeyViolations": sqlite["foreignKeyViolations"],
        "migrations": sqlite["migrations"],
        "phase63FavoritePresent": sqlite["phase63FavoritePresent"],
        "cacheIndexIntegrity": cache_index_integrity(),
        "criticalEventCount": critical_count,
        "secretLeakSuspected": leak,
    }

def token_from(path):
    if not path:
        return ""
    return Path(path).read_text(encoding="ascii").strip()

def operation(name, result, events, status, size=None, sha=None, cache_hit=False):
    ok = result["status"] == status
    if size is not None:
        ok = ok and result["sizeBytes"] == size
    if sha is not None:
        ok = ok and result["sha256"] == sha
    return {
        "name": name,
        "ok": ok,
        "status": result["status"],
        "sizeBytes": result["sizeBytes"],
        "sha256": result["sha256"] if name == "fullGet" else None,
        "requestId": result["requestId"],
        "elapsedMs": result["elapsedMs"],
        "requiresCacheHit": cache_hit,
        "cacheHit": "CACHE_HIT" in events,
        "remoteStorageStarted": "REMOTE_STORAGE_REQUEST_STARTED" in events,
    }

def load_cycle(token, since, include_full):
    operations = []
    listing = http_request("GET", "/api/tracks?limit=1", token)
    operations.append(operation("trackList", listing, [], 200))
    head = http_request("HEAD", f"/api/tracks/{TRACK_ID}/stream", token)
    head_events = journal_events(head["requestId"], since)
    operations.append(operation("headHit", head, head_events, 200, size=0, cache_hit=True))
    ranged = http_request(
        "GET", f"/api/tracks/{TRACK_ID}/stream", token, range_value="bytes=0-1023"
    )
    range_events = journal_events(ranged["requestId"], since)
    ranged_op = operation("rangeHit", ranged, range_events, 206, size=1024, cache_hit=True)
    ranged_op["ok"] = ranged_op["ok"] and ranged["contentRange"] == f"bytes 0-1023/{EXPECTED_SIZE}"
    operations.append(ranged_op)
    if include_full:
        full = http_request("GET", f"/api/tracks/{TRACK_ID}/stream", token)
        full_events = journal_events(full["requestId"], since)
        operations.append(
            operation(
                "fullGet", full, full_events, 200, size=EXPECTED_SIZE,
                sha=EXPECTED_SHA256, cache_hit=True,
            )
        )
    return {
        "timestampUtc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "operations": operations,
    }

def sanitize(value):
    if isinstance(value, dict):
        output = {}
        for key, item in value.items():
            if re.search(r"(authorization|token|secret|password)", key, re.IGNORECASE):
                output[key] = "[REDACTED]"
            else:
                output[key] = sanitize(item)
        return output
    if isinstance(value, list):
        return [sanitize(item) for item in value]
    if isinstance(value, str):
        return SENSITIVE.sub("[REDACTED]", value)[:1000]
    return value

def sanitized_journal(since):
    events = []
    secret_leak = False
    error_count = warning_count = 0
    all_lines = journal_lines(since)
    warning_lines = priority_lines("warning", since)
    error_lines = priority_lines("err", since)
    for line in all_lines:
        if SENSITIVE.search(line):
            secret_leak = True
        start = line.find("{")
        if start < 0:
            continue
        try:
            record = json.loads(line[start:])
        except ValueError:
            continue
        level = record.get("level")
        if isinstance(level, int) and level >= 50:
            error_count += 1
        elif isinstance(level, int) and level >= 40:
            warning_count += 1
        if (isinstance(level, int) and level >= 40) or CRITICAL.search(line):
            events.append(sanitize(record))
    for line in warning_lines:
        events.append({"source": "journald", "message": sanitize(line)})
    error_count += len(error_lines)
    warning_count += len(warning_lines)
    return {
        "events": events[:500],
        "errorCount": error_count,
        "warningCount": warning_count,
        "secretLeakSuspected": secret_leak,
    }

def agent_reachable():
    try:
        with socket.create_connection(("10.8.0.2", 3100), timeout=6):
            return True
    except OSError:
        return False

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", required=True)
    parser.add_argument("--token-file", default="")
    parser.add_argument("--since", default="-")
    args = parser.parse_args()
    if args.mode == "preflight":
        result = service_sample(args.since)
        result.update({
            "serviceEnabled": enabled(),
            "releaseId": CURRENT.resolve().name if CURRENT.is_symlink() else "",
            "caddyActive": run(["systemctl", "is-active", "caddy"])[1].strip(),
            "caddySha256": caddy_hash(),
            "wireguardActive": run(["systemctl", "is-active", "wg-quick@wg0"])[1].strip(),
            "storageAgentReachable": agent_reachable(),
            "incomingCount": count_files(INCOMING),
            "unexpectedVariantCount": count_files(VARIANTS),
        })
    elif args.mode == "sample":
        result = service_sample(args.since)
    elif args.mode == "load":
        result = load_cycle(token_from(args.token_file), args.since, False)
    elif args.mode == "full":
        result = load_cycle(token_from(args.token_file), args.since, True)
    elif args.mode == "integrity":
        result = sqlite_state()
        result.update({
            "cacheIndexIntegrity": cache_index_integrity(),
            "incomingCount": count_files(INCOMING),
            "unexpectedVariantCount": count_files(VARIANTS),
            "caddyActive": run(["systemctl", "is-active", "caddy"])[1].strip(),
            "caddySha256": caddy_hash(),
            "publicHealth": public_health(),
            "storageAgentReachable": agent_reachable(),
            "serviceEnabled": enabled(),
        })
    elif args.mode == "journal":
        result = sanitized_journal(args.since)
    else:
        raise SystemExit("unknown mode")
    print(json.dumps(result, separators=(",", ":")))

if __name__ == "__main__":
    main()
'@

Assert-LocalArguments

if ($ValidateOnly) {
    [pscustomobject]@{
        ok = $true
        mode = 'ValidateOnly'
        sshConnectionsOpened = 0
        durationMinutes = $DurationMinutes
        expectedReleaseId = $ExpectedReleaseId
    } | ConvertTo-Json -Compress
    exit 0
}

Initialize-Output

if ($SelfTest) {
    Invoke-SelfTest
    exit 0
}

$preflightCompleted = $false
$soakCompleted = $false
$lastTokenMint = [DateTimeOffset]::MinValue

try {
    $script:StorageAgentInitialStatus = Get-WindowsStorageAgentStatus
    [void](Invoke-SshText -RemoteCommand "printf '{`"ok`":true}`n'")
    Install-RemoteHelper
    New-ShadowToken
    $lastTokenMint = [DateTimeOffset]::UtcNow

    $preflight = Invoke-RemoteMode -Mode 'preflight'
    $script:Baseline = $preflight
    Assert-Preflight $preflight
    $preflightCompleted = $true

    $script:StartedAtUtc = Get-UtcIso
    $deadline = [DateTimeOffset]::UtcNow.AddMinutes($DurationMinutes)
    $nextSample = [DateTimeOffset]::UtcNow
    $nextLoad = [DateTimeOffset]::UtcNow
    $nextFull = [DateTimeOffset]::UtcNow

    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        $now = [DateTimeOffset]::UtcNow
        if ($now -ge $nextSample) {
            $sample = Invoke-RemoteMode -Mode 'sample'
            Add-Sample $sample
            Assert-Sample $sample
            $nextSample = $nextSample.AddSeconds($SampleIntervalSeconds)
            if ($nextSample -le $now) { $nextSample = $now.AddSeconds($SampleIntervalSeconds) }
        }

        if ($now -ge $nextLoad) {
            if (($now - $lastTokenMint).TotalMinutes -ge 25) {
                New-ShadowToken
                $lastTokenMint = $now
            }
            $includeFull = $now -ge $nextFull
            $mode = if ($includeFull) { 'full' } else { 'load' }
            $record = Invoke-RemoteMode -Mode $mode
            Add-RequestRecord $record
            Assert-RequestRecord $record
            $script:LoadCycleCount++
            $nextLoad = $nextLoad.AddMinutes($LoadIntervalMinutes)
            if ($nextLoad -le $now) { $nextLoad = $now.AddMinutes($LoadIntervalMinutes) }
            if ($includeFull) {
                $nextFull = $nextFull.AddMinutes($FullGetIntervalMinutes)
                if ($nextFull -le $now) { $nextFull = $now.AddMinutes($FullGetIntervalMinutes) }
            }
        }

        $remainingMs = [Math]::Max(100, [Math]::Min(
            1000,
            ($nextSample - [DateTimeOffset]::UtcNow).TotalMilliseconds
        ))
        Start-Sleep -Milliseconds ([int]$remainingMs)
    }

    # The end controls happen only after the full requested duration elapsed.
    $finalSample = Invoke-RemoteMode -Mode 'sample'
    Add-Sample $finalSample
    Assert-Sample $finalSample
    if (([DateTimeOffset]::UtcNow - $lastTokenMint).TotalMinutes -ge 25) {
        New-ShadowToken
    }
    $finalRequests = Invoke-RemoteMode -Mode 'full'
    Add-RequestRecord $finalRequests
    Assert-RequestRecord $finalRequests

    $integrity = Invoke-RemoteMode -Mode 'integrity'
    if ($integrity.integrity -ne 'ok' -or
        [int64]$integrity.foreignKeyViolations -ne 0 -or
        [int64]$integrity.migrations -ne 18 -or
        $integrity.phase63FavoritePresent -or
        $integrity.cacheIndexIntegrity -ne 'ok' -or
        [int64]$integrity.incomingCount -ne 0 -or
        [int64]$integrity.unexpectedVariantCount -ne 0 -or
        $integrity.caddyActive -ne 'active' -or
        -not "$($integrity.caddySha256)".StartsWith($QualifiedCaddySha256Prefix) -or
        $integrity.caddySha256 -ne $script:Baseline.caddySha256 -or
        [int]$integrity.publicHealth -ne 200 -or
        -not $integrity.storageAgentReachable -or
        $integrity.serviceEnabled -ne 'disabled') {
        Fail 'NO-GO: final integrity or infrastructure control failed.'
    }
    $script:ServiceEnabledObserved = $integrity.serviceEnabled

    $journal = Invoke-RemoteMode -Mode 'journal'
    $script:JournalSummary = $journal
    foreach ($event in @($journal.events)) {
        $script:SanitizedEvents.Add($event)
        ConvertTo-JsonLine $event | Add-Content -LiteralPath $script:EventsPath -Encoding ascii
    }
    if ($journal.secretLeakSuspected -or [int64]$journal.errorCount -gt 0) {
        Fail 'NO-GO: journald contains an error or suspected sensitive value.'
    }

    $script:StorageAgentFinalStatus = Get-WindowsStorageAgentStatus
    if ($script:StorageAgentFinalStatus -ne 'Running') {
        Fail 'NO-GO: Windows Storage Agent is not Running at the end.'
    }
    $script:FinalState = $finalSample
    $soakCompleted = $true
    $script:Verdict = 'GO'
} catch {
    $script:FailureReason = $_.Exception.Message
    if ($preflightCompleted -and -not $soakCompleted -and
        -not $script:FailureReason.StartsWith('NO-GO:')) {
        $script:Verdict = 'INCOMPLETE_RESTART_REQUIRED'
    } else {
        $script:Verdict = 'NO_GO'
    }
    if ($null -eq $script:StorageAgentFinalStatus) {
        $script:StorageAgentFinalStatus = Get-WindowsStorageAgentStatus
    }
} finally {
    $script:EndedAtUtc = Get-UtcIso
    if ($script:SshWasUsed) {
        try {
            $paths = @($script:RemoteTokenPath, $script:RemoteHelperPath) |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            if ($paths.Count -gt 0) {
                $quoted = ($paths | ForEach-Object { "'$_'" }) -join ' '
                [void](Invoke-SshText -RemoteCommand "sudo -n rm -f -- $quoted")
            }
        } catch {
            if ([string]::IsNullOrWhiteSpace($script:FailureReason)) {
                $script:FailureReason = 'Remote cleanup could not be confirmed.'
            } else {
                $script:FailureReason += ' Remote cleanup could not be confirmed.'
            }
            if ($script:Verdict -eq 'GO') { $script:Verdict = 'NO_GO' }
        }
    }
    Write-Reports
}

if ($script:Verdict -ne 'GO') {
    Write-Error "Phase 6.4A verdict: $($script:Verdict). $($script:FailureReason)"
    exit 1
}

Write-Host "Phase 6.4A GO. Reports: $OutputDirectory"
