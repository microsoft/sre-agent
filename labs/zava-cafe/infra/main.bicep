// ──────────────────────────────────────────────────────────────
// Zava — Zava Café SRE Agent Lab
// Subscription-scoped entrypoint. Creates the resource group and
// delegates to resources.bicep + subscription-rbac.bicep.
// ──────────────────────────────────────────────────────────────

targetScope = 'subscription'

@description('Name of the environment (auto-populated by azd)')
param environmentName string

@description('Primary location for all resources')
param location string = 'westus2'

@description('Naming prefix for all resources')
param prefix string = 'zava'

@description('Entra ID user/group login (UPN) to set as SQL Server admin')
param aadAdminLogin string

@description('Entra ID user/group object ID to set as SQL Server admin')
param aadAdminObjectId string

@description('Optional alert notification email address')
param alertEmail string = ''

// Resource group
var resourceGroupName = 'rg-${environmentName}'

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceGroupName
  location: location
}

// Deploy app + agent resources into the resource group
module resources 'resources.bicep' = {
  name: 'resources-deployment'
  scope: rg
  params: {
    environmentName: environmentName
    location: location
    prefix: prefix
    aadAdminLogin: aadAdminLogin
    aadAdminObjectId: aadAdminObjectId
    alertEmail: alertEmail
  }
}

// Subscription-scoped RBAC for SRE Agent managed identity
module subscriptionRbac 'modules/subscription-rbac.bicep' = {
  name: 'subscription-rbac-${environmentName}'
  params: {
    principalId: resources.outputs.identityPrincipalId
  }
}

// Outputs consumed by azd and post-provision script
output AZURE_RESOURCE_GROUP string = rg.name
output AZURE_LOCATION string = location
output SRE_AGENT_NAME string = resources.outputs.agentName
output SRE_AGENT_ENDPOINT string = resources.outputs.agentEndpoint
output AGENT_PORTAL_URL string = resources.outputs.agentPortalUrl
output AZURE_SQL_SERVER_FQDN string = resources.outputs.sqlServerFqdn
output AZURE_SQL_DATABASE string = resources.outputs.sqlDatabaseName
output AZURE_APP_URL string = resources.outputs.appUrl
output AZURE_APP_NAME string = resources.outputs.appName
output AZURE_WEBAPP_PRINCIPAL_ID string = resources.outputs.webAppPrincipalId
output APPINSIGHTS_CONNECTION_STRING string = resources.outputs.appInsightsConnectionString
