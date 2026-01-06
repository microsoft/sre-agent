// =============================================================================
// Virtual Machines Module with Azure Monitor Agent
// =============================================================================

@description('Location for VMs')
param location string

@description('Base name for resources')
param baseName string

@description('Admin username')
param adminUsername string

@description('SSH public key')
@secure()
param sshPublicKey string

@description('Number of VMs to create')
param vmCount int

@description('VM size')
param vmSize string

@description('Log Analytics Workspace ID for AMA')
param logAnalyticsWorkspaceId string

// =============================================================================
// Variables
// =============================================================================

var vnetName = 'vnet-${baseName}'
var subnetName = 'subnet-vms'
var vnetAddressPrefix = '10.0.0.0/16'
var subnetAddressPrefix = '10.0.1.0/24'

// =============================================================================
// Resources
// =============================================================================

// Virtual Network
resource vnet 'Microsoft.Network/virtualNetworks@2023-05-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressPrefix
      ]
    }
    subnets: [
      {
        name: subnetName
        properties: {
          addressPrefix: subnetAddressPrefix
        }
      }
    ]
  }
}

// Network Security Group
resource nsg 'Microsoft.Network/networkSecurityGroups@2023-05-01' = {
  name: 'nsg-${baseName}'
  location: location
  properties: {
    securityRules: [
      {
        name: 'AllowSSH'
        properties: {
          priority: 1000
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '22'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
        }
      }
    ]
  }
}

// Public IPs
resource publicIps 'Microsoft.Network/publicIPAddresses@2023-05-01' = [for i in range(0, vmCount): {
  name: 'pip-vm-${baseName}-${padLeft(i + 1, 2, '0')}'
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    dnsSettings: {
      domainNameLabel: 'vm-${baseName}-${padLeft(i + 1, 2, '0')}-${uniqueString(resourceGroup().id)}'
    }
  }
}]

// Network Interfaces
resource nics 'Microsoft.Network/networkInterfaces@2023-05-01' = [for i in range(0, vmCount): {
  name: 'nic-vm-${baseName}-${padLeft(i + 1, 2, '0')}'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: vnet.properties.subnets[0].id
          }
          publicIPAddress: {
            id: publicIps[i].id
          }
        }
      }
    ]
    networkSecurityGroup: {
      id: nsg.id
    }
  }
}]

// Virtual Machines
resource vms 'Microsoft.Compute/virtualMachines@2023-07-01' = [for i in range(0, vmCount): {
  name: 'vm-${baseName}-${padLeft(i + 1, 2, '0')}'
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      computerName: 'vm-${baseName}-${padLeft(i + 1, 2, '0')}'
      adminUsername: adminUsername
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: sshPublicKey
            }
          ]
        }
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: '0001-com-ubuntu-server-jammy'
        sku: '22_04-lts-gen2'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Standard_LRS'
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nics[i].id
        }
      ]
    }
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
      }
    }
  }
}]

// Azure Monitor Agent Extension
resource amaExtension 'Microsoft.Compute/virtualMachines/extensions@2023-07-01' = [for i in range(0, vmCount): {
  parent: vms[i]
  name: 'AzureMonitorLinuxAgent'
  location: location
  properties: {
    publisher: 'Microsoft.Azure.Monitor'
    type: 'AzureMonitorLinuxAgent'
    typeHandlerVersion: '1.0'
    autoUpgradeMinorVersion: true
    enableAutomaticUpgrade: true
    settings: {
      authentication: {
        managedIdentity: {
          'identifier-name': 'mi_res_id'
          'identifier-value': vms[i].id
        }
      }
    }
  }
}]

// Install stress-ng for generating load (custom script extension)
resource stressExtension 'Microsoft.Compute/virtualMachines/extensions@2023-07-01' = [for i in range(0, vmCount): {
  parent: vms[i]
  name: 'InstallStressTools'
  location: location
  dependsOn: [
    amaExtension[i]
  ]
  properties: {
    publisher: 'Microsoft.Azure.Extensions'
    type: 'CustomScript'
    typeHandlerVersion: '2.1'
    autoUpgradeMinorVersion: true
    settings: {
      commandToExecute: 'apt-get update && apt-get install -y stress-ng fio'
    }
  }
}]

// =============================================================================
// Outputs
// =============================================================================

output vmIds array = [for i in range(0, vmCount): vms[i].id]
output vmNames array = [for i in range(0, vmCount): vms[i].name]
output nsgId string = nsg.id
output nsgName string = nsg.name
