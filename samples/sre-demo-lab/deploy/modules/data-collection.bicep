// =============================================================================
// Data Collection Rules Module
// =============================================================================

@description('Name of the DCR')
param name string

@description('Location for the DCR')
param location string

@description('Log Analytics Workspace ID')
param logAnalyticsWorkspaceId string

@description('VM IDs to associate with DCR')
param vmIds array

// =============================================================================
// Resources
// =============================================================================

// Data Collection Rule for Performance Metrics
resource dcr 'Microsoft.Insights/dataCollectionRules@2022-06-01' = {
  name: name
  location: location
  kind: 'Linux'
  properties: {
    dataSources: {
      performanceCounters: [
        {
          name: 'perfCounterDataSource'
          streams: [
            'Microsoft-Perf'
          ]
          samplingFrequencyInSeconds: 60
          counterSpecifiers: [
            // CPU Metrics
            'Processor(*)\\% Processor Time'
            'Processor(*)\\% Idle Time'
            'Processor(*)\\% User Time'
            'Processor(*)\\% Nice Time'
            'Processor(*)\\% Privileged Time'
            'Processor(*)\\% IO Wait Time'
            'Processor(*)\\% Interrupt Time'
            'Processor(*)\\% DPC Time'
            // Memory Metrics
            'Memory(*)\\Available MBytes Memory'
            'Memory(*)\\% Available Memory'
            'Memory(*)\\Used Memory MBytes'
            'Memory(*)\\% Used Memory'
            'Memory(*)\\Pages/sec'
            'Memory(*)\\Page Reads/sec'
            'Memory(*)\\Page Writes/sec'
            // Disk Metrics
            'Logical Disk(*)\\% Free Space'
            'Logical Disk(*)\\Free Megabytes'
            'Logical Disk(*)\\% Used Space'
            'Logical Disk(*)\\Disk Transfers/sec'
            'Logical Disk(*)\\Disk Read Bytes/sec'
            'Logical Disk(*)\\Disk Write Bytes/sec'
            'Logical Disk(*)\\Disk Reads/sec'
            'Logical Disk(*)\\Disk Writes/sec'
            // Network Metrics
            'Network(*)\\Total Bytes Transmitted'
            'Network(*)\\Total Bytes Received'
            'Network(*)\\Total Bytes'
            'Network(*)\\Total Packets Transmitted'
            'Network(*)\\Total Packets Received'
          ]
        }
      ]
      syslog: [
        {
          name: 'syslogDataSource'
          streams: [
            'Microsoft-Syslog'
          ]
          facilityNames: [
            'auth'
            'authpriv'
            'cron'
            'daemon'
            'kern'
            'syslog'
            'user'
          ]
          logLevels: [
            'Debug'
            'Info'
            'Notice'
            'Warning'
            'Error'
            'Critical'
            'Alert'
            'Emergency'
          ]
        }
      ]
    }
    destinations: {
      logAnalytics: [
        {
          name: 'logAnalyticsDestination'
          workspaceResourceId: logAnalyticsWorkspaceId
        }
      ]
    }
    dataFlows: [
      {
        streams: [
          'Microsoft-Perf'
        ]
        destinations: [
          'logAnalyticsDestination'
        ]
      }
      {
        streams: [
          'Microsoft-Syslog'
        ]
        destinations: [
          'logAnalyticsDestination'
        ]
      }
    ]
  }
}

// DCR Associations for each VM
resource dcrAssociations 'Microsoft.Insights/dataCollectionRuleAssociations@2022-06-01' = [for (vmId, i) in vmIds: {
  name: 'dcr-assoc-${i}'
  scope: resourceId('Microsoft.Compute/virtualMachines', last(split(vmId, '/')))
  properties: {
    dataCollectionRuleId: dcr.id
  }
}]

// =============================================================================
// Outputs
// =============================================================================

output dcrId string = dcr.id
output dcrName string = dcr.name
