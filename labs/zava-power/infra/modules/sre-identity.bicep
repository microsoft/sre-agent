// ── User-Assigned Managed Identity for SRE Agent ──

param location string
param workloadName string
param tags object

#disable-next-line BCP073
resource sreIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' = {
  name: 'id-${workloadName}-sre'
  location: location
  tags: tags
  properties: {
    isolationScope: 'Regional'
  }
}

output identityId string = sreIdentity.id
output identityName string = sreIdentity.name
output identityPrincipalId string = sreIdentity.properties.principalId
