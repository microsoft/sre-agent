targetScope = 'subscription'

// ╔══════════════════════════════════════════════════════════════╗
// ║  PowerGrid ZeroOps Lab — Main Bicep Template                ║
// ║  Deploys the full Zava Power ZeroOps SRE Agent demo environment    ║
// ╚══════════════════════════════════════════════════════════════╝

@description('Azure region for all resources')
param location string

@description('Workload name prefix for all resources')
param workloadName string = 'powergrid'

@description('Compute platform: Azure Container Apps or AKS')
@allowed(['aca', 'aks'])
param computePlatform string = 'aca'

@description('Deploy Arc-enabled VM for hybrid scenario (optional)')
param deployArcVm bool = false

@description('Container image tag to deploy')
param imageTag string = 'latest'

@description('RBAC tier for the SRE Agent managed identity. custom = least-priv (PowerGrid SRE Agent Operator); contributor = built-in Contributor on RG; readonly = no remediation. Set by preprovision script.')
@allowed(['custom', 'contributor', 'readonly'])
param rbacTier string = 'custom'

@description('Role definition GUID for the operator role assigned to the SRE Agent MI. Empty when rbacTier=readonly. Set by preprovision script after probing.')
param agentOperatorRoleId string = ''

var resourceGroupName = 'rg-${workloadName}'
var tags = {
  project: 'zava-power-zeroops-lab'
  environment: 'demo'
  managedBy: 'bicep'
}

// ── Resource Group ────────────────────────────────────────────
resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceGroupName
  location: location
  tags: tags
}

// ── Observability (Log Analytics + App Insights + Grafana) ────
module observability 'modules/observability.bicep' = {
  name: 'observability'
  scope: rg
  params: {
    location: location
    workloadName: workloadName
    tags: tags
  }
}

// ── SRE Agent Identity ────────────────────────────────────────
module sreIdentity 'modules/sre-identity.bicep' = {
  name: 'sre-identity'
  scope: rg
  params: {
    location: location
    workloadName: workloadName
    tags: tags
  }
}

// ── Container Registry ────────────────────────────────────────
module acr 'modules/container-registry.bicep' = {
  name: 'container-registry'
  scope: rg
  params: {
    location: location
    workloadName: workloadName
    tags: tags
  }
}

// ── Compute: ACA or AKS ──────────────────────────────────────
module containerApps 'modules/container-apps.bicep' = if (computePlatform == 'aca') {
  name: 'container-apps'
  scope: rg
  params: {
    location: location
    workloadName: workloadName
    tags: tags
    logAnalyticsWorkspaceId: observability.outputs.logAnalyticsWorkspaceId
    appInsightsConnectionString: observability.outputs.appInsightsConnectionString
    containerRegistryName: acr.outputs.registryName
    imageTag: imageTag
  }
}

module aks 'modules/aks.bicep' = if (computePlatform == 'aks') {
  name: 'aks'
  scope: rg
  params: {
    location: location
    workloadName: workloadName
    tags: tags
    logAnalyticsWorkspaceId: observability.outputs.logAnalyticsWorkspaceId
    containerRegistryName: acr.outputs.registryName
  }
}

// ── Azure Monitor Alerts ──────────────────────────────────────
module alerts 'modules/alerts.bicep' = {
  name: 'alerts'
  scope: rg
  params: {
    location: location
    workloadName: workloadName
    tags: tags
    logAnalyticsWorkspaceId: observability.outputs.logAnalyticsWorkspaceId
    appInsightsId: observability.outputs.appInsightsId
  }
}

// ── SRE Agent ─────────────────────────────────────────────────
module sreAgent 'modules/sre-agent.bicep' = {
  name: 'sre-agent'
  scope: rg
  params: {
    location: location
    workloadName: workloadName
    tags: tags
    targetResourceGroupName: resourceGroupName
    identityId: sreIdentity.outputs.identityId
    identityPrincipalId: sreIdentity.outputs.identityPrincipalId
    appInsightsAppId: observability.outputs.appInsightsAppId
    appInsightsConnectionString: observability.outputs.appInsightsConnectionString
    appInsightsId: observability.outputs.appInsightsId
    rbacTier: rbacTier
    agentOperatorRoleId: agentOperatorRoleId
  }
}

// ── Arc-Enabled VM (Optional) ─────────────────────────────────
module arcVm 'modules/arc-vm.bicep' = if (deployArcVm) {
  name: 'arc-vm'
  scope: rg
  params: {
    location: location
    workloadName: workloadName
    tags: tags
    logAnalyticsWorkspaceId: observability.outputs.logAnalyticsWorkspaceId
  }
}

// ── Outputs ───────────────────────────────────────────────────
output resourceGroupName string = rg.name
output AZURE_RESOURCE_GROUP string = rg.name
output AZURE_LOCATION string = location
output logAnalyticsWorkspaceId string = observability.outputs.logAnalyticsWorkspaceId
output appInsightsConnectionString string = observability.outputs.appInsightsConnectionString
output containerRegistryName string = acr.outputs.registryName
output CONTAINER_REGISTRY_NAME string = acr.outputs.registryName
output CONTAINER_APP_PREFIX string = 'ca-${workloadName}'
output WORKLOAD_NAME string = workloadName
output portalUrl string = computePlatform == 'aca' && containerApps != null ? containerApps.outputs.portalUrl : ''
output sreAgentName string = sreAgent.outputs.agentName
output SRE_OPS_AGENT_NAME string = sreAgent.outputs.agentName
output sreAgentPortalUrl string = sreAgent.outputs.agentPortalUrl
