<#
.SYNOPSIS
    Step 4 (On-Prem Windows Server): Installs the Azure Connected Machine Agent (azcmagent) and
    onboards win-caldova-exp01 to Azure Arc over outbound HTTPS 443.

.DESCRIPTION
    Supports both Service Principal onboarding (generate credentials with 
    .\azure\create-arc-onboarding-sp.ps1) and interactive device-code login.
    Note: Must run on genuine non-Azure hardware/VM (Hyper-V, Proxmox, VMware, bare metal).

.EXAMPLE
    # Interactive (device code / browser)
    .\onprem\4-connect-azure-arc.ps1 -SubscriptionId "66a7fcba-dac3-46d8-b509-202f305618c8"

    # Non-interactive with an onboarding Service Principal
    .\onprem\4-connect-azure-arc.ps1 `
      -SubscriptionId "66a7fcba-dac3-46d8-b509-202f305618c8" `
      -TenantId "<TENANT_ID>" `
      -ServicePrincipalId "<APP_ID>" `
      -ServicePrincipalSecret "<SECRET>"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $SubscriptionId,

    [string] $ResourceGroup = "rg-hybrid-connectivity",
    [string] $Location = "eastus2",
    [string] $MachineName = "win-caldova-exp01",
    [string] $TenantId = "",
    [string] $ServicePrincipalId = "",
    [string] $ServicePrincipalSecret = "",
    [switch] $UseDeviceCode
)

$ErrorActionPreference = "Stop"

$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)
if (-not $isAdmin) {
    throw "Run 4-connect-azure-arc.ps1 from an Administrator PowerShell session."
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13

$azcmagentExe = "$env:ProgramW6432\AzureConnectedMachineAgent\azcmagent.exe"
if (-not (Test-Path $azcmagentExe)) {
    Write-Host "[1/3] Downloading Azure Connected Machine Agent MSI..." -ForegroundColor Cyan
    $msiPath = Join-Path $env:TEMP "AzureConnectedMachineAgent.msi"
    Invoke-WebRequest -Uri "https://aka.ms/AzureConnectedMachineAgent" -OutFile $msiPath -UseBasicParsing

    Write-Host "Installing Azure Connected Machine Agent..." -ForegroundColor Cyan
    $msiProc = Start-Process -FilePath "msiexec.exe" -ArgumentList "/i", "`"$msiPath`"", "/l*v", "`"$env:TEMP\azcmagent-install.log`"", "/qn" -Wait -PassThru
    if ($msiProc.ExitCode -notin @(0, 3010)) {
        throw "azcmagent MSI installation failed with exit code $($msiProc.ExitCode). Check $env:TEMP\azcmagent-install.log."
    }
    Remove-Item -Path $msiPath -Force -ErrorAction SilentlyContinue
}
else {
    Write-Host "[1/3] Azure Connected Machine Agent is already installed." -ForegroundColor Green
}

# Check if already connected
$statusJson = & $azcmagentExe show --json 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue
if ($statusJson -and $statusJson.status -eq "Connected") {
    Write-Host "[2/3] Machine is already Connected to Azure Arc ($($statusJson.resourceId))." -ForegroundColor Green
}
else {
    Write-Host "[2/3] Validating outbound HTTPS 443 reachability to Azure Arc endpoints..." -ForegroundColor Cyan
    & $azcmagentExe check --location $Location

    $connectArgs = @(
        "connect",
        "--subscription-id", $SubscriptionId,
        "--resource-group", $ResourceGroup,
        "--location", $Location,
        "--resource-name", $MachineName,
        "--tags", "Application=CaldovaExpense,Environment=OnPremLab,Role=IIS-SQL"
    )

    if ($TenantId) {
        $connectArgs += @("--tenant-id", $TenantId)
    }

    if ($ServicePrincipalId -and $ServicePrincipalSecret) {
        if (-not $TenantId) {
            throw "-TenantId is required when authenticating with -ServicePrincipalId and -ServicePrincipalSecret."
        }
        $connectArgs += @(
            "--service-principal-id", $ServicePrincipalId,
            "--service-principal-secret", $ServicePrincipalSecret
        )
    }
    elseif ($UseDeviceCode) {
        $connectArgs += "--use-device-code"
    }

    Write-Host "Connecting '$MachineName' to Azure Arc ($ResourceGroup in $Location)..." -ForegroundColor Cyan
    & $azcmagentExe @connectArgs
    if ($LASTEXITCODE -ne 0) {
        throw "azcmagent connect failed with exit code $LASTEXITCODE."
    }
}

Write-Host "[3/3] Verifying Azure Arc agent status..." -ForegroundColor Cyan
& $azcmagentExe show

Write-Host "`nStep 4 complete! Notify the Azure operator to run .\azure\2-attach-arc-monitoring.ps1 (or re-run .\azure\1-setup-azure-and-sre-agent.ps1) to push AMAWindows + DCR associations." -ForegroundColor Green
