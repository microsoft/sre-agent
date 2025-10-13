targetScope = 'subscription'

#disable-next-line BCP081
@description('The name of the SRE Agent')
param agentName string

@description('The subscription ID where resources will be deployed')
param subscriptionId string = subscription().subscriptionId

@description('The name of the resource group where the SRE Agent will be deployed')
param deploymentResourceGroupName string

@description('The location where the resources will be deployed')
@allowed(['swedencentral', 'uksouth', 'eastus2', 'australiaeast'])
param location string = 'eastus2'

@description('Optional: The resource ID of an existing user-assigned managed identity. If not provided, a new one will be created.')
param existingManagedIdentityId string = ''

@description('The access level for the SRE Agent')
@allowed(['High', 'Low'])
param accessLevel string = 'High'

@description('Array of resource group names that the SRE Agent should have permissions to manage')
param targetResourceGroups array = []

@description('Array of subscription IDs where the target resource groups exist (optional, defaults to deployment subscription)')
param targetSubscriptions array = []

// Generate unique suffix for resource names
var uniqueSuffix = uniqueString(subscriptionId, deploymentResourceGroupName)

// Reference to the deployment resource group
resource deploymentResourceGroup 'Microsoft.Resources/resourceGroups@2021-04-01' existing = {
  name: deploymentResourceGroupName
  scope: subscription(subscriptionId)
}

// Deploy SRE Agent resources to the deployment resource group
module sreAgentResourcesDeployment 'sre-agent-resources.bicep' = {
  name: 'sre-agent-resources-${uniqueString(deployment().name)}'
  scope: deploymentResourceGroup
  params: {
    agentName: agentName
    location: location
    existingManagedIdentityId: existingManagedIdentityId
    accessLevel: accessLevel
    targetResourceGroups: targetResourceGroups
    targetSubscriptions: targetSubscriptions
    subscriptionId: subscriptionId
    uniqueSuffix: uniqueSuffix
  }
}

// Outputs
output agentName string = sreAgentResourcesDeployment.outputs.agentName
output agentId string = sreAgentResourcesDeployment.outputs.agentId
output agentPortalUrl string = sreAgentResourcesDeployment.outputs.agentPortalUrl
output userAssignedIdentityId string = sreAgentResourcesDeployment.outputs.userAssignedIdentityId
output applicationInsightsConnectionString string = sreAgentResourcesDeployment.outputs.applicationInsightsConnectionString
output logAnalyticsWorkspaceId string = sreAgentResourcesDeployment.outputs.logAnalyticsWorkspaceId
output createdNewManagedIdentity bool = sreAgentResourcesDeployment.outputs.createdNewManagedIdentity
