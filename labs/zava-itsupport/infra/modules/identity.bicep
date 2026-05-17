@description('Location for resources')
param location string

@description('Managed Identity name')
param identityName string

resource userAssignedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' = {
  name: identityName
  location: location
  properties: {
    isolationScope: 'Regional'
  }
}

output identityId string = userAssignedIdentity.id
output identityName string = userAssignedIdentity.name
output identityPrincipalId string = userAssignedIdentity.properties.principalId
