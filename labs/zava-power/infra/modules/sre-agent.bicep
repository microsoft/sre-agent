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

// ── RBAC: Custom least-priv role for SRE Agent writes ──
// "PowerGrid SRE Agent Operator" — created out-of-band via:
//   az role definition create --role-definition infra/roles/powergrid-sre-agent-operator.json
// Grants ONLY the actions the agent needs across demo scenarios:
//   • Microsoft.App/containerApps/{write,listSecrets,revisions/{activate,deactivate,restart}}
//   • Microsoft.Compute/virtualMachines/{runCommand,runCommands/{write,delete},restart}
//   • Microsoft.HybridCompute/machines/runCommands/{write,delete}
// See docs/SRE-AGENT-MI-ACCESS.md for rationale.
var sreAgentOperatorRoleId = 'b592102b-80f0-4cc3-99ac-282f746b0978'
resource sreAgentOperatorRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(identityId, targetResourceGroupName, 'PowerGrid SRE Agent Operator')
  properties: {
    principalId: identityPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', sreAgentOperatorRoleId)
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
    sreAgentOperatorRole
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
// (not just to the user-assigned identity).
resource sreAgentSystemMiOperatorRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(sreAgent.id, targetResourceGroupName, 'PowerGrid SRE Agent Operator', 'system')
  properties: {
    principalId: sreAgent.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', sreAgentOperatorRoleId)
  }
}

// ── IT Support Agent removed: extracted to labs/zava-itsupport/ ──

output agentName string = sreAgent.name
output agentId string = sreAgent.id
output agentPortalUrl string = 'https://sre.azure.com'
