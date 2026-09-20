// Onboarding lab - converge the pre-created final SRE Agent
//
// The Cloud Shell bootstrap creates this agent, its identity, and its telemetry
// so Code Access can be completed before deployment. This template declares the
// permanent read-only RBAC and workload connector without updating the running
// agent that is executing the deployment.

@description('Name of the SRE Agent.')
param agentName string

@description('Resource ID of the workload Application Insights instance.')
param workloadAppInsightsId string

@description('Name of the existing user-assigned managed identity used by the agent.')
param identityName string

// Built-in role definition IDs.
var readerRoleId = 'acdd72a7-3385-48ef-bd42-f606fba81ae7'
var logAnalyticsReaderRoleId = '73c42c96-874c-492b-b04d-ab87d138a893'
var monitoringReaderRoleId = '43d0d8ad-25c7-4714-9337-8ba259a9fe05'
resource workloadAppInsights 'Microsoft.Insights/components@2020-02-02' existing = {
  name: last(split(workloadAppInsightsId, '/'))
}

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  name: identityName
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

resource sreAgent 'Microsoft.App/agents@2025-05-01-preview' existing = {
  name: agentName
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

// ── Application Insights connector ──

#disable-next-line BCP081
resource appInsightsConnector 'Microsoft.App/agents/connectors@2025-05-01-preview' = {
  parent: sreAgent
  name: 'app-insights'
  properties: {
    dataConnectorType: 'AppInsights'
    dataSource: workloadAppInsightsId
    extendedProperties: {
      armResourceId: workloadAppInsightsId
      resource: { name: workloadAppInsights.name }
      appId: workloadAppInsights.properties.AppId
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
