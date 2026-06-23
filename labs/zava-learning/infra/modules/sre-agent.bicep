// SRE Agent for the Zava Learning lab — DEPLOYMENT ONLY.
//
// This template provisions just the agent resource and its RBAC. All agent
// CONFIGURATION (connectors, skills, incident filters, knowledge base, custom
// tools) is applied separately via the public Azure MCP SRE Agent tools
// (azure-mcp 3.0.0-beta.16+) — see ../../sre-config/agent-config/README.md.
//
// Rationale: Bicep gives a reproducible, templatized "deploy the agent" step
// (azd up / az deployment), while the Azure MCP tools are publicly available so
// anyone running the published lab can apply the configuration the same way we do.
//
// Schema mirrors the verified microsoft/sre-agent reference pattern:
// Microsoft.App/agents@2025-05-01-preview.

@description('Location for the agent.')
param location string

@description('SRE Agent name (use a per-environment suffix so each env gets a fresh thread store).')
param agentName string

@description('User-Assigned Managed Identity resource ID.')
param identityId string

@description('Application Insights App ID.')
param appInsightsAppId string

@description('Application Insights connection string.')
@secure()
param appInsightsConnectionString string

@description('Application Insights resource ID (used for the portal hidden-link tag).')
param appInsightsId string

@description('Resource Group ID added to the agent knowledge graph (the lab RG).')
param managedResourceGroupId string

@description('Incident platform for this agent.')
@allowed([ 'PagerDuty', 'AzMonitor' ])
param incidentPlatform string = 'PagerDuty'

@description('Model provider backing the agent.')
@allowed([ 'Anthropic', 'MicrosoftFoundry' ])
param modelProvider string = 'Anthropic'

@description('Model name. "Automatic" lets the platform pick the best available model.')
param modelName string = 'Automatic'

@allowed([ 'Preview', 'Stable' ])
param upgradeChannel string = 'Preview'

param enableEarlyAccessFeatures bool = true

var sreAgentAdminRoleId = 'e79298df-d852-4c6d-84f9-5d13249d1e55'

#disable-next-line BCP081
resource sreAgent 'Microsoft.App/agents@2025-05-01-preview' = {
  name: agentName
  location: location
  tags: {
    'hidden-link: /app-insights-resource-id': appInsightsId
    sample: 'zava-learning'
  }
  identity: {
    type: 'SystemAssigned, UserAssigned'
    userAssignedIdentities: {
      '${identityId}': {}
    }
  }
  properties: {
    knowledgeGraphConfiguration: {
      managedResources: [ managedResourceGroupId ]
      identity: identityId
    }
    // NOTE: agent-level mode governs CHAT only. Autonomy for incident / HTTP /
    // scheduled triggers is set per-trigger (e.g. the incident filter applied via
    // Azure MCP), not here.
    actionConfiguration: {
      mode: 'autonomous'
      identity: identityId
      accessLevel: 'High'
    }
    defaultModel: {
      name: modelName
      provider: modelProvider
    }
    upgradeChannel: upgradeChannel
    experimentalSettings: {
      EnableWorkspaceTools: enableEarlyAccessFeatures
    }
    incidentManagementConfiguration: incidentPlatform == 'PagerDuty' ? {
      type: 'PagerDuty'
      connectionName: 'pagerduty'
    } : {
      type: 'AzMonitor'
      connectionName: 'azmonitor'
    }
    mcpServers: []
    logConfiguration: {
      applicationInsightsConfiguration: {
        appId: appInsightsAppId
        connectionString: appInsightsConnectionString
      }
    }
  }
}

// Agent admin role for the deployer (so they land in the portal with access).
resource sreAgentAdminRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(sreAgent.id, deployer().objectId, sreAgentAdminRoleId)
  scope: sreAgent
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', sreAgentAdminRoleId)
    principalId: deployer().objectId
    principalType: 'User'
  }
}

// RG-scoped roles for the identity the agent ACTS AS. The agent's
// actionConfiguration.identity and knowledgeGraphConfiguration.identity both resolve to the
// user-assigned identity passed in `identityId` (NOT the system-assigned identity), so the
// remediation roles must be granted to THAT principal — otherwise az network/NSG/App Gateway
// write+action calls (e.g. application-gateway show-backend-health, NSG securityRules delete)
// fall back to OBO and prompt. Reader+MonitoringReader cover telemetry/config reads; Network
// Contributor covers the connectivity scenario's writes/actions (the app-tier revision restart
// is covered by the Container Apps Contributor grant the agent identity already carries).
resource agentUami 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  name: last(split(identityId, '/'))
}

resource readerAgent 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, identityId, 'reader-agent')
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'acdd72a7-3385-48ef-bd42-f606fba81ae7')
    principalId: agentUami.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource monitoringReaderAgent 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, identityId, 'monreader-agent')
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '43d0d8ad-25c7-4714-9337-8ba259a9fe05')
    principalId: agentUami.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource networkContributorAgent 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, identityId, 'netcontrib-agent')
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4d97b98b-1d4f-4787-a291-c67834d212e7')
    principalId: agentUami.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// Key Vault Secrets User -> lets the agent read the DB password (Key Vault `db-password`) so it can
// run read-only psql confirmation queries (index health, role connection limits) when diagnosing a
// database-backed quiz lane. Read-only data-plane access; secrets are redacted from reports by the
// redaction-guard skill.
resource kvSecretsUserAgent 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, identityId, 'kvsecrets-agent')
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6')
    principalId: agentUami.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// Virtual Machine Contributor -> lets the agent remediate the reporting-worker VM disk-pressure
// scenario autonomously. The fix is `az vm run-command invoke ... rm -f /data/exports/backlog.bin`,
// which needs Microsoft.Compute/virtualMachines/runCommand/action; without it the write call returns
// AuthorizationFailed and the runtime stalls the thread as PendingAuthorization (surfaces in the UI
// as an approval prompt). Also covers start/deallocate of the VM if the agent restarts the worker.
resource vmContributorAgent 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, identityId, 'vmcontrib-agent')
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '9980e02c-c2be-4d73-94e8-173b1dc7cf3c')
    principalId: agentUami.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// Key Vault Secrets Officer -> lets the agent remediate the secret-lane scenario autonomously by
// rotating the expired/invalid secret back to a valid value (`az keyvault secret set`), which needs
// Microsoft.KeyVault/vaults/secrets/setSecret/action. Secrets User (read) alone is not enough: the
// recovery write returns Forbidden, forcing a container-app-level fallback that escalates to an OBO
// approval prompt. Granting write here keeps the secret lane fully hands-off.
resource kvSecretsOfficerAgent 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, identityId, 'kvsecretsofficer-agent')
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7')
    principalId: agentUami.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// Managed Identity Operator -> lets the agent self-heal Container Apps that reference the
// user-assigned identity. `az containerapp secret set`/`update` re-asserts the secret's
// identityref, which requires Microsoft.ManagedIdentity/userAssignedIdentities/assign/action on
// the identity. Container Apps Contributor alone is not enough: without this the write fails with
// (LinkedAuthorizationFailed) and the action falls into the OBO/PendingAuthorization path, which
// stalls the autonomous incident runbook.
resource miOperatorAgent 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, identityId, 'mioperator-agent')
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'f1a07417-d97a-45cb-824c-7a7467783830')
    principalId: agentUami.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

output agentName string = sreAgent.name
output agentId string = sreAgent.id
output agentEndpoint string = sreAgent.properties.agentEndpoint
output agentSystemPrincipalId string = sreAgent.identity.principalId
output agentPortalUrl string = 'https://sre.azure.com/agents${sreAgent.id}'
