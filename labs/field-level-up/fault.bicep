@description('NSG from the LAB_NSG_NAME azd output.')
param networkSecurityGroupName string

@description('True blocks new PostgreSQL connections; false restores them.')
param injectDatabaseFault bool

resource nsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' existing = {
  name: networkSecurityGroupName
}

resource faultRule 'Microsoft.Network/networkSecurityGroups/securityRules@2024-05-01' = {
  parent: nsg
  name: 'PostgreSqlFaultInjection'
  properties: {
    description: 'Toggle for the Field Level Up database connectivity incident.'
    protocol: 'Tcp'
    sourcePortRange: '*'
    destinationPortRange: '5432'
    sourceAddressPrefix: '10.42.0.0/23'
    destinationAddressPrefix: '10.42.2.0/24'
    access: injectDatabaseFault ? 'Deny' : 'Allow'
    priority: 100
    direction: 'Outbound'
  }
}