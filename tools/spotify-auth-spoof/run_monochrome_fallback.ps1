[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$JobId,

    [string]$ApiBaseUrl = $env:HOMESPOTIFY_API_BASE_URL,

    [switch]$DryRunMonochrome
)

$ErrorActionPreference = 'Stop'
$parsedJobId = [Guid]::Empty
if (
    -not [Guid]::TryParseExact(
        $JobId,
        'D',
        [ref]$parsedJobId
    )
) {
    throw 'JobId doit être un UUID canonique valide.'
}
$JobId = $parsedJobId.ToString('D')

$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$apiRoot = Join-Path $projectRoot 'services\api'
$envPath = Join-Path $apiRoot '.env'
$pythonScript = Join-Path $PSScriptRoot 'monochrome_fallback.py'
$script:childProcess = $null
$script:terminalCode = $null
$script:sawSuccess = $false
$script:reportedResult = $null
$holderReserved = $false
$ownsStaging = $false
$token = $null

function Read-AllowedEnvValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )
    if (-not (Test-Path -LiteralPath $envPath -PathType Leaf)) {
        return $null
    }
    foreach ($line in Get-Content -LiteralPath $envPath -Encoding UTF8) {
        if ($line -match "^\s*$([regex]::Escape($Name))\s*=\s*(.*)\s*$") {
            return $Matches[1].Trim().Trim('"').Trim("'")
        }
    }
    return $null
}

function Resolve-ProjectPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )
    if ([IO.Path]::IsPathRooted($Value)) {
        return [IO.Path]::GetFullPath($Value)
    }
    return [IO.Path]::GetFullPath((Join-Path $apiRoot $Value))
}

function Read-MaskedToken {
    $secure = Read-Host `
        'Collez un jeton API OWNER HomeSpotify (saisie masquée)' `
        -AsSecureString
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
    }
}

function Send-MonochromeResult {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Result
    )
    $payload = @{ result = $Result } | ConvertTo-Json -Compress
    Invoke-RestMethod `
        -Method Post `
        -Uri "$ApiBaseUrl/api/imports/jobs/$JobId/monochrome-manual-result" `
        -Headers $headers `
        -ContentType 'application/json' `
        -Body $payload | Out-Null
    $script:reportedResult = $Result
}

if ([string]::IsNullOrWhiteSpace($ApiBaseUrl)) {
    $ApiBaseUrl = 'http://127.0.0.1:3000'
}
$ApiBaseUrl = $ApiBaseUrl.TrimEnd('/')
if (-not (Test-Path -LiteralPath $pythonScript -PathType Leaf)) {
    throw "Script Monochrome introuvable : $pythonScript"
}

$pythonValue = Read-AllowedEnvValue -Name 'LUCIDA_PYTHON_PATH'
if ([string]::IsNullOrWhiteSpace($pythonValue)) {
    $pythonValue = 'python'
}
$baseUrl = Read-AllowedEnvValue -Name 'MONOCHROME_BASE_URL'
if ([string]::IsNullOrWhiteSpace($baseUrl)) {
    $baseUrl = 'https://monochrome.tf/'
}
$downloadDirectory = Read-AllowedEnvValue `
    -Name 'MONOCHROME_DOWNLOAD_DIRECTORY'
if ([string]::IsNullOrWhiteSpace($downloadDirectory)) {
    throw 'MONOCHROME_DOWNLOAD_DIRECTORY doit être configuré dans services/api/.env.'
}
$downloadDirectory = [IO.Path]::GetFullPath($downloadDirectory)
if (-not (Test-Path -LiteralPath $downloadDirectory -PathType Container)) {
    throw 'Le dossier Downloads Monochrome configuré est introuvable.'
}
$stabilitySeconds = Read-AllowedEnvValue `
    -Name 'MONOCHROME_FILE_STABILITY_SECONDS'
if ([string]::IsNullOrWhiteSpace($stabilitySeconds)) {
    $stabilitySeconds = '3'
}
$importRootValue = Read-AllowedEnvValue -Name 'HOMESPOTIFY_IMPORT_ROOT'
if ([string]::IsNullOrWhiteSpace($importRootValue)) {
    $importRootValue = '../../storage/imports'
}
$importRoot = Resolve-ProjectPath -Value $importRootValue
$stagingRootName = if ($DryRunMonochrome) {
    '.monochrome-diagnostics'
}
else {
    '.monochrome'
}
$stagingRoot = [IO.Path]::GetFullPath(
    (Join-Path $importRoot $stagingRootName)
)
$outputDirectory = [IO.Path]::GetFullPath(
    (Join-Path $stagingRoot $JobId)
)
$requiredPrefix = $stagingRoot.TrimEnd('\') + '\'
if (
    -not $outputDirectory.StartsWith(
        $requiredPrefix,
        [StringComparison]::OrdinalIgnoreCase
    )
) {
    throw 'Le dossier de staging Monochrome calculé est invalide.'
}

$token = Read-MaskedToken
if ([string]::IsNullOrWhiteSpace($token)) {
    throw 'Jeton API vide.'
}
$headers = @{ Authorization = "Bearer $token" }

try {
    $context = Invoke-RestMethod `
        -Method Get `
        -Uri "$ApiBaseUrl/api/imports/jobs/$JobId/monochrome-manual" `
        -Headers $headers
    $holderReserved = $true
    if (
        $context.jobId -ne $JobId -or
        [string]::IsNullOrWhiteSpace([string]$context.target.title) -or
        [string]::IsNullOrWhiteSpace([string]$context.target.artist)
    ) {
        throw 'Le backend a retourné une cible Monochrome invalide.'
    }

    if (Test-Path -LiteralPath $outputDirectory) {
        if (@(Get-ChildItem -LiteralPath $outputDirectory -Force).Count -gt 0) {
            throw 'Le staging de ce job existe déjà et n’est pas vide.'
        }
    }
    else {
        New-Item -ItemType Directory -Path $outputDirectory | Out-Null
    }
    $ownsStaging = $true
    $sessionStartedAtUtc = [DateTime]::UtcNow.ToString('o')

    Write-Host "Session Monochrome démarrée à $sessionStartedAtUtc UTC."
    Write-Host 'Chromium visible va s’ouvrir.'
    Write-Host 'Le helper remplit uniquement la recherche et met en évidence la correspondance exacte.'
    Write-Host 'Il ne clique jamais sur Download : effectuez vous-même cette action.'

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $pythonValue
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $false
    @(
        $pythonScript,
        '--title',
        [string]$context.target.title,
        '--artist',
        [string]$context.target.artist,
        '--output',
        $outputDirectory,
        '--download-directory',
        $downloadDirectory,
        '--base-url',
        $baseUrl,
        '--timeout',
        [string]$context.timeoutSeconds,
        '--stability-seconds',
        [string]$stabilitySeconds
    ) | ForEach-Object {
        $startInfo.ArgumentList.Add($_)
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$context.target.album)) {
        $startInfo.ArgumentList.Add('--album')
        $startInfo.ArgumentList.Add([string]$context.target.album)
    }
    if ($null -ne $context.target.durationSeconds) {
        $startInfo.ArgumentList.Add('--duration')
        $startInfo.ArgumentList.Add([string]$context.target.durationSeconds)
    }
    if ($DryRunMonochrome) {
        $startInfo.ArgumentList.Add('--dry-run-monochrome')
    }

    $script:childProcess = [Diagnostics.Process]::new()
    $script:childProcess.StartInfo = $startInfo
    $script:childProcess.add_OutputDataReceived({
        param($sender, $eventArgs)
        if ($null -eq $eventArgs.Data) {
            return
        }
        Write-Host $eventArgs.Data
        try {
            $event = $eventArgs.Data | ConvertFrom-Json
            if ($event.type -eq 'success') {
                $script:sawSuccess = $true
            }
            elseif ($event.type -eq 'error') {
                $script:terminalCode = [string]$event.code
            }
        }
        catch {
            # Une ligne non NDJSON n'est ni exécutée ni envoyée au backend.
        }
    })
    $script:childProcess.add_ErrorDataReceived({
        param($sender, $eventArgs)
        if ($null -ne $eventArgs.Data) {
            Write-Host $eventArgs.Data -ForegroundColor DarkYellow
        }
    })
    if (-not $script:childProcess.Start()) {
        throw 'Impossible de démarrer Python.'
    }
    $script:childProcess.BeginOutputReadLine()
    $script:childProcess.BeginErrorReadLine()
    $script:childProcess.WaitForExit()
    $script:childProcess.WaitForExit()

    if ($script:childProcess.ExitCode -eq 0 -and $script:sawSuccess) {
        if ($DryRunMonochrome) {
            Send-MonochromeResult -Result 'dry_run_completed'
            Write-Host "Diagnostic conservé dans : $outputDirectory"
        }
        else {
            Send-MonochromeResult -Result 'download_ready'
            Write-Host 'Fichier transmis au pipeline local HomeSpotify.'
        }
        exit 0
    }

    $result = switch ($script:terminalCode) {
        'CANCELLED' { 'cancelled' }
        'MONOCHROME_MANUAL_TIMEOUT' { 'timeout' }
        'MONOCHROME_NO_EXACT_MATCH' { 'no_exact_match' }
        'MONOCHROME_AMBIGUOUS_MATCH' { 'ambiguous_match' }
        'MANUAL_FILE_CONFIRMATION_REQUIRED' { 'file_rejected' }
        'MANUAL_FILE_METADATA_MISMATCH' { 'file_rejected' }
        'MANUAL_FILE_DURATION_MISMATCH' { 'file_rejected' }
        default { 'provider_error' }
    }
    Send-MonochromeResult -Result $result
    exit 4
}
catch {
    $failureMessage = $_.Exception.Message
    if ($holderReserved -and $null -eq $script:reportedResult) {
        try {
            Send-MonochromeResult -Result 'provider_error'
        }
        catch {
            # Au redémarrage, le backend rend un holder interrompu réservable.
        }
    }
    Write-Error $failureMessage
    exit 2
}
finally {
    if (
        $null -ne $script:childProcess -and
        -not $script:childProcess.HasExited
    ) {
        $script:childProcess.Kill($true)
        $script:childProcess.WaitForExit()
    }
    if (
        -not $DryRunMonochrome -and
        $script:reportedResult -ne 'download_ready' -and
        $ownsStaging -and
        (Test-Path -LiteralPath $outputDirectory) -and
        $outputDirectory.StartsWith(
            $requiredPrefix,
            [StringComparison]::OrdinalIgnoreCase
        )
    ) {
        Remove-Item -LiteralPath $outputDirectory -Recurse -Force
    }
    $headers = $null
    $token = $null
}
