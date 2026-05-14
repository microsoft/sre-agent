// ── SRE Agents: Ops + IT Support ──
// Based on microsoft/sre-agent/labs/zava-eats/infra/modules/sre-agent.bicep

param location string
param workloadName string
param tags object
param targetResourceGroupName string
param identityId string
param identityPrincipalId string
param appInsightsAppId string
param appInsightsConnectionString string
param appInsightsId string

@allowed(['custom', 'contributor', 'readonly'])
param rbacTier string = 'custom'

@description('Operator role definition GUID. Empty when rbacTier=readonly.')
param agentOperatorRoleId string = ''

var assignOperatorRole = rbacTier != 'readonly' && !empty(agentOperatorRoleId)

var agentName = 'sre-zavapower-ops'
var sreAgentAdminRoleId = 'e79298df-d852-4c6d-84f9-5d13249d1e55'

// ── RBAC: Reader on target resource group ──
resource readerRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(identityId, targetResourceGroupName, 'Reader')
  properties: {
    principalId: identityPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'acdd72a7-3385-48ef-bd42-f606fba81ae7')
  }
}

// ── RBAC: Monitoring Reader ──
resource monitoringReaderRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(identityId, targetResourceGroupName, 'Monitoring Reader')
  properties: {
    principalId: identityPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '43d0d8ad-25c7-4714-9337-8ba259a9fe05')
  }
}

// ── RBAC: Log Analytics Reader ──
resource logAnalyticsReaderRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(identityId, targetResourceGroupName, 'Log Analytics Reader')
  properties: {
    principalId: identityPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '73c42c96-874c-492b-b04d-ab87d138a893')
  }
}

// ── RBAC: Operator role for SRE Agent writes ──
// rbacTier='custom'      → PowerGrid SRE Agent Operator (least-priv, 11 actions, RG-scoped)
//                          Created by preprovision-rbac via az role definition create
//                          using infra/roles/powergrid-sre-agent-operator.json
// rbacTier='contributor' → Built-in Contributor (broader, RG-scoped) — fallback when
//                          custom role can't be created (tenant role limit, no perms)
// rbacTier='readonly'    → no operator role; agent can detect/diagnose only
//                          (Reader, Monitoring Reader, Log Analytics Reader still granted)
//
// Either way the agent's actionConfiguration.mode is 'Review' so every action requires
// human approval — in 'readonly' mode the human admin handles remediation manually.
resource sreAgentOperatorRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (assignOperatorRole) {
  name: guid(identityId, targetResourceGroupName, 'PowerGrid SRE Agent Operator', rbacTier)
  properties: {
    principalId: identityPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', agentOperatorRoleId)
  }
}

// ── SRE Agent Resource ──
#disable-next-line BCP081
resource sreAgent 'Microsoft.App/agents@2025-05-01-preview' = {
  name: agentName
  location: location
  tags: union(tags, {
    'hidden-link: /app-insights-resource-id': appInsightsId
  })
  identity: {
    type: 'SystemAssigned, UserAssigned'
    userAssignedIdentities: {
      '${identityId}': {}
    }
  }
  properties: {
    knowledgeGraphConfiguration: {
      managedResources: [
        resourceGroup().id
      ]
      identity: identityId
    }
    actionConfiguration: {
      mode: 'Review'
      identity: identityId
      accessLevel: 'Low'
    }
    mcpServers: []
    logConfiguration: {
      applicationInsightsConfiguration: {
        appId: appInsightsAppId
        connectionString: appInsightsConnectionString
      }
    }
  }
  dependsOn: [
    readerRole
    monitoringReaderRole
    logAnalyticsReaderRole
  ]
}

// ── Assign SRE Agent Administrator to deployer (ops) ──
resource sreAgentAdminRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(sreAgent.id, deployer().objectId, sreAgentAdminRoleId)
  scope: sreAgent
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', sreAgentAdminRoleId)
    principalId: deployer().objectId
    principalType: 'User'
  }
}

// PythonTool's DefaultAzureCredential picks the system-assigned MI by default,
// so the operator role MUST also be granted to the agent's system-assigned identity
// (not just to the user-assigned identity). Skipped in readonly mode.
resource sreAgentSystemMiOperatorRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (assignOperatorRole) {
  name: guid(sreAgent.id, targetResourceGroupName, 'PowerGrid SRE Agent Operator', 'system', rbacTier)
  properties: {
    principalId: sreAgent.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', agentOperatorRoleId)
  }
}

// ── IT Support Agent removed: extracted to labs/zava-itsupport/ ──

output agentName string = sreAgent.name
output agentId string = sreAgent.id
output agentPortalUrl string = 'https://sre.azure.com'
