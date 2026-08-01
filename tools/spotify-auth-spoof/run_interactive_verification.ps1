[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$JobId,

    [string]$ApiBaseUrl = $env:HOMESPOTIFY_API_BASE_URL
)

$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$apiRoot = Join-Path $projectRoot 'services\api'
$envPath = Join-Path $apiRoot '.env'
$script:terminalCode = $null
$script:sawSuccess = $false
$script:childProcess = $null
$reportedResult = $null
$ownsOutputDirectory = $false
$holderReserved = $false

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

function Resolve-ConfiguredPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    if ([IO.Path]::IsPathRooted($Value)) {
        return [IO.Path]::GetFullPath($Value)
    }
    return [IO.Path]::GetFullPath((Join-Path $apiRoot $Value))
}

function Read-BearerToken {
    if ($env:HOMESPOTIFY_HELPER_API_TOKEN) {
        return $env:HOMESPOTIFY_HELPER_API_TOKEN
    }

    $secureToken = Read-Host `
        'Collez un jeton API HomeSpotify valide (la saisie reste masquée)' `
        -AsSecureString
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR(
        $secureToken
    )
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
    }
}

function Send-HelperResult {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Result
    )

    $payload = @{ result = $Result } | ConvertTo-Json -Compress
    Invoke-RestMethod `
        -Method Post `
        -Uri "$ApiBaseUrl/api/imports/jobs/$JobId/manual-verification-result" `
        -Headers $headers `
        -ContentType 'application/json' `
        -Body $payload | Out-Null
    $script:reportedResult = $Result
}

if ([string]::IsNullOrWhiteSpace($ApiBaseUrl)) {
    $ApiBaseUrl = 'http://127.0.0.1:3000'
}
$ApiBaseUrl = $ApiBaseUrl.TrimEnd('/')

$pythonValue = Read-AllowedEnvValue -Name 'LUCIDA_PYTHON_PATH'
if ([string]::IsNullOrWhiteSpace($pythonValue)) {
    $pythonValue = 'python'
}
$scriptValue = Read-AllowedEnvValue -Name 'LUCIDA_SCRIPT_PATH'
if ([string]::IsNullOrWhiteSpace($scriptValue)) {
    $scriptValue = Join-Path $PSScriptRoot 'lucida_dl_final.py'
}
$scriptPath = Resolve-ConfiguredPath -Value $scriptValue
if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
    throw "Script Lucida introuvable : $scriptPath"
}

$importRootValue = Read-AllowedEnvValue -Name 'HOMESPOTIFY_IMPORT_ROOT'
if ([string]::IsNullOrWhiteSpace($importRootValue)) {
    $importRootValue = '../../storage/imports'
}
$importRoot = Resolve-ConfiguredPath -Value $importRootValue
$interactiveRoot = [IO.Path]::GetFullPath(
    (Join-Path $importRoot '.interactive')
)
$outputDirectory = [IO.Path]::GetFullPath(
    (Join-Path $interactiveRoot $JobId)
)
$requiredPrefix = $interactiveRoot.TrimEnd('\') + '\'
if (-not $outputDirectory.StartsWith(
    $requiredPrefix,
    [StringComparison]::OrdinalIgnoreCase
)) {
    throw 'Le dossier de sortie interactif calculé est invalide.'
}
$token = Read-BearerToken
if ([string]::IsNullOrWhiteSpace($token)) {
    throw 'Jeton API vide.'
}
$headers = @{ Authorization = "Bearer $token" }

try {
    $context = Invoke-RestMethod `
        -Method Get `
        -Uri "$ApiBaseUrl/api/imports/jobs/$JobId/manual-verification" `
        -Headers $headers

    if (
        $context.jobId -ne $JobId -or
        [string]::IsNullOrWhiteSpace([string]$context.query)
    ) {
        throw 'Le backend a retourné un contexte de vérification invalide.'
    }
    $holderReserved = $true

    if (Test-Path -LiteralPath $outputDirectory) {
        $existing = @(Get-ChildItem -LiteralPath $outputDirectory -Force)
        if ($existing.Count -gt 0) {
            throw 'Le dossier de résultat du job existe déjà et n’est pas vide.'
        }
    }
    else {
        New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
    }
    $ownsOutputDirectory = $true

    Write-Host 'Ouverture de Chromium pour une vérification strictement manuelle.'
    Write-Host 'Le script ne clique pas sur Cloudflare et ne résout aucun challenge.'

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $pythonValue
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $false
    @(
        $scriptPath,
        [string]$context.query,
        '--visible',
        '--interactive-verification',
        '--verification-timeout',
        [string]$context.verificationTimeoutSeconds,
        '--index',
        [string]$context.resultIndex,
        '--output',
        $outputDirectory,
        '--json'
    ) | ForEach-Object {
        $startInfo.ArgumentList.Add($_)
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
            # stdout est validé par Python ; une ligne non JSON ne devient
            # jamais une instruction ou une donnée envoyée au backend.
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
        Send-HelperResult -Result 'verification_completed'
        Write-Host 'Acquisition manuelle transmise au pipeline HomeSpotify.'
        exit 0
    }
    if ($script:terminalCode -eq 'CANCELLED') {
        Send-HelperResult -Result 'cancelled'
        exit 3
    }
    if ($script:terminalCode -eq 'PROVIDER_VERIFICATION_TIMEOUT') {
        Send-HelperResult -Result 'timeout'
        exit 4
    }

    Send-HelperResult -Result 'provider_error'
    exit 4
}
catch {
    $failureMessage = $_.Exception.Message
    if ($holderReserved -and $null -eq $script:reportedResult) {
        try {
            Send-HelperResult -Result 'provider_error'
        }
        catch {
            # Le holder sera aussi libéré au prochain démarrage du backend.
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
        $script:reportedResult -ne 'verification_completed' -and
        $ownsOutputDirectory -and
        (Test-Path -LiteralPath $outputDirectory) -and
        $outputDirectory.StartsWith(
            $requiredPrefix,
            [StringComparison]::OrdinalIgnoreCase
        )
    ) {
        Remove-Item -LiteralPath $outputDirectory -Recurse -Force
    }
    $token = $null
}
