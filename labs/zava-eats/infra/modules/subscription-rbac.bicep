targetScope = 'subscription'

@description('Principal ID of the managed identity to assign roles to')
param principalId string

// Subscription-scoped RBAC for SRE Agent managed identity
// These roles allow the agent to read resources, query logs, and manage container apps

var roles = [
  {
    name: 'Reader'
    id: 'acdd72a7-3385-48ef-bd42-f606fba81ae7'
  }
  {
    name: 'Monitoring Reader'
    id: '43d0d8ad-25c7-4714-9337-8ba259a9fe05'
  }
  {
    name: 'Monitoring Contributor'
    id: '749f88d5-cbae-40b8-bcfc-e573ddc772fa'
  }
  {
    name: 'Log Analytics Reader'
    id: '73c42c96-874c-492b-b04d-ab87d138a893'
  }
  {
    name: 'Container Apps Contributor'
    id: '358470bc-b998-42bd-ab17-a7e34c199c0f'
  }
]

resource roleAssignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for role in roles: {
  name: guid(subscription().id, principalId, role.id)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', role.id)
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}]
