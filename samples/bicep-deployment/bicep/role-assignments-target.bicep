@description('The principal ID of the user-assigned managed identity')
param userAssignedIdentityPrincipalId string

@description('The access level for role assignments')
@allowed(['Low', 'High'])
param accessLevel string

// Define role definition IDs based on the access level
var roleDefinitions = {
  Low: [
    '92aaf0da-9dab-42b6-94a3-d43ce8d16293' // Log Analytics Reader
    'acdd72a7-3385-48ef-bd42-f606fba81ae7' // Reader
  ]
  High: [
    '92aaf0da-9dab-42b6-94a3-d43ce8d16293' // Log Analytics Reader
    'acdd72a7-3385-48ef-bd42-f606fba81ae7' // Reader
    'b24988ac-6180-42a0-ab88-20f7382dd24c' // Contributor
  ]
}

// Create role assignments based on access level for user-assigned identity in target resource groups
resource roleAssignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for (roleDefinitionId, index) in roleDefinitions[accessLevel]: {
  name: guid(resourceGroup().id, userAssignedIdentityPrincipalId, roleDefinitionId)
  properties: {
    roleDefinitionId: resourceId('Microsoft.Authorization/roleDefinitions', roleDefinitionId)
    principalId: userAssignedIdentityPrincipalId
    principalType: 'ServicePrincipal'
  }
}]

output assignedRoles array = [for (roleDefinitionId, index) in roleDefinitions[accessLevel]: {
  roleDefinitionId: roleDefinitionId
  principalId: userAssignedIdentityPrincipalId
  resourceGroupId: resourceGroup().id
}]
