param namePrefix string
param location string
param vnetAddressPrefix string
param agentSubnetPrefix string
param splunkSubnetPrefix string
param splunkNsgId string
param natGatewayId string
param privateDnsZoneName string
param tags object

resource labVnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: '${namePrefix}-vnet'
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
  name: 'agent-subnet'
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
  name: 'splunk-subnet'
  dependsOn: [
    agentSubnet
  ]
  properties: {
    addressPrefix: splunkSubnetPrefix
    networkSecurityGroup: {
      id: splunkNsgId
    }
    natGateway: {
      id: natGatewayId
    }
  }
}

resource privateDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' existing = {
  name: privateDnsZoneName
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

output agentSubnetId string = agentSubnet.id
output splunkSubnetId string = splunkSubnet.id
output agentVnetId string = labVnet.id
output splunkVnetId string = labVnet.id
