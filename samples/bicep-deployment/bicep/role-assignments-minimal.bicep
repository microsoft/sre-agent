@description('The principal ID of the user-assigned managed identity')
param userAssignedIdentityPrincipalId string

@description('The principal ID of the system-assigned managed identity (optional)')
param systemAssignedIdentityPrincipalId string = ''

@description('The access level for role assignments')
@allowed(['Low', 'Medium', 'High'])
param accessLevel string

@description('Enable Key Vault role assignments')
param enableKeyVault bool = true

@description('Key Vault resource ID for scoped role assignments (optional)')
param keyVaultResourceId string = ''

// Define role definition IDs based on the access level
var roleDefinitions = {
  Low: [
    '92aaf0da-9dab-42b6-94a3-d43ce8d16293' // Log Analytics Reader
  ]
  Medium: [
    '92aaf0da-9dab-42b6-94a3-d43ce8d16293' // Log Analytics Reader
    'acdd72a7-3385-48ef-bd42-f606fba81ae7' // Reader
  ]
  High: [
    '92aaf0da-9dab-42b6-94a3-d43ce8d16293' // Log Analytics Reader
    'acdd72a7-3385-48ef-bd42-f606fba81ae7' // Reader
    'b24988ac-6180-42a0-ab88-20f7382dd24c' // Contributor
  ]
}

// Create role assignments based on access level for user-assigned identity
resource roleAssignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for (roleDefinitionId, index) in roleDefinitions[accessLevel]: {
  name: guid(resourceGroup().id, userAssignedIdentityPrincipalId, roleDefinitionId)
  properties: {
    roleDefinitionId: resourceId('Microsoft.Authorization/roleDefinitions', roleDefinitionId)
    principalId: userAssignedIdentityPrincipalId
    principalType: 'ServicePrincipal'
  }
}]

// Create Application Insights Component Contributor role assignment for system-assigned identity (if provided)
// Note: This creates the role assignment at the resource group level for now
resource appInsightsRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(systemAssignedIdentityPrincipalId)) {
  name: guid(resourceGroup().id, systemAssignedIdentityPrincipalId, 'ae349356-3a1b-4a5e-921d-050484c6347e')
  properties: {
    roleDefinitionId: resourceId('Microsoft.Authorization/roleDefinitions', 'ae349356-3a1b-4a5e-921d-050484c6347e') // Application Insights Component Contributor
    principalId: systemAssignedIdentityPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// Create Key Vault role assignments for the user-assigned identity (if Key Vault is enabled)
// Key Vault Certificate User role
resource keyVaultCertificateUserRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (enableKeyVault && !empty(keyVaultResourceId)) {
  name: guid(keyVaultResourceId, userAssignedIdentityPrincipalId, 'db79e9a7-68ee-4b58-9aeb-b90e7c24fcba')
  scope: resourceGroup()
  properties: {
    roleDefinitionId: resourceId('Microsoft.Authorization/roleDefinitions', 'db79e9a7-68ee-4b58-9aeb-b90e7c24fcba') // Key Vault Certificate User
    principalId: userAssignedIdentityPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// Key Vault Secrets User role
resource keyVaultSecretsUserRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (enableKeyVault && !empty(keyVaultResourceId)) {
  name: guid(keyVaultResourceId, userAssignedIdentityPrincipalId, '4633458b-17de-408a-b874-0445c86b69e6')
  scope: resourceGroup()
  properties: {
    roleDefinitionId: resourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6') // Key Vault Secrets User
    principalId: userAssignedIdentityPrincipalId
    principalType: 'ServicePrincipal'
  }
}

output assignedRoles array = [for (roleDefinitionId, index) in roleDefinitions[accessLevel]: {
  roleDefinitionId: roleDefinitionId
  principalId: userAssignedIdentityPrincipalId
}]
