@description('Name of the environment')
param environmentName string

@description('Location for all resources')
param location string

// ============================================================
// Variables
// ============================================================
var uniqueSuffix = uniqueString(resourceGroup().id, environmentName)
var agentName = 'sre-agent-${uniqueSuffix}'
var logAnalyticsName = 'law-${uniqueSuffix}'
var appInsightsName = 'appi-${uniqueSuffix}'
var identityName = 'id-sre-${uniqueSuffix}'
var containerAppEnvName = 'cae-${uniqueSuffix}'
var containerAppName = 'ca-grubify-${uniqueSuffix}'

// ============================================================
// Module: Monitoring (Log Analytics + App Insights)
// ============================================================
module monitoring 'modules/monitoring.bicep' = {
  name: 'monitoring'
  params: {
    location: location
    logAnalyticsName: logAnalyticsName
    appInsightsName: appInsightsName
  }
}

// ============================================================
// Module: Managed Identity + RBAC
// ============================================================
module identity 'modules/identity.bicep' = {
  name: 'identity'
  params: {
    location: location
    identityName: identityName
  }
}

// ============================================================
// Module: Container App (Grubify)
// ============================================================
module containerApp 'modules/container-app.bicep' = {
  name: 'container-app'
  params: {
    location: location
    containerAppEnvName: containerAppEnvName
    containerAppName: containerAppName
    logAnalyticsWorkspaceId: monitoring.outputs.logAnalyticsWorkspaceId
    logAnalyticsWorkspaceKey: monitoring.outputs.logAnalyticsWorkspaceKey
  }
}

// ============================================================
// Module: SRE Agent
// ============================================================
module sreAgent 'modules/sre-agent.bicep' = {
  name: 'sre-agent'
  params: {
    location: location
    agentName: agentName
    identityId: identity.outputs.identityId
    identityPrincipalId: identity.outputs.identityPrincipalId
    appInsightsAppId: monitoring.outputs.appInsightsAppId
    appInsightsConnectionString: monitoring.outputs.appInsightsConnectionString
    appInsightsId: monitoring.outputs.appInsightsId
    managedResourceGroupId: resourceGroup().id
  }
}

// ============================================================
// Module: Alert Rules
// ============================================================
module alertRules 'modules/alert-rules.bicep' = {
  name: 'alert-rules'
  params: {
    containerAppId: containerApp.outputs.containerAppId
    environmentName: environmentName
  }
}

// ============================================================
// Outputs
// ============================================================
output agentName string = sreAgent.outputs.agentName
output agentEndpoint string = sreAgent.outputs.agentEndpoint
output agentPortalUrl string = sreAgent.outputs.agentPortalUrl
output containerAppUrl string = containerApp.outputs.containerAppUrl
output containerAppName string = containerApp.outputs.containerAppName
output frontendAppUrl string = containerApp.outputs.frontendAppUrl
output frontendAppName string = containerApp.outputs.frontendAppName
output containerAppEnvName string = containerApp.outputs.containerAppEnvName
output containerAppEnvId string = containerApp.outputs.containerAppEnvId
output acrName string = containerApp.outputs.acrName
output acrLoginServer string = containerApp.outputs.acrLoginServer
output identityPrincipalId string = identity.outputs.identityPrincipalId
output systemIdentityPrincipalId string = sreAgent.outputs.systemIdentityPrincipalId
output logAnalyticsWorkspaceId string = monitoring.outputs.logAnalyticsWorkspaceId
output appInsightsConnectionString string = monitoring.outputs.appInsightsConnectionString
