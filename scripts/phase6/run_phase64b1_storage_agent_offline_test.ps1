[CmdletBinding()]
param(
    [string] $VpsHost = '135.125.101.79',
    [string] $VpsUser = 'debian',
    [Parameter(Mandatory = $true)]
    [string] $SshKeyPath,
    [Parameter(Mandatory = $true)]
    [string] $OutputDirectory,
    [string] $StorageAgentServiceName = 'HomeSpotifyStorageAgent',
    [string] $ProductionApiServiceName = 'HomeSpotifyApi',
    [ValidateRange(1, 90)]
    [int] $MaxAgentDowntimeSeconds = 90,
    [int] $CachedTrackId = 119,
    [switch] $ValidateOnly,
    [switch] $SelfTest,
    [ValidateSet(
        'Healthy', 'NonElevated', 'ExceptionAfterStop', 'CachedMiss',
        'UncachedUnexpectedSuccess', 'PartResidual', 'FillMissing',
        'FinalHitMissing'
    )]
    [string] $SelfTestScenario = 'Healthy'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$expectedReleaseId = '20260729T200813Z-596e4764-f09a54cf'
$expectedStorageAgentService = 'HomeSpotifyStorageAgent'
$expectedProductionApiService = 'HomeSpotifyApi'
$script:remoteHelperPath = $null
$script:remoteTokenPath = $null
$script:sshConnectionsOpened = 0
$script:stopCalls = 0
$script:startCalls = 0
$script:agentWasStopped = $false
$script:downtimeWatch = $null
$script:requests = [System.Collections.Generic.List[object]]::new()
$script:events = [System.Collections.Generic.List[object]]::new()
$script:summary = [ordered]@{
    verdict = 'INCOMPLETE'
    failureReason = $null
    elevationConfirmed = $false
    validateOnly = [bool]$ValidateOnly
    serviceAgentInitialState = $null
    serviceAgentStopped = $false
    serviceAgentFinalState = $null
    productionApiInitialState = $null
    productionApiFinalState = $null
    downtimeSeconds = $null
    cachedTrackId = $CachedTrackId
    uncachedTrackId = $null
    cachedOffline = $null
    uncachedOffline = $null
    offlineHttpStatus = $null
    fillAfterRecovery = $null
    finalHit = $null
    partFilesBefore = $null
    partFilesAfter = $null
    publicHealthBefore = $null
    publicHealthDuring = $null
    publicHealthAfter = $null
    shadowHealthBefore = $null
    shadowHealthDuring = $null
    shadowHealthAfter = $null
    serviceEnabled = $false
    rebootPerformed = $false
    publicCutoverPerformed = $false
    secretsPrinted = $false
    sshConnectionsOpened = 0
    stopCalls = 0
    startCalls = 0
}

function Fail([string] $Message) {
    throw [System.InvalidOperationException]::new($Message)
}

function Get-UtcIso {
    return [DateTimeOffset]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
}

function ConvertTo-JsonLine([object] $Value) {
    return ($Value | ConvertTo-Json -Depth 30 -Compress)
}

function Initialize-OutputFiles {
    [void](New-Item -ItemType Directory -Force -Path $OutputDirectory)
    $script:summaryPath = Join-Path $OutputDirectory 'phase64b1b-summary.json'
    $script:requestsPath = Join-Path $OutputDirectory 'requests.jsonl'
    $script:eventsPath = Join-Path $OutputDirectory 'events-sanitized.jsonl'
    $script:reportPath = Join-Path $OutputDirectory 'PHASE64B1B_STORAGE_AGENT_OFFLINE_REPORT.md'
    [void](New-Item -ItemType File -Force -Path $script:requestsPath)
    [void](New-Item -ItemType File -Force -Path $script:eventsPath)
}

function Test-IsAdministrator {
    if ($SelfTest) {
        return $SelfTestScenario -ne 'NonElevated'
    }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-LocalArguments {
    if ($StorageAgentServiceName -ne $expectedStorageAgentService) {
        Fail "Only $expectedStorageAgentService may be controlled."
    }
    if ($ProductionApiServiceName -ne $expectedProductionApiService) {
        Fail "Production API service must remain $expectedProductionApiService."
    }
    if ($MaxAgentDowntimeSeconds -gt 90) {
        Fail 'MaxAgentDowntimeSeconds must not exceed 90.'
    }
    if ($CachedTrackId -le 0) {
        Fail 'CachedTrackId must be positive.'
    }
    if ([string]::IsNullOrWhiteSpace($VpsHost) -or
        [string]::IsNullOrWhiteSpace($VpsUser)) {
        Fail 'VpsHost and VpsUser are required.'
    }
    if (-not $SelfTest -and -not (Test-Path -LiteralPath $SshKeyPath -PathType Leaf)) {
        Fail 'SshKeyPath does not identify an existing file.'
    }
}

function Get-ServiceState([string] $Name) {
    if ($SelfTest) {
        if ($Name -eq $expectedStorageAgentService -and $script:agentWasStopped) {
            return 'Stopped'
        }
        return 'Running'
    }
    return (Get-Service -Name $Name -ErrorAction Stop).Status.ToString()
}

function Stop-StorageAgent {
    if ($StorageAgentServiceName -ne $expectedStorageAgentService) {
        Fail 'Refusing to stop an unexpected service.'
    }
    $script:stopCalls++
    if ($SelfTest) {
        $script:agentWasStopped = $true
        return
    }
    Stop-Service -Name $expectedStorageAgentService -ErrorAction Stop
    (Get-Service -Name $expectedStorageAgentService -ErrorAction Stop).WaitForStatus(
        [ServiceProcess.ServiceControllerStatus]::Stopped,
        [TimeSpan]::FromSeconds(15)
    )
    $script:agentWasStopped = $true
}

function Start-StorageAgentBounded {
    $script:startCalls++
    if ($SelfTest) {
        $script:agentWasStopped = $false
        return 'Running'
    }

    $attempt = 0
    while ($attempt -lt 3 -and
           $script:downtimeWatch.Elapsed.TotalSeconds -lt $MaxAgentDowntimeSeconds) {
        $attempt++
        try {
            Start-Service -Name $expectedStorageAgentService -ErrorAction Stop
        } catch {
            $state = Get-ServiceState $expectedStorageAgentService
            if ($state -notin @('Running', 'StartPending')) {
                if ($attempt -ge 3) { throw }
                Start-Sleep -Milliseconds 500
                continue
            }
        }
        $remaining = [Math]::Max(
            1,
            [Math]::Floor($MaxAgentDowntimeSeconds -
                          $script:downtimeWatch.Elapsed.TotalSeconds)
        )
        $waitSeconds = [Math]::Min(15, $remaining)
        try {
            (Get-Service -Name $expectedStorageAgentService -ErrorAction Stop).WaitForStatus(
                [ServiceProcess.ServiceControllerStatus]::Running,
                [TimeSpan]::FromSeconds($waitSeconds)
            )
        } catch {
            if ($attempt -ge 3) { throw }
        }
        if ((Get-ServiceState $expectedStorageAgentService) -eq 'Running') {
            $script:agentWasStopped = $false
            return 'Running'
        }
    }
    Fail ("CRITICAL_STORAGE_AGENT_NOT_RUNNING after {0:N3}s" -f
          $script:downtimeWatch.Elapsed.TotalSeconds)
}

function Assert-DowntimeBudget([double] $ReserveSeconds) {
    if ($null -eq $script:downtimeWatch) { return }
    $remaining = $MaxAgentDowntimeSeconds -
        $script:downtimeWatch.Elapsed.TotalSeconds
    if ($remaining -lt $ReserveSeconds) {
        Fail ("DOWNTIME_BUDGET_EXHAUSTED: {0:N3}s remaining." -f $remaining)
    }
}

function Get-SshArguments {
    return @(
        '-o', 'BatchMode=yes',
        '-o', 'ConnectTimeout=15',
        '-o', 'ConnectionAttempts=1',
        '-o', 'ServerAliveInterval=10',
        '-o', 'ServerAliveCountMax=3',
        '-i', $SshKeyPath,
        "$VpsUser@$VpsHost"
    )
}

function Get-LastJson([object[]] $Lines) {
    for ($index = $Lines.Count - 1; $index -ge 0; $index--) {
        $candidate = "$($Lines[$index])".Trim()
        if (-not $candidate.StartsWith('{')) { continue }
        try {
            return $candidate | ConvertFrom-Json -ErrorAction Stop
        } catch {
            continue
        }
    }
    Fail 'Remote output did not contain a readable JSON object.'
}

function Invoke-SshText([string] $RemoteCommand) {
    if ($SelfTest) {
        Fail 'SELF_TEST_SSH_FORBIDDEN'
    }
    $script:sshConnectionsOpened++
    $output = & ssh.exe @(Get-SshArguments) $RemoteCommand 2>&1
    if ($LASTEXITCODE -ne 0) {
        $safe = (($output | ForEach-Object { "$_" }) -join "`n")
        if ($safe.Length -gt 800) { $safe = $safe.Substring(0, 800) }
        Fail "SSH failed with exit code $LASTEXITCODE. $safe"
    }
    return @($output)
}

function Install-RemoteHelper {
    if ($SelfTest) { return }
    $runId = [Guid]::NewGuid().ToString('N')
    $script:remoteHelperPath = "/run/phase64b1b-$runId.py"
    $script:remoteTokenPath = "/run/phase64b1b-$runId.token"
    $bytes = [Text.Encoding]::UTF8.GetBytes(
        $script:remoteHelperSource.Replace("`r`n", "`n")
    )
    $payload = [Convert]::ToBase64String($bytes)
    $command = "printf '%s' '$payload' | base64 -d | " +
        "sudo -n install -o root -g root -m 0700 /dev/stdin " +
        "'$($script:remoteHelperPath)'"
    [void](Invoke-SshText $command)
    $tokenCommand = @(
        'sudo -n node /opt/homespotify-api-shadow/tools/phase6_shadow_token.mjs',
        '/etc/homespotify/api-shadow.env',
        '/var/lib/homespotify-shadow/data/runtime.db',
        '/opt/homespotify-api-shadow/dependency-bundles/linux-x64-node22.18.0-abi127/node_modules',
        "'$($script:remoteTokenPath)'"
    ) -join ' '
    $tokenResult = Get-LastJson @(Invoke-SshText $tokenCommand)
    if (-not $tokenResult.ok -or
        $tokenResult.tokenPrinted -ne $false -or
        $tokenResult.secretPrinted -ne $false) {
        Fail 'Token helper contract failed.'
    }
}

function Remove-RemoteHelper {
    if ($SelfTest -or $script:sshConnectionsOpened -eq 0) { return }
    $paths = @($script:remoteTokenPath, $script:remoteHelperPath) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    if ($paths.Count -eq 0) { return }
    $quoted = ($paths | ForEach-Object { "'$_'" }) -join ' '
    [void](Invoke-SshText "sudo -n rm -f -- $quoted")
}

function New-SelfTestRemoteResult([string] $Mode) {
    $cachedOperation = [pscustomobject]@{
        name = 'cachedHead'; status = 200; requestId = 'self-cached-head'
        cacheHit = $true; remoteStorageStarted = $false; sizeBytes = 0
        expectedSizeBytes = 18619182
        events = @([pscustomobject]@{
            level = 30; event = 'CACHE_HIT'; requestId = 'self-cached-head'
        })
    }
    $rangeOperation = [pscustomobject]@{
        name = 'cachedRange'; status = 206; requestId = 'self-cached-range'
        cacheHit = $true; remoteStorageStarted = $false; sizeBytes = 1024
        expectedSizeBytes = 18619182
        contentRange = 'bytes 0-1023/18619182'
        events = @([pscustomobject]@{
            level = 30; event = 'CACHE_HIT'; requestId = 'self-cached-range'
        })
    }
    $cachedOperation | Add-Member -NotePropertyName contentLength -NotePropertyValue 18619182
    if ($SelfTestScenario -eq 'CachedMiss') {
        $cachedOperation.cacheHit = $false
    }
    if ($Mode -eq 'preflight') {
        return [pscustomobject]@{
            ok = ($SelfTestScenario -ne 'CachedMiss')
            activeState = 'active'; subState = 'running'
            serviceEnabled = 'disabled'; releaseId = $expectedReleaseId
            listenerCount = 1; publicListenerCount = 0
            shadowHealth = 200; publicHealth = 200
            cachedTrackPresent = $true; uncachedTrackId = 1
            uncachedTrackSize = 28870968
            uncachedTrackSha256 = ('2e' * 32)
            uncachedObjectExists = $false
            partCount = 0; cacheIndexIntegrity = 'ok'
            operations = @($cachedOperation, $rangeOperation)
        }
    }
    if ($Mode -eq 'offline') {
        if ($SelfTestScenario -eq 'ExceptionAfterStop') {
            Fail 'SIMULATED_OFFLINE_EXCEPTION'
        }
        $status = if ($SelfTestScenario -eq 'UncachedUnexpectedSuccess') { 206 } else { 503 }
        $parts = if ($SelfTestScenario -eq 'PartResidual') { 1 } else { 0 }
        return [pscustomobject]@{
            ok = ($status -eq 503 -and $parts -eq 0)
            shadowHealth = 200; publicHealth = 200
            partCount = $parts; cacheIndexIntegrity = 'ok'
            uncachedObjectExists = $false
            operations = @(
                $cachedOperation,
                $rangeOperation,
                [pscustomobject]@{
                    name = 'uncachedOfflineRange'; status = $status
                    requestId = 'self-uncached'; elapsedMs = 20
                    sizeBytes = 0; contentRange = $null
                    remoteStorageStarted = $true
                    events = @([pscustomobject]@{
                        level = 30; event = 'REMOTE_STORAGE_REQUEST_STARTED'
                        requestId = 'self-uncached'
                    })
                }
            )
        }
    }
    if ($Mode -eq 'recovery') {
        $fillCompleted = $SelfTestScenario -ne 'FillMissing'
        $finalHit = $SelfTestScenario -ne 'FinalHitMissing'
        return [pscustomobject]@{
            ok = ($fillCompleted -and $finalHit)
            shadowHealth = 200; publicHealth = 200
            partCount = 0; cacheIndexIntegrity = 'ok'
            operations = @(
                [pscustomobject]@{
                    name = 'recoveryFill'; status = 200
                    requestId = 'self-fill'; sizeBytes = 28870968
                    sizeExact = $true
                    hashExact = $true; fillStarted = $true
                    fillCompleted = $fillCompleted
                    events = @(
                        [pscustomobject]@{
                            level = 30; event = 'CACHE_FILL_STARTED'
                            requestId = 'self-fill'
                        },
                        [pscustomobject]@{
                            level = 30; event = 'CACHE_FILL_COMPLETED'
                            requestId = 'self-fill'
                        }
                    )
                },
                [pscustomobject]@{
                    name = 'finalHit'; status = 206
                    requestId = 'self-final'; cacheHit = $finalHit
                    remoteStorageStarted = $false; sizeBytes = 1024
                    events = @([pscustomobject]@{
                        level = 30; event = 'CACHE_HIT'
                        requestId = 'self-final'
                    })
                }
            )
        }
    }
    Fail "Unknown self-test mode: $Mode"
}

function Invoke-RemoteMode([string] $Mode, [Nullable[int]] $UncachedTrackId) {
    if ($SelfTest) {
        return New-SelfTestRemoteResult $Mode
    }
    $command = @(
        "sudo -n python3 '$($script:remoteHelperPath)'",
        "--mode '$Mode'",
        "--token-file '$($script:remoteTokenPath)'",
        "--cached-track-id '$CachedTrackId'"
    )
    if ($null -ne $UncachedTrackId) {
        $command += "--uncached-track-id '$UncachedTrackId'"
    }
    return Get-LastJson @(Invoke-SshText ($command -join ' '))
}

function Add-RemoteEvidence([object] $Result) {
    foreach ($operation in @($Result.operations)) {
        $record = [ordered]@{
            timestampUtc = Get-UtcIso
            name = $operation.name
            status = $operation.status
            requestId = $operation.requestId
            sizeBytes = $operation.sizeBytes
        }
        foreach ($property in @(
            'cacheHit', 'remoteStorageStarted', 'elapsedMs', 'contentRange',
            'contentLength', 'expectedSizeBytes', 'sizeExact', 'hashExact',
            'fillStarted', 'fillCompleted'
        )) {
            if ($null -ne $operation.PSObject.Properties[$property]) {
                $record[$property] = $operation.$property
            }
        }
        $script:requests.Add([pscustomobject]$record)
        ConvertTo-JsonLine $record |
            Add-Content -LiteralPath $script:requestsPath -Encoding ascii
        foreach ($event in @($operation.events)) {
            $script:events.Add($event)
            ConvertTo-JsonLine $event |
                Add-Content -LiteralPath $script:eventsPath -Encoding ascii
        }
    }
}

function Get-Operation([object] $Result, [string] $Name) {
    return @($Result.operations | Where-Object { $_.name -eq $Name })[0]
}

function Assert-Preflight([object] $State) {
    $failures = [System.Collections.Generic.List[string]]::new()
    if ($State.activeState -ne 'active' -or $State.subState -ne 'running') {
        $failures.Add('shadow is not active/running')
    }
    if ($State.serviceEnabled -ne 'disabled') { $failures.Add('shadow is enabled') }
    if ($State.releaseId -ne $expectedReleaseId) { $failures.Add('release B is not current') }
    if ([int]$State.listenerCount -ne 1 -or [int]$State.publicListenerCount -ne 0) {
        $failures.Add('listener is not unique loopback')
    }
    if ([int]$State.shadowHealth -ne 200) { $failures.Add('shadow health failed') }
    if ([int]$State.publicHealth -ne 200) { $failures.Add('public health failed') }
    if ($State.cachedTrackPresent -ne $true) { $failures.Add('cached track absent') }
    if ($State.uncachedObjectExists -ne $false) { $failures.Add('uncached track is cached') }
    if ([int]$State.partCount -ne 0) { $failures.Add('.part present before stop') }
    if ($State.cacheIndexIntegrity -ne 'ok') { $failures.Add('cache index invalid') }
    foreach ($name in @('cachedHead', 'cachedRange')) {
        $operation = Get-Operation $State $name
        $expectedStatus = if ($name -eq 'cachedHead') { 200 } else { 206 }
        if ([int]$operation.status -ne $expectedStatus -or
            $operation.cacheHit -ne $true -or
            $operation.remoteStorageStarted -ne $false) {
            $failures.Add("$name is not a proven offline-safe HIT")
        }
        if ($name -eq 'cachedHead' -and
            ([int64]$operation.contentLength -ne
             [int64]$operation.expectedSizeBytes -or
             [int]$operation.sizeBytes -ne 0)) {
            $failures.Add('cached HEAD size is incorrect')
        }
        if ($name -eq 'cachedRange' -and
            ([int]$operation.sizeBytes -ne 1024 -or
             $operation.contentRange -ne
             "bytes 0-1023/$($operation.expectedSizeBytes)")) {
            $failures.Add('cached Range size is incorrect')
        }
    }
    if ($failures.Count -gt 0) {
        Fail ("PREFLIGHT_NO_GO: " + ($failures -join '; '))
    }
}

function Assert-Offline([object] $State) {
    $uncached = Get-Operation $State 'uncachedOfflineRange'
    if ([int]$State.shadowHealth -ne 200 -or [int]$State.publicHealth -ne 200) {
        Fail 'OFFLINE_HEALTH_FAILED'
    }
    foreach ($name in @('cachedHead', 'cachedRange')) {
        $operation = Get-Operation $State $name
        if ($operation.cacheHit -ne $true -or
            $operation.remoteStorageStarted -ne $false) {
            Fail "OFFLINE_CACHED_TRACK_FAILED: $name"
        }
        if ($name -eq 'cachedHead' -and
            ([int]$operation.status -ne 200 -or
             [int64]$operation.contentLength -ne
             [int64]$operation.expectedSizeBytes -or
             [int]$operation.sizeBytes -ne 0)) {
            Fail 'OFFLINE_CACHED_HEAD_SIZE_FAILED'
        }
        if ($name -eq 'cachedRange' -and
            ([int]$operation.status -ne 206 -or
             [int]$operation.sizeBytes -ne 1024 -or
             $operation.contentRange -ne
             "bytes 0-1023/$($operation.expectedSizeBytes)")) {
            Fail 'OFFLINE_CACHED_RANGE_SIZE_FAILED'
        }
    }
    if ([int]$uncached.status -ne 503) {
        Fail "UNCACHED_OFFLINE_STATUS_$($uncached.status)"
    }
    if ($uncached.remoteStorageStarted -ne $true) {
        Fail 'UNCACHED_REMOTE_ATTEMPT_NOT_OBSERVED'
    }
    if ($null -ne $uncached.contentRange) {
        Fail 'UNCACHED_PARTIAL_RESPONSE_EXPOSED'
    }
    if ([double]$uncached.elapsedMs -ge 20000) {
        Fail 'UNCACHED_OFFLINE_RESPONSE_NOT_BOUNDED'
    }
    if ([int]$State.partCount -ne 0 -or $State.uncachedObjectExists -ne $false) {
        Fail 'UNCACHED_CACHE_RESIDUE'
    }
    if ($State.cacheIndexIntegrity -ne 'ok') {
        Fail 'CACHE_INDEX_CORRUPT_OFFLINE'
    }
}

function Assert-Recovery([object] $State) {
    $fill = Get-Operation $State 'recoveryFill'
    $hit = Get-Operation $State 'finalHit'
    if ([int]$State.shadowHealth -ne 200 -or [int]$State.publicHealth -ne 200) {
        Fail 'RECOVERY_HEALTH_FAILED'
    }
    if ([int]$fill.status -ne 200 -or
        $fill.fillStarted -ne $true -or $fill.fillCompleted -ne $true -or
        $fill.sizeExact -ne $true -or $fill.hashExact -ne $true) {
        Fail 'RECOVERY_FILL_FAILED'
    }
    if ([int]$State.partCount -ne 0 -or $State.cacheIndexIntegrity -ne 'ok') {
        Fail 'RECOVERY_CACHE_INVALID'
    }
    if ([int]$hit.status -ne 206 -or $hit.cacheHit -ne $true -or
        $hit.remoteStorageStarted -ne $false) {
        Fail 'RECOVERY_FINAL_HIT_FAILED'
    }
}

function Write-Reports {
    $script:summary.sshConnectionsOpened = $script:sshConnectionsOpened
    $script:summary.stopCalls = $script:stopCalls
    $script:summary.startCalls = $script:startCalls
    ConvertTo-JsonLine $script:summary |
        Set-Content -LiteralPath $script:summaryPath -Encoding ascii

    $report = @"
# Phase 6.4B1b - Storage Agent offline qualification

- Verdict: **$($script:summary.verdict)**
- Failure: $($script:summary.failureReason)
- Elevation confirmed: $($script:summary.elevationConfirmed)
- ValidateOnly: $($script:summary.validateOnly)
- Storage Agent: $($script:summary.serviceAgentInitialState) -> stopped=$($script:summary.serviceAgentStopped) -> $($script:summary.serviceAgentFinalState)
- Production API: $($script:summary.productionApiInitialState) -> $($script:summary.productionApiFinalState)
- Downtime: $($script:summary.downtimeSeconds) seconds
- Cached track: $($script:summary.cachedTrackId)
- Uncached track: $($script:summary.uncachedTrackId)
- Cached offline: $($script:summary.cachedOffline)
- Uncached offline: $($script:summary.uncachedOffline)
- Offline HTTP status: $($script:summary.offlineHttpStatus)
- Fill after recovery: $($script:summary.fillAfterRecovery)
- Final HIT: $($script:summary.finalHit)
- Part files: $($script:summary.partFilesBefore) -> $($script:summary.partFilesAfter)
- Public health before/during/after: $($script:summary.publicHealthBefore)/$($script:summary.publicHealthDuring)/$($script:summary.publicHealthAfter)
- Shadow health before/during/after: $($script:summary.shadowHealthBefore)/$($script:summary.shadowHealthDuring)/$($script:summary.shadowHealthAfter)
- serviceEnabled=$($script:summary.serviceEnabled)
- rebootPerformed=false
- publicCutoverPerformed=false
- secretsPrinted=false
"@
    $report | Set-Content -LiteralPath $script:reportPath -Encoding ascii
}

$script:remoteHelperSource = @'
#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import http.client
import json
import os
import secrets
import signal
import socket
import sqlite3
import subprocess
import time
from pathlib import Path

SERVICE = "homespotify-api-shadow.service"
ROOT = Path("/opt/homespotify-api-shadow")
STATE = Path("/var/lib/homespotify-shadow")
DB = STATE / "data/runtime.db"
CACHE = STATE / "cache/audio"
OBJECTS = CACHE / "objects"
INDEX = CACHE / "metadata/cache-index.sqlite"
EXPECTED_RELEASE = "20260729T200813Z-596e4764-f09a54cf"
CACHE_HIT = "CACHE_HIT"
REMOTE_STARTED = "REMOTE_STORAGE_REQUEST_STARTED"
FILL_STARTED = "CACHE_FILL_STARTED"
FILL_COMPLETED = "CACHE_FILL_COMPLETED"


def run(args: list[str], timeout: int = 30) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        args, capture_output=True, text=True, timeout=timeout, check=False
    )


def token_from(path: str) -> str:
    return Path(path).read_text(encoding="utf-8").strip()


def request(
    method: str,
    path: str,
    token: str = "",
    range_value: str | None = None,
    timeout: int = 25,
) -> dict:
    request_id = f"phase64b1b-{secrets.token_hex(8)}"
    headers = {"X-Request-Id": request_id}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    if range_value:
        headers["Range"] = range_value
    connection = http.client.HTTPConnection("127.0.0.1", 3002, timeout=timeout)
    started = time.perf_counter()
    try:
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
        return {
            "status": response.status,
            "sizeBytes": size,
            "sha256": digest.hexdigest(),
            "contentRange": response.getheader("Content-Range"),
            "contentLength": response.getheader("Content-Length"),
            "requestId": request_id,
            "elapsedMs": round((time.perf_counter() - started) * 1000, 1),
        }
    finally:
        connection.close()


def journal_events(request_id: str, attempts: int = 30) -> list[dict]:
    for attempt in range(attempts):
        result = run(
            ["journalctl", "-u", SERVICE, "-n", "2500", "-o", "cat", "--no-pager"],
            timeout=20,
        )
        events = []
        for line in result.stdout.splitlines():
            start = line.find("{")
            if start < 0:
                continue
            try:
                record = json.loads(line[start:])
            except ValueError:
                continue
            if not isinstance(record, dict) or record.get("requestId") != request_id:
                continue
            name = record.get("event")
            if isinstance(name, str):
                events.append({
                    "level": record.get("level", 30),
                    "event": name,
                    "requestId": request_id,
                })
        names = {event["event"] for event in events}
        if names & {CACHE_HIT, REMOTE_STARTED, FILL_COMPLETED}:
            return events
        if attempt < attempts - 1:
            time.sleep(0.25)
    return []


def track(track_id: int) -> dict:
    with sqlite3.connect(f"file:{DB}?mode=ro", uri=True) as database:
        row = database.execute(
            "SELECT id, size_bytes, hash FROM tracks WHERE id = ?", (track_id,)
        ).fetchone()
    if row is None:
        raise RuntimeError(f"track {track_id} absent")
    return {"id": row[0], "sizeBytes": row[1], "sha256": row[2]}


def object_path(item: dict) -> Path:
    return OBJECTS / item["sha256"][:2] / f'{item["sha256"]}.audio'


def select_uncached(cached_track_id: int) -> dict:
    with sqlite3.connect(f"file:{DB}?mode=ro", uri=True) as database:
        rows = database.execute(
            "SELECT id, size_bytes, hash FROM tracks WHERE id <> ? ORDER BY id",
            (cached_track_id,),
        ).fetchall()
    for row in rows:
        item = {"id": row[0], "sizeBytes": row[1], "sha256": row[2]}
        if not object_path(item).exists():
            return item
    raise RuntimeError("no genuinely uncached track available")


def parts() -> int:
    return sum(1 for path in CACHE.rglob("*.part") if path.is_file())


def index_integrity() -> str:
    if not INDEX.is_file():
        return "missing"
    try:
        with sqlite3.connect(f"file:{INDEX}?mode=ro", uri=True) as database:
            return str(database.execute("PRAGMA integrity_check").fetchone()[0])
    except sqlite3.Error:
        return "error"


def health() -> int:
    try:
        connection = http.client.HTTPConnection("127.0.0.1", 3002, timeout=5)
        connection.request("GET", "/health")
        response = connection.getresponse()
        response.read()
        connection.close()
        return response.status
    except OSError:
        return 0


def public_health() -> int:
    try:
        context = __import__("ssl").create_default_context()
        connection = http.client.HTTPSConnection(
            "music.romainbegot.fr", 443, timeout=10, context=context
        )
        connection.request("GET", "/health")
        response = connection.getresponse()
        response.read()
        connection.close()
        return response.status
    except OSError:
        return 0


def system_state() -> dict:
    active = run(["systemctl", "show", SERVICE, "-p", "ActiveState", "--value"])
    sub = run(["systemctl", "show", SERVICE, "-p", "SubState", "--value"])
    enabled = run(["systemctl", "is-enabled", SERVICE])
    listeners = run(["ss", "-H", "-ltn", "sport = :3002"])
    lines = [line for line in listeners.stdout.splitlines() if line.strip()]
    loopback = [line for line in lines if "127.0.0.1:3002" in line]
    return {
        "activeState": active.stdout.strip(),
        "subState": sub.stdout.strip(),
        "serviceEnabled": enabled.stdout.strip(),
        "releaseId": Path(os.path.realpath(ROOT / "current")).name,
        "listenerCount": len(lines),
        "publicListenerCount": len(lines) - len(loopback),
    }


def cached_operations(token: str, cached: dict) -> list[dict]:
    stream = f'/api/tracks/{cached["id"]}/stream'
    head = request("HEAD", stream, token)
    head_events = journal_events(head["requestId"])
    ranged = request("GET", stream, token, "bytes=0-1023")
    range_events = journal_events(ranged["requestId"])

    def evidence(name: str, result: dict, events: list[dict]) -> dict:
        names = {event["event"] for event in events}
        return {
            "name": name,
            **result,
            "expectedSizeBytes": cached["sizeBytes"],
            "cacheHit": CACHE_HIT in names,
            "remoteStorageStarted": REMOTE_STARTED in names,
            "events": events,
        }

    return [
        evidence("cachedHead", head, head_events),
        evidence("cachedRange", ranged, range_events),
    ]


def preflight(args: argparse.Namespace, token: str) -> dict:
    cached = track(args.cached_track_id)
    uncached = select_uncached(args.cached_track_id)
    operations = cached_operations(token, cached)
    state = system_state()
    state.update({
        "ok": True,
        "shadowHealth": health(),
        "publicHealth": public_health(),
        "cachedTrackPresent": object_path(cached).is_file(),
        "uncachedTrackId": uncached["id"],
        "uncachedTrackSize": uncached["sizeBytes"],
        "uncachedTrackSha256": uncached["sha256"],
        "uncachedObjectExists": object_path(uncached).exists(),
        "partCount": parts(),
        "cacheIndexIntegrity": index_integrity(),
        "operations": operations,
    })
    return state


def offline(args: argparse.Namespace, token: str) -> dict:
    cached = track(args.cached_track_id)
    uncached = track(args.uncached_track_id)
    operations = cached_operations(token, cached)
    result = request(
        "GET",
        f'/api/tracks/{uncached["id"]}/stream',
        token,
        "bytes=0-1023",
        timeout=20,
    )
    events = journal_events(result["requestId"])
    names = {event["event"] for event in events}
    operations.append({
        "name": "uncachedOfflineRange",
        **result,
        "remoteStorageStarted": REMOTE_STARTED in names,
        "events": events,
    })
    cleanup_deadline = time.monotonic() + 5
    while parts() and time.monotonic() < cleanup_deadline:
        time.sleep(0.25)
    return {
        "ok": True,
        "shadowHealth": health(),
        "publicHealth": public_health(),
        "uncachedObjectExists": object_path(uncached).exists(),
        "partCount": parts(),
        "cacheIndexIntegrity": index_integrity(),
        "operations": operations,
    }


def recovery(args: argparse.Namespace, token: str) -> dict:
    uncached = track(args.uncached_track_id)
    stream = f'/api/tracks/{uncached["id"]}/stream'
    filled = request("GET", stream, token, timeout=60)
    fill_events = []
    for _ in range(60):
        fill_events = journal_events(filled["requestId"], attempts=1)
        if FILL_COMPLETED in {event["event"] for event in fill_events}:
            break
        time.sleep(0.25)
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        if object_path(uncached).is_file() and (
            object_path(uncached).stat().st_size == uncached["sizeBytes"]
        ):
            break
        time.sleep(0.25)
    fill_names = {event["event"] for event in fill_events}
    final = request("GET", stream, token, "bytes=0-1023")
    final_events = journal_events(final["requestId"])
    final_names = {event["event"] for event in final_events}
    operations = [
        {
            "name": "recoveryFill",
            **filled,
            "sizeExact": filled["sizeBytes"] == uncached["sizeBytes"],
            "hashExact": filled["sha256"] == uncached["sha256"],
            "fillStarted": FILL_STARTED in fill_names,
            "fillCompleted": FILL_COMPLETED in fill_names,
            "events": fill_events,
        },
        {
            "name": "finalHit",
            **final,
            "cacheHit": CACHE_HIT in final_names,
            "remoteStorageStarted": REMOTE_STARTED in final_names,
            "events": final_events,
        },
    ]
    return {
        "ok": True,
        "shadowHealth": health(),
        "publicHealth": public_health(),
        "partCount": parts(),
        "cacheIndexIntegrity": index_integrity(),
        "operations": operations,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", choices=("preflight", "offline", "recovery"), required=True)
    parser.add_argument("--token-file", required=True)
    parser.add_argument("--cached-track-id", type=int, required=True)
    parser.add_argument("--uncached-track-id", type=int)
    args = parser.parse_args()
    token = token_from(args.token_file)
    if args.mode == "preflight":
        result = preflight(args, token)
    elif args.mode == "offline":
        def offline_timeout(_signum, _frame):
            raise TimeoutError("offline helper exceeded 35 seconds")

        signal.signal(signal.SIGALRM, offline_timeout)
        signal.alarm(35)
        try:
            result = offline(args, token)
        finally:
            signal.alarm(0)
    else:
        result = recovery(args, token)
    print(json.dumps(result, separators=(",", ":")))


if __name__ == "__main__":
    main()
'@

$exitCode = 1

if (-not (Test-IsAdministrator)) {
    $script:summary.verdict = 'ELEVATION_REQUIRED'
    $script:summary.failureReason =
        'Run this owner script from an explicitly elevated PowerShell console.'
    ConvertTo-JsonLine $script:summary
    exit 2
}

Initialize-OutputFiles
$script:summary.elevationConfirmed = $true

try {
    Assert-LocalArguments

    $script:summary.serviceAgentInitialState =
        Get-ServiceState $expectedStorageAgentService
    $script:summary.productionApiInitialState =
        Get-ServiceState $expectedProductionApiService
    if ($script:summary.serviceAgentInitialState -ne 'Running') {
        Fail 'Storage Agent is not Running.'
    }
    if ($script:summary.productionApiInitialState -ne 'Running') {
        Fail 'Production API is not Running.'
    }

    if (-not $SelfTest) {
        [void](Invoke-SshText "printf '{`"ok`":true}`n'")
    }
    Install-RemoteHelper
    $preflight = Invoke-RemoteMode 'preflight' $null
    Add-RemoteEvidence $preflight
    Assert-Preflight $preflight
    $script:summary.uncachedTrackId = [int]$preflight.uncachedTrackId
    $script:summary.partFilesBefore = [int]$preflight.partCount
    $script:summary.publicHealthBefore = [int]$preflight.publicHealth
    $script:summary.shadowHealthBefore = [int]$preflight.shadowHealth

    if ($ValidateOnly) {
        $script:summary.verdict = 'GO_VALIDATE_ONLY'
        $script:summary.serviceAgentFinalState =
            Get-ServiceState $expectedStorageAgentService
        $script:summary.productionApiFinalState =
            Get-ServiceState $expectedProductionApiService
        $script:summary.publicHealthAfter = [int]$preflight.publicHealth
        $script:summary.shadowHealthAfter = [int]$preflight.shadowHealth
        $script:summary.partFilesAfter = [int]$preflight.partCount
        $exitCode = 0
        throw [OperationCanceledException]::new('VALIDATE_ONLY_COMPLETE')
    }

    try {
        Stop-StorageAgent
        if ((Get-ServiceState $expectedStorageAgentService) -ne 'Stopped') {
            Fail 'Storage Agent did not reach Stopped.'
        }
        $script:summary.serviceAgentStopped = $true
        $script:downtimeWatch = [Diagnostics.Stopwatch]::StartNew()
        if ((Get-ServiceState $expectedProductionApiService) -ne 'Running') {
            Fail 'Production API stopped unexpectedly.'
        }
        Assert-DowntimeBudget 45
        $offline = Invoke-RemoteMode 'offline' $script:summary.uncachedTrackId
        Add-RemoteEvidence $offline
        if ((Get-ServiceState $expectedProductionApiService) -ne 'Running') {
            Fail 'Production API stopped during offline qualification.'
        }
        $script:summary.publicHealthDuring = [int]$offline.publicHealth
        $script:summary.shadowHealthDuring = [int]$offline.shadowHealth
        $offlineUncached = Get-Operation $offline 'uncachedOfflineRange'
        $script:summary.offlineHttpStatus = [int]$offlineUncached.status
        Assert-Offline $offline
        $script:summary.cachedOffline = $true
        $script:summary.uncachedOffline = $true
    } finally {
        if ($script:agentWasStopped -or
            (Get-ServiceState $expectedStorageAgentService) -ne 'Running') {
            try {
                $finalAgentState = Start-StorageAgentBounded
                $script:summary.serviceAgentFinalState = $finalAgentState
            } catch {
                $script:summary.serviceAgentFinalState =
                    Get-ServiceState $expectedStorageAgentService
                $script:summary.failureReason =
                    "CRITICAL: $($_.Exception.Message)"
                throw
            } finally {
                if ($null -ne $script:downtimeWatch) {
                    $script:downtimeWatch.Stop()
                    $script:summary.downtimeSeconds = [Math]::Round(
                        $script:downtimeWatch.Elapsed.TotalSeconds, 3
                    )
                }
            }
        }
    }

    if ($script:summary.serviceAgentFinalState -ne 'Running') {
        Fail 'CRITICAL: Storage Agent is not Running after finally.'
    }
    if ($script:summary.downtimeSeconds -ge $MaxAgentDowntimeSeconds) {
        Fail 'Storage Agent downtime reached the configured limit.'
    }
    if ((Get-ServiceState $expectedProductionApiService) -ne 'Running') {
        Fail 'Production API is not Running after recovery.'
    }

    $recovery = Invoke-RemoteMode 'recovery' $script:summary.uncachedTrackId
    Add-RemoteEvidence $recovery
    Assert-Recovery $recovery
    $script:summary.fillAfterRecovery = $true
    $script:summary.finalHit = $true
    $script:summary.partFilesAfter = [int]$recovery.partCount
    $script:summary.publicHealthAfter = [int]$recovery.publicHealth
    $script:summary.shadowHealthAfter = [int]$recovery.shadowHealth
    $script:summary.productionApiFinalState =
        Get-ServiceState $expectedProductionApiService
    $script:summary.verdict = 'GO'
    $exitCode = 0
} catch {
    if ($script:summary.verdict -eq 'GO_VALIDATE_ONLY') {
        $exitCode = 0
    } elseif ($script:summary.verdict -eq 'INCOMPLETE') {
        $script:summary.verdict = 'NO_GO'
        if ([string]::IsNullOrWhiteSpace("$($script:summary.failureReason)")) {
            $script:summary.failureReason = $_.Exception.Message
        }
        try {
            $script:summary.serviceAgentFinalState =
                Get-ServiceState $expectedStorageAgentService
            $script:summary.productionApiFinalState =
                Get-ServiceState $expectedProductionApiService
        } catch {
            $script:summary.failureReason += '; final Windows service state unreadable'
        }
        $exitCode = 1
    }
} finally {
    try {
        Remove-RemoteHelper
    } catch {
        if ($script:summary.verdict -in @('GO', 'GO_VALIDATE_ONLY')) {
            $script:summary.verdict = 'NO_GO'
            $exitCode = 1
        }
        $script:summary.failureReason =
            "$($script:summary.failureReason); remote cleanup failed"
    }
    Write-Reports
}

ConvertTo-JsonLine $script:summary
exit $exitCode
