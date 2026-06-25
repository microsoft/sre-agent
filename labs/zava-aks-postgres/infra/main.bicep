targetScope = 'subscription'

@description('Azure region for all resources')
param location string = 'swedencentral'

@description('Resource group name')
param resourceGroupName string = 'rg-zava-aks-postgres'

@description('Unique suffix for globally unique resource names. Deterministic on subscription+RG so that incremental `azd up` is idempotent.')
param uniqueSuffix string = take(uniqueString(subscription().subscriptionId, resourceGroupName), 6)

@description('AZD environment name (auto-injected from AZURE_ENV_NAME by main.bicepparam). Used only to derive a short distinguishing suffix on the SRE Agent name so that fresh `azd env new` demos get fresh agents (and therefore fresh data-plane thread state). Other resources keep using uniqueSuffix only, so they remain idempotent across incremental `azd up` runs on the same env.')
param environmentName string = ''

@description('''Lock the SRE Agent down to PRIVATE-ONLY Azure Monitor (maximum restraint).
When true (default): the agent\'s Monitor private-DNS zones are linked to the agent VNet AND the
public `AzureMonitor` service tag is removed from the firewall L4 allow-list, so the agent reaches
Log Analytics / Application Insights only via the AMPLS private endpoint over the hub/spoke.

The agent remains fully functional under this lockdown: it queries Log Analytics / Application
Insights and remediates incidents end-to-end over the private path. (The agent\'s Monitor query
connector is platform-brokered, so dropping the public `AzureMonitor` tag from the agent-VNet
firewall does not gate it.) Set false to keep the public allow-listed Monitor path instead.''')
param lockAgentToPrivateMonitor bool = true

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
    lockAgentToPrivateMonitor: lockAgentToPrivateMonitor
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
    agentSubnetId: vnet.outputs.agentSubnetId
  }
}

// Azure Monitor Private Link Scope (AMPLS) — the private ingress/egress path for
// Azure Monitor. The agent is locked to the private path by default
// (lockAgentToPrivateMonitor); the platform/workload spoke stays on the public
// allow-listed path unless linkWorkloadVnetsToPrivateMonitor is also set true
// (off by default — linking it risks NXDOMAIN on the app's regional App Insights
// ingestion host; a documented private-link DNS pitfall, not validated here). See
// the module header.
module monitorPrivateLink 'modules/monitor-private-link.bicep' = {
  scope: rg
  name: 'monitor-private-link'
  params: {
    location: location
    uniqueSuffix: uniqueSuffix
    logAnalyticsWorkspaceResourceId: monitoring.outputs.logAnalyticsWorkspaceId
    appInsightsResourceId: monitoring.outputs.appInsightsResourceId
    peSubnetId: vnet.outputs.peSubnetId
    hubVnetId: vnet.outputs.hubVnetId
    platformVnetId: vnet.outputs.platformVnetId
    agentVnetId: vnet.outputs.agentVnetId
    lockAgentToPrivateMonitor: lockAgentToPrivateMonitor
  }
}

// Firewall diagnostic logs → Log Analytics (AZFW* tables). Lets the SRE Agent
// interrogate the hub firewall — the demo's "network device" — the INDIRECT way
// (querying what it observed), complementing the DIRECT ARM reads of its policy.
module firewallDiagnostics 'modules/firewall-diagnostics.bicep' = {
  scope: rg
  name: 'firewall-diagnostics'
  params: {
    firewallName: vnet.outputs.firewallName
    logAnalyticsWorkspaceId: monitoring.outputs.logAnalyticsWorkspaceId
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
output HUB_VNET_NAME string = vnet.outputs.hubVnetName
output FIREWALL_NAME string = vnet.outputs.firewallName
output AMPLS_NAME string = monitorPrivateLink.outputs.amplsName
output SRE_AGENT_NAME string = sreAgent.outputs.agentName
output SRE_AGENT_ENDPOINT string = sreAgent.outputs.agentEndpoint
output AGENT_PORTAL_URL string = sreAgent.outputs.agentPortalUrl
