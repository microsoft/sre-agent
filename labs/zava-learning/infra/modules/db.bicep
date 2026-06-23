// Azure Database for PostgreSQL Flexible Server (Burstable B1ms) backing the Zava
// Learning platform. Public access + firewall (Azure services + the deployer IP) so the
// VNet-integrated container apps and the post-provision seed step can both reach it.
//
// Two databases:
//   * zava        — shared by the baseline platform and all lanes except query.
//   * zava_query  — owned by the query lane only, so chaos/break-query.ps1 can DROP its
//                   question_bank index (real seq scan) without slowing any other lane.
@description('Azure region.')
param location string
@description('Resource name suffix token.')
param resourceToken string
@description('Tags applied to all resources.')
param tags object = {}

@description('PostgreSQL administrator login.')
param administratorLogin string = 'zavaadmin'
@secure()
@description('PostgreSQL administrator password (generated at deploy time; never committed).')
param administratorPassword string

@description('Public IP of the machine running post-provision seeding (adds a firewall rule). Empty to skip.')
param deployerIp string = ''

var serverName = 'psql-zava-wus3-${resourceToken}'

resource pg 'Microsoft.DBforPostgreSQL/flexibleServers@2024-08-01' = {
  name: serverName
  location: location
  tags: tags
  sku: {
    name: 'Standard_B1ms'
    tier: 'Burstable'
  }
  properties: {
    version: '16'
    administratorLogin: administratorLogin
    administratorLoginPassword: administratorPassword
    storage: { storageSizeGB: 32 }
    backup: { backupRetentionDays: 7, geoRedundantBackup: 'Disabled' }
    highAvailability: { mode: 'Disabled' }
    network: { publicNetworkAccess: 'Enabled' }
  }
}

// Allow other Azure services (incl. the VNet-integrated Container Apps egress) to connect.
resource fwAzure 'Microsoft.DBforPostgreSQL/flexibleServers/firewallRules@2024-08-01' = {
  parent: pg
  name: 'AllowAllAzureServices'
  properties: { startIpAddress: '0.0.0.0', endIpAddress: '0.0.0.0' }
}

// Allow the deployer (post-provision seeding via psql) when an IP is supplied.
resource fwDeployer 'Microsoft.DBforPostgreSQL/flexibleServers/firewallRules@2024-08-01' = if (!empty(deployerIp)) {
  parent: pg
  name: 'AllowDeployer'
  properties: { startIpAddress: deployerIp, endIpAddress: deployerIp }
}

resource dbMain 'Microsoft.DBforPostgreSQL/flexibleServers/databases@2024-08-01' = {
  parent: pg
  name: 'zava'
}

resource dbQuery 'Microsoft.DBforPostgreSQL/flexibleServers/databases@2024-08-01' = {
  parent: pg
  name: 'zava_query'
}

output serverName string = pg.name
output fqdn string = pg.properties.fullyQualifiedDomainName
output administratorLogin string = administratorLogin
output mainDatabase string = dbMain.name
output queryDatabase string = dbQuery.name
