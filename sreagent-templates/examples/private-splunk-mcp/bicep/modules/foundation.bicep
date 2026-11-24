param namePrefix string
param location string
param agentSubnetPrefix string
param privateDnsZoneName string
param tags object

resource splunkNsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: '${namePrefix}-splunk-nsg'
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
  name: '${namePrefix}-splunk-nat-pip'
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
  name: '${namePrefix}-splunk-nat'
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

resource privateDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: privateDnsZoneName
  location: 'global'
  tags: tags
}

output splunkNsgId string = splunkNsg.id
output natGatewayId string = natGateway.id
output privateDnsZoneId string = privateDnsZone.id
output privateDnsZoneName string = privateDnsZone.name
