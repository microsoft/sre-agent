@description('Azure region for the managed identities.')
param location string

@description('Unique suffix for identity resource names.')
param uniqueSuffix string

@description('AKS cluster name — used to grant SRE Agent K8s-level RBAC')
param aksClusterName string

@description('Application Insights component name')
param appInsightsName string

// === App Workload Identity (for AKS pods → PostgreSQL Entra auth) ===
var appIdentityName = 'id-Zava-app-${uniqueSuffix}'

resource appIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: appIdentityName
  location: location
}

// The @azure/monitor-opentelemetry SDK in the api uses the workload identity
// (AZURE_CLIENT_ID injected by the AKS workload-identity webhook) to acquire
// an AAD token for the AI ingestion endpoint when the pod has a federated
// credential — even if APPLICATIONINSIGHTS_CONNECTION_STRING is set. Without
// this role grant, OTel ingestion is silently rejected (HTTP 403/Unauthorized
// on the breeze endpoint), no AppRequests/AppTraces flow, and every
// scheduled-query alert that reads those tables can never fire. We hit this
// in Scenario 3 — queries genuinely slowed to >1s but the alert never fired.
resource aiAppIdentity 'Microsoft.Insights/components@2020-02-02' existing = {
  name: appInsightsName
}

resource appMetricsPublisher 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(aiAppIdentity.id, appIdentity.id, 'metrics-publisher')
  scope: aiAppIdentity
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '3913510d-42f4-4e42-8a64-420c390055eb')
    principalId: appIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// === SRE Agent Identity ===
var sreIdentityName = 'id-sre-agent-${uniqueSuffix}'

resource sreAgentIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: sreIdentityName
  location: location
}

// Reader role on resource group (for SRE Agent)
resource readerRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, sreAgentIdentity.id, 'reader')
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'acdd72a7-3385-48ef-bd42-f606fba81ae7')
    principalId: sreAgentIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// Monitoring Reader role
resource monitoringReaderRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, sreAgentIdentity.id, 'monreader')
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '43d0d8ad-25c7-4714-9337-8ba259a9fe05')
    principalId: sreAgentIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// Contributor on resource group (for start/stop PostgreSQL, NSG modifications)
resource contributorRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, sreAgentIdentity.id, 'contributor')
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b24988ac-6180-42a0-ab88-20f7382dd24c')
    principalId: sreAgentIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// AKS RBAC Cluster Admin — RG-level Contributor does NOT grant K8s access
// when AKS has enableAzureRBAC: true.
resource aksCluster 'Microsoft.ContainerService/managedClusters@2024-09-01' existing = {
  name: aksClusterName
}

resource aksRbacClusterAdmin 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(aksCluster.id, sreAgentIdentity.id, 'aksrbacadmin')
  scope: aksCluster
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b1ff04bb-8a4e-4dc4-8eb5-8693973ce19b')
    principalId: sreAgentIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

output sreAgentIdentityName string = sreAgentIdentity.name
output sreAgentIdentityPrincipalId string = sreAgentIdentity.properties.principalId
output sreAgentIdentityId string = sreAgentIdentity.id
output appIdentityName string = appIdentity.name
output appIdentityClientId string = appIdentity.properties.clientId
output appIdentityPrincipalId string = appIdentity.properties.principalId
