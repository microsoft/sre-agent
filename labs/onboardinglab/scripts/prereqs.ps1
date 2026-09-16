[CmdletBinding()]
param(
    [switch]$Check
)

if ($MyInvocation.InvocationName -ne '.') {
    throw 'Dot-source this script so Node.js and npm settings remain active: . .\scripts\prereqs.ps1'
}

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'This script supports Windows. On macOS, run source ./scripts/prereqs.sh.'
}

$script:Missing = 0

function Update-ProcessPath {
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = "$machinePath;$userPath"
}

function Install-WinGetPackage {
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$Id,

        [switch]$Upgrade
    )

    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw 'WinGet is required to install missing prerequisites. Install App Installer from Microsoft Store, then rerun this script.'
    }

    $operation = if ($Upgrade) { 'upgrade' } else { 'install' }
    Write-Host "  [$operation] $Name"

    $arguments = @(
        $operation,
        '--id', $Id,
        '--exact',
        '--accept-package-agreements',
        '--accept-source-agreements',
        '--disable-interactivity'
    )
    & winget @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "WinGet failed to $operation $Name."
    }

    Update-ProcessPath
}

function Ensure-Command {
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$Command,

        [Parameter(Mandatory)]
        [string]$PackageId
    )

    if (Get-Command $Command -ErrorAction SilentlyContinue) {
        Write-Host "  [ok] $Name"
        return
    }

    Write-Host "  [missing] $Name"
    if ($Check) {
        $script:Missing++
        return
    }

    Install-WinGetPackage -Name $Name -Id $PackageId
}

function Get-NodeMajorVersion {
    if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
        return 0
    }

    $major = & node -p 'Number(process.versions.node.split(".")[0])' 2>$null
    if ($LASTEXITCODE -ne 0 -or $major -notmatch '^\d+$') {
        return 0
    }

    return [int]$major
}

function Ensure-Node {
    $major = Get-NodeMajorVersion
    if ($major -ge 22) {
        Write-Host "  [ok] Node.js $(& node --version)"
        return
    }

    if ($major -gt 0) {
        Write-Host "  [outdated] Node.js $(& node --version); version 22 or later is required"
    }
    else {
        Write-Host '  [missing] Node.js 22 or later'
    }

    if ($Check) {
        $script:Missing++
        return
    }

    if (Get-Command nvm -ErrorAction SilentlyContinue) {
        Write-Host '  [install] Node.js 22 with NVM'
        & nvm install 22
        if ($LASTEXITCODE -ne 0) {
            throw 'NVM failed to install Node.js 22.'
        }
        & nvm use 22
        if ($LASTEXITCODE -ne 0) {
            throw 'NVM failed to activate Node.js 22.'
        }
    }
    elseif ($major -gt 0) {
        Install-WinGetPackage -Name 'Node.js LTS' -Id 'OpenJS.NodeJS.LTS' -Upgrade
    }
    else {
        Install-WinGetPackage -Name 'Node.js LTS' -Id 'OpenJS.NodeJS.LTS'
    }
}

function Restore-AppDependencies {
    $appPath = Join-Path $PSScriptRoot '..\ticketingapp-source\app'
    if (-not (Test-Path (Join-Path $appPath 'package-lock.json'))) {
        throw 'The onboarding lab ticketingapp-source/app/package-lock.json file was not found.'
    }

    if ($Check) {
        Write-Host '  [check skipped] App dependency restore'
        return
    }

    Write-Host '  [verify] Restoring locked app dependencies'
    & npm ci --prefix $appPath --ignore-scripts --no-audit --no-fund
    if ($LASTEXITCODE -ne 0) {
        $registry = (& npm config get registry).Trim()
        throw "Unable to restore app dependencies from $registry. Check network or VPN access, then rerun . .\scripts\prereqs.ps1."
    }
    Write-Host '  [ok] App dependencies restored'
}

Write-Host ''
Write-Host '============================================='
Write-Host '  Onboarding Lab - Prerequisite Setup'
Write-Host '============================================='
Write-Host ''
Write-Host 'Platform: Windows'
Write-Host ''

Ensure-Command -Name 'Azure CLI' -Command 'az' -PackageId 'Microsoft.AzureCLI'
Ensure-Command -Name 'Azure Developer CLI' -Command 'azd' -PackageId 'Microsoft.Azd'
Ensure-Command -Name 'PowerShell 7' -Command 'pwsh' -PackageId 'Microsoft.PowerShell'
Ensure-Node

if (Get-Command npm -ErrorAction SilentlyContinue) {
    Write-Host "  [ok] npm registry $((& npm config get registry).Trim())"
}
elseif ($Check) {
    $script:Missing++
}
else {
    throw 'Required command is still unavailable: npm.'
}

if ($Check) {
    if ($script:Missing -gt 0) {
        Write-Host ''
        throw "$($script:Missing) prerequisite(s) need installation, activation, or configuration."
    }
}
else {
    Update-ProcessPath
    foreach ($command in @('az', 'azd', 'pwsh', 'node')) {
        if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
            throw "Required command is still unavailable: $command. Open a new terminal and rerun with -Check."
        }
    }

    if ((Get-NodeMajorVersion) -lt 22) {
        throw 'Node.js 22 or later is still not active in this terminal.'
    }
}

Restore-AppDependencies

Write-Host ''
Write-Host 'All local prerequisites are installed and active in this terminal.'
Write-Host "  Node.js: $(& node --version) ($((Get-Command node).Source))"
Write-Host "  npm registry: $((& npm config get registry).Trim())"
if (-not $Check) {
    Write-Host '  App dependencies: restored'
}