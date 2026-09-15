@description('Azure region for the lab workload.')
param location string

@description('Short lowercase prefix used for globally scoped resource names.')
@minLength(3)
@maxLength(20)
param namePrefix string

@description('When true, deny checkout traffic to PostgreSQL on TCP 5432.')
param injectDatabaseFault bool = false

@description('Resource tags applied to the lab resources.')
param tags object = {}

var uniqueSuffix = toLower(uniqueString(resourceGroup().id))
var virtualNetworkName = '${namePrefix}-vnet'
var applicationSubnetName = 'app-service'
var databaseSubnetName = 'postgresql'
var networkSecurityGroupName = '${namePrefix}-app-nsg'
var logAnalyticsName = '${namePrefix}-logs'
var applicationInsightsName = '${namePrefix}-appi'
var appServicePlanName = '${namePrefix}-plan'
var webAppName = '${namePrefix}-checkout-${uniqueSuffix}'
var postgresServerName = take('${namePrefix}-pg-${uniqueSuffix}', 63)
var privateDnsZoneName = 'private.postgres.database.azure.com'
var databaseName = 'checkout'

resource checkoutIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${namePrefix}-checkout-identity'
  location: location
  tags: tags
}

resource applicationNetworkSecurityGroup 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: networkSecurityGroupName
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'PostgreSqlFaultInjection'
        properties: {
          description: 'Toggle for the Azure SRE Agent Onboarding Lab database connectivity incident.'
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
    ]
  }
}

resource virtualNetwork 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: virtualNetworkName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.42.0.0/16'
      ]
    }
    subnets: [
      {
        name: applicationSubnetName
        properties: {
          addressPrefix: '10.42.0.0/23'
          networkSecurityGroup: {
            id: applicationNetworkSecurityGroup.id
          }
          delegations: [
            {
              name: 'Microsoft.Web.serverFarms'
              properties: {
                serviceName: 'Microsoft.Web/serverFarms'
              }
            }
          ]
        }
      }
      {
        name: databaseSubnetName
        properties: {
          addressPrefix: '10.42.2.0/24'
          delegations: [
            {
              name: 'Microsoft.DBforPostgreSQL.flexibleServers'
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
  name: privateDnsZoneName
  location: 'global'
  tags: tags
}

resource privateDnsLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: privateDnsZone
  name: '${namePrefix}-vnet-link'
  location: 'global'
  tags: tags
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: virtualNetwork.id
    }
  }
}

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: logAnalyticsName
  location: location
  tags: tags
  properties: {
    retentionInDays: 30
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
  }
}

resource applicationInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: applicationInsightsName
  location: location
  kind: 'web'
  tags: tags
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalytics.id
  }
}

resource appServicePlan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: appServicePlanName
  location: location
  tags: tags
  kind: 'linux'
  sku: {
    name: 'B1'
    tier: 'Basic'
    capacity: 1
  }
  properties: {
    reserved: true
  }
}

resource postgresServer 'Microsoft.DBforPostgreSQL/flexibleServers@2024-08-01' = {
  name: postgresServerName
  location: location
  tags: tags
  sku: {
    name: 'Standard_B1ms'
    tier: 'Burstable'
  }
  properties: {
    version: '16'
    authConfig: {
      activeDirectoryAuth: 'Enabled'
      passwordAuth: 'Disabled'
      tenantId: tenant().tenantId
    }
    backup: {
      backupRetentionDays: 7
      geoRedundantBackup: 'Disabled'
    }
    highAvailability: {
      mode: 'Disabled'
    }
    network: {
      delegatedSubnetResourceId: resourceId('Microsoft.Network/virtualNetworks/subnets', virtualNetwork.name, databaseSubnetName)
      privateDnsZoneArmResourceId: privateDnsZone.id
      publicNetworkAccess: 'Disabled'
    }
    storage: {
      autoGrow: 'Enabled'
      storageSizeGB: 32
    }
  }
  dependsOn: [
    privateDnsLink
  ]
}

resource checkoutDatabase 'Microsoft.DBforPostgreSQL/flexibleServers/databases@2024-08-01' = {
  parent: postgresServer
  name: databaseName
  properties: {}
}

// Disposable lab only: ARM can bootstrap an Entra administrator without a SQL
// migration host. The app exposes only SELECT 1, never user-supplied SQL.
module checkoutDatabaseAdministrator 'database-identity.bicep' = {
  params: {
    serverName: postgresServer.name
    principalId: checkoutIdentity.properties.principalId
    principalName: checkoutIdentity.name
  }
}

resource checkoutApp 'Microsoft.Web/sites@2024-04-01' = {
  name: webAppName
  location: location
  kind: 'app,linux'
  tags: union(tags, {
    'azd-service-name': 'checkout'
  })
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${checkoutIdentity.id}': {}
    }
  }
  properties: {
    serverFarmId: appServicePlan.id
    httpsOnly: true
    virtualNetworkSubnetId: resourceId('Microsoft.Network/virtualNetworks/subnets', virtualNetwork.name, applicationSubnetName)
    siteConfig: {
      linuxFxVersion: 'NODE|22-lts'
      appCommandLine: 'npm start'
      alwaysOn: true
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      scmMinTlsVersion: '1.2'
      healthCheckPath: '/healthz'
      appSettings: [
        {
          name: 'SCM_DO_BUILD_DURING_DEPLOYMENT'
          value: 'true'
        }
        {
          name: 'ENABLE_ORYX_BUILD'
          value: 'true'
        }
        {
          name: 'AZURE_CLIENT_ID'
          value: checkoutIdentity.properties.clientId
        }
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: applicationInsights.properties.ConnectionString
        }
        {
          name: 'POSTGRES_HOST'
          value: postgresServer.properties.fullyQualifiedDomainName
        }
        {
          name: 'POSTGRES_PORT'
          value: '5432'
        }
        {
          name: 'POSTGRES_DATABASE'
          value: databaseName
        }
        {
          name: 'POSTGRES_USER'
          value: checkoutIdentity.name
        }
      ]
    }
  }
  dependsOn: [
    checkoutDatabase
    checkoutDatabaseAdministrator
  ]
}

resource disableFtp 'Microsoft.Web/sites/basicPublishingCredentialsPolicies@2024-04-01' = {
  parent: checkoutApp
  name: 'ftp'
  properties: {
    allow: false
  }
}

resource disableScmBasicAuth 'Microsoft.Web/sites/basicPublishingCredentialsPolicies@2024-04-01' = {
  parent: checkoutApp
  name: 'scm'
  properties: {
    allow: false
  }
}

output checkoutAppName string = checkoutApp.name
output checkoutAppId string = checkoutApp.id
output checkoutUrl string = 'https://${checkoutApp.properties.defaultHostName}'
output postgresServerId string = postgresServer.id
output postgresHost string = postgresServer.properties.fullyQualifiedDomainName
output applicationInsightsId string = applicationInsights.id
output applicationInsightsAppId string = applicationInsights.properties.AppId
output logAnalyticsWorkspaceId string = logAnalytics.id
output faultInjectionEnabled bool = injectDatabaseFault
output networkSecurityGroupName string = applicationNetworkSecurityGroup.name