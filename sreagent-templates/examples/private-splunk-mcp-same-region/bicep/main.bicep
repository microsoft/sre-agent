targetScope = 'resourceGroup'

@description('Prefix used for lab resource names.')
@minLength(3)
@maxLength(24)
param namePrefix string = 'sre-splunk'

@description('Region that hosts both the existing SRE Agent and the private Splunk VM.')
param location string = 'eastus2'

@description('Address space for the shared lab VNet.')
param vnetAddressPrefix string = '10.100.0.0/16'

@description('Dedicated /27-or-larger subnet delegated to Microsoft.App/environments.')
param agentSubnetPrefix string = '10.100.0.0/27'

@description('Subnet used only by the private Splunk VM.')
param splunkSubnetPrefix string = '10.100.1.0/24'

@description('Static private IP assigned to the Splunk VM and private DNS record.')
param splunkPrivateIp string = '10.100.1.4'

@description('Private DNS zone used by the lab.')
param privateDnsZoneName string = 'lab.internal'

@description('Private DNS record name for the Splunk MCP endpoint.')
param splunkDnsRecordName string = 'splunk-mcp'

@description('Ubuntu VM size. Confirm quota and availability in location before deployment.')
param vmSize string = 'Standard_D4as_v5'

@description('Administrator username for the private VM.')
param adminUsername string = 'azureuser'

@description('SSH public key used for Azure VM Run Command break-glass access. The VM receives no public IP.')
param adminSshPublicKey string

@description('Optional Azure resource tags.')
param tags object = {}

var vnetName = '${namePrefix}-vnet'
var agentSubnetName = 'agent-subnet'
var splunkSubnetName = 'splunk-subnet'
var splunkNsgName = '${namePrefix}-splunk-nsg'
var natGatewayName = '${namePrefix}-splunk-nat'
var natPublicIpName = '${namePrefix}-splunk-nat-pip'
var vmName = '${namePrefix}-vm'
var nicName = '${vmName}-nic'

resource splunkNsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: splunkNsgName
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'AllowAgentToPrivateTestAndMcp'
        properties: {
          priority: 100
          access: 'Allow'
          direction: 'Inbound'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRanges: [
            '8080'
            '8089'
          ]
          sourceAddressPrefix: agentSubnetPrefix
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'DenyOtherVirtualNetworkInbound'
        properties: {
          priority: 4000
          access: 'Deny'
          direction: 'Inbound'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: 'VirtualNetwork'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'DenyInternetInbound'
        properties: {
          priority: 4010
          access: 'Deny'
          direction: 'Inbound'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: 'Internet'
          destinationAddressPrefix: '*'
        }
      }
    ]
  }
}

resource natPublicIp 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: natPublicIpName
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource natGateway 'Microsoft.Network/natGateways@2024-05-01' = {
  name: natGatewayName
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    idleTimeoutInMinutes: 10
    publicIpAddresses: [
      {
        id: natPublicIp.id
      }
    ]
  }
}

resource labVnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: vnetName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressPrefix
      ]
    }
  }
}

resource agentSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' = {
  parent: labVnet
  name: agentSubnetName
  properties: {
    addressPrefix: agentSubnetPrefix
    delegations: [
      {
        name: 'sre-agent-environment'
        properties: {
          serviceName: 'Microsoft.App/environments'
        }
      }
    ]
  }
}

resource splunkSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' = {
  parent: labVnet
  name: splunkSubnetName
  dependsOn: [
    agentSubnet
  ]
  properties: {
    addressPrefix: splunkSubnetPrefix
    networkSecurityGroup: {
      id: splunkNsg.id
    }
    natGateway: {
      id: natGateway.id
    }
  }
}

resource privateDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: privateDnsZoneName
  location: 'global'
  tags: tags
}

resource labDnsLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: privateDnsZone
  name: 'lab-vnet-link'
  location: 'global'
  tags: tags
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: labVnet.id
    }
  }
}

resource splunkDnsRecord 'Microsoft.Network/privateDnsZones/A@2024-06-01' = {
  parent: privateDnsZone
  name: splunkDnsRecordName
  properties: {
    ttl: 300
    aRecords: [
      {
        ipv4Address: splunkPrivateIp
      }
    ]
  }
}

resource vmNic 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: nicName
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Static'
          privateIPAddress: splunkPrivateIp
          subnet: {
            id: splunkSubnet.id
          }
        }
      }
    ]
  }
}

resource splunkVm 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: vmName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    hardwareProfile: {
      vmSize: vmSize
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
          storageAccountType: 'Premium_LRS'
        }
      }
    }
    osProfile: {
      computerName: vmName
      adminUsername: adminUsername
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: adminSshPublicKey
            }
          ]
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: vmNic.id
        }
      ]
    }
    securityProfile: {
      securityType: 'TrustedLaunch'
      uefiSettings: {
        secureBootEnabled: true
        vTpmEnabled: true
      }
    }
  }
}

output agentSubnetId string = agentSubnet.id
output labVnetId string = labVnet.id
output splunkVmId string = splunkVm.id
output splunkVmName string = splunkVm.name
output splunkPrivateIp string = splunkPrivateIp
output splunkPrivateHostname string = '${splunkDnsRecordName}.${privateDnsZone.name}'
output splunkHttpsMcpEndpoint string = 'https://${splunkDnsRecordName}.${privateDnsZone.name}:8089/services/mcp'
output privateTestEndpoint string = 'http://${splunkDnsRecordName}.${privateDnsZone.name}:8080'
