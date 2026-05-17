// ============================================================
// Roles Module — RBAC assignments for SRE Agent
// ============================================================

param sreAgentPrincipalId string
param resourceGroupId string
param logAnalyticsWorkspaceId string

// Log Analytics Reader on workspace
var logAnalyticsReaderRoleId = '73c42c96-874c-492b-b04d-ab87d138a893'
resource lawReaderRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(logAnalyticsWorkspaceId, sreAgentPrincipalId, logAnalyticsReaderRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', logAnalyticsReaderRoleId)
    principalId: sreAgentPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// Virtual Machine Contributor on resource group
var vmContributorRoleId = '9980e02c-c2be-4d73-94e8-173b1dc7cf3c'
resource vmContributorRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroupId, sreAgentPrincipalId, vmContributorRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', vmContributorRoleId)
    principalId: sreAgentPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// Monitoring Contributor on resource group
var monitoringContributorRoleId = '749f88d5-cbae-40b8-bcfc-e573ddc772fa'
resource monitoringContributorRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroupId, sreAgentPrincipalId, monitoringContributorRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', monitoringContributorRoleId)
    principalId: sreAgentPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// Reader on resource group (for resource discovery)
var readerRoleId = 'acdd72a7-3385-48ef-bd42-f606fba81ae7'
resource readerRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroupId, sreAgentPrincipalId, readerRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', readerRoleId)
    principalId: sreAgentPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// Network Contributor (for NSG remediation)
var networkContributorRoleId = '4d97b98b-1d4f-4787-a291-c67834d212e7'
resource networkContributorRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroupId, sreAgentPrincipalId, networkContributorRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', networkContributorRoleId)
    principalId: sreAgentPrincipalId
    principalType: 'ServicePrincipal'
  }
}
