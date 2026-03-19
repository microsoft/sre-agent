// ============================================================
// Main Bicep — VM Performance + Compliance Drift Demo
// Deploys: VMs + Networking + Monitoring + SRE Agent
// ============================================================
targetScope = 'subscription'

@minLength(1)
@maxLength(64)
@description('Name of the environment (e.g. "vm-perf-demo")')
param environmentName string

@minLength(1)
@description('Primary location for all resources')
param location string

@description('Object ID of the user running azd up (for role assignments)')
param principalId string = ''

@description('VM admin username')
param vmAdminUsername string = 'azureuser'

@secure()
@description('VM admin password or SSH key')
param vmAdminPassword string

// Tags applied to all resources — compliance baseline
var tags = {
  'azd-env-name': environmentName
  purpose: 'vm-perf-drift-demo'
  environment: 'demo'
  'cost-center': 'sre-ebc'
  'deployed-by': 'pipeline'
  'compliance-required': 'true'
}

// Resource group
resource rg 'Microsoft.Resources/resourceGroups@2021-04-01' = {
  name: 'rg-${environmentName}'
  location: location
  tags: tags
}

// ---- Networking (VNet + NSG + Subnets) ----
module network 'modules/network.bicep' = {
  scope: rg
  name: 'network'
  params: {
    location: location
    environmentName: environmentName
    tags: tags
  }
}

// ---- VMs (SAP App + DB simulation) ----
module vmApp 'modules/vm.bicep' = {
  scope: rg
  name: 'vm-sap-app'
  params: {
    location: location
    vmName: 'vm-sap-app-01'
    subnetId: network.outputs.appSubnetId
    adminUsername: vmAdminUsername
    adminPassword: vmAdminPassword
    vmSize: 'Standard_B2s'
    tags: union(tags, { role: 'sap-application-server' })
  }
}

// ---- Cosmos DB ----
module cosmosDb 'modules/cosmosdb.bicep' = {
  scope: rg
  name: 'cosmos-db'
  params: {
    location: location
    environmentName: environmentName
    tags: union(tags, { role: 'database' })
    vmIdentityPrincipalId: vmApp.outputs.vmPrincipalId
  }
}

// ---- Monitoring (LAW + Alert Rules + Diagnostics) ----
module monitoring 'modules/monitoring.bicep' = {
  scope: rg
  name: 'monitoring'
  params: {
    location: location
    environmentName: environmentName
    tags: tags
    vmAppId: vmApp.outputs.vmId
    vmDbId: ''
    vmAppName: vmApp.outputs.vmName
    vmDbName: ''
  }
}

// ---- SRE Agent ----
module sreAgent 'modules/sre-agent.bicep' = {
  scope: rg
  name: 'sre-agent'
  params: {
    location: location
    environmentName: environmentName
    tags: tags
    logAnalyticsWorkspaceId: monitoring.outputs.logAnalyticsWorkspaceId
    managedResourceGroupId: rg.id
    deployingUserObjectId: principalId
  }
}

// ---- Role Assignments ----
module roles 'modules/roles.bicep' = {
  scope: rg
  name: 'role-assignments'
  params: {
    sreAgentPrincipalId: sreAgent.outputs.sreAgentPrincipalId
    resourceGroupId: rg.id
    logAnalyticsWorkspaceId: monitoring.outputs.logAnalyticsWorkspaceId
  }
}

// ============================================================
// Outputs
// ============================================================
output RESOURCE_GROUP_NAME string = rg.name
output VM_APP_NAME string = vmApp.outputs.vmName
output VM_APP_IP string = vmApp.outputs.publicIpAddress
output COSMOS_ENDPOINT string = cosmosDb.outputs.endpoint
output COSMOS_DB_NAME string = cosmosDb.outputs.databaseName
output LOG_ANALYTICS_WORKSPACE_ID string = monitoring.outputs.logAnalyticsWorkspaceId
output SRE_AGENT_NAME string = sreAgent.outputs.sreAgentName
output SRE_AGENT_ID string = sreAgent.outputs.sreAgentId
output NSG_NAME string = network.outputs.nsgName
