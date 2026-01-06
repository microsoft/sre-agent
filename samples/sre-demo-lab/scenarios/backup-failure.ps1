<#
.SYNOPSIS
    Triggers or resolves backup failure for SRE Agent demo.

.DESCRIPTION
    This script manipulates NSG rules to block/allow Azure Backup service,
    causing backup jobs to fail for demonstration purposes.

.PARAMETER ResourceGroupName
    Name of the resource group. Default: infra-sre-demo-rg

.PARAMETER TriggerFailure
    Block Azure Backup service to cause backup failures.

.PARAMETER ResolveFailure
    Remove the blocking rule to restore backup functionality.

.EXAMPLE
    ./backup-failure.ps1 -TriggerFailure

.EXAMPLE
    ./backup-failure.ps1 -ResolveFailure
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ResourceGroupName = "infra-sre-demo-rg",

    [Parameter(Mandatory = $false)]
    [switch]$TriggerFailure,

    [Parameter(Mandatory = $false)]
    [switch]$ResolveFailure
)

$ErrorActionPreference = "Stop"

if (-not $TriggerFailure -and -not $ResolveFailure) {
    Write-Host "Please specify -TriggerFailure or -ResolveFailure" -ForegroundColor Red
    exit 1
}

# Get NSG name
$nsgName = az network nsg list -g $ResourceGroupName --query "[0].name" -o tsv
if (-not $nsgName) {
    Write-Error "No NSG found in resource group: $ResourceGroupName"
}

Write-Host "NSG: $nsgName" -ForegroundColor Cyan

if ($TriggerFailure) {
    Write-Host "`nTriggering backup failure..." -ForegroundColor Yellow
    
    # Add rule to block Azure Backup
    az network nsg rule create `
        --resource-group $ResourceGroupName `
        --nsg-name $nsgName `
        --name "BlockAzureBackup" `
        --priority 100 `
        --direction Outbound `
        --access Deny `
        --protocol "*" `
        --source-address-prefixes "*" `
        --source-port-ranges "*" `
        --destination-address-prefixes "AzureBackup" `
        --destination-port-ranges "*" `
        --output none
    
    Write-Host "✓ NSG rule 'BlockAzureBackup' created" -ForegroundColor Green
    Write-Host "  Backup jobs will now fail" -ForegroundColor Gray
    
    # Trigger immediate backup to generate failure
    Write-Host "`nTriggering backup jobs to generate failures..." -ForegroundColor Yellow
    
    $rsvName = az backup vault list -g $ResourceGroupName --query "[0].name" -o tsv
    $vms = az vm list -g $ResourceGroupName --query "[].name" -o json | ConvertFrom-Json
    
    foreach ($vmName in $vms) {
        $containerName = "IaasVMContainer;iaasvmcontainerv2;$ResourceGroupName;$vmName"
        $itemName = "VM;iaasvmcontainerv2;$ResourceGroupName;$vmName"
        
        az backup protection backup-now `
            --resource-group $ResourceGroupName `
            --vault-name $rsvName `
            --container-name $containerName `
            --item-name $itemName `
            --backup-management-type AzureIaasVM `
            --output none 2>$null
        
        Write-Host "  Backup triggered for: $vmName" -ForegroundColor Gray
    }
    
    Write-Host "`n✓ Backup failure scenario active" -ForegroundColor Green
    Write-Host "  Check failures: az backup job list -g $ResourceGroupName --vault-name $rsvName --status Failed" -ForegroundColor Yellow
}

if ($ResolveFailure) {
    Write-Host "`nResolving backup failure..." -ForegroundColor Yellow
    
    # Remove the blocking rule
    az network nsg rule delete `
        --resource-group $ResourceGroupName `
        --nsg-name $nsgName `
        --name "BlockAzureBackup" `
        --output none 2>$null
    
    Write-Host "✓ NSG rule 'BlockAzureBackup' removed" -ForegroundColor Green
    Write-Host "  Backup jobs will now succeed" -ForegroundColor Gray
}
