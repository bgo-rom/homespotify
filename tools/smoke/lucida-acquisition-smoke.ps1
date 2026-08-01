[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateNotNullOrEmpty()]
  [string]$Username,

  [Parameter(Mandatory = $true)]
  [ValidateNotNullOrEmpty()]
  [string]$Query,

  [string]$ApiBase = 'http://127.0.0.1:3000',

  [Security.SecureString]$Password,

  [switch]$StartAcquisition,

  [ValidateRange(0, 100)]
  [int]$ResultIndex = 0,

  [ValidateRange(10, 300)]
  [int]$DownloadTimeoutSeconds = 75,

  [ValidateRange(0, 9)]
  [int]$DownloadRetries = 2,

  [ValidateRange(1, 30)]
  [int]$PollIntervalSeconds = 2,

  [ValidateRange(30, 3600)]
  [int]$MaxWaitSeconds = 900
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-HomeSpotifyJson {
  param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('GET', 'POST', 'DELETE')]
    [string]$Method,

    [Parameter(Mandatory = $true)]
    [string]$Uri,

    [hashtable]$Headers,

    [object]$Body
  )

  $parameters = @{
    Method      = $Method
    Uri         = $Uri
    ErrorAction = 'Stop'
  }

  if ($null -ne $Headers) {
    $parameters.Headers = $Headers
  }

  if ($null -ne $Body) {
    $parameters.ContentType = 'application/json; charset=utf-8'
    $parameters.Body = $Body | ConvertTo-Json -Depth 8 -Compress
  }

  try {
    return Invoke-RestMethod @parameters
  }
  catch {
    $details = $_.ErrorDetails.Message
    if ([string]::IsNullOrWhiteSpace($details)) {
      $details = $_.Exception.Message
    }
    throw "Echec HTTP $Method $Uri : $details"
  }
}

function ConvertFrom-SecurePassword {
  param(
    [Parameter(Mandatory = $true)]
    [Security.SecureString]$SecurePassword
  )

  $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR(
    $SecurePassword
  )
  try {
    return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
  }
  finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
  }
}

$ApiBase = $ApiBase.TrimEnd('/')
$plainPassword = $null
$accessToken = $null
$jobId = $null

# Ne jamais lancer un job par defaut. Le telechargement n'est autorise que
# lorsque -StartAcquisition est explicitement present dans la commande.
$startRequested =
  $PSBoundParameters.ContainsKey('StartAcquisition') -and
  $StartAcquisition.IsPresent

try {
  if ($null -eq $Password) {
    $Password = Read-Host `
      -Prompt "Mot de passe HomeSpotify pour $Username" `
      -AsSecureString
  }

  $plainPassword = ConvertFrom-SecurePassword -SecurePassword $Password

  Write-Host '1/4 Connexion a HomeSpotify...'
  $login = Invoke-HomeSpotifyJson `
    -Method POST `
    -Uri "$ApiBase/api/auth/login" `
    -Body @{
      username = $Username
      password = $plainPassword
    }

  if ([string]::IsNullOrWhiteSpace([string]$login.accessToken)) {
    throw 'La reponse de connexion ne contient aucun accessToken.'
  }

  $accessToken = [string]$login.accessToken
  $headers = @{
    Authorization = "Bearer $accessToken"
  }

  Write-Host '2/4 Recherche distante...'
  $search = Invoke-HomeSpotifyJson `
    -Method POST `
    -Uri "$ApiBase/api/imports/search" `
    -Headers $headers `
    -Body @{
      query = $Query
    }

  $results = @($search.results)

  if ($results.Count -eq 0) {
    Write-Warning "Aucun resultat trouve. Aucun job n'a ete cree."
    exit 2
  }

  $results |
    Select-Object `
      index, `
      title, `
      artist, `
      album, `
      @{ Name = 'durationSeconds'; Expression = { $_.duration } } |
    Format-Table -AutoSize

  if (-not $startRequested) {
    Write-Host ''
    Write-Host "Recherche validee. Aucun telechargement n'a ete lance."
    Write-Host (
      "Relance avec -StartAcquisition -ResultIndex INDEX " +
      "pour tester un contenu que tu possedes ou es autorise a importer."
    )
    exit 0
  }

  $selected = @(
    $results | Where-Object {
      [int]$_.index -eq $ResultIndex
    }
  )

  if ($selected.Count -ne 1) {
    throw (
      "ResultIndex=$ResultIndex ne correspond pas exactement a un resultat."
    )
  }

  Write-Host (
    "3/4 Creation du job pour l'index $ResultIndex : " +
    "$($selected[0].artist) - $($selected[0].title)"
  )

  $created = Invoke-HomeSpotifyJson `
    -Method POST `
    -Uri "$ApiBase/api/imports/jobs" `
    -Headers $headers `
    -Body @{
      query                  = $Query
      resultIndex            = $ResultIndex
      service                = 'Qobuz'
      downloadTimeoutSeconds = $DownloadTimeoutSeconds
      downloadRetries        = $DownloadRetries
    }

  $jobId = [string]$created.item.id
  if ([string]::IsNullOrWhiteSpace($jobId)) {
    throw 'La reponse de creation ne contient aucun identifiant de job.'
  }

  Write-Host "Job cree : $jobId"
  Write-Host (
    "Annulation manuelle : Invoke-RestMethod -Method DELETE " +
    "-Uri '$ApiBase/api/imports/jobs/$jobId' " +
    "-Headers @{ Authorization = 'Bearer <TOKEN>' }"
  )

  Write-Host '4/4 Suivi du job...'
  $deadline = [DateTimeOffset]::UtcNow.AddSeconds($MaxWaitSeconds)
  $terminalStatuses = @(
    'COMPLETED',
    'FAILED',
    'CANCELLED',
    'INTERRUPTED'
  )
  $lastDisplay = $null

  while ([DateTimeOffset]::UtcNow -lt $deadline) {
    $response = Invoke-HomeSpotifyJson `
      -Method GET `
      -Uri "$ApiBase/api/imports/jobs/$jobId" `
      -Headers $headers

    $job = $response.item
    $display = '{0}|{1}|{2}|{3}|{4}' -f `
      $job.status, `
      $job.stage, `
      $job.progress, `
      $job.attempt, `
      $job.message

    if ($display -ne $lastDisplay) {
      $timestamp = Get-Date -Format 'HH:mm:ss'
      Write-Host (
        "[$timestamp] status=$($job.status) stage=$($job.stage) " +
        "progress=$($job.progress)% attempt=$($job.attempt)/" +
        "$($job.maxAttempts) message=$($job.message)"
      )
      $lastDisplay = $display
    }

    if ($terminalStatuses -contains [string]$job.status) {
      switch ([string]$job.status) {
        'COMPLETED' {
          if ($null -eq $job.finalTrackId) {
            Write-Host `
              'Le job est COMPLETED mais finalTrackId est absent.' `
              -ForegroundColor Red
            exit 4
          }

          Write-Host ''
          Write-Host (
            "SUCCES : piste importee, finalTrackId=$($job.finalTrackId)."
          )
          exit 0
        }

        'FAILED' {
          Write-Host (
            "ECHEC : code=$($job.errorCode) " +
            "message=$($job.errorMessage)"
          ) -ForegroundColor Red
          exit 3
        }

        'CANCELLED' {
          Write-Warning 'Le job a ete annule.'
          exit 5
        }

        'INTERRUPTED' {
          Write-Host (
            "Le job a ete interrompu : $($job.errorMessage)"
          ) -ForegroundColor Red
          exit 6
        }
      }
    }

    Start-Sleep -Seconds $PollIntervalSeconds
  }

  Write-Host (
    "Le job $jobId n'a pas termine apres $MaxWaitSeconds secondes."
  ) -ForegroundColor Red
  exit 7
}
finally {
  $plainPassword = $null
  $accessToken = $null
}
