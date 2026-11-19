# Install a verified `az sre` extension wheel.
#
# Supported sources (see devx/sdks/python/azure-cli-sre/docs/release.md):
#   -WheelUrl URL -ExpectedSha256 HEX     exact HTTPS wheel + trusted digest
#   -WheelPath FILE [-ExpectedSha256 HEX] local copy of an official wheel
#   (no arguments)                        the pinned $DefaultWheelUrl release below
# Private GitHub run/release selectors are intentionally not supported.

[CmdletBinding()]
param(
    [string]$WheelUrl,
    [string]$WheelPath,
    [string]$ExpectedSha256,
    [switch]$Uninstall,
    [switch]$Help
)

# Keep irm | iex from changing caller preferences or helper definitions.
& {
param([hashtable]$InstallerParameters)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$ExtensionName = 'sre'

# Pinned release used when no wheel source is given (irm ... | iex).
# Each public release PR updates both values together.
$DefaultWheelUrl = 'https://github.com/microsoft/sre-agent/releases/download/cli-v1.0.0b2/sre-1.0.0b2-py3-none-any.whl'
$DefaultExpectedSha256 = 'e1a05b99d9006e76a1e2949ce8a6bb70143f573e11169f7b28c773328c06fa08'

$WheelUrl = $InstallerParameters['WheelUrl']
$WheelPath = $InstallerParameters['WheelPath']
$ExpectedSha256 = $InstallerParameters['ExpectedSha256']
if (-not $WheelUrl) { $WheelUrl = $env:SRE_INSTALL_WHEEL_URL }
if (-not $WheelPath) { $WheelPath = $env:SRE_INSTALL_WHEEL_PATH }
if (-not $ExpectedSha256) { $ExpectedSha256 = $env:SRE_INSTALL_EXPECTED_SHA256 }

function Show-Usage {
    @(
        'Usage: install-az-sre.ps1 [options]'
        ''
        'Install a verified az sre extension wheel.'
        'With no wheel source, installs the pinned default release.'
        ''
        'Options:'
        '  -WheelUrl URL           Exact HTTPS URL ending in sre-<version>-py3-none-any.whl'
        '  -WheelPath FILE         Local sre-<version>-py3-none-any.whl'
        '  -ExpectedSha256 HEX     Trusted SHA-256 (required with -WheelUrl)'
        '  -Uninstall              Remove sre if installed'
        '  -Help                   Show this help'
        ''
        'Matching environment variables use the SRE_INSTALL_* prefix'
        '(SRE_INSTALL_WHEEL_URL, SRE_INSTALL_WHEEL_PATH, SRE_INSTALL_EXPECTED_SHA256).'
    ) | ForEach-Object { Write-Host $_ }
}

function Invoke-NativeText {
    param(
        [string]$Command,
        [string[]]$Arguments
    )
    $stdoutPath = [System.IO.Path]::GetTempFileName()
    $stderrPath = [System.IO.Path]::GetTempFileName()
    try {
        # Windows PowerShell 5.1 turns native stderr (e.g. az preview warnings)
        # into terminating errors under 'Stop'; rely on the exit code instead.
        $previousPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            & $Command @Arguments 1>$stdoutPath 2>$stderrPath
            $exitCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $previousPreference
        }
        $stdout = [System.IO.File]::ReadAllText($stdoutPath).Trim()
        $stderr = [System.IO.File]::ReadAllText($stderrPath).Trim()
        if ($exitCode -ne 0) {
            $details = @(@($stderr, $stdout) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            $suffix = if ($details.Count) { [Environment]::NewLine + ($details -join [Environment]::NewLine) } else { '' }
            throw "$Command failed with exit code $exitCode.$suffix"
        }
        return $stdout
    } finally {
        Remove-Item -LiteralPath $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue
    }
}

function Confirm-Sha256 {
    param(
        [string]$AssetName,
        [string]$Path,
        [string]$ExpectedDigest
    )
    if ($ExpectedDigest -notmatch '^[0-9A-Fa-f]{64}$') {
        throw "Invalid expected SHA-256 digest for '$AssetName'."
    }
    $actualDigest = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualDigest -ne $ExpectedDigest.ToLowerInvariant()) {
        throw "SHA-256 verification failed for '$AssetName'."
    }
}

function Confirm-WheelName {
    param([string]$Name)
    if ($Name -notmatch '^sre-[A-Za-z0-9.+_]+-py3-none-any\.whl$') {
        throw "'$Name' is not an exact sre-<version>-py3-none-any.whl filename."
    }
}

if ($InstallerParameters['Help']) {
    Show-Usage
    return
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw "Azure CLI ('az') not found. Install it first: https://learn.microsoft.com/cli/azure/install-azure-cli"
}

if ($InstallerParameters['Uninstall']) {
    $installed = Invoke-NativeText 'az' @('extension', 'list', '--query', "[?name=='$ExtensionName'].name", '--output', 'tsv')
    if ($installed -eq $ExtensionName) {
        Invoke-NativeText 'az' @('extension', 'remove', '--name', $ExtensionName) | Out-Null
        Write-Host "Uninstalled '$ExtensionName'."
    } elseif ([string]::IsNullOrWhiteSpace($installed)) {
        Write-Host "'$ExtensionName' is not installed; nothing to do."
    } else {
        throw 'Unexpected extension list response; refusing to uninstall.'
    }
    return
}

if ($WheelUrl -and $WheelPath) {
    throw 'Use either -WheelUrl or -WheelPath, not both.'
}
if (-not $WheelUrl -and -not $WheelPath) {
    if (-not $DefaultWheelUrl -or -not $DefaultExpectedSha256) {
        Show-Usage
        throw 'No default release is pinned yet. Provide -WheelUrl (with -ExpectedSha256) or -WheelPath.'
    }
    $WheelUrl = $DefaultWheelUrl
    $ExpectedSha256 = $DefaultExpectedSha256
}

$tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ("sre-install-" + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmpDir | Out-Null
try {
    if ($WheelUrl) {
        if (-not $ExpectedSha256) {
            throw '-WheelUrl requires -ExpectedSha256.'
        }
        $uri = [System.Uri]::new($WheelUrl)
        if (-not $uri.IsAbsoluteUri -or $uri.Scheme -ne 'https' -or $uri.UserInfo -or $uri.Query -or $uri.Fragment) {
            throw '-WheelUrl must be an HTTPS URL without query, fragment, or credentials.'
        }
        $wheelName = [System.IO.Path]::GetFileName($uri.AbsolutePath)
        Confirm-WheelName $wheelName
        $wheelFile = Join-Path $tmpDir $wheelName
        if ($PSVersionTable.PSEdition -eq 'Desktop') {
            [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
        }
        $response = Invoke-WebRequest -Uri $uri -OutFile $wheelFile -UseBasicParsing -PassThru -ErrorAction Stop
        $finalUri = $null
        if ($response.PSObject.Properties['BaseResponse']) {
            $base = $response.BaseResponse
            if ($base.PSObject.Properties['ResponseUri']) { $finalUri = $base.ResponseUri }
            elseif ($base.PSObject.Properties['RequestMessage']) { $finalUri = $base.RequestMessage.RequestUri }
        }
        if ($null -ne $finalUri -and $finalUri.Scheme -ne 'https') {
            throw 'Wheel download did not finish at an HTTPS URL.'
        }
        $head = [System.Text.Encoding]::ASCII.GetString(
            [System.IO.File]::ReadAllBytes($wheelFile), 0,
            [Math]::Min(512, (Get-Item -LiteralPath $wheelFile).Length))
        if ($head -match '(?i)<html|<!doctype') {
            throw 'Download looks like an HTML page (sign-in?), not a wheel.'
        }
        Confirm-Sha256 $wheelName $wheelFile $ExpectedSha256
        $sourceDescription = "URL:    $WheelUrl"
    } else {
        if (-not (Test-Path -LiteralPath $WheelPath -PathType Leaf)) {
            throw "Wheel file not found: $WheelPath"
        }
        $wheelName = [System.IO.Path]::GetFileName($WheelPath)
        Confirm-WheelName $wheelName
        $wheelFile = Join-Path $tmpDir $wheelName
        Copy-Item -LiteralPath $WheelPath -Destination $wheelFile
        if ($ExpectedSha256) {
            Confirm-Sha256 $wheelName $wheelFile $ExpectedSha256
        } else {
            Write-Warning 'No -ExpectedSha256 given; local wheel digest not verified.'
        }
        $sourceDescription = "File:   $WheelPath"
    }

    $expectedVersion = $wheelName -replace '^sre-', '' -replace '-py3-none-any\.whl$', ''

    Invoke-NativeText 'az' @('extension', 'add', '--upgrade', '--yes', '--source', $wheelFile, '--output', 'none') | Out-Null

    $actualName = Invoke-NativeText 'az' @('sre', 'version', '--query', 'extensionName', '--output', 'tsv')
    $actualVersion = Invoke-NativeText 'az' @('sre', 'version', '--query', 'extensionVersion', '--output', 'tsv')
    if ($actualName -ne $ExtensionName) {
        throw "Installed extension name '$actualName' is not '$ExtensionName'."
    }
    if ($actualVersion -ne $expectedVersion) {
        throw "Installed version '$actualVersion' does not match wheel '$expectedVersion'."
    }

    Write-Host "Installed '$ExtensionName' $actualVersion successfully."
    Write-Host "  $sourceDescription"
    Write-Host "  Wheel:  $wheelName"
    Write-Host 'Verify with: az sre version'
} finally {
    Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
}
} $PSBoundParameters
