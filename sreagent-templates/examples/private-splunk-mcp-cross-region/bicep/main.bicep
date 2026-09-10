targetScope = 'resourceGroup'

@description('Prefix used for lab resource names.')
@minLength(3)
@maxLength(24)
param namePrefix string = 'sre-splunk'

@description('Region that hosts the existing SRE Agent. The delegated agent subnet must be in this region.')
param agentLocation string = 'eastus2'

@description('Region that hosts the private Splunk VM. Use a region different from agentLocation to test cross-region routing.')
param splunkLocation string = 'centralus'

@description('Address space for the SRE Agent VNet.')
param agentVnetAddressPrefix string = '10.20.0.0/16'

@description('Dedicated /27-or-larger subnet delegated to Microsoft.App/environments.')
param agentSubnetPrefix string = '10.20.0.0/27'

@description('Address space for the private Splunk VNet. It must not overlap the agent VNet.')
param splunkVnetAddressPrefix string = '10.40.0.0/16'

@description('Subnet used only by the private Splunk VM.')
param splunkSubnetPrefix string = '10.40.1.0/24'

@description('Static private IP assigned to the Splunk VM and private DNS record.')
param splunkPrivateIp string = '10.40.1.4'

@description('Private DNS zone used by the lab.')
param privateDnsZoneName string = 'lab.internal'

@description('Private DNS record name for the Splunk MCP endpoint.')
param splunkDnsRecordName string = 'splunk-mcp'

@description('Ubuntu VM size. Confirm quota and availability in splunkLocation before deployment.')
param vmSize string = 'Standard_D4as_v5'

@description('Administrator username for the private VM.')
param adminUsername string = 'azureuser'

@description('SSH public key used for Azure VM Run Command break-glass access. The VM receives no public IP.')
param adminSshPublicKey string

@description('Optional Azure resource tags.')
param tags object = {}

var agentVnetName = '${namePrefix}-agent-vnet'
var splunkVnetName = '${namePrefix}-splunk-vnet'
var agentSubnetName = 'agent-subnet'
var splunkSubnetName = 'splunk-subnet'
var splunkNsgName = '${namePrefix}-splunk-nsg'
var natGatewayName = '${namePrefix}-splunk-nat'
var natPublicIpName = '${namePrefix}-splunk-nat-pip'
var vmName = '${namePrefix}-vm'
var nicName = '${vmName}-nic'

resource splunkNsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: splunkNsgName
  location: splunkLocation
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
  location: splunkLocation
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
  location: splunkLocation
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

resource agentVnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: agentVnetName
  location: agentLocation
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        agentVnetAddressPrefix
      ]
    }
  }
}

resource agentSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' = {
  parent: agentVnet
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

resource splunkVnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: splunkVnetName
  location: splunkLocation
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        splunkVnetAddressPrefix
      ]
    }
  }
}

resource splunkSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' = {
  parent: splunkVnet
  name: splunkSubnetName
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

resource agentToSplunk 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-05-01' = {
  parent: agentVnet
  name: 'agent-to-splunk'
  properties: {
    remoteVirtualNetwork: {
      id: splunkVnet.id
    }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: false
    allowGatewayTransit: false
    useRemoteGateways: false
  }
}

resource splunkToAgent 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-05-01' = {
  parent: splunkVnet
  name: 'splunk-to-agent'
  properties: {
    remoteVirtualNetwork: {
      id: agentVnet.id
    }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: false
    allowGatewayTransit: false
    useRemoteGateways: false
  }
}

resource privateDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: privateDnsZoneName
  location: 'global'
  tags: tags
}

resource agentDnsLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: privateDnsZone
  name: 'agent-vnet-link'
  location: 'global'
  tags: tags
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: agentVnet.id
    }
  }
}

resource splunkDnsLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: privateDnsZone
  name: 'splunk-vnet-link'
  location: 'global'
  tags: tags
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: splunkVnet.id
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
  location: splunkLocation
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
  location: splunkLocation
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
output agentVnetId string = agentVnet.id
output splunkVnetId string = splunkVnet.id
output splunkVmId string = splunkVm.id
output splunkVmName string = splunkVm.name
output splunkPrivateIp string = splunkPrivateIp
output splunkPrivateHostname string = '${splunkDnsRecordName}.${privateDnsZone.name}'
output splunkHttpsMcpEndpoint string = 'https://${splunkDnsRecordName}.${privateDnsZone.name}:8089/services/mcp'
output privateTestEndpoint string = 'http://${splunkDnsRecordName}.${privateDnsZone.name}:8080'
