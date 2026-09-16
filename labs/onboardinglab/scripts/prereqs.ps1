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
$script:NeedsPowerShellRestart = $false

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

function Ensure-PowerShellHost {
    if ($PSVersionTable.PSVersion.Major -ge 7) {
        Write-Host "  [ok] PowerShell $($PSVersionTable.PSVersion) host"
        return
    }

    Write-Host "  [restart required] Current host is Windows PowerShell $($PSVersionTable.PSVersion)"
    if ($Check) {
        $script:Missing++
    }
    else {
        $script:NeedsPowerShellRestart = $true
    }
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

function Get-WorkingPython {
    $candidates = @(
        @{ Command = 'py'; Arguments = @('-3') },
        @{ Command = 'python'; Arguments = @() },
        @{ Command = 'python3'; Arguments = @() }
    )
    foreach ($candidate in $candidates) {
        $resolved = Get-Command $candidate.Command -ErrorAction SilentlyContinue
        if (-not $resolved) { continue }
        $version = & $resolved.Source @($candidate.Arguments) -c 'import sys; print(sys.version.split()[0])' 2>$null
        if ($LASTEXITCODE -eq 0 -and $version) {
            return [pscustomobject]@{
                Command = $resolved.Source
                Arguments = @($candidate.Arguments)
                Version = ($version -join '').Trim()
            }
        }
    }
    return $null
}

function Ensure-Python {
    $python = Get-WorkingPython
    if (-not $python) {
        Write-Host '  [missing] Python 3'
        if ($Check) {
            $script:Missing++
            return
        }
        Install-WinGetPackage -Name 'Python 3' -Id 'Python.Python.3.12'
        $python = Get-WorkingPython
        if (-not $python) { throw 'Python was installed but is not executable in this terminal.' }
    }

    Write-Host "  [ok] Python $($python.Version)"
    & $python.Command @($python.Arguments) -c 'import yaml' 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Host '  [ok] PyYAML'
        $script:Python = $python
        return
    }

    Write-Host '  [missing] PyYAML'
    if ($Check) {
        $script:Missing++
        return
    }
    & $python.Command @($python.Arguments) -m pip install PyYAML
    if ($LASTEXITCODE -ne 0) { throw 'Unable to install PyYAML with the selected Python interpreter.' }
    & $python.Command @($python.Arguments) -c 'import yaml' 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'PyYAML is still unavailable after installation.' }
    $script:Python = $python
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
Ensure-PowerShellHost
Ensure-Command -Name 'jq' -Command 'jq' -PackageId 'jqlang.jq'
Ensure-Python
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
    foreach ($command in @('az', 'azd', 'pwsh', 'jq', 'node')) {
        if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
            throw "Required command is still unavailable: $command. Open a new terminal and rerun with -Check."
        }
    }

    if ((Get-NodeMajorVersion) -lt 22) {
        throw 'Node.js 22 or later is still not active in this terminal.'
    }
}

Restore-AppDependencies

if ($script:NeedsPowerShellRestart) {
    throw 'PowerShell 7 is installed. Open a PowerShell 7 terminal with pwsh, return to labs\onboardinglab, and run . .\scripts\prereqs.ps1 -Check.'
}

Write-Host ''
Write-Host 'All local prerequisites are installed and active in this terminal.'
Write-Host "  Node.js: $(& node --version) ($((Get-Command node).Source))"
Write-Host "  Python: $($script:Python.Version) ($($script:Python.Command))"
Write-Host "  npm registry: $((& npm config get registry).Trim())"
if (-not $Check) {
    Write-Host '  App dependencies: restored'
}