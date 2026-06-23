// Key Vault holding the platform's database credentials. RBAC-authorized; the container
// apps' user-assigned identity is granted Key Vault Secrets User so Container Apps can
// resolve secret references at runtime.
//
// Secrets:
//   * db-password           — the real admin password, used by the baseline + most lanes.
//   * db-password-secretlane — a COPY of the password, used ONLY by the secret lane.
//                              chaos/break-secret.ps1 rotates this to an invalid value so
//                              only that lane hits authentication failures.
//   * db-pool-password      — login for the dedicated app_pool role (pool lane), created
//                              by post-provision; chaos/break-pool.ps1 sets a real
//                              CONNECTION LIMIT on that role.
@description('Azure region.')
param location string
@description('Resource name suffix token.')
param resourceToken string
@description('Tags applied to all resources.')
param tags object = {}

@description('Principal id of the container apps user-assigned identity (granted Secrets User).')
param identityPrincipalId string

@secure()
@description('PostgreSQL admin password (stored as db-password and db-password-secretlane).')
param dbAdminPassword string
@secure()
@description('Password for the dedicated app_pool role (pool lane).')
param dbPoolPassword string

var vaultName = 'kv-zava-${resourceToken}'

resource vault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: vaultName
  location: location
  tags: tags
  properties: {
    sku: { family: 'A', name: 'standard' }
    tenantId: tenant().tenantId
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    publicNetworkAccess: 'Enabled'
  }
}

resource secretDbPassword 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: vault
  name: 'db-password'
  properties: { value: dbAdminPassword }
}

resource secretSecretLane 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: vault
  name: 'db-password-secretlane'
  properties: { value: dbAdminPassword }
}

resource secretPoolPassword 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: vault
  name: 'db-pool-password'
  properties: { value: dbPoolPassword }
}

// Key Vault Secrets User -> the apps' managed identity.
var secretsUserRoleId = '4633458b-17de-408a-b874-0445c86b69e6'
resource secretsUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(vault.id, identityPrincipalId, secretsUserRoleId)
  scope: vault
  properties: {
    principalId: identityPrincipalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', secretsUserRoleId)
    principalType: 'ServicePrincipal'
  }
}

output vaultName string = vault.name
output vaultUri string = vault.properties.vaultUri
output secretUriDbPassword string = '${vault.properties.vaultUri}secrets/db-password'
output secretUriSecretLane string = '${vault.properties.vaultUri}secrets/db-password-secretlane'
output secretUriPoolPassword string = '${vault.properties.vaultUri}secrets/db-pool-password'
