// =============================================================================
// Azure Monitor Alert Rules Module
// =============================================================================

@description('Location for resources')
param location string

@description('Base name for resources')
param baseName string

@description('Log Analytics Workspace ID')
param logAnalyticsWorkspaceId string

@description('Action group name')
param actionGroupName string

@description('Email for alert notifications (optional)')
param alertEmail string

@description('Recovery Services Vault name')
param rsvName string

// =============================================================================
// Resources
// =============================================================================

// Action Group for notifications
resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: actionGroupName
  location: 'global'
  properties: {
    groupShortName: 'SREDemo'
    enabled: true
    emailReceivers: alertEmail != '' ? [
      {
        name: 'EmailNotification'
        emailAddress: alertEmail
        useCommonAlertSchema: true
      }
    ] : []
  }
}

// =============================================================================
// VM Performance Alerts
// =============================================================================

// CPU Spike Alert (>90%)
resource cpuAlert 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: 'alert-${baseName}-cpu-spike'
  location: location
  properties: {
    displayName: 'VM CPU Spike Alert'
    description: 'Alerts when CPU usage exceeds 90% for 5 minutes'
    severity: 2
    enabled: true
    evaluationFrequency: 'PT5M'
    scopes: [
      logAnalyticsWorkspaceId
    ]
    targetResourceTypes: [
      'Microsoft.OperationalInsights/workspaces'
    ]
    windowSize: 'PT5M'
    criteria: {
      allOf: [
        {
          query: '''
            Perf
            | where ObjectName == "Processor" and CounterName == "% Processor Time" and InstanceName == "_Total"
            | summarize AvgCPU = avg(CounterValue) by bin(TimeGenerated, 1m), Computer
            | where AvgCPU > 90
          '''
          timeAggregation: 'Count'
          dimensions: [
            {
              name: 'Computer'
              operator: 'Include'
              values: ['*']
            }
          ]
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    actions: {
      actionGroups: [
        actionGroup.id
      ]
    }
  }
}

// Memory Low Alert (<500MB available)
resource memoryAlert 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: 'alert-${baseName}-memory-low'
  location: location
  properties: {
    displayName: 'VM Low Memory Alert'
    description: 'Alerts when available memory is below 500MB'
    severity: 2
    enabled: true
    evaluationFrequency: 'PT5M'
    scopes: [
      logAnalyticsWorkspaceId
    ]
    targetResourceTypes: [
      'Microsoft.OperationalInsights/workspaces'
    ]
    windowSize: 'PT5M'
    criteria: {
      allOf: [
        {
          query: '''
            Perf
            | where CounterName == "Available MBytes Memory" or CounterName == "Available MBytes"
            | summarize AvgMem = avg(CounterValue) by bin(TimeGenerated, 1m), Computer
            | where AvgMem < 500
          '''
          timeAggregation: 'Count'
          dimensions: [
            {
              name: 'Computer'
              operator: 'Include'
              values: ['*']
            }
          ]
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    actions: {
      actionGroups: [
        actionGroup.id
      ]
    }
  }
}

// Disk IOPS Spike Alert
resource diskIopsAlert 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: 'alert-${baseName}-disk-iops'
  location: location
  properties: {
    displayName: 'VM Disk IOPS Spike Alert'
    description: 'Alerts when disk transfers exceed 500/sec'
    severity: 3
    enabled: true
    evaluationFrequency: 'PT5M'
    scopes: [
      logAnalyticsWorkspaceId
    ]
    targetResourceTypes: [
      'Microsoft.OperationalInsights/workspaces'
    ]
    windowSize: 'PT5M'
    criteria: {
      allOf: [
        {
          query: '''
            Perf
            | where CounterName == "Disk Transfers/sec"
            | summarize AvgIOPS = avg(CounterValue) by bin(TimeGenerated, 1m), Computer, InstanceName
            | where AvgIOPS > 500
          '''
          timeAggregation: 'Count'
          dimensions: [
            {
              name: 'Computer'
              operator: 'Include'
              values: ['*']
            }
          ]
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    actions: {
      actionGroups: [
        actionGroup.id
      ]
    }
  }
}

// Low Disk Space Alert (<20% free)
resource diskSpaceAlert 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: 'alert-${baseName}-disk-space'
  location: location
  properties: {
    displayName: 'VM Low Disk Space Alert'
    description: 'Alerts when free disk space is below 20%'
    severity: 2
    enabled: true
    evaluationFrequency: 'PT5M'
    scopes: [
      logAnalyticsWorkspaceId
    ]
    targetResourceTypes: [
      'Microsoft.OperationalInsights/workspaces'
    ]
    windowSize: 'PT5M'
    criteria: {
      allOf: [
        {
          query: '''
            Perf
            | where ObjectName == "Logical Disk" or ObjectName == "LogicalDisk"
            | where CounterName == "% Free Space" and InstanceName != "_Total"
            | summarize AvgFreeSpace = avg(CounterValue) by bin(TimeGenerated, 1m), Computer, InstanceName
            | where AvgFreeSpace < 20
          '''
          timeAggregation: 'Count'
          dimensions: [
            {
              name: 'Computer'
              operator: 'Include'
              values: ['*']
            }
          ]
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    actions: {
      actionGroups: [
        actionGroup.id
      ]
    }
  }
}

// =============================================================================
// Backup Failure Alert
// =============================================================================

resource backupAlert 'Microsoft.Insights/activityLogAlerts@2020-10-01' = {
  name: 'alert-${baseName}-backup-failure'
  location: 'global'
  properties: {
    scopes: [
      resourceGroup().id
    ]
    condition: {
      allOf: [
        {
          field: 'category'
          equals: 'Administrative'
        }
        {
          field: 'resourceType'
          equals: 'Microsoft.RecoveryServices/vaults'
        }
        {
          field: 'status'
          equals: 'Failed'
        }
      ]
    }
    actions: {
      actionGroups: [
        {
          actionGroupId: actionGroup.id
        }
      ]
    }
    enabled: true
    description: 'Alert on backup job failures'
  }
}

// =============================================================================
// Service Health Alert
// =============================================================================

resource serviceHealthAlert 'Microsoft.Insights/activityLogAlerts@2020-10-01' = {
  name: 'alert-${baseName}-service-health'
  location: 'global'
  properties: {
    scopes: [
      subscription().id
    ]
    condition: {
      allOf: [
        {
          field: 'category'
          equals: 'ServiceHealth'
        }
        {
          field: 'properties.incidentType'
          containsAny: [
            'Incident'
            'Maintenance'
            'Informational'
            'Security'
          ]
        }
      ]
    }
    actions: {
      actionGroups: [
        {
          actionGroupId: actionGroup.id
        }
      ]
    }
    enabled: true
    description: 'Alert on Azure Service Health events'
  }
}

// =============================================================================
// Outputs
// =============================================================================

output actionGroupId string = actionGroup.id
output cpuAlertId string = cpuAlert.id
output memoryAlertId string = memoryAlert.id
output diskIopsAlertId string = diskIopsAlert.id
output diskSpaceAlertId string = diskSpaceAlert.id
output backupAlertId string = backupAlert.id
output serviceHealthAlertId string = serviceHealthAlert.id
