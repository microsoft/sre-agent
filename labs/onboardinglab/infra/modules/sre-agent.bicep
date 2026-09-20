// Onboarding lab — SRE Agent
//
// Lab-owned agent template, following the same pattern as the other labs
// (starter-lab, deployment-compliance, vm-cosmosdb, zava-*). The shared
// sreagent-templates/bicep/agent-core.bicep is deliberately NOT used here so
// that lab-specific requirements cannot regress the other labs.
//
// What is lab-specific:
//   * The deployer is a *service principal* (the lab creator agent), not a
//     human. Templates that hardcode principalType: 'User' fail with
//     UnmatchedPrincipalType under a managed identity, so the type is detected
//     rather than assumed.
//   * The Application Insights instance already exists in this resource group
//     (created by ticketingapp-source), so it is referenced rather than passed
//     in piece by piece.
//   * The App Insights connector is created here, so the lab needs one
//     deployment instead of two.

@description('Location for the agent.')
param location string

@description('Name of the SRE Agent.')
param agentName string

@description('Resource ID of the Application Insights instance in this resource group.')
param appInsightsId string

@description('Name for the user-assigned managed identity.')
param identityName string = '${agentName}-id'

@description('Agent action access level.')
@allowed([ 'Low', 'Medium', 'High' ])
param accessLevel string = 'Low'

@description('Agent action mode. Review keeps a human in the loop for writes.')
@allowed([ 'autonomous', 'Review' ])
param actionMode string = 'Review'

@description('Model provider. Anthropic may be blocked by data-residency policy in some regions.')
param defaultModelProvider string = 'MicrosoftFoundry'

@description('Model name. Empty lets the platform choose the provider default.')
param defaultModelName string = ''

@description('''
Principal type of the deployer. Leave empty to detect it: a service principal
has no userPrincipalName. Set explicitly only to override the detection.
''')
@allowed([ '', 'User', 'ServicePrincipal', 'Group' ])
param deployerPrincipalType string = ''

// Built-in role definition IDs.
var readerRoleId = 'acdd72a7-3385-48ef-bd42-f606fba81ae7'
var logAnalyticsReaderRoleId = '73c42c96-874c-492b-b04d-ab87d138a893'
var monitoringReaderRoleId = '43d0d8ad-25c7-4714-9337-8ba259a9fe05'
var sreAgentAdminRoleId = 'e79298df-d852-4c6d-84f9-5d13249d1e55'

// deployer().userPrincipalName is empty for a service principal.
var detectedDeployerPrincipalType = empty(deployer().userPrincipalName) ? 'ServicePrincipal' : 'User'
var effectiveDeployerPrincipalType = empty(deployerPrincipalType) ? detectedDeployerPrincipalType : deployerPrincipalType

resource appInsights 'Microsoft.Insights/components@2020-02-02' existing = {
  name: last(split(appInsightsId, '/'))
}

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: identityName
  location: location
}

// ── RBAC for the user-assigned identity on this resource group ──
// The agent reads the lab resources it investigates: the app, the database,
// the alert rule and the telemetry behind them.

resource uamiReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, identity.id, readerRoleId)
  properties: {
    roleDefinitionId: resourceId('Microsoft.Authorization/roleDefinitions', readerRoleId)
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource uamiLogAnalyticsReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, identity.id, logAnalyticsReaderRoleId)
  properties: {
    roleDefinitionId: resourceId('Microsoft.Authorization/roleDefinitions', logAnalyticsReaderRoleId)
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource uamiMonitoringReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, identity.id, monitoringReaderRoleId)
  properties: {
    roleDefinitionId: resourceId('Microsoft.Authorization/roleDefinitions', monitoringReaderRoleId)
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

#disable-next-line BCP081
resource sreAgent 'Microsoft.App/agents@2025-05-01-preview' = {
  name: agentName
  location: location
  tags: {
    'hidden-link: /app-insights-resource-id': appInsightsId
    lab: 'onboardinglab'
  }
  identity: {
    type: 'SystemAssigned, UserAssigned'
    userAssignedIdentities: { '${identity.id}': {} }
  }
  properties: {
    knowledgeGraphConfiguration: {
      identity: identity.id
      managedResources: [ resourceGroup().id ]
    }
    actionConfiguration: {
      accessLevel: accessLevel
      identity: identity.id
      mode: actionMode
    }
    logConfiguration: {
      applicationInsightsConfiguration: {
        appId: appInsights.properties.AppId
        connectionString: appInsights.properties.ConnectionString
      }
    }
    defaultModel: {
      provider: defaultModelProvider
      name: defaultModelName
    }
  }
  dependsOn: [ uamiReader, uamiLogAnalyticsReader, uamiMonitoringReader ]
}

// The connector queries App Insights using the agent's system-assigned
// identity, so that identity needs read access to this resource group too.

resource systemMiReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, sreAgent.id, readerRoleId)
  properties: {
    roleDefinitionId: resourceId('Microsoft.Authorization/roleDefinitions', readerRoleId)
    principalId: sreAgent.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource systemMiLogAnalyticsReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, sreAgent.id, logAnalyticsReaderRoleId)
  properties: {
    roleDefinitionId: resourceId('Microsoft.Authorization/roleDefinitions', logAnalyticsReaderRoleId)
    principalId: sreAgent.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// ── SRE Agent Administrator ──

resource deployerAdminRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(sreAgent.id, deployer().objectId, sreAgentAdminRoleId)
  scope: sreAgent
  properties: {
    roleDefinitionId: resourceId('Microsoft.Authorization/roleDefinitions', sreAgentAdminRoleId)
    principalId: deployer().objectId
    principalType: effectiveDeployerPrincipalType
  }
}

resource uamiAdminRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(sreAgent.id, identity.id, sreAgentAdminRoleId)
  scope: sreAgent
  properties: {
    roleDefinitionId: resourceId('Microsoft.Authorization/roleDefinitions', sreAgentAdminRoleId)
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// ── Application Insights connector ──

#disable-next-line BCP081
resource appInsightsConnector 'Microsoft.App/agents/connectors@2025-05-01-preview' = {
  parent: sreAgent
  name: 'app-insights'
  properties: {
    dataConnectorType: 'AppInsights'
    dataSource: appInsightsId
    extendedProperties: {
      armResourceId: appInsightsId
      resource: { name: appInsights.name }
      appId: appInsights.properties.AppId
    }
    identity: 'system'
  }
}

// ── Outputs ──
// agentEndpoint must come from the resource. It contains service-assigned
// segments and cannot be composed from the agent name and region.

output agentId string = sreAgent.id
output agentName string = sreAgent.name
output agentEndpoint string = sreAgent.properties.agentEndpoint
output identityId string = identity.id
output identityPrincipalId string = identity.properties.principalId
output systemIdentityPrincipalId string = sreAgent.identity.principalId
