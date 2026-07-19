[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$stretchUrls = @(
  'https://signalsmith-audio.co.uk/code/stretch.git',
  'https://github.com/Signalsmith-Audio/signalsmith-stretch.git'
)
$stretchCommit = '57b93f4e9206a089a45387eaa39bdc9f310d3308'
$stretchVersion = '1.3.2'
$linearUrls = @(
  'https://git.signalsmith-audio.co.uk/Signalsmith-Audio/linear.git',
  'https://github.com/Signalsmith-Audio/linear.git'
)
$linearCommit = '5668673560146a9cfe38c25315071e3fd68c8317'
$linearVersion = '0.3.1'

$pocRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$vendorRoot = [System.IO.Path]::GetFullPath((Join-Path `
      $pocRoot `
      'android/src/main/cpp/third_party/signalsmith_stretch'))
$workRoot = [System.IO.Path]::GetFullPath((Join-Path `
      $pocRoot `
      ('.vendor-work-' + [System.Guid]::NewGuid().ToString('N'))))

function Assert-PathInsidePoc {
  param(
    [Parameter(Mandatory = $true)]
    [string] $Candidate
  )

  $fullPath = [System.IO.Path]::GetFullPath($Candidate)
  $pocPrefix = $pocRoot + [System.IO.Path]::DirectorySeparatorChar
  if (-not $fullPath.StartsWith(
      $pocPrefix,
      [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing a path outside the POC directory: $fullPath"
  }
}

function Invoke-GitCommand {
  param(
    [Parameter(Mandatory = $true)]
    [string[]] $Arguments
  )

  $output = @()
  $exitCode = 1
  $previousErrorActionPreference = $ErrorActionPreference
  try {
    $ErrorActionPreference = 'Continue'
    $output = & git @Arguments 2>&1
    $exitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $previousErrorActionPreference
  }
  if ($exitCode -ne 0) {
    $details = ($output | Out-String).Trim()
    throw "git $($Arguments -join ' ') failed with exit code $exitCode.`n$details"
  }

  return $output
}

function Checkout-ExactCommit {
  param(
    [Parameter(Mandatory = $true)]
    [string[]] $Urls,

    [Parameter(Mandatory = $true)]
    [string] $Commit,

    [Parameter(Mandatory = $true)]
    [string] $Destination
  )

  $failures = New-Object System.Collections.Generic.List[string]
  foreach ($url in $Urls) {
    if (Test-Path -LiteralPath $Destination) {
      Assert-PathInsidePoc -Candidate $Destination
      Remove-Item -LiteralPath $Destination -Recurse -Force
    }

    try {
      Invoke-GitCommand -Arguments @(
        'clone',
        '--no-checkout',
        '--quiet',
        $url,
        $Destination
      ) | Out-Null

      Invoke-GitCommand -Arguments @(
        '-C',
        $Destination,
        'cat-file',
        '-e',
        ($Commit + '^{tree}')
      ) | Out-Null

      Invoke-GitCommand -Arguments @(
        '-C',
        $Destination,
        'checkout',
        '--detach',
        '--quiet',
        $Commit
      ) | Out-Null

      $actualCommit = ((Invoke-GitCommand -Arguments @(
            '-C',
            $Destination,
            'rev-parse',
            'HEAD'
          )) | Out-String).Trim()
      if ($actualCommit -ne $Commit) {
        throw "Upstream checkout mismatch: expected $Commit, got $actualCommit"
      }

      return $url
    } catch {
      $failures.Add("$url`n$($_.Exception.Message)")
    }
  }

  throw "No official upstream provided a complete checkout for $Commit.`n$($failures -join "`n---`n")"
}

function Assert-SourceFile {
  param(
    [Parameter(Mandatory = $true)]
    [string] $Path
  )

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "Required upstream file is missing: $Path"
  }
}

function Get-VendoredFileRecord {
  param(
    [Parameter(Mandatory = $true)]
    [string] $RelativePath
  )

  $nativeRelativePath = $RelativePath.Replace(
    '/',
    [System.IO.Path]::DirectorySeparatorChar)
  $fullPath = Join-Path $vendorRoot $nativeRelativePath
  Assert-SourceFile -Path $fullPath

  return [ordered]@{
    path = $RelativePath
    sha256 = (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash.ToLowerInvariant()
  }
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
  throw 'git is required to vendor the pinned Signalsmith sources.'
}

Assert-PathInsidePoc -Candidate $vendorRoot
Assert-PathInsidePoc -Candidate $workRoot

$stretchCheckout = Join-Path $workRoot 'signalsmith-stretch'
$linearCheckout = Join-Path $workRoot 'signalsmith-linear'
$stagedVendor = Join-Path $workRoot 'vendor'

try {
  New-Item -ItemType Directory -Path $workRoot -Force | Out-Null
  $stretchSource = Checkout-ExactCommit `
    -Urls $stretchUrls `
    -Commit $stretchCommit `
    -Destination $stretchCheckout
  $linearSource = Checkout-ExactCommit `
    -Urls $linearUrls `
    -Commit $linearCommit `
    -Destination $linearCheckout

  $stretchHeader = Join-Path $stretchCheckout 'signalsmith-stretch.h'
  $stretchLicense = Join-Path $stretchCheckout 'LICENSE.txt'
  $linearStft = Join-Path $linearCheckout 'stft.h'
  $linearFft = Join-Path $linearCheckout 'fft.h'
  $linearLicense = Join-Path $linearCheckout 'LICENSE.txt'

  @(
    $stretchHeader,
    $stretchLicense,
    $linearStft,
    $linearFft,
    $linearLicense
  ) | ForEach-Object { Assert-SourceFile -Path $_ }

  $stretchHeaderContent = [System.IO.File]::ReadAllText($stretchHeader)
  if ($stretchHeaderContent -notmatch `
      'version\s*\[\s*3\s*\]\s*=\s*\{\s*1\s*,\s*3\s*,\s*2\s*\}') {
    throw "Pinned Stretch header does not declare version $stretchVersion."
  }

  foreach ($licensePath in @($stretchLicense, $linearLicense)) {
    if ([System.IO.File]::ReadAllText($licensePath) -notmatch 'MIT License') {
      throw "Expected MIT license text was not found in $licensePath"
    }
  }

  $stagedLinear = Join-Path $stagedVendor 'signalsmith-linear'
  New-Item -ItemType Directory -Path $stagedLinear -Force | Out-Null
  Copy-Item -LiteralPath $stretchHeader `
    -Destination (Join-Path $stagedVendor 'signalsmith-stretch.h')
  Copy-Item -LiteralPath $stretchLicense `
    -Destination (Join-Path $stagedVendor 'LICENSE.signalsmith-stretch.txt')
  Copy-Item -LiteralPath $linearStft `
    -Destination (Join-Path $stagedLinear 'stft.h')
  Copy-Item -LiteralPath $linearFft `
    -Destination (Join-Path $stagedLinear 'fft.h')
  Copy-Item -LiteralPath $linearLicense `
    -Destination (Join-Path $stagedVendor 'LICENSE.signalsmith-linear.txt')

  New-Item -ItemType Directory -Path $vendorRoot -Force | Out-Null
  New-Item -ItemType Directory `
    -Path (Join-Path $vendorRoot 'signalsmith-linear') `
    -Force | Out-Null

  Copy-Item -LiteralPath (Join-Path $stagedVendor 'signalsmith-stretch.h') `
    -Destination (Join-Path $vendorRoot 'signalsmith-stretch.h') `
    -Force
  Copy-Item -LiteralPath (Join-Path $stagedVendor 'LICENSE.signalsmith-stretch.txt') `
    -Destination (Join-Path $vendorRoot 'LICENSE.signalsmith-stretch.txt') `
    -Force
  Copy-Item -LiteralPath (Join-Path $stagedVendor 'signalsmith-linear/stft.h') `
    -Destination (Join-Path $vendorRoot 'signalsmith-linear/stft.h') `
    -Force
  Copy-Item -LiteralPath (Join-Path $stagedVendor 'signalsmith-linear/fft.h') `
    -Destination (Join-Path $vendorRoot 'signalsmith-linear/fft.h') `
    -Force
  Copy-Item -LiteralPath (Join-Path $stagedVendor 'LICENSE.signalsmith-linear.txt') `
    -Destination (Join-Path $vendorRoot 'LICENSE.signalsmith-linear.txt') `
    -Force

  $manifest = [ordered]@{
    schemaVersion = 1
    status = 'verified-local-checkout'
    generatedAtUtc = [System.DateTime]::UtcNow.ToString('o')
    components = @(
      [ordered]@{
        name = 'Signalsmith Stretch'
        version = $stretchVersion
        license = 'MIT'
        upstream = $stretchSource
        commit = $stretchCommit
        files = @(
          (Get-VendoredFileRecord -RelativePath 'signalsmith-stretch.h'),
          (Get-VendoredFileRecord `
              -RelativePath 'LICENSE.signalsmith-stretch.txt')
        )
      },
      [ordered]@{
        name = 'Signalsmith Linear'
        version = $linearVersion
        license = 'MIT'
        upstream = $linearSource
        commit = $linearCommit
        files = @(
          (Get-VendoredFileRecord -RelativePath 'signalsmith-linear/stft.h'),
          (Get-VendoredFileRecord -RelativePath 'signalsmith-linear/fft.h'),
          (Get-VendoredFileRecord `
              -RelativePath 'LICENSE.signalsmith-linear.txt')
        )
      }
    )
  }

  $manifestPath = Join-Path $vendorRoot 'VENDOR_MANIFEST.json'
  $manifestJson = $manifest | ConvertTo-Json -Depth 8
  $utf8WithoutBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText(
    $manifestPath,
    $manifestJson + [System.Environment]::NewLine,
    $utf8WithoutBom)

  Write-Host "Signalsmith sources vendored from exact commits into $vendorRoot"
  Write-Host "SHA-256 manifest written to $manifestPath"
} finally {
  if (Test-Path -LiteralPath $workRoot) {
    Assert-PathInsidePoc -Candidate $workRoot
    Remove-Item -LiteralPath $workRoot -Recurse -Force
  }
}
