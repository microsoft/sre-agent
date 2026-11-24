targetScope = 'subscription'

@minLength(1)
@maxLength(40)
@description('Name of the azd environment. Used to name the resource group.')
param environmentName string

@minLength(1)
@description('Region for the Caldova web app and monitoring resources.')
@metadata({
  azd: {
    type: 'location'
  }
})
param location string

@description('Region for the Azure SRE Agent. Must be an SRE Agent supported region.')
@allowed([
  'australiaeast'
  'canadacentral'
  'centralus'
  'eastasia'
  'eastus2'
  'francecentral'
  'italynorth'
  'japaneast'
  'koreacentral'
  'northcentralus'
  'polandcentral'
  'southafricanorth'
  'southcentralus'
  'southeastasia'
  'spaincentral'
  'swedencentral'
  'uksouth'
  'westcentralus'
  'westus2'
  'westus3'
])
param agentLocation string = 'eastus2'

@description('App Service plan SKU. Must support Always On (Basic or higher).')
param appServicePlanSku string = 'B1'

var tags = {
  'azd-env-name': environmentName
  workload: 'caldova-retail-ops'
}

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: 'rg-${environmentName}'
  location: location
  tags: tags
}

module resources 'resources.bicep' = {
  name: 'caldova-resources'
  scope: rg
  params: {
    location: location
    agentLocation: agentLocation
    appServicePlanSku: appServicePlanSku
    tags: tags
  }
}

module subscriptionReader 'modules/subscription-reader.bicep' = {
  name: 'caldova-sre-subscription-reader'
  params: {
    principalId: resources.outputs.sreAgentPrincipalId
  }
}

output AZURE_LOCATION string = location
output AZURE_RESOURCE_GROUP string = rg.name
output WEB_APP_NAME string = resources.outputs.webAppName
output WEB_APP_URL string = resources.outputs.webAppUrl
output APPLICATION_INSIGHTS_NAME string = resources.outputs.applicationInsightsName
output LOG_ANALYTICS_WORKSPACE_NAME string = resources.outputs.logAnalyticsWorkspaceName
output SRE_AGENT_NAME string = resources.outputs.sreAgentName
output SRE_AGENT_RESOURCE_ID string = resources.outputs.sreAgentResourceId
output SRE_AGENT_PORTAL_URL string = resources.outputs.sreAgentPortalUrl
output SRE_AGENT_READER_ROLE_ASSIGNMENT_ID string = subscriptionReader.outputs.roleAssignmentId
