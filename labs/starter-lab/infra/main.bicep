targetScope = 'subscription'

@description('Name of the environment (auto-populated by azd)')
param environmentName string

@description('Primary location for all resources')
@allowed(['swedencentral', 'eastus2', 'australiaeast'])
param location string = 'eastus2'

@description('GitHub Personal Access Token (optional - enables GitHub integration)')
@secure()
param githubPat string = ''

// Resource group
var resourceGroupName = 'rg-${environmentName}'

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceGroupName
  location: location
}

// Deploy all resources into the resource group
module resources 'resources.bicep' = {
  name: 'resources-deployment'
  scope: rg
  params: {
    environmentName: environmentName
    location: location
  }
}

// ============================================================
// Subscription-scoped RBAC for SRE Agent managed identity
// ============================================================
module subscriptionRbac 'modules/subscription-rbac.bicep' = {
  name: 'subscription-rbac'
  params: {
    principalId: resources.outputs.identityPrincipalId
  }
}

// Also assign RBAC to the agent's system-assigned identity (used for Azure Monitor alerts)
module subscriptionRbacSystem 'modules/subscription-rbac.bicep' = {
  name: 'subscription-rbac-system'
  params: {
    principalId: resources.outputs.systemIdentityPrincipalId
  }
}

// Outputs consumed by azd and post-provision script
output AZURE_RESOURCE_GROUP string = rg.name
output AZURE_LOCATION string = location
output AZURE_CONTAINER_REGISTRY_ENDPOINT string = resources.outputs.acrLoginServer
output AZURE_CONTAINER_REGISTRY_NAME string = resources.outputs.acrName
output AZURE_CONTAINER_APPS_ENVIRONMENT_NAME string = resources.outputs.containerAppEnvName
output AZURE_CONTAINER_APPS_ENVIRONMENT_ID string = resources.outputs.containerAppEnvId
output SRE_AGENT_NAME string = resources.outputs.agentName
output SRE_AGENT_ENDPOINT string = resources.outputs.agentEndpoint
output AGENT_PORTAL_URL string = resources.outputs.agentPortalUrl
output CONTAINER_APP_URL string = resources.outputs.containerAppUrl
output CONTAINER_APP_NAME string = resources.outputs.containerAppName
output FRONTEND_APP_URL string = resources.outputs.frontendAppUrl
output FRONTEND_APP_NAME string = resources.outputs.frontendAppName
output LOG_ANALYTICS_WORKSPACE_ID string = resources.outputs.logAnalyticsWorkspaceId
output APP_INSIGHTS_CONNECTION_STRING string = resources.outputs.appInsightsConnectionString
