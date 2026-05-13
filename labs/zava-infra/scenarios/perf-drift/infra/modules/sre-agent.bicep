// ============================================================
// SRE Agent module — Microsoft.App/agents resource
// ============================================================

param location string
param environmentName string
param tags object
param logAnalyticsWorkspaceId string
param managedResourceGroupId string
param deployingUserObjectId string = ''

// ---- Managed Identity for the SRE Agent ----
resource agentIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' = {
  name: 'id-sreagent-${environmentName}'
  location: location
  tags: tags
}

// ---- SRE Agent ----
resource agent 'Microsoft.App/agents@2025-05-01-preview' = {
  name: 'sreagent-${environmentName}'
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned, UserAssigned'
    userAssignedIdentities: {
      '${agentIdentity.id}': {}
    }
  }
  properties: {
    knowledgeGraphConfiguration: {
      identity: agentIdentity.id
      managedResources: [
        managedResourceGroupId
      ]
    }
    actionConfiguration: {
      mode: 'autonomous'
      identity: agentIdentity.id
      accessLevel: 'High'
    }
    mcpServers: []
  }
}

// ---- SRE Agent Administrator role for deploying user ----
var sreAgentAdminRoleId = 'e79298df-d852-4c6d-84f9-5d13249d1e55'

resource agentAdminRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(deployingUserObjectId)) {
  name: guid(agent.id, deployingUserObjectId, sreAgentAdminRoleId)
  scope: agent
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', sreAgentAdminRoleId)
    principalId: deployingUserObjectId
    principalType: 'User'
  }
}

output sreAgentName string = agent.name
output sreAgentId string = agent.id
output sreAgentPrincipalId string = agentIdentity.properties.principalId
output sreAgentIdentityId string = agentIdentity.id
output systemIdentityPrincipalId string = agent.identity.principalId
