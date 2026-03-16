// ============================================================
// Main Bicep — Deployment Compliance Demo
// Deploys: Container App + Log Analytics + SRE Agent
// ============================================================
targetScope = 'subscription'

@minLength(1)
@maxLength(64)
@description('Name of the environment (e.g. "compliance-demo")')
param environmentName string

@minLength(1)
@description('Primary location for all resources')
param location string

@description('Container image to deploy (e.g. myacr.azurecr.io/api:latest)')
param containerImage string = ''

@description('Object ID of the user running azd up (for role assignments)')
param principalId string = ''

@description('Client ID of the GitHub Actions service principal (compliant caller)')
param cicdServicePrincipalClientId string = ''

// Tags applied to all resources
var tags = {
  'azd-env-name': environmentName
  purpose: 'deployment-compliance-demo'
  'deployed-by': 'pipeline'   // CI/CD tag — compliance signal
}

// Resource group for all resources
resource rg 'Microsoft.Resources/resourceGroups@2021-04-01' = {
  name: 'rg-${environmentName}'
  location: location
  tags: tags
}

// ---- Workload infrastructure (Container App + ACR) ----
module workload 'modules/workload.bicep' = {
  scope: rg
  name: 'workload'
  params: {
    location: location
    environmentName: environmentName
    tags: tags
    containerImage: containerImage
  }
}

// ---- Monitoring infrastructure (LAW + Diagnostic Settings + Alerts) ----
module monitoring 'modules/monitoring.bicep' = {
  scope: rg
  name: 'monitoring'
  params: {
    location: location
    environmentName: environmentName
    tags: tags
    containerAppId: workload.outputs.containerAppId
    containerAppName: workload.outputs.containerAppName
  }
}

// ---- SRE Agent (Microsoft.App/agents via ARM API) ----
module sreAgent 'modules/sre-agent.bicep' = {
  scope: rg
  name: 'sre-agent'
  params: {
    location: location
    environmentName: environmentName
    tags: tags
    logAnalyticsWorkspaceId: monitoring.outputs.logAnalyticsWorkspaceCustomerId
    logAnalyticsWorkspaceKey: monitoring.outputs.logAnalyticsWorkspaceKey
    managedResourceGroupId: rg.id
    deployingUserObjectId: principalId
  }
}

// ---- Role assignments (Subscription Reader for SRE Agent MI) ----
module roles 'modules/roles.bicep' = {
  name: 'role-assignments'
  params: {
    sreAgentPrincipalId: sreAgent.outputs.sreAgentPrincipalId
    principalId: principalId
  }
}

// ============================================================
// Outputs
// ============================================================
output RESOURCE_GROUP_NAME string = rg.name
output CONTAINER_APP_NAME string = workload.outputs.containerAppName
output CONTAINER_APP_FQDN string = workload.outputs.containerAppFqdn
output ACR_NAME string = workload.outputs.acrName
output ACR_LOGIN_SERVER string = workload.outputs.acrLoginServer
output LOG_ANALYTICS_WORKSPACE_ID string = monitoring.outputs.logAnalyticsWorkspaceId
output SRE_AGENT_NAME string = sreAgent.outputs.sreAgentName
output SRE_AGENT_ID string = sreAgent.outputs.sreAgentId
output CICD_SP_CLIENT_ID string = cicdServicePrincipalClientId
