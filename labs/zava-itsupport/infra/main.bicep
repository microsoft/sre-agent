// ──────────────────────────────────────────────────────────────
// Zava — IT Support SRE Agent Lab
// Subscription-scoped entrypoint. Creates the resource group and
// delegates to resources.bicep + subscription-rbac.bicep.
// ──────────────────────────────────────────────────────────────

targetScope = 'subscription'

@description('Name of the environment (auto-populated by azd)')
param environmentName string

@description('Primary location for all resources')
param location string = 'westus2'

@description('Naming prefix for all resources')
param prefix string = 'zavaits'

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
output AZURE_CONTAINER_REGISTRY_NAME string = resources.outputs.containerRegistryName
output AZURE_CONTAINER_REGISTRY_LOGIN_SERVER string = resources.outputs.containerRegistryLoginServer
output AZURE_CONTAINER_APPS_ENVIRONMENT_NAME string = resources.outputs.acaEnvName
output AZURE_IT_PORTAL_NAME string = resources.outputs.itPortalAppName
output AZURE_IT_PORTAL_URL string = resources.outputs.itPortalUrl
output AZURE_WARRANTY_API_NAME string = resources.outputs.warrantyAppName
output AZURE_WARRANTY_API_URL string = resources.outputs.warrantyApiUrl
output APPINSIGHTS_CONNECTION_STRING string = resources.outputs.appInsightsConnectionString
