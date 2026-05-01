targetScope = 'subscription'

@description('Azure region for all resources')
param location string = 'swedencentral'

@description('Resource group name')
param resourceGroupName string = 'rg-zava-aks-postgres'

@description('Unique suffix for globally unique resource names. Deterministic on subscription+RG so that incremental `azd up` is idempotent.')
param uniqueSuffix string = take(uniqueString(subscription().subscriptionId, resourceGroupName), 6)

@description('AZD environment name (auto-injected from AZURE_ENV_NAME by main.bicepparam). Used only to derive a short distinguishing suffix on the SRE Agent name so that fresh `azd env new` demos get fresh agents (and therefore fresh data-plane thread state). Other resources keep using uniqueSuffix only, so they remain idempotent across incremental `azd up` runs on the same env.')
param environmentName string = ''

// 4-char hash of the env name appended to the SRE Agent name. Empty when
// environmentName is blank (e.g. raw `az deployment sub create`), preserving
// the legacy `sre-agent-${uniqueSuffix}` shape for that path.
var agentEnvSuffix = empty(environmentName) ? '' : '-${take(uniqueString(environmentName), 4)}'

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceGroupName
  location: location
}

module vnet 'modules/vnet.bicep' = {
  scope: rg
  name: 'vnet'
  params: {
    location: location
    uniqueSuffix: uniqueSuffix
  }
}

module acr 'modules/acr.bicep' = {
  scope: rg
  name: 'acr'
  params: {
    location: location
    uniqueSuffix: uniqueSuffix
  }
}

module monitoring 'modules/monitoring.bicep' = {
  scope: rg
  name: 'monitoring'
  params: {
    location: location
    uniqueSuffix: uniqueSuffix
    postgresServerName: postgresql.outputs.serverName
    resourceGroupId: rg.id
  }
}

module postgresql 'modules/postgresql.bicep' = {
  scope: rg
  name: 'postgresql'
  params: {
    location: location
    uniqueSuffix: uniqueSuffix
    subnetId: vnet.outputs.dbSubnetId
    privateDnsZoneId: vnet.outputs.privateDnsZoneId
  }
}

module aks 'modules/aks.bicep' = {
  scope: rg
  name: 'aks'
  params: {
    location: location
    uniqueSuffix: uniqueSuffix
    subnetId: vnet.outputs.aksSubnetId
    logAnalyticsWorkspaceId: monitoring.outputs.logAnalyticsWorkspaceId
    acrId: acr.outputs.acrId
  }
}

module identity 'modules/identity.bicep' = {
  scope: rg
  name: 'identity'
  params: {
    location: location
    uniqueSuffix: uniqueSuffix
    aksClusterName: aks.outputs.clusterName
    appInsightsName: monitoring.outputs.appInsightsName
  }
}

module sreAgent 'modules/sre-agent.bicep' = {
  scope: rg
  name: 'sre-agent'
  params: {
    location: location
    // Zava-branded for friendliness ('sre-agent-dbthfn-...' is cryptic);
    // ${agentEnvSuffix} gives per-env distinctiveness so fresh demos always
    // get fresh agents. Falls back to 'sre-agent-zava' when env name is empty.
    agentName: 'sre-agent-zava${agentEnvSuffix}'
    identityId: identity.outputs.sreAgentIdentityId
    appInsightsAppId: monitoring.outputs.appInsightsAppId
    appInsightsConnectionString: monitoring.outputs.appInsightsConnectionString
    appInsightsId: monitoring.outputs.appInsightsResourceId
    logAnalyticsId: monitoring.outputs.logAnalyticsWorkspaceId
    managedResourceGroupId: rg.id
    aksClusterName: aks.outputs.clusterName
  }
}

// PostgreSQL Entra admin grants for the three managed identities — the SRE
// Agent UMI, the SRE Agent SMI (system-assigned, only known after the agent
// resource exists), and the app workload identity. Done in Bicep so the deploy
// is reproducible and parity is enforced at template time.
//
// PG Flex serializes administrator writes ("ServerIsBusy" on parallel
// requests). The idiomatic `@batchSize(1)` loop pattern can't be used here
// because for-expressions require values calculable at deployment-plan time
// (BCP178), and managed-identity principalIds are runtime expressions. The
// explicit per-module dependsOn chain below is the correct workaround for
// runtime-known fan-out that needs serialization.
module pgAdminSreAgentUmi 'modules/pg-admin.bicep' = {
  scope: rg
  name: 'pg-admin-sre-umi'
  params: {
    pgServerName: postgresql.outputs.serverName
    principalId: identity.outputs.sreAgentIdentityPrincipalId
    principalName: identity.outputs.sreAgentIdentityName
  }
}

module pgAdminSreAgentSmi 'modules/pg-admin.bicep' = {
  scope: rg
  name: 'pg-admin-sre-smi'
  params: {
    pgServerName: postgresql.outputs.serverName
    principalId: sreAgent.outputs.agentSystemPrincipalId
    principalName: sreAgent.outputs.agentName
  }
  dependsOn: [pgAdminSreAgentUmi]
}

module pgAdminAppIdentity 'modules/pg-admin.bicep' = {
  scope: rg
  name: 'pg-admin-app'
  params: {
    pgServerName: postgresql.outputs.serverName
    principalId: identity.outputs.appIdentityPrincipalId
    principalName: identity.outputs.appIdentityName
  }
  dependsOn: [pgAdminSreAgentSmi]
}

// Outputs for post-provision script
output RESOURCE_GROUP string = rg.name
output AKS_CLUSTER_NAME string = aks.outputs.clusterName
output AKS_OIDC_ISSUER string = aks.outputs.oidcIssuerUrl
output ACR_NAME string = acr.outputs.acrName
output ACR_LOGIN_SERVER string = acr.outputs.acrLoginServer
output DB_HOST string = postgresql.outputs.fqdn
output DB_NAME string = 'zava_store'
output PG_SERVER_NAME string = postgresql.outputs.serverName
output APP_IDENTITY_NAME string = identity.outputs.appIdentityName
output APP_IDENTITY_CLIENT_ID string = identity.outputs.appIdentityClientId
output APP_IDENTITY_PRINCIPAL_ID string = identity.outputs.appIdentityPrincipalId
output LOG_ANALYTICS_WORKSPACE_ID string = monitoring.outputs.logAnalyticsWorkspaceId
// NOTE: do NOT mark this @secure(). `azd env get-value` (used by post-provision.ps1)
// silently omits secure outputs and returns the literal "ERROR: key not found" text
// instead, which then gets substituted verbatim into the k8s secret and breaks
// App Insights instrumentation. The connection string contains the instrumentation
// key, but it's already written to a k8s Secret object — that's the correct
// boundary for this demo.
output APPINSIGHTS_CONNECTION_STRING string = monitoring.outputs.appInsightsConnectionString
output APPINSIGHTS_RESOURCE_ID string = monitoring.outputs.appInsightsResourceId
output VNET_NAME string = vnet.outputs.vnetName
output NSG_NAME string = vnet.outputs.nsgName
output SRE_AGENT_NAME string = sreAgent.outputs.agentName
output SRE_AGENT_ENDPOINT string = sreAgent.outputs.agentEndpoint
output AGENT_PORTAL_URL string = sreAgent.outputs.agentPortalUrl
