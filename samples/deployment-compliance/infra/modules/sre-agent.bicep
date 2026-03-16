// ============================================================
// SRE Agent module — Microsoft.App/agents resource
// ============================================================

@description('Location for all resources')
param location string

@description('Environment name for naming')
param environmentName string

@description('Tags for all resources')
param tags object

@description('Log Analytics workspace customer ID')
param logAnalyticsWorkspaceId string

@secure()
@description('Log Analytics workspace shared key')
param logAnalyticsWorkspaceKey string

@description('Resource group ID that the agent should monitor')
param managedResourceGroupId string

@description('Object ID of the deploying user (for SRE Agent Administrator role)')
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
    type: 'UserAssigned'
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
      mode: 'Review'       // Review mode — agent proposes actions, user approves
      identity: agentIdentity.id
      accessLevel: 'low'   // Subscription Reader
    }
    logConfiguration: {
      logAnalyticsConfiguration: {
        workspaceId: logAnalyticsWorkspaceId
        sharedKey: logAnalyticsWorkspaceKey
      }
    }
    mcpServers: []  // Kusto MCP configured post-deploy via Portal/SRECTL
  }
}

// ---- SRE Agent Administrator role for deploying user ----
// This role allows the user to manage the agent via data plane API (skills, hooks, etc.)
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

// ============================================================
// Outputs
// ============================================================
output sreAgentName string = agent.name
output sreAgentId string = agent.id
output sreAgentPrincipalId string = agentIdentity.properties.principalId
output sreAgentIdentityId string = agentIdentity.id
