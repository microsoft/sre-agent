<#
.SYNOPSIS
    Deploys the SRE Agent Demo Lab infrastructure to Azure.

.DESCRIPTION
    This script deploys all required Azure resources for demonstrating
    SRE Agent troubleshooting capabilities including:
    - Log Analytics Workspace
    - Virtual Machines with Azure Monitor Agent
    - Data Collection Rules
    - Recovery Services Vault with backup policies
    - Azure Monitor Alert Rules

.PARAMETER SubscriptionId
    The Azure subscription ID to deploy to.

.PARAMETER Location
    The Azure region for deployment. Default: eastus

.PARAMETER ResourceGroupName
    Name of the resource group. Default: infra-sre-demo-rg

.PARAMETER BaseName
    Base name for resources. Default: sre-demo

.PARAMETER VmCount
    Number of VMs to deploy. Default: 2

.PARAMETER AlertEmail
    Optional email address for alert notifications.

.EXAMPLE
    ./deploy.ps1 -SubscriptionId "00000000-0000-0000-0000-000000000000"

.EXAMPLE
    ./deploy.ps1 -SubscriptionId "00000000-0000-0000-0000-000000000000" -Location "westus2" -AlertEmail "admin@contoso.com"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $false)]
    [string]$Location = "eastus",

    [Parameter(Mandatory = $false)]
    [string]$ResourceGroupName = "infra-sre-demo-rg",

    [Parameter(Mandatory = $false)]
    [string]$BaseName = "sre-demo",

    [Parameter(Mandatory = $false)]
    [int]$VmCount = 2,

    [Parameter(Mandatory = $false)]
    [string]$AlertEmail = ""
)

$ErrorActionPreference = "Stop"

# =============================================================================
# Helper Functions
# =============================================================================

function Write-Step {
    param([string]$Message)
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host $Message -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
}

function Write-Success {
    param([string]$Message)
    Write-Host "✓ $Message" -ForegroundColor Green
}

function Write-Info {
    param([string]$Message)
    Write-Host "ℹ $Message" -ForegroundColor Yellow
}

# =============================================================================
# Pre-flight Checks
# =============================================================================

Write-Step "Step 1: Pre-flight checks"

# Check Azure CLI
try {
    $azVersion = az version --output json | ConvertFrom-Json
    Write-Success "Azure CLI version: $($azVersion.'azure-cli')"
} catch {
    Write-Error "Azure CLI is not installed. Please install it from https://docs.microsoft.com/cli/azure/install-azure-cli"
}

# Check logged in
$account = az account show --output json 2>$null | ConvertFrom-Json
if (-not $account) {
    Write-Error "Not logged in to Azure CLI. Please run 'az login' first."
}
Write-Success "Logged in as: $($account.user.name)"

# Set subscription
Write-Info "Setting subscription to: $SubscriptionId"
az account set --subscription $SubscriptionId
Write-Success "Subscription set successfully"

# =============================================================================
# Generate SSH Key
# =============================================================================

Write-Step "Step 2: Generate SSH key pair"

$sshKeyPath = "$env:USERPROFILE\.ssh\sre-demo-key"
if (-not (Test-Path $sshKeyPath)) {
    Write-Info "Generating new SSH key pair..."
    ssh-keygen -t rsa -b 4096 -f $sshKeyPath -N '""' -q
    Write-Success "SSH key generated at: $sshKeyPath"
} else {
    Write-Success "Using existing SSH key: $sshKeyPath"
}

$sshPublicKey = Get-Content "$sshKeyPath.pub"

# =============================================================================
# Create Resource Group
# =============================================================================

Write-Step "Step 3: Create Resource Group"

$rgExists = az group exists --name $ResourceGroupName
if ($rgExists -eq "true") {
    Write-Info "Resource group '$ResourceGroupName' already exists"
} else {
    az group create --name $ResourceGroupName --location $Location --output none
    Write-Success "Created resource group: $ResourceGroupName in $Location"
}

# =============================================================================
# Deploy Bicep Template
# =============================================================================

Write-Step "Step 4: Deploy infrastructure (this may take 10-15 minutes)"

$deploymentName = "sre-demo-deployment-$(Get-Date -Format 'yyyyMMddHHmmss')"
$templateFile = Join-Path $PSScriptRoot "main.bicep"

Write-Info "Starting deployment: $deploymentName"

$deploymentOutput = az deployment group create `
    --name $deploymentName `
    --resource-group $ResourceGroupName `
    --template-file $templateFile `
    --parameters `
        location=$Location `
        baseName=$BaseName `
        sshPublicKey="$sshPublicKey" `
        vmCount=$VmCount `
        alertEmail="$AlertEmail" `
    --output json | ConvertFrom-Json

if ($LASTEXITCODE -ne 0) {
    Write-Error "Deployment failed. Check the Azure portal for details."
}

Write-Success "Deployment completed successfully"

# Extract outputs
$outputs = $deploymentOutput.properties.outputs
$logAnalyticsWorkspaceName = $outputs.logAnalyticsWorkspaceName.value
$vmNames = $outputs.vmNames.value
$rsvName = $outputs.rsvName.value

# =============================================================================
# Configure VM Backup Protection
# =============================================================================

Write-Step "Step 5: Configure VM Backup Protection"

foreach ($vmName in $vmNames) {
    Write-Info "Enabling backup for VM: $vmName"
    
    az backup protection enable-for-vm `
        --resource-group $ResourceGroupName `
        --vault-name $rsvName `
        --vm $vmName `
        --policy-name "DemoBackupPolicy" `
        --output none 2>$null
    
    if ($LASTEXITCODE -eq 0) {
        Write-Success "Backup enabled for: $vmName"
    } else {
        Write-Info "Backup may already be configured for: $vmName"
    }
}

# =============================================================================
# Trigger Initial Backup
# =============================================================================

Write-Step "Step 6: Trigger initial backup jobs"

foreach ($vmName in $vmNames) {
    Write-Info "Starting backup for: $vmName"
    
    $containerName = "IaasVMContainer;iaasvmcontainerv2;$ResourceGroupName;$vmName"
    $itemName = "VM;iaasvmcontainerv2;$ResourceGroupName;$vmName"
    
    az backup protection backup-now `
        --resource-group $ResourceGroupName `
        --vault-name $rsvName `
        --container-name $containerName `
        --item-name $itemName `
        --backup-management-type AzureIaasVM `
        --output none 2>$null
    
    Write-Success "Backup job started for: $vmName"
}

# =============================================================================
# Summary
# =============================================================================

Write-Step "Deployment Complete!"

Write-Host "`nResources Created:" -ForegroundColor White
Write-Host "  • Resource Group: $ResourceGroupName" -ForegroundColor Gray
Write-Host "  • Log Analytics: $logAnalyticsWorkspaceName" -ForegroundColor Gray
Write-Host "  • VMs: $($vmNames -join ', ')" -ForegroundColor Gray
Write-Host "  • Recovery Vault: $rsvName" -ForegroundColor Gray

Write-Host "`nNext Steps:" -ForegroundColor White
Write-Host "  1. Wait 5-10 minutes for Azure Monitor Agent to start collecting metrics" -ForegroundColor Gray
Write-Host "  2. Run './scenarios/generate-problems.ps1' to create troubleshooting scenarios" -ForegroundColor Gray
Write-Host "  3. Use SRE Agent to detect and troubleshoot the issues" -ForegroundColor Gray

Write-Host "`nSSH Access:" -ForegroundColor White
foreach ($vmName in $vmNames) {
    $publicIp = az vm show -g $ResourceGroupName -n $vmName -d --query publicIps -o tsv
    Write-Host "  ssh -i $sshKeyPath azureuser@$publicIp" -ForegroundColor Gray
}

Write-Host "`n" -NoNewline
