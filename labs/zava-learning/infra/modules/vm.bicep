// Reporting-worker VM (disk scenario). A small Ubuntu Standard_D2as_v6 VM (NVMe disk
// controller) that runs a "nightly grade
// export" job (see src/reporting-worker/cloud-init.yaml). Exports are written to a separate
// 8 GB DATA disk mounted at /data; chaos/break-disk.ps1 fills that disk so the export job
// fails with "No space left on device". The Azure Monitor Agent ships Syslog (where the
// worker logs its heartbeats/failures) to Log Analytics so the alert can page on the SYMPTOM
// (grade exports failing) and the SRE Agent can diagnose the disk-pressure root cause.
@description('Azure region for all resources.')
param location string
@description('Resource name suffix token.')
param resourceToken string
@description('Tags applied to all resources.')
param tags object = {}
@description('Resource id of the subnet the VM NIC attaches to (vm-subnet).')
param subnetId string
@description('Log Analytics workspace resource id (Syslog + disk perf destination).')
param logAnalyticsWorkspaceId string
@description('Admin username for the VM.')
param adminUsername string = 'zavaops'
@secure()
@description('Admin password for the VM.')
param adminPassword string

var vmName = 'vm-zava-reporting-${resourceToken}'

resource nic 'Microsoft.Network/networkInterfaces@2023-11-01' = {
  name: 'nic-${vmName}'
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: { id: subnetId }
          privateIPAllocationMethod: 'Dynamic'
        }
      }
    ]
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: vmName
  location: location
  tags: tags
  properties: {
    hardwareProfile: { vmSize: 'Standard_D2as_v6' }
    osProfile: {
      computerName: 'zava-reporting'
      adminUsername: adminUsername
      adminPassword: adminPassword
      customData: loadFileAsBase64('../../src/reporting-worker/cloud-init.yaml')
      linuxConfiguration: {
        disablePasswordAuthentication: false
      }
    }
    storageProfile: {
      diskControllerType: 'NVMe'
      imageReference: {
        publisher: 'Canonical'
        offer: '0001-com-ubuntu-server-jammy'
        sku: '22_04-lts-gen2'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: { storageAccountType: 'Standard_LRS' }
      }
      dataDisks: [
        {
          lun: 0
          name: 'datadisk-${vmName}'
          createOption: 'Empty'
          diskSizeGB: 8
          managedDisk: { storageAccountType: 'Standard_LRS' }
        }
      ]
    }
    networkProfile: {
      networkInterfaces: [ { id: nic.id } ]
    }
  }
}

// Azure Monitor Agent — collects Syslog (and disk perf) and ships to Log Analytics.
resource ama 'Microsoft.Compute/virtualMachines/extensions@2023-09-01' = {
  parent: vm
  name: 'AzureMonitorLinuxAgent'
  location: location
  tags: tags
  properties: {
    publisher: 'Microsoft.Azure.Monitor'
    type: 'AzureMonitorLinuxAgent'
    typeHandlerVersion: '1.29'
    autoUpgradeMinorVersion: true
    enableAutomaticUpgrade: true
  }
}

// Data Collection Rule: Syslog (so the alert can read the worker's heartbeat/failure lines)
// plus Linux disk performance counters (so the SRE Agent has real disk telemetry to diagnose).
resource dcr 'Microsoft.Insights/dataCollectionRules@2022-06-01' = {
  name: 'dcr-zava-reporting-${resourceToken}'
  location: location
  tags: tags
  kind: 'Linux'
  properties: {
    dataSources: {
      syslog: [
        {
          name: 'zavaSyslog'
          streams: [ 'Microsoft-Syslog' ]
          facilityNames: [ 'user', 'daemon', 'syslog' ]
          logLevels: [ 'Info', 'Notice', 'Warning', 'Error', 'Critical', 'Alert', 'Emergency' ]
        }
      ]
      performanceCounters: [
        {
          name: 'zavaDiskPerf'
          streams: [ 'Microsoft-Perf' ]
          samplingFrequencyInSeconds: 60
          counterSpecifiers: [
            'Logical Disk(*)\\% Used Space'
            'Logical Disk(*)\\Free Megabytes'
          ]
        }
      ]
    }
    destinations: {
      logAnalytics: [
        {
          name: 'zavaLaw'
          workspaceResourceId: logAnalyticsWorkspaceId
        }
      ]
    }
    dataFlows: [
      {
        streams: [ 'Microsoft-Syslog' ]
        destinations: [ 'zavaLaw' ]
      }
      {
        streams: [ 'Microsoft-Perf' ]
        destinations: [ 'zavaLaw' ]
      }
    ]
  }
}

resource dcrAssociation 'Microsoft.Insights/dataCollectionRuleAssociations@2022-06-01' = {
  name: 'dcra-zava-reporting'
  scope: vm
  properties: {
    dataCollectionRuleId: dcr.id
  }
  dependsOn: [ ama ]
}

output vmName string = vm.name
output vmId string = vm.id
