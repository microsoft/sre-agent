// ── Arc-Enabled VM (Simulated On-Prem Server) ──

param location string
param workloadName string
param tags object
param logAnalyticsWorkspaceId string

param vmSize string = 'Standard_B2ms'
param adminUsername string = 'azureuser'

@secure()
param adminPassword string = 'P@ssw0rd${uniqueString(resourceGroup().id)}!'

// ── Network ──
resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: 'vnet-${workloadName}-arc'
  location: location
  tags: tags
  properties: {
    addressSpace: { addressPrefixes: ['10.100.0.0/24'] }
    subnets: [
      { name: 'default', properties: { addressPrefix: '10.100.0.0/24' } }
    ]
  }
}

resource pip 'Microsoft.Network/publicIPAddresses@2023-11-01' = {
  name: 'pip-${workloadName}-arc'
  location: location
  tags: tags
  sku: { name: 'Standard' }
  properties: { publicIPAllocationMethod: 'Static' }
}

resource nic 'Microsoft.Network/networkInterfaces@2023-11-01' = {
  name: 'nic-${workloadName}-arc'
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          publicIPAddress: { id: pip.id }
          subnet: { id: vnet.properties.subnets[0].id }
        }
      }
    ]
  }
}

// ── VM ──
resource vm 'Microsoft.Compute/virtualMachines@2024-03-01' = {
  name: 'vm-${workloadName}-arc'
  location: location
  tags: union(tags, { role: 'simulated-onprem' })
  identity: { type: 'SystemAssigned' }
  properties: {
    hardwareProfile: { vmSize: vmSize }
    osProfile: {
      computerName: 'grid-mgmt-01'
      adminUsername: adminUsername
      adminPassword: adminPassword
      windowsConfiguration: {
        provisionVMAgent: true
        enableAutomaticUpdates: true
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'MicrosoftWindowsServer'
        offer: 'WindowsServer'
        sku: '2022-datacenter-g2'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: { storageAccountType: 'StandardSSD_LRS' }
        diskSizeGB: 64
      }
      dataDisks: [
        {
          lun: 0
          name: 'data-${workloadName}-arc'
          createOption: 'Empty'
          diskSizeGB: 32
          managedDisk: { storageAccountType: 'StandardSSD_LRS' }
        }
      ]
    }
    networkProfile: { networkInterfaces: [{ id: nic.id }] }
  }
}

// ── Azure Monitor Agent extension ──
resource ama 'Microsoft.Compute/virtualMachines/extensions@2024-03-01' = {
  parent: vm
  name: 'AzureMonitorWindowsAgent'
  location: location
  properties: {
    publisher: 'Microsoft.Azure.Monitor'
    type: 'AzureMonitorWindowsAgent'
    typeHandlerVersion: '1.0'
    autoUpgradeMinorVersion: true
  }
}

output vmName string = vm.name
output vmId string = vm.id
output vmPrincipalId string = vm.identity.principalId
output publicIp string = pip.properties.ipAddress
