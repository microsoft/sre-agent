param namePrefix string
param agentLocation string
param splunkLocation string
param agentVnetAddressPrefix string
param splunkVnetAddressPrefix string
param agentSubnetPrefix string
param splunkSubnetPrefix string
param splunkNsgId string
param natGatewayId string
param privateDnsZoneName string
param tags object

resource agentVnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: '${namePrefix}-agent-vnet'
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

resource splunkVnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: '${namePrefix}-splunk-vnet'
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
  name: 'splunk-subnet'
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

resource agentToSplunk 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-05-01' = {
  parent: agentVnet
  name: 'agent-to-splunk'
  dependsOn: [
    agentSubnet
    splunkSubnet
  ]
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
  dependsOn: [
    agentSubnet
    splunkSubnet
    agentToSplunk
  ]
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

resource privateDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' existing = {
  name: privateDnsZoneName
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

output agentSubnetId string = agentSubnet.id
output splunkSubnetId string = splunkSubnet.id
output agentVnetId string = agentVnet.id
output splunkVnetId string = splunkVnet.id
