<#
.SYNOPSIS
    Déploie de façon coordonnée l'artefact Phase 4 du Storage Agent.

.DESCRIPTION
    À exécuter dans une console PowerShell élevée. Le script :
      - ne lit et n'affiche jamais le contenu de agent.env ;
      - sauvegarde l'artefact installé, le XML WinSW et uniquement les
        métadonnées/ACL de agent.env ;
      - ne redémarre que HomeSpotifyStorageAgent ;
      - conserve HomeSpotifyApi et vérifie que son PID ne change pas ;
      - prépare l'artefact suivant avant l'arrêt puis permute les répertoires
        sur le même volume ;
      - restaure automatiquement l'ancien artefact si la nouvelle instance
        n'est pas saine.

    Le mode -RollbackFrom restaure exactement le dossier app d'une sauvegarde
    Phase 4.5 et ne touche à aucun autre service.
#>
[CmdletBinding(DefaultParameterSetName = 'Deploy')]
param(
    [Parameter(ParameterSetName = 'Deploy')]
    [string] $ArtifactPath = 'F:\dev\homespotify\storage\phase45-artifact',

    [Parameter(ParameterSetName = 'Rollback', Mandatory = $true)]
    [string] $RollbackFrom,

    [string] $Root = 'C:\ProgramData\HomeSpotify\StorageAgent',
    [string] $ServiceName = 'HomeSpotifyStorageAgent',
    [string] $PublicHealthUrl = 'https://music.romainbegot.fr/health'
)

$ErrorActionPreference = 'Stop'

function Step { param([string] $Message) Write-Host "[phase45] $Message" }
function Fail { param([string] $Message) throw $Message }

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Fail 'console non élevée : aucune modification effectuée'
    }
}

function Resolve-ChildPath {
    param([string] $Candidate, [string] $ExpectedParent)
    $resolvedParent = [IO.Path]::GetFullPath($ExpectedParent).TrimEnd('\')
    $resolved = [IO.Path]::GetFullPath($Candidate).TrimEnd('\')
    if (-not $resolved.StartsWith("$resolvedParent\", [StringComparison]::OrdinalIgnoreCase)) {
        Fail "chemin hors périmètre refusé : $resolved"
    }
    return $resolved
}

function Get-ServiceRecord {
    param([string] $Name)
    $record = Get-CimInstance Win32_Service -Filter "Name='$Name'"
    if (-not $record) { Fail "service absent : $Name" }
    return $record
}

function Wait-ServiceState {
    param([string] $Name, [string] $Expected, [int] $TimeoutSeconds = 45)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $service = Get-Service -Name $Name
        if ($service.Status.ToString() -eq $Expected) { return }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)
    Fail "service $Name non $Expected après ${TimeoutSeconds}s"
}

function Get-PublicHealthStatus {
    $response = Invoke-WebRequest -Uri $PublicHealthUrl -UseBasicParsing -TimeoutSec 20
    return [int] $response.StatusCode
}

function Assert-AgentHealthy {
    param([datetime] $StartedAfter)

    $deadline = (Get-Date).AddSeconds(45)
    do {
        $service = Get-ServiceRecord $ServiceName
        if ($service.StartName -ne "NT SERVICE\$ServiceName") {
            Fail "identité agent incorrecte : $($service.StartName)"
        }

        $listeners = @(Get-NetTCPConnection -State Listen |
            Where-Object LocalPort -eq 3100 |
            Select-Object LocalAddress, LocalPort, OwningProcess)
        $listenerValid = $listeners.Count -eq 1 -and $listeners[0].LocalAddress -eq '10.8.0.2'

        $logFiles = @(Get-ChildItem -LiteralPath (Join-Path $Root 'logs') -File |
            Where-Object LastWriteTime -ge $StartedAfter.AddSeconds(-5))
        $indexLoaded = $false
        $listening = $false
        $entryCount = $null
        foreach ($logFile in $logFiles) {
            foreach ($line in Get-Content -LiteralPath $logFile.FullName -ErrorAction SilentlyContinue) {
                if ($line -match 'STORAGE_AGENT_INDEX_LOADED') {
                    $indexLoaded = $true
                    if ($line -match '"entryCount"\s*:\s*(\d+)') {
                        $entryCount = [int] $Matches[1]
                    }
                }
                if ($line -match 'Server listening at http://10\.8\.0\.2:3100') {
                    $listening = $true
                }
            }
        }

        if ($service.State -eq 'Running' -and $listenerValid -and $indexLoaded -and $listening) {
            return [pscustomobject]@{
                ServicePid = [int] $service.ProcessId
                ListenerPid = [int] $listeners[0].OwningProcess
                IndexEntryCount = $entryCount
            }
        }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)

    Fail 'agent non sain après 45 s (service, listener ou événements de démarrage)'
}

function Start-AgentOrFail {
    Start-Service -Name $ServiceName
    Wait-ServiceState -Name $ServiceName -Expected 'Running'
}

Assert-Administrator

$resolvedRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\')
$appPath = Resolve-ChildPath -Candidate (Join-Path $resolvedRoot 'app') -ExpectedParent $resolvedRoot

if ($PSCmdlet.ParameterSetName -eq 'Rollback') {
    $backupBase = Resolve-ChildPath -Candidate $RollbackFrom -ExpectedParent (Join-Path $resolvedRoot 'backup')
    $backupApp = Resolve-ChildPath -Candidate (Join-Path $backupBase 'app') -ExpectedParent $backupBase
    if (-not (Test-Path -LiteralPath (Join-Path $backupApp 'dist\main.js'))) {
        Fail 'sauvegarde de rollback invalide : dist\main.js absent'
    }

    $failedPath = Resolve-ChildPath `
        -Candidate (Join-Path $resolvedRoot "app.phase45-rollback-replaced-$(Get-Date -Format 'yyyyMMdd-HHmmss')") `
        -ExpectedParent $resolvedRoot
    Step 'arrêt du seul service HomeSpotifyStorageAgent'
    Stop-Service -Name $ServiceName
    Wait-ServiceState -Name $ServiceName -Expected 'Stopped'
    Rename-Item -LiteralPath $appPath -NewName ([IO.Path]::GetFileName($failedPath))
    Copy-Item -LiteralPath $backupApp -Destination $appPath -Recurse
    try {
        Start-AgentOrFail
        $health = Assert-AgentHealthy -StartedAfter (Get-Date).AddSeconds(-10)
        Step "rollback sain : PID service $($health.ServicePid), index $($health.IndexEntryCount)"
    } catch {
        Step "ÉCHEC du rollback : $($_.Exception.Message)"
        throw
    }
    exit 0
}

$resolvedArtifact = [IO.Path]::GetFullPath($ArtifactPath).TrimEnd('\')
if (-not (Test-Path -LiteralPath (Join-Path $resolvedArtifact 'dist\main.js'))) {
    Fail 'artefact Phase 4.5 invalide : dist\main.js absent'
}
if (-not (Test-Path -LiteralPath (Join-Path $resolvedArtifact 'node_modules\fastify'))) {
    Fail 'artefact Phase 4.5 invalide : dépendances de production absentes'
}
$links = @(Get-ChildItem -LiteralPath $resolvedArtifact -Recurse -Force |
    Where-Object LinkType)
if ($links.Count -ne 0) { Fail "$($links.Count) lien(s) détecté(s) dans l'artefact autonome" }

$apiBefore = Get-ServiceRecord 'HomeSpotifyApi'
$wireGuard = Get-ServiceRecord 'WireGuardTunnel$HomeSpotify-VPS'
$agentBefore = Get-ServiceRecord $ServiceName
if ($apiBefore.State -ne 'Running') { Fail 'HomeSpotifyApi non Running' }
if ($wireGuard.State -ne 'Running') { Fail 'WireGuard non Running' }
if ($agentBefore.State -ne 'Running') { Fail 'Storage Agent non Running avant déploiement' }
if ((Get-PublicHealthStatus) -ne 200) { Fail 'domaine public non sain avant déploiement' }

$beforeListeners = @(Get-NetTCPConnection -State Listen | Where-Object LocalPort -eq 3100)
if ($beforeListeners.Count -ne 1 -or $beforeListeners[0].LocalAddress -ne '10.8.0.2') {
    Fail 'listener 3100 non conforme avant déploiement'
}

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backupRoot = Resolve-ChildPath `
    -Candidate (Join-Path $resolvedRoot "backup\phase45-$timestamp") `
    -ExpectedParent (Join-Path $resolvedRoot 'backup')
$nextPath = Resolve-ChildPath `
    -Candidate (Join-Path $resolvedRoot "app.phase45-next-$timestamp") `
    -ExpectedParent $resolvedRoot
$previousPath = Resolve-ChildPath `
    -Candidate (Join-Path $resolvedRoot "app.phase45-previous-$timestamp") `
    -ExpectedParent $resolvedRoot
$failedPath = Resolve-ChildPath `
    -Candidate (Join-Path $resolvedRoot "app.phase45-failed-$timestamp") `
    -ExpectedParent $resolvedRoot

New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null

Step "sauvegarde de l'artefact installé dans $backupRoot"
Copy-Item -LiteralPath $appPath -Destination (Join-Path $backupRoot 'app') -Recurse
Copy-Item -LiteralPath (Join-Path $resolvedRoot 'service\HomeSpotifyStorageAgent.xml') `
    -Destination (Join-Path $backupRoot 'HomeSpotifyStorageAgent.xml')

$envPath = Join-Path $resolvedRoot 'config\agent.env'
$envItem = Get-Item -LiteralPath $envPath
$envAcl = Get-Acl -LiteralPath $envPath
[pscustomobject]@{
    CapturedAt = (Get-Date).ToString('o')
    Length = $envItem.Length
    CreationTimeUtc = $envItem.CreationTimeUtc.ToString('o')
    LastWriteTimeUtc = $envItem.LastWriteTimeUtc.ToString('o')
    Owner = $envAcl.Owner
    Sddl = $envAcl.Sddl
    AccessRulesProtected = $envAcl.AreAccessRulesProtected
} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $backupRoot 'agent-env-metadata-acl.json') -Encoding UTF8

$indexPath = Join-Path $resolvedRoot 'data\index.json'
$indexItem = Get-Item -LiteralPath $indexPath
[pscustomobject]@{
    CapturedAt = (Get-Date).ToString('o')
    Length = $indexItem.Length
    LastWriteTimeUtc = $indexItem.LastWriteTimeUtc.ToString('o')
    Sha256 = (Get-FileHash -LiteralPath $indexPath -Algorithm SHA256).Hash
} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $backupRoot 'index-metadata.json') -Encoding UTF8

[pscustomobject]@{
    CapturedAt = (Get-Date).ToString('o')
    HomeSpotifyApi = @{
        State = $apiBefore.State
        ProcessId = [int] $apiBefore.ProcessId
        StartName = $apiBefore.StartName
    }
    WireGuard = @{
        State = $wireGuard.State
        ProcessId = [int] $wireGuard.ProcessId
    }
    StorageAgent = @{
        State = $agentBefore.State
        ProcessId = [int] $agentBefore.ProcessId
        StartName = $agentBefore.StartName
    }
    Listener3100 = @($beforeListeners | Select-Object LocalAddress, LocalPort, OwningProcess)
    InstalledServerSha256 = (Get-FileHash -LiteralPath (Join-Path $appPath 'dist\server.js') -Algorithm SHA256).Hash
    CandidateServerSha256 = (Get-FileHash -LiteralPath (Join-Path $resolvedArtifact 'dist\server.js') -Algorithm SHA256).Hash
} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $backupRoot 'pre-deployment-state.json') -Encoding UTF8

Step 'préparation de app.next avant interruption'
Copy-Item -LiteralPath $resolvedArtifact -Destination $nextPath -Recurse

$stopped = $false
$swapped = $false
$startedAt = Get-Date
try {
    Step 'arrêt du seul service HomeSpotifyStorageAgent'
    Stop-Service -Name $ServiceName
    Wait-ServiceState -Name $ServiceName -Expected 'Stopped'
    $stopped = $true

    Rename-Item -LiteralPath $appPath -NewName ([IO.Path]::GetFileName($previousPath))
    Rename-Item -LiteralPath $nextPath -NewName 'app'
    $swapped = $true

    Step 'démarrage du seul service HomeSpotifyStorageAgent'
    $startedAt = Get-Date
    Start-AgentOrFail
    $agentHealth = Assert-AgentHealthy -StartedAfter $startedAt

    $apiAfter = Get-ServiceRecord 'HomeSpotifyApi'
    if ($apiAfter.State -ne 'Running' -or $apiAfter.ProcessId -ne $apiBefore.ProcessId) {
        Fail "HomeSpotifyApi a changé : $($apiBefore.ProcessId) -> $($apiAfter.ProcessId)"
    }
    if ((Get-PublicHealthStatus) -ne 200) { Fail 'domaine public non sain après déploiement' }

    $liveHash = (Get-FileHash -LiteralPath (Join-Path $appPath 'dist\server.js') -Algorithm SHA256).Hash
    $candidateHash = (Get-FileHash -LiteralPath (Join-Path $resolvedArtifact 'dist\server.js') -Algorithm SHA256).Hash
    if ($liveHash -ne $candidateHash) { Fail 'hash de l’artefact actif différent du candidat' }

    [pscustomobject]@{
        CompletedAt = (Get-Date).ToString('o')
        BackupPath = $backupRoot
        PreviousAppPath = $previousPath
        ServerSha256 = $liveHash
        ServicePid = $agentHealth.ServicePid
        ListenerPid = $agentHealth.ListenerPid
        IndexEntryCount = $agentHealth.IndexEntryCount
        HomeSpotifyApiPidUnchanged = $true
        PublicHealthStatus = 200
        RollbackCommand = ".\scripts\deploy_storage_agent_phase45.ps1 -RollbackFrom '$backupRoot'"
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $backupRoot 'deployment-result.json') -Encoding UTF8

    Step "déploiement sain ; sauvegarde/rollback : $backupRoot"
    Step "agent PID $($agentHealth.ServicePid), listener PID $($agentHealth.ListenerPid), index $($agentHealth.IndexEntryCount)"
} catch {
    $failure = $_.Exception.Message
    Step "échec après arrêt : $failure"
    if ($stopped) {
        try {
            Stop-Service -Name $ServiceName -ErrorAction SilentlyContinue
            if ($swapped -and (Test-Path -LiteralPath $appPath)) {
                Rename-Item -LiteralPath $appPath -NewName ([IO.Path]::GetFileName($failedPath))
            }
            if (Test-Path -LiteralPath $previousPath) {
                Rename-Item -LiteralPath $previousPath -NewName 'app'
            }
            Start-AgentOrFail
            $rollbackHealth = Assert-AgentHealthy -StartedAfter (Get-Date).AddSeconds(-10)
            Step "rollback automatique sain : PID $($rollbackHealth.ServicePid)"
        } catch {
            Step "ÉCHEC CRITIQUE DU ROLLBACK : $($_.Exception.Message)"
        }
    }
    throw
}
