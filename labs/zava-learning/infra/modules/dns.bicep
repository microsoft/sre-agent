// Private DNS zone for the Container Apps environment default domain, with a
// wildcard A record to the environment's internal static IP and a VNet link.
// This lets the Application Gateway resolve the portal's internal FQDN.
@description('Resource name suffix token.')
param resourceToken string
@description('Tags applied to all resources.')
param tags object = {}
@description('Container Apps environment default domain.')
param defaultDomain string
@description('Container Apps environment static IP.')
param environmentStaticIp string
@description('VNet resource id to link.')
param vnetId string

resource zone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: defaultDomain
  location: 'global'
  tags: tags
}

resource wildcard 'Microsoft.Network/privateDnsZones/A@2020-06-01' = {
  parent: zone
  name: '*'
  properties: {
    ttl: 300
    aRecords: [ { ipv4Address: environmentStaticIp } ]
  }
}

resource link 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: zone
  name: 'link-${resourceToken}'
  location: 'global'
  tags: tags
  properties: {
    registrationEnabled: false
    virtualNetwork: { id: vnetId }
  }
}
