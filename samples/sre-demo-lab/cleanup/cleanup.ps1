<#
.SYNOPSIS
    Cleans up all SRE Demo Lab resources.

.DESCRIPTION
    Removes all resources created by the deploy script, including:
    - Virtual Machines
    - Log Analytics Workspace
    - Recovery Services Vault
    - All associated resources in the resource group

.PARAMETER SubscriptionId
    The Azure subscription ID. If not specified, uses current subscription.

.PARAMETER ResourceGroupName
    Name of the resource group. Default: infra-sre-demo-rg

.PARAMETER Force
    Skip confirmation prompt.

.EXAMPLE
    ./cleanup.ps1

.EXAMPLE
    ./cleanup.ps1 -Force
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $false)]
    [string]$ResourceGroupName = "infra-sre-demo-rg",

    [Parameter(Mandatory = $false)]
    [switch]$Force
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
# Pre-flight
# =============================================================================

if ($SubscriptionId) {
    az account set --subscription $SubscriptionId
}

$currentSub = az account show --query name -o tsv
Write-Host "Subscription: $currentSub" -ForegroundColor Cyan

# Check if RG exists
$rgExists = az group exists --name $ResourceGroupName
if ($rgExists -eq "false") {
    Write-Host "Resource group '$ResourceGroupName' does not exist. Nothing to clean up." -ForegroundColor Yellow
    exit 0
}

# List resources
Write-Step "Resources to be deleted"

$resources = az resource list -g $ResourceGroupName --query "[].{Name:name, Type:type}" -o json | ConvertFrom-Json
Write-Host "Found $($resources.Count) resources in $ResourceGroupName`:" -ForegroundColor White
foreach ($resource in $resources) {
    Write-Host "  • $($resource.Name) ($($resource.Type))" -ForegroundColor Gray
}

# =============================================================================
# Confirmation
# =============================================================================

if (-not $Force) {
    Write-Host "`n"
    $confirmation = Read-Host "Are you sure you want to delete all these resources? (yes/no)"
    if ($confirmation -ne "yes") {
        Write-Host "Cleanup cancelled." -ForegroundColor Yellow
        exit 0
    }
}

# =============================================================================
# Disable Backup Protection
# =============================================================================

Write-Step "Step 1: Disable Backup Protection"

$rsvName = az backup vault list -g $ResourceGroupName --query "[0].name" -o tsv 2>$null

if ($rsvName) {
    Write-Info "Disabling backup protection for VMs..."
    
    $items = az backup item list `
        -g $ResourceGroupName `
        --vault-name $rsvName `
        --backup-management-type AzureIaasVM `
        --query "[].name" -o json 2>$null | ConvertFrom-Json
    
    foreach ($item in $items) {
        Write-Info "  Disabling backup for: $item"
        
        # Get container name from item
        $containerName = az backup item show `
            -g $ResourceGroupName `
            --vault-name $rsvName `
            --name $item `
            --backup-management-type AzureIaasVM `
            --query "properties.containerName" -o tsv 2>$null
        
        # Disable protection and delete data
        az backup protection disable `
            -g $ResourceGroupName `
            --vault-name $rsvName `
            --container-name $containerName `
            --item-name $item `
            --backup-management-type AzureIaasVM `
            --delete-backup-data true `
            --yes `
            --output none 2>$null
    }
    
    Write-Success "Backup protection disabled"
} else {
    Write-Info "No Recovery Services Vault found"
}

# =============================================================================
# Remove NSG Blocking Rules
# =============================================================================

Write-Step "Step 2: Remove NSG Blocking Rules"

$nsgName = az network nsg list -g $ResourceGroupName --query "[0].name" -o tsv 2>$null

if ($nsgName) {
    # Remove any blocking rules we added
    az network nsg rule delete `
        -g $ResourceGroupName `
        --nsg-name $nsgName `
        --name "BlockAzureBackup" `
        --output none 2>$null
    
    Write-Success "NSG cleanup complete"
} else {
    Write-Info "No NSG found"
}

# =============================================================================
# Delete Resource Group
# =============================================================================

Write-Step "Step 3: Delete Resource Group (this may take several minutes)"

Write-Info "Deleting resource group: $ResourceGroupName"

az group delete --name $ResourceGroupName --yes --no-wait

Write-Success "Resource group deletion initiated"

# =============================================================================
# Clean up SSH Keys
# =============================================================================

Write-Step "Step 4: Clean up local SSH keys (optional)"

$sshKeyPath = "$env:USERPROFILE\.ssh\sre-demo-key"
if (Test-Path $sshKeyPath) {
    $deleteKeys = Read-Host "Delete SSH key at $sshKeyPath? (yes/no)"
    if ($deleteKeys -eq "yes") {
        Remove-Item $sshKeyPath -Force
        Remove-Item "$sshKeyPath.pub" -Force
        Write-Success "SSH keys deleted"
    } else {
        Write-Info "SSH keys retained"
    }
} else {
    Write-Info "No SSH keys found"
}

# =============================================================================
# Summary
# =============================================================================

Write-Step "Cleanup Complete!"

Write-Host "`nThe following actions were taken:" -ForegroundColor White
Write-Host "  • Disabled backup protection for all VMs" -ForegroundColor Gray
Write-Host "  • Removed NSG blocking rules" -ForegroundColor Gray
Write-Host "  • Initiated resource group deletion" -ForegroundColor Gray

Write-Host "`nNote: Resource group deletion runs in the background." -ForegroundColor Yellow
Write-Host "Check the Azure portal to confirm deletion is complete.`n" -ForegroundColor Yellow
