@description('The name of the SRE Agent')
param agentName string

@description('The location where the resources will be deployed')
param location string

@description('Optional: The resource ID of an existing user-assigned managed identity. If not provided, a new one will be created.')
param existingManagedIdentityId string = ''

@description('The access level for the SRE Agent')
@allowed(['High', 'Low'])
param accessLevel string = 'High'

@description('Array of resource group names that the SRE Agent should have permissions to manage')
param targetResourceGroups array = []

@description('Array of subscription IDs where the target resource groups exist')
param targetSubscriptions array = []

@description('The subscription ID where resources will be deployed')
param subscriptionId string

@description('The unique suffix for resource names')
param uniqueSuffix string

// Determine if we should create a new managed identity or use an existing one
var shouldCreateManagedIdentity = empty(existingManagedIdentityId)

// Resource names
var logAnalyticsWorkspaceName = 'workspace${uniqueSuffix}'
var appInsightsName = 'app-insights-${uniqueSuffix}'
var userAssignedIdentityName = '${agentName}-${uniqueSuffix}'

// Create Log Analytics Workspace
resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: logAnalyticsWorkspaceName
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
  }
}

// Create Application Insights
resource applicationInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    Request_Source: 'SreAgent'
    WorkspaceResourceId: logAnalyticsWorkspace.id
  }
}

// Create Action Group for Smart Detection alerts
resource smartDetectionActionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: 'Application Insights Smart Detection'
  location: 'Global'
  properties: {
    groupShortName: 'SmartDetect'
    enabled: true
    armRoleReceivers: [
      {
        name: 'Monitoring Contributor'
        roleId: '749f88d5-cbae-40b8-bcfc-e573ddc772fa'
        useCommonAlertSchema: true
      }
      {
        name: 'Monitoring Reader'
        roleId: '43d0d8ad-25c7-4714-9337-8ba259a9fe05'
        useCommonAlertSchema: true
      }
    ]
  }
}

// Create Smart Detector Alert Rule for Failure Anomalies
resource failureAnomaliesSmartDetector 'Microsoft.AlertsManagement/smartDetectorAlertRules@2021-04-01' = {
  name: 'Failure Anomalies - ${appInsightsName}'
  location: 'Global'
  properties: {
    description: 'Failure Anomalies notifies you of an unusual rise in the rate of failed HTTP requests or dependency calls.'
    state: 'Enabled'
    severity: 'Sev3'
    frequency: 'PT1M'
    detector: {
      id: 'FailureAnomaliesDetector'
    }
    scope: [
      applicationInsights.id
    ]
    actionGroups: {
      groupIds: [
        smartDetectionActionGroup.id
      ]
    }
  }
}

// Create User-Assigned Managed Identity (only if not using existing one)
#disable-next-line BCP073
resource userAssignedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' = if (shouldCreateManagedIdentity) {
  name: userAssignedIdentityName
  location: location
  properties: {
    isolationScope: 'Regional'
  }
}

// Reference to the managed identity (either existing or newly created)
resource existingManagedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' existing = if (!shouldCreateManagedIdentity) {
  name: last(split(existingManagedIdentityId, '/'))
  scope: resourceGroup(split(existingManagedIdentityId, '/')[2], split(existingManagedIdentityId, '/')[4])
}

// Define role assignments for target resource groups (new identity)
module targetRoleAssignmentsNew 'role-assignments-target.bicep' = [for (targetRG, index) in targetResourceGroups: if (shouldCreateManagedIdentity) {
  name: 'targetRoleAssignments-new-${index}-${uniqueString(deployment().name)}'
  scope: resourceGroup(length(targetSubscriptions) > index ? targetSubscriptions[index] : subscriptionId, targetRG)
  params: {
    userAssignedIdentityPrincipalId: userAssignedIdentity!.properties.principalId
    accessLevel: accessLevel
  }
}]

// Define role assignments for target resource groups (existing identity)
module targetRoleAssignmentsExisting 'role-assignments-target.bicep' = [for (targetRG, index) in targetResourceGroups: if (!shouldCreateManagedIdentity) {
  name: 'targetRoleAssignments-existing-${index}-${uniqueString(deployment().name)}'
  scope: resourceGroup(length(targetSubscriptions) > index ? targetSubscriptions[index] : subscriptionId, targetRG)
  params: {
    userAssignedIdentityPrincipalId: existingManagedIdentity!.properties.principalId
    accessLevel: accessLevel
  }
}]

// Define role assignments for the deployment resource group (new identity)
module deploymentRoleAssignmentsNew 'role-assignments-minimal.bicep' = if (shouldCreateManagedIdentity) {
  name: 'deploymentRoleAssignments-new-${uniqueString(deployment().name)}'
  params: {
    userAssignedIdentityPrincipalId: userAssignedIdentity!.properties.principalId
    systemAssignedIdentityPrincipalId: ''
    accessLevel: accessLevel
    enableKeyVault: false
    keyVaultResourceId: ''
  }
}

// Define role assignments for the deployment resource group (existing identity)
module deploymentRoleAssignmentsExisting 'role-assignments-minimal.bicep' = if (!shouldCreateManagedIdentity) {
  name: 'deploymentRoleAssignments-existing-${uniqueString(deployment().name)}'
  params: {
    userAssignedIdentityPrincipalId: existingManagedIdentity!.properties.principalId
    systemAssignedIdentityPrincipalId: ''
    accessLevel: accessLevel
    enableKeyVault: false
    keyVaultResourceId: ''
  }
}

// Create the SRE Agent with new managed identity
#disable-next-line BCP081
resource sreAgentNew 'Microsoft.App/agents@2025-05-01-preview' = if (shouldCreateManagedIdentity) {
  name: agentName
  location: location
  identity: {
    type: 'SystemAssigned, UserAssigned'
    userAssignedIdentities: {
      '${userAssignedIdentity.id}': {}
    }
  }
  properties: {
    knowledgeGraphConfiguration: {
      identity: userAssignedIdentity.id
      managedResources: []
    }
    actionConfiguration: {
      accessLevel: accessLevel
      identity: userAssignedIdentity.id
      mode: 'Review'
    }
    logConfiguration: {
      applicationInsightsConfiguration: {
        appId: applicationInsights.properties.AppId
        connectionString: applicationInsights.properties.ConnectionString
      }
    }
  }
  dependsOn: [
    deploymentRoleAssignmentsNew
    targetRoleAssignmentsNew
  ]
}

// Create the SRE Agent with existing managed identity
#disable-next-line BCP081
resource sreAgentExisting 'Microsoft.App/agents@2025-05-01-preview' = if (!shouldCreateManagedIdentity) {
  name: agentName
  location: location
  identity: {
    type: 'SystemAssigned, UserAssigned'
    userAssignedIdentities: {
      '${existingManagedIdentityId}': {}
    }
  }
  properties: {
    knowledgeGraphConfiguration: {
      identity: existingManagedIdentityId
      managedResources: []
    }
    actionConfiguration: {
      accessLevel: accessLevel
      identity: existingManagedIdentityId
      mode: 'Review'
    }
    logConfiguration: {
      applicationInsightsConfiguration: {
        appId: applicationInsights.properties.AppId
        connectionString: applicationInsights.properties.ConnectionString
      }
    }
  }
  dependsOn: [
    deploymentRoleAssignmentsExisting
    targetRoleAssignmentsExisting
  ]
}

// Assign SRE Agent Administrator role to the deployment user on the SRE Agent resource (for new identity)
// The user needs this role to manage the SRE Agent through the portal, configure workflows, and monitor the agent
// Using deployer().objectId automatically gets the principal ID of whoever runs the deployment
resource sreAgentAdminUserRoleAssignmentNew 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (shouldCreateManagedIdentity) {
  name: guid(sreAgentNew.id, deployer().objectId, 'e79298df-d852-4c6d-84f9-5d13249d1e55-user')
  scope: sreAgentNew
  properties: {
    roleDefinitionId: resourceId('Microsoft.Authorization/roleDefinitions', 'e79298df-d852-4c6d-84f9-5d13249d1e55') // SRE Agent Administrator
    principalId: deployer().objectId
    principalType: 'User'
  }
}

// Assign SRE Agent Administrator role to the deployment user on the SRE Agent resource (for existing identity)
// The user needs this role to manage the SRE Agent through the portal, configure workflows, and monitor the agent
resource sreAgentAdminUserRoleAssignmentExisting 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!shouldCreateManagedIdentity) {
  name: guid(sreAgentExisting.id, deployer().objectId, 'e79298df-d852-4c6d-84f9-5d13249d1e55-user')
  scope: sreAgentExisting
  properties: {
    roleDefinitionId: resourceId('Microsoft.Authorization/roleDefinitions', 'e79298df-d852-4c6d-84f9-5d13249d1e55') // SRE Agent Administrator
    principalId: deployer().objectId
    principalType: 'User'
  }
}

// Outputs
output agentName string = shouldCreateManagedIdentity ? sreAgentNew.name : sreAgentExisting.name
output agentId string = shouldCreateManagedIdentity ? sreAgentNew.id : sreAgentExisting.id
output agentPortalUrl string = 'https://ms.portal.azure.com/#view/Microsoft_Azure_PaasServerless/AgentFrameBlade.ReactView/id/${replace(shouldCreateManagedIdentity ? sreAgentNew.id : sreAgentExisting.id, '/', '%2F')}'
output userAssignedIdentityId string = shouldCreateManagedIdentity ? userAssignedIdentity.id : existingManagedIdentityId
output applicationInsightsConnectionString string = applicationInsights.properties.ConnectionString
output logAnalyticsWorkspaceId string = logAnalyticsWorkspace.id
output createdNewManagedIdentity bool = shouldCreateManagedIdentity
