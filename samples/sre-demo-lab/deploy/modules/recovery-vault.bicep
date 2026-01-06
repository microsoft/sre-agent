// =============================================================================
// Recovery Services Vault Module
// =============================================================================

@description('Name of the Recovery Services Vault')
param name string

@description('Location for the vault')
param location string

@description('VM IDs to protect')
param vmIds array

@description('VM names for backup')
param vmNames array

// =============================================================================
// Resources
// =============================================================================

// Recovery Services Vault
resource rsv 'Microsoft.RecoveryServices/vaults@2023-06-01' = {
  name: name
  location: location
  sku: {
    name: 'RS0'
    tier: 'Standard'
  }
  properties: {
    publicNetworkAccess: 'Enabled'
  }
}

// Backup Policy - Frequent backups for demo (every 4 hours)
resource backupPolicy 'Microsoft.RecoveryServices/vaults/backupPolicies@2023-06-01' = {
  parent: rsv
  name: 'DemoBackupPolicy'
  properties: {
    backupManagementType: 'AzureIaasVM'
    instantRpRetentionRangeInDays: 2
    schedulePolicy: {
      schedulePolicyType: 'SimpleSchedulePolicy'
      scheduleRunFrequency: 'Hourly'
      hourlySchedule: {
        interval: 4
        scheduleWindowStartTime: '2024-01-01T00:00:00Z'
        scheduleWindowDuration: 4
      }
    }
    retentionPolicy: {
      retentionPolicyType: 'SimpleRetentionPolicy'
      retentionDuration: {
        count: 7
        durationType: 'Days'
      }
    }
    timeZone: 'UTC'
  }
}

// Note: VM backup protection must be configured after VMs are created
// This is typically done via Azure CLI or PowerShell in the deployment script

// =============================================================================
// Outputs
// =============================================================================

output vaultId string = rsv.id
output vaultName string = rsv.name
output backupPolicyId string = backupPolicy.id
output backupPolicyName string = backupPolicy.name
