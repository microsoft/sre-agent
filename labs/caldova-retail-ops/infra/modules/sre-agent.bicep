@description('SRE Agent name.')
param agentName string

@description('User-assigned managed identity name for the agent.')
param identityName string

@description('SRE Agent region.')
param location string

param tags object

param workspaceId string
param workspaceName string
param workspaceCustomerId string
param applicationInsightsId string
param applicationInsightsName string
param applicationInsightsAppId string

var contributorRoleId = 'b24988ac-6180-42a0-ab88-20f7382dd24c'
var sreAgentAdminRoleId = 'e79298df-d852-4c6d-84f9-5d13249d1e55'

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: identityName
  location: location
  tags: tags
}

// Lets the agent inspect and repair the lab's resources (for example, the web app's settings).
resource rgContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, identity.id, contributorRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', contributorRoleId)
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource agent 'Microsoft.App/agents@2026-01-01' = {
  name: agentName
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${identity.id}': {}
    }
  }
  properties: {
    knowledgeGraphConfiguration: {
      identity: identity.id
      managedResources: [
        resourceGroup().id
      ]
    }
    actionConfiguration: {
      identity: identity.id
      mode: 'Review'
      accessLevel: 'Low'
    }
    upgradeChannel: 'Stable'
  }
  dependsOn: [
    rgContributor
  ]
}

resource logAnalyticsConnector 'Microsoft.App/agents/connectors@2026-01-01' = {
  parent: agent
  name: 'lab-log-analytics'
  properties: {
    dataConnectorType: 'LogAnalytics'
    #disable-next-line use-secure-value-for-secure-inputs
    dataSource: workspaceId
    identity: identity.id
    extendedProperties: {
      workspace: {
        name: workspaceName
        customerId: workspaceCustomerId
      }
    }
  }
}

resource appInsightsConnector 'Microsoft.App/agents/connectors@2026-01-01' = {
  parent: agent
  name: 'lab-application-insights'
  properties: {
    dataConnectorType: 'AppInsights'
    #disable-next-line use-secure-value-for-secure-inputs
    dataSource: applicationInsightsId
    identity: identity.id
    extendedProperties: {
      armResourceId: applicationInsightsId
      resource: {
        name: applicationInsightsName
      }
      appId: applicationInsightsAppId
    }
  }
}

// Lets the person running `azd up` open and use the agent.
resource deployerAgentAdmin 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(agent.id, deployer().objectId, sreAgentAdminRoleId)
  scope: agent
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', sreAgentAdminRoleId)
    principalId: deployer().objectId
  }
}

output agentName string = agent.name
output agentId string = agent.id
output principalId string = identity.properties.principalId
output portalUrl string = 'https://sre.azure.com'
