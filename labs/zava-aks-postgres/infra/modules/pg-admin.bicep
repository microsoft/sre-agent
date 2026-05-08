// Registers a single service principal as a PostgreSQL Flexible Server Entra admin.
//
// Lives in its own module because the admin resource's `name` field must be the
// principal object ID, and Bicep requires resource names to be calculable at
// deployment-plan time (BCP120). For newly-created managed identities the
// principalId is a runtime expression — but when passed as a *string parameter*
// into a sub-deployment, it IS resolvable at the start of THAT deployment.
//
// Each PG admin grant gets its own module instance, which also lets the caller
// chain them with module-level `dependsOn` to serialize against PG Flex's
// "ServerIsBusy" rejection on parallel administrator writes.

@description('PostgreSQL Flexible Server name (parent resource).')
param pgServerName string

@description('Object ID of the principal to register as PG Entra admin.')
param principalId string

@description('Display name of the principal (shown in the PG admin list and required by the API).')
param principalName string

@description('Principal type. ServicePrincipal for managed identities, User for human admins.')
@allowed([
  'ServicePrincipal'
  'User'
  'Group'
])
param principalType string = 'ServicePrincipal'

resource pgServer 'Microsoft.DBforPostgreSQL/flexibleServers@2024-08-01' existing = {
  name: pgServerName
}

resource admin 'Microsoft.DBforPostgreSQL/flexibleServers/administrators@2024-08-01' = {
  parent: pgServer
  name: principalId
  properties: {
    principalType: principalType
    principalName: principalName
    tenantId: subscription().tenantId
  }
}
