# Azure Backup Failure Detection - CLI Commands

This document provides Azure CLI commands for detecting and troubleshooting 
backup failures using the SRE Agent.

## Resource Information

```bash
RESOURCE_GROUP="infra-sre-demo-rg"
VAULT_NAME="rsv-sre-demo"
```

## List All Backup Jobs

```bash
# List all backup jobs (last 7 days by default)
az backup job list \
  --resource-group $RESOURCE_GROUP \
  --vault-name $VAULT_NAME \
  --output table

# Output columns: Name, Operation, Status, Item Name, Start Time UTC
```

## List Failed Backup Jobs

```bash
# List only failed backup jobs
az backup job list \
  --resource-group $RESOURCE_GROUP \
  --vault-name $VAULT_NAME \
  --status Failed \
  --output table

# Get detailed information about failed jobs
az backup job list \
  --resource-group $RESOURCE_GROUP \
  --vault-name $VAULT_NAME \
  --status Failed \
  --query "[].{JobId:name, Status:properties.status, VMName:properties.entityFriendlyName, StartTime:properties.startTime, EndTime:properties.endTime, ErrorCode:properties.errorDetails[0].errorCode, ErrorMessage:properties.errorDetails[0].errorString}" \
  --output table
```

## List In-Progress Backup Jobs

```bash
# List currently running backup jobs
az backup job list \
  --resource-group $RESOURCE_GROUP \
  --vault-name $VAULT_NAME \
  --status InProgress \
  --output table
```

## Get Backup Job Details

```bash
# Get detailed information about a specific job
JOB_NAME="<job-id-from-list>"
az backup job show \
  --resource-group $RESOURCE_GROUP \
  --vault-name $VAULT_NAME \
  --name $JOB_NAME \
  --output json
```

## List Protected Items (VMs with Backup Enabled)

```bash
# List all VMs protected by the vault
az backup item list \
  --resource-group $RESOURCE_GROUP \
  --vault-name $VAULT_NAME \
  --backup-management-type AzureIaasVM \
  --query "[].{Name:properties.friendlyName, Status:properties.protectionStatus, HealthStatus:properties.healthStatus, LastBackupStatus:properties.lastBackupStatus, LastBackupTime:properties.lastBackupTime}" \
  --output table
```

## Check Backup Policy

```bash
# List backup policies
az backup policy list \
  --resource-group $RESOURCE_GROUP \
  --vault-name $VAULT_NAME \
  --output table

# Get policy details
az backup policy show \
  --resource-group $RESOURCE_GROUP \
  --vault-name $VAULT_NAME \
  --name "DemoBackupPolicy" \
  --output json
```

## Trigger Manual Backup

```bash
# Trigger backup for a specific VM
VM_NAME="vm-sre-demo-01"
CONTAINER_NAME="IaasVMContainer;iaasvmcontainerv2;$RESOURCE_GROUP;$VM_NAME"
ITEM_NAME="VM;iaasvmcontainerv2;$RESOURCE_GROUP;$VM_NAME"

az backup protection backup-now \
  --resource-group $RESOURCE_GROUP \
  --vault-name $VAULT_NAME \
  --container-name $CONTAINER_NAME \
  --item-name $ITEM_NAME \
  --backup-management-type AzureIaasVM
```

## Troubleshooting Steps

### 1. Check NSG Rules (Common Cause of Failure)

```bash
# List NSG rules that might block backup
NSG_NAME=$(az network nsg list -g $RESOURCE_GROUP --query "[0].name" -o tsv)

az network nsg rule list \
  --resource-group $RESOURCE_GROUP \
  --nsg-name $NSG_NAME \
  --query "[?access=='Deny'].{Name:name, Priority:priority, Direction:direction, DestinationAddressPrefix:destinationAddressPrefix}" \
  --output table

# Check for rules blocking AzureBackup service tag
az network nsg rule list \
  --resource-group $RESOURCE_GROUP \
  --nsg-name $NSG_NAME \
  --query "[?contains(destinationAddressPrefix, 'AzureBackup') || contains(destinationAddressPrefixes, 'AzureBackup')]" \
  --output table
```

### 2. Check VM Status

```bash
# Verify VM is running (required for backup)
az vm list -g $RESOURCE_GROUP \
  --query "[].{Name:name, PowerState:powerState}" \
  --output table

# Get VM agent status
az vm get-instance-view \
  --resource-group $RESOURCE_GROUP \
  --name $VM_NAME \
  --query "instanceView.vmAgent.statuses[0]" \
  --output json
```

### 3. Check Vault Soft Delete Status

```bash
# Check if soft delete is enabled
az backup vault show \
  --resource-group $RESOURCE_GROUP \
  --name $VAULT_NAME \
  --query "properties.securitySettings.softDeleteSettings" \
  --output json
```

## Common Error Codes and Resolutions

| Error Code | Description | Resolution |
|------------|-------------|------------|
| UserErrorVmNotInDesiredState | VM is not running | Start the VM |
| ExtensionSnapshotFailedNoSecureNetwork | Network connectivity issue | Check NSG rules, allow AzureBackup service tag |
| UserErrorVmAgentNotRunning | VM agent not running | Restart VM agent or reinstall |
| UserErrorRequestDisallowedByPolicy | Azure Policy blocking | Check and update policies |

## ARM REST API Alternative

```bash
# List backup jobs via REST API
SUBSCRIPTION_ID=$(az account show --query id -o tsv)

az rest --method get \
  --uri "https://management.azure.com/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.RecoveryServices/vaults/$VAULT_NAME/backupJobs?api-version=2023-06-01&\$filter=status eq 'Failed'" \
  --output json
```
