@description('Azure region for the VNet and NSG.')
param location string

@description('Unique suffix for resource names.')
param uniqueSuffix string

var vnetName = 'vnet-Zava-${uniqueSuffix}'
var nsgName = 'nsg-aks-${uniqueSuffix}'

resource nsg 'Microsoft.Network/networkSecurityGroups@2024-01-01' = {
  name: nsgName
  location: location
  properties: {
    securityRules: [
      {
        // Intentionally permissive: this demo needs to reproduce egress patterns
        // (PostgreSQL on 5432, ACR pulls, ARM control plane). A locked-down NSG
        // would mask the failure modes the SRE Agent is supposed to diagnose —
        // Scenario 2 specifically depends on being able to add/remove a deny
        // rule against this open baseline. Do NOT tighten without rewriting the
        // break/fix scenarios.
        name: 'allow-all-outbound'
        properties: {
          priority: 1000
          direction: 'Outbound'
          access: 'Allow'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
    ]
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2024-01-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: ['10.0.0.0/8']
    }
    subnets: [
      {
        name: 'aks-subnet'
        properties: {
          addressPrefix: '10.0.0.0/16'
          networkSecurityGroup: { id: nsg.id }
          serviceEndpoints: [
            { service: 'Microsoft.Storage' }
          ]
        }
      }
      {
        name: 'db-subnet'
        properties: {
          addressPrefix: '10.1.0.0/24'
          delegations: [
            {
              name: 'postgres-delegation'
              properties: {
                serviceName: 'Microsoft.DBforPostgreSQL/flexibleServers'
              }
            }
          ]
        }
      }
    ]
  }
}

resource privateDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: '${uniqueSuffix}.private.postgres.database.azure.com'
  location: 'global'
}

resource privateDnsVnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: privateDnsZone
  name: 'vnet-link'
  location: 'global'
  properties: {
    virtualNetwork: { id: vnet.id }
    registrationEnabled: false
  }
}

output vnetName string = vnet.name
output vnetId string = vnet.id
output aksSubnetId string = vnet.properties.subnets[0].id
output dbSubnetId string = vnet.properties.subnets[1].id
output nsgName string = nsg.name
output privateDnsZoneId string = privateDnsZone.id
