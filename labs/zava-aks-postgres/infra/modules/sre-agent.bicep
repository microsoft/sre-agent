@description('Location for resources')
param location string

@description('SRE Agent name')
param agentName string

@description('User-Assigned Managed Identity resource ID')
param identityId string

@description('Application Insights App ID')
param appInsightsAppId string

@description('Application Insights Connection String')
@secure()
param appInsightsConnectionString string

@description('Application Insights resource ID')
param appInsightsId string

@description('Log Analytics workspace resource ID — used for the log-analytics agent connector')
param logAnalyticsId string

@description('Resource Group ID to add as managed resource')
param managedResourceGroupId string

@description('AKS cluster name — used to grant system identity K8s-level RBAC')
param aksClusterName string

@description('AI model provider for the agent (Anthropic enables web search; not in EU Data Boundary)')
@allowed([
  'Anthropic'
  'MicrosoftFoundry'
])
param modelProvider string = 'Anthropic'

@description('Upgrade channel — Preview enables early-access features (e.g., Code Interpreter, marketplace plugins)')
@allowed([
  'Preview'
  'Stable'
])
param upgradeChannel string = 'Preview'

@description('Enables workspace tools / early-access experimental features (paired with upgradeChannel: Preview)')
param enableEarlyAccessFeatures bool = true

var sreAgentAdminRoleId = 'e79298df-d852-4c6d-84f9-5d13249d1e55'

#disable-next-line BCP081
resource sreAgent 'Microsoft.App/agents@2025-05-01-preview' = {
  name: agentName
  location: location
  tags: {
    'hidden-link: /app-insights-resource-id': appInsightsId
    sample: 'zava-aks-postgres'
  }
  identity: {
    type: 'SystemAssigned, UserAssigned'
    userAssignedIdentities: {
      '${identityId}': {}
    }
  }
  properties: {
    knowledgeGraphConfiguration: {
      managedResources: [
        managedResourceGroupId
      ]
      identity: identityId
    }
    actionConfiguration: {
      mode: 'autonomous'
      identity: identityId
      accessLevel: 'High'
    }
    defaultModel: {
      name: 'Automatic'
      provider: modelProvider
    }
    upgradeChannel: upgradeChannel
    experimentalSettings: {
      EnableWorkspaceTools: enableEarlyAccessFeatures
    }
    incidentManagementConfiguration: {
      type: 'AzMonitor'
      connectionName: 'azmonitor'
    }
    mcpServers: []
    logConfiguration: {
      applicationInsightsConfiguration: {
        appId: appInsightsAppId
        connectionString: appInsightsConnectionString
      }
    }
  }
}

resource sreAgentAdminRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(sreAgent.id, deployer().objectId, sreAgentAdminRoleId)
  scope: sreAgent
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', sreAgentAdminRoleId)
    principalId: deployer().objectId
    principalType: 'User'
  }
}

// AKS RBAC Cluster Admin for agent's system-assigned identity
resource aksCluster 'Microsoft.ContainerService/managedClusters@2024-09-01' existing = {
  name: aksClusterName
}

resource aksRbacClusterAdminSystem 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(aksCluster.id, sreAgent.id, 'aksrbacadmin-system')
  scope: aksCluster
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b1ff04bb-8a4e-4dc4-8eb5-8693973ce19b')
    principalId: sreAgent.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// RG-level roles for agent's system-assigned identity (matches UMI roles for redundancy)
resource readerSystem 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, sreAgent.id, 'reader-system')
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'acdd72a7-3385-48ef-bd42-f606fba81ae7')
    principalId: sreAgent.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource monitoringReaderSystem 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, sreAgent.id, 'monreader-system')
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '43d0d8ad-25c7-4714-9337-8ba259a9fe05')
    principalId: sreAgent.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource contributorSystem 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, sreAgent.id, 'contributor-system')
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b24988ac-6180-42a0-ab88-20f7382dd24c')
    principalId: sreAgent.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// Agent configuration via ARM data-plane resources
// (Microsoft.App/agents/{connectors,skills,incidentFilters}). Skills and
// incident filters wrap an opaque JSON blob in properties.value.

var aiResourceName = last(split(appInsightsId, '/'))
var lawResourceName = last(split(logAnalyticsId, '/'))
var rgName = resourceGroup().name

// --- Connectors ------------------------------------------------------------

#disable-next-line BCP081
resource appInsightsConnector 'Microsoft.App/agents/connectors@2025-05-01-preview' = {
  parent: sreAgent
  name: 'app-insights'
  properties: {
    dataConnectorType: 'AppInsights'
    dataSource: appInsightsId
    extendedProperties: {
      armResourceId: appInsightsId
      resource: {
        name: aiResourceName
      }
    }
    identity: 'system'
  }
}

#disable-next-line BCP081
resource logAnalyticsConnector 'Microsoft.App/agents/connectors@2025-05-01-preview' = {
  parent: sreAgent
  name: 'log-analytics'
  properties: {
    dataConnectorType: 'LogAnalytics'
    dataSource: logAnalyticsId
    extendedProperties: {
      armResourceId: logAnalyticsId
      resource: {
        name: lawResourceName
      }
    }
    identity: 'system'
  }
}

#disable-next-line BCP081
resource microsoftLearnConnector 'Microsoft.App/agents/connectors@2025-05-01-preview' = {
  parent: sreAgent
  name: 'microsoft-learn'
  properties: {
    dataConnectorType: 'Mcp'
    dataSource: 'zava-aks-postgres-microsoft-learn-mcp'
    extendedProperties: {
      type: 'http'
      endpoint: 'https://learn.microsoft.com/api/mcp'
      authType: 'CustomHeaders'
    }
    identity: ''
  }
}

// Azure Monitor connector — provisioned in Bicep so the portal doesn't have to
// jit-create it on first use. Schema is bare: no extendedProperties, no ARM
// resource id. Reachable resources are gated by the agent MSI's existing
// Reader + Monitoring Reader RG-scoped role assignments.
#disable-next-line BCP081
resource azureMonitorConnector 'Microsoft.App/agents/connectors@2025-05-01-preview' = {
  parent: sreAgent
  name: 'azure-monitor'
  properties: {
    dataConnectorType: 'MonitorClient'
    dataSource: 'n/a'
    identity: 'system'
  }
}

// --- Skills (opaque JSON blob, base64-encoded into properties.value) -------

var dbIncidentSkill = {
  // Symptom classes only — do NOT enumerate alert names or specific error strings
  // here. The skill is the agent's entry point for ALL Zava infra incidents; the
  // diagnosis happens inside the runbook from telemetry, not by name-matching the
  // alert payload. See AGENTS.md.
  description: 'Use for any infrastructure incident affecting the Zava Athletic application — database connectivity, query latency, HTTP 5xx, network/NSG configuration changes, or pod state — and for chat questions about the same surface. Diagnoses root cause from telemetry and remediates autonomously within the skill\'s permitted-action boundary.'
  tools: [
    'RunAzCliReadCommands'
    'RunAzCliWriteCommands'
    'SearchMemory'
    'microsoft-learn_microsoft_code_sample_search'
    'microsoft-learn_microsoft_docs_fetch'
    'microsoft-learn_microsoft_docs_search'
  ]
  skillContent: '''
## Zava Incident Runbook

Resource Group: `@@RG@@`. App Insights `cloud_RoleName`: `zava-api`. App k8s namespace: `zava-demo`.

You diagnose from telemetry, then remediate within the permitted-action boundary below. Outside that boundary you summarize and stop. When in doubt about an Azure / AKS / PostgreSQL surface you haven't seen before, look it up in Microsoft Learn before guessing.

## Tools you have

- **`az` CLI (read + write)** — your only Azure interface. For in-cluster operations (kubectl, exec, SQL through the app pod), the path is `az aks command invoke`.
- **Memory search** — past investigations and the architecture knowledge base.
- **Microsoft Learn search/fetch** — for Azure / AKS / PostgreSQL Flexible Server / KQL surfaces you're unsure about. Prefer documenting your reasoning over guessing.

You do NOT have direct kubectl, psql, Test-NetConnection, or any TCP-level tools. You're outside this VNet — see the knowledge base for the architecture.

## Identities and grants (do NOT try to elevate)

Both your system-assigned and user-assigned managed identities have what you need: AKS RBAC Cluster Admin (so `az aks command invoke` works without further consent), Reader + Monitoring Reader + Contributor on the resource group, and PostgreSQL Entra admin. You do NOT have `Microsoft.Authorization/roleAssignments/write`. **Never** attempt `az role assignment create` — it will be denied. If you think you need a role you don't have, the diagnosis is wrong; back up.

## Always filter telemetry to `zava-api`

App Insights and Log Analytics are shared with your own ARM-poll telemetry. Filter every KQL query by `AppRoleName == 'zava-api'` (KQL) or `cloud/roleName == 'zava-api'` (metrics) — unfiltered queries are dominated by agent self-noise.

## What the Zava alerts mean

| Alert title | Meaning |
|---|---|
| `postgres-server-stopped` / `postgres-server-down` | PostgreSQL Flexible Server is Stopped or unreachable at the TCP layer. Read `state` from ARM; if Stopped, start it. |
| `postgres-network-blocked` | App pods see `ETIMEDOUT` to PG's private IP. PG is up; something is dropping packets. There are two enforcement surfaces between the app pods and PG (an NSG on the AKS subnet, and Kubernetes NetworkPolicy inside the cluster) — both can produce this symptom. The KB documents which is platform-managed and which is user-controlled. |
| `Zava-products-query-slow` | App Insights `AppRequests` for `/api/products*` (excluding `__probe`) breached the latency threshold. Bottleneck is at PostgreSQL, not pods/CPU/memory. Look at PG's own statistics views (the KB documents the helper for running SQL through the app pod). Never restart pods or scale the cluster for this alert. |
| `Zava-http-5xx-errors` | Composite signal — almost always a downstream effect of one of the conditions above. Check those first before treating it as a separate failure. |

## Permitted autonomous actions

- Start / restart / parameter-set on PostgreSQL Flexible Server.
- Delete a NetworkPolicy in `zava-demo` whose egress blocks PG, and delete a matching NSG deny rule on the AKS subnet.
- Restart deployments in `zava-demo`.
- Read-mostly DDL on PostgreSQL: `CREATE INDEX CONCURRENTLY IF NOT EXISTS`, `ANALYZE`, `REINDEX CONCURRENTLY`.

## Out of scope (require human approval)

- `DROP`, DML, schema migrations, role/grant changes.
- Cluster scale, node deletion, VNet changes.
- Any IAM modification.

## Verification

Re-check the resource you changed, confirm error rate / latency is back to baseline, confirm the alert auto-mitigated.
'''
  additionalFiles: []
  sourcePluginInstallation: null
}

var proactiveHealthSkill = {
  description: 'Use when a human operator asks for a proactive health check of the Zava Athletic API — request success rate, latency, exception patterns, PostgreSQL state — to detect anomalies before they become alerts. Hands off to db-incident-investigation if a known failure mode is found; otherwise completes silently.'
  tools: [
    'RunAzCliReadCommands'
    'RunAzCliWriteCommands'
    'SearchMemory'
    'ExecutePythonCode'
    'microsoft-learn_microsoft_code_sample_search'
    'microsoft-learn_microsoft_docs_fetch'
    'microsoft-learn_microsoft_docs_search'
  ]
  skillContent: '''
## Proactive Health Check

Pull current signals; complete silently if everything is in baseline.

Always filter App Insights queries by `AppRoleName == 'zava-api'` — the workspace is shared with SRE Agent's own ARM polling, which dominates unfiltered queries.

What "baseline" means for Zava:

1. Request success rate >99% on `/api/*` over the last 15 minutes; single-digit ms avg/p95 on `/api/products*`.
2. Zero `ECONNREFUSED` / `ETIMEDOUT` / "timeout exceeded when trying to connect" exceptions or traces from `zava-api` in the last 15 minutes.
3. PostgreSQL Flexible Server `state == Ready`.

If any of those is missed, hand off to the `db-incident-investigation` skill. If everything is in baseline, complete silently.
'''
  additionalFiles: []
  sourcePluginInstallation: null
}

// NOTE: Browser-based site diagnosis is intentionally NOT defined as an SRE
// Agent skill. The `BrowseWebPage` / Browser Operator tool is not generally
// available to deployed SRE Agents, so a skill that references it would never
// load successfully. The browser-verification path lives in the
// `.github/skills/running-demo` Copilot CLI skill, which uses Playwright /
// Chrome DevTools MCP from the operator's machine to visually verify the
// storefront before/after a break/fix scenario.

#disable-next-line BCP081
resource skillDbIncident 'Microsoft.App/agents/skills@2025-05-01-preview' = {
  parent: sreAgent
  name: 'db-incident-investigation'
  properties: {
    value: base64(string(union(dbIncidentSkill, {
      skillContent: replace(dbIncidentSkill.skillContent, '@@RG@@', rgName)
    })))
  }
}

#disable-next-line BCP081
resource skillProactiveHealth 'Microsoft.App/agents/skills@2025-05-01-preview' = {
  parent: sreAgent
  name: 'proactive-health-check'
  properties: {
    value: base64(string(union(proactiveHealthSkill, {
      skillContent: replace(proactiveHealthSkill.skillContent, '@@RG@@', rgName)
    })))
  }
}

// --- Incident filters (a.k.a. response plans) ------------------------------
// Routing model: incident -> first matching filter -> handlingAgent. We use
// 'default', so the built-in default agent picks a skill by description match
// (skills are NOT linked to filters). Skill descriptions are the discovery
// key — keep them concrete and mention real alert names + error tokens.
//
// The `postgres` and `Zava` titleContains values are deliberately non-
// overlapping: alerts named `postgres-*` route to the DB filter, `Zava-*` to
// the app filter. Activity-log alerts (e.g. `postgres-server-stopped`,
// `Zava-nsg-change`) are intentionally named without the conflicting prefix.

var defaultPriorities = [
  'Sev0'
  'Sev1'
  'Sev2'
  'Sev3'
  // Sev4 is required: `Microsoft.Insights/activityLogAlerts` rules default
  // to Sev4 (Informational) when severity isn't explicitly set on the rule
  // (we don't set it — the schema only exposes the field for some alert
  // categories). Dropping Sev4 here would silently break activity-log-driven
  // scenarios like `postgres-server-stopped` and `Zava-nsg-*`.
  'Sev4'
]

var dbResponseFilter = {
  incidentPlatform: 'AzMonitor'
  impactedService: ''
  priorities: defaultPriorities
  incidentType: ''
  alertId: ''
  titleContains: 'postgres'
  titleContainsAll: []
  titleContainsAny: []
  titleNotContains: []
  agentMode: 'autonomous'
  handlingAgent: 'default'
  handlingAgents: null
  owningTeamId: ''
  owningTeamIds: []
  maxAutomatedInvestigationAttempts: 3
  deepInvestigationEnabled: false
  // Merge enabled with the platform-default 3-hour window. This keeps cost
  // bounded for users testing the demo (or running it in production-like
  // settings) by folding repeat alerts of the same root cause into one
  // investigation instead of dispatching N parallel ones. Fresh dispatches
  // per `azd env new` are still guaranteed because the SRE Agent name
  // includes a per-env suffix, so a brand-new env gets a brand-new agent
  // with an empty thread store. If you do back-to-back demo runs on the
  // SAME env within 3 hours, new alerts will fold into the previous run's
  // (closed) thread; the agent acknowledges the alert but doesn't open a
  // new thread. Set `mergeEnabled: false` to defeat that.
  mergeEnabled: true
  mergeWindowHours: 3
  isEnabled: true
  icmFilterSettings: null
  azMonitorFilterSettings: {
    targetResourceType: ''
    targetResource: ''
  }
}

var appResponseFilter = {
  incidentPlatform: 'AzMonitor'
  impactedService: ''
  priorities: defaultPriorities
  incidentType: ''
  alertId: ''
  titleContains: 'Zava'
  titleContainsAll: []
  titleContainsAny: []
  titleNotContains: []
  agentMode: 'autonomous'
  handlingAgent: 'default'
  handlingAgents: null
  owningTeamId: ''
  owningTeamIds: []
  maxAutomatedInvestigationAttempts: 3
  deepInvestigationEnabled: false
  // See dbResponseFilter for rationale.
  mergeEnabled: true
  mergeWindowHours: 3
  isEnabled: true
  icmFilterSettings: null
  azMonitorFilterSettings: {
    targetResourceType: ''
    targetResource: ''
  }
}

#disable-next-line BCP081
resource filterDbResponse 'Microsoft.App/agents/incidentFilters@2025-05-01-preview' = {
  parent: sreAgent
  name: 'zava-db-response'
  properties: {
    value: base64(string(dbResponseFilter))
  }
}

#disable-next-line BCP081
resource filterAppResponse 'Microsoft.App/agents/incidentFilters@2025-05-01-preview' = {
  parent: sreAgent
  name: 'zava-app-response'
  properties: {
    value: base64(string(appResponseFilter))
  }
}

output agentName string = sreAgent.name
output agentId string = sreAgent.id
output agentEndpoint string = sreAgent.properties.agentEndpoint
output agentSystemPrincipalId string = sreAgent.identity.principalId
// Deep-link straight to this agent's blade so the operator lands on the
// Threads tab without having to pick the agent from a list.
output agentPortalUrl string = 'https://sre.azure.com/agents${sreAgent.id}'


