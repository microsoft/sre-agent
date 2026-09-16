@description('Location for resources')
param location string

@description('SRE Agent name')
param agentName string

@description('User-Assigned Managed Identity resource ID')
param identityId string

@description('User-Assigned Managed Identity client ID used by native PostgreSQL tools')
param sreAgentClientId string

@description('Application Insights App ID')
param appInsightsAppId string

@description('Application Insights Connection String')
@secure()
param appInsightsConnectionString string

@description('Application Insights resource ID')
param appInsightsId string

@description('Resource Group ID to add as managed resource')
param managedResourceGroupId string

@description('AKS cluster name')
param aksClusterName string

@description('Resource ID of the VNet-injection subnet delegated to Microsoft.App/environments')
param agentSubnetId string

@description('AI model provider for the agent')
@allowed([
  'Anthropic'
  'MicrosoftFoundry'
])
param modelProvider string = 'Anthropic'

@description('Agent upgrade channel')
@allowed([
  'Preview'
  'Stable'
])
param upgradeChannel string = 'Preview'

@description('Enables workspace tools and early-access experimental features')
param enableEarlyAccessFeatures bool = true

var sreAgentAdminRoleId = 'e79298df-d852-4c6d-84f9-5d13249d1e55'

#disable-next-line BCP081
resource sreAgent 'Microsoft.App/agents@2025-05-01-preview' = {
  name: agentName
  location: location
  tags: {
    'hidden-link: /app-insights-resource-id': appInsightsId
    'sre-agent-umi-client-id': sreAgentClientId
    sample: 'zava-aks-postgres'
  }
  identity: {
    type: 'SystemAssigned, UserAssigned'
    userAssignedIdentities: {
      '${identityId}': {}
    }
  }
  properties: {
    vnetConfiguration: {
      subnetResourceId: agentSubnetId
    }
    sandboxConfiguration: {
      egress: {
        mode: 'AzureVNet'
        vnetConfiguration: {
          usePrivateDnsResolution: true
        }
        // Keep remote MCP traffic inside the customer VNet and hub firewall.
        allowHttpMcpServerNetworkAccess: false
        allowedCodeRepositories: []
        allowedRegistries: [
          'pypi'
        ]
        allowedHosts: []
      }
      packages: [
        {
          name: 'pg8000'
          version: '1.30.5'
          packageManager: 'pip'
        }
        {
          name: 'azure-identity'
          version: '1.24.0'
          packageManager: 'pip'
        }
      ]
    }
    knowledgeGraphConfiguration: {
      managedResources: [
        managedResourceGroupId
      ]
      identity: identityId
    }
    actionConfiguration: {
      mode: 'autonomous'
      identity: identityId
      accessLevel: 'High'
    }
    defaultModel: {
      name: 'Automatic'
      provider: modelProvider
    }
    upgradeChannel: upgradeChannel
    experimentalSettings: {
      EnableWorkspaceTools: enableEarlyAccessFeatures
      EnableAdcSharedWorkspace: enableEarlyAccessFeatures
      EnableEgressProxy: enableEarlyAccessFeatures
    }
    incidentManagementConfiguration: {
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

resource sreAgentAdminRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(sreAgent.id, deployer().objectId, sreAgentAdminRoleId)
  scope: sreAgent
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', sreAgentAdminRoleId)
    principalId: deployer().objectId
    principalType: 'User'
  }
}

resource aksCluster 'Microsoft.ContainerService/managedClusters@2024-09-01' existing = {
  name: aksClusterName
}

resource aksRbacClusterAdminSystem 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(aksCluster.id, sreAgent.id, 'aksrbacadmin-system')
  scope: aksCluster
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b1ff04bb-8a4e-4dc4-8eb5-8693973ce19b')
    principalId: sreAgent.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource readerSystem 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, sreAgent.id, 'reader-system')
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'acdd72a7-3385-48ef-bd42-f606fba81ae7')
    principalId: sreAgent.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource monitoringReaderSystem 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, sreAgent.id, 'monreader-system')
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '43d0d8ad-25c7-4714-9337-8ba259a9fe05')
    principalId: sreAgent.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource contributorSystem 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, sreAgent.id, 'contributor-system')
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b24988ac-6180-42a0-ab88-20f7382dd24c')
    principalId: sreAgent.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// Connectors are deployed separately after setup verifies backend readiness.

output agentName string = sreAgent.name
output agentId string = sreAgent.id
output agentEndpoint string = sreAgent.properties.agentEndpoint
output agentSystemPrincipalId string = sreAgent.identity.principalId
output agentPortalUrl string = 'https://sre.azure.com/agents${sreAgent.id}'
