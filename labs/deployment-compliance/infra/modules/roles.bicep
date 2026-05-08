// ============================================================
// Role assignments — Subscription Reader for SRE Agent
// ============================================================
targetScope = 'subscription'

@description('Principal ID of the SRE Agent managed identity')
param sreAgentPrincipalId string

@description('Principal ID of the deploying user (for RBAC on the agent)')
param principalId string

// Built-in role: Reader
var readerRoleId = 'acdd72a7-3385-48ef-bd42-f606fba81ae7'

// Built-in role: Monitoring Reader
var monitoringReaderRoleId = '43d0d8ad-25c7-4714-9337-8ba259a9fe05'

// SRE Agent → Subscription Reader
resource sreAgentReaderRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, sreAgentPrincipalId, readerRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', readerRoleId)
    principalId: sreAgentPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// SRE Agent → Monitoring Reader (to query activity logs)
resource sreAgentMonitoringRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, sreAgentPrincipalId, monitoringReaderRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', monitoringReaderRoleId)
    principalId: sreAgentPrincipalId
    principalType: 'ServicePrincipal'
  }
}
