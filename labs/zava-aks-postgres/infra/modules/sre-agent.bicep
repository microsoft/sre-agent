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

@description('Resource ID of the VNet-injection subnet (delegated to Microsoft.App/environments). The agent sandbox runs here with egress forced through the Azure Firewall.')
param agentSubnetId string

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
    // VNet injection: the agent's sandbox (where its CLI tools run) is placed in
    // the delegated agent subnet, with all egress forced through the Azure Firewall.
    // The agent works the cluster with native, first-class kubectl tools
    // authenticated by its own managed identity, runs PostgreSQL SQL through an
    // in-cluster helper, and uses az / ARM for control-plane actions and Azure
    // Monitor — all permitted by the firewall allow-list. No public reachability
    // to the AKS API server or PostgreSQL is required.
    vnetConfiguration: {
      subnetResourceId: agentSubnetId
    }
    sandboxConfiguration: {
      egress: {
        mode: 'AzureVNet'
        vnetConfiguration: {
          usePrivateDnsResolution: true
        }
        // Remote HTTP MCP servers (the microsoft-learn connector below) are
        // brokered by the platform rather than the customer VNet — required for
        // the agent's Microsoft Learn lookups to work behind the firewall.
        allowHttpMcpServerNetworkAccess: true
        allowedCodeRepositories: []
        // Maximum lockdown: nothing extra is allow-listed. Note the sandbox egress is
        // HTTP(S)-proxy-brokered — it reaches allow-listed HTTPS endpoints (ARM,
        // Entra, Azure Monitor, Microsoft Learn) but CANNOT open raw TCP to private VNet
        // IPs (e.g. PostgreSQL:5432, verified). Private DB access therefore runs from an
        // in-cluster pod (a real VNet NIC) via `kubectl exec`, not from the agent sandbox.
        allowedRegistries: []
        allowedHosts: []
      }
      packages: []
    }
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
    'RunKubectlReadCommand'
    'RunKubectlWriteCommand'
    'RunKubectlCommandHelp'
    'RunInTerminal'
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

You operate with your **own managed identity (Entra)** — no passwords, no app credentials. You work AKS through the Kubernetes control plane (your `kubectl` tools, authenticated by your Entra identity) and the database/resources through the Azure control plane (`az`). Important nuance: your sandbox's egress is **HTTP(S)-proxy-brokered**, so it can reach allow-listed HTTPS endpoints (ARM, Entra, Azure Monitor, Microsoft Learn) but **cannot open raw TCP to private VNet IPs** — so PostgreSQL SQL runs from an in-cluster app pod (a real VNet NIC) via `kubectl exec`, never a direct socket from your sandbox.

- **kubectl (read + write + help)** — `RunKubectlReadCommand` / `RunKubectlWriteCommand` / `RunKubectlCommandHelp`. First-class kubectl against the AKS API with your Entra identity (you hold AKS RBAC Cluster Admin). Use these directly for pods, logs, events, deployments, and NetworkPolicies. Do NOT hand-wrap kubectl inside `az aks command invoke`.
- **Terminal in your sandbox** — `RunInTerminal` runs shell commands (`python3`, `node`, scripts) inside your workspace sandbox. Important: the sandbox's egress is HTTP(S)-proxy-brokered — it can reach allow-listed HTTPS endpoints but **cannot open raw TCP to private VNet IPs** (e.g. PostgreSQL:5432 — verified refused). Use it for compute/scripting, not for direct database or private-service connections.
- **PostgreSQL SQL** — your sandbox can't open a raw socket to the private database, so run SQL (reads `pg_stat_*`, and read-mostly DDL like `CREATE INDEX CONCURRENTLY` / `ANALYZE`) through the in-cluster helper, which executes from an app pod (a real VNet NIC): `kubectl exec -n zava-demo deploy/zava-api -- node bin/run-sql.js "<SQL>"` (the helper reuses the app pod's PG Entra identity).
- **`az` CLI (read + write)** — `RunAzCliReadCommands` / `RunAzCliWriteCommands`. Your control-plane interface: PostgreSQL start/stop/parameter-set, NSG rules, resource state, Azure Monitor.
- **Memory search** — past investigations and the architecture knowledge base.
- **Microsoft Learn search/fetch** — for Azure / AKS / PostgreSQL Flexible Server / KQL surfaces you're unsure about. Prefer documenting your reasoning over guessing.

## Identities and grants (do NOT try to elevate)

Both your system-assigned and user-assigned managed identities have what you need: AKS RBAC Cluster Admin (so kubectl works without further consent), Reader + Monitoring Reader + Contributor on the resource group, and PostgreSQL Entra admin (the app pod's identity, used by `bin/run-sql.js`, is also a PG Entra admin). You do NOT have `Microsoft.Authorization/roleAssignments/write`. **Never** attempt `az role assignment create` — it will be denied. If you think you need a role you don't have, the diagnosis is wrong; back up.

## Always filter telemetry to `zava-api`

App Insights and Log Analytics are shared with your own ARM-poll telemetry. Filter every KQL query by `AppRoleName == 'zava-api'` (KQL) or `cloud/roleName == 'zava-api'` (metrics) — unfiltered queries are dominated by agent self-noise.

## What the Zava alerts mean

| Alert title | Meaning |
|---|---|
| `postgres-server-stopped` / `postgres-server-down` | PostgreSQL Flexible Server is Stopped or unreachable at the TCP layer. Read `state` from ARM; if Stopped, start it. |
| `postgres-network-blocked` | App pods see `ETIMEDOUT` to PG's private IP. PG is up; something is dropping packets. There are two enforcement surfaces between the app pods and PG (an NSG on the AKS subnet, and Kubernetes NetworkPolicy inside the cluster) — both can produce this symptom. The KB documents which is platform-managed and which is user-controlled. |
| `Zava-products-query-slow` | App Insights `AppRequests` for `/api/products*` (excluding `__probe`) breached the latency threshold. Bottleneck is at PostgreSQL, not pods/CPU/memory. Inspect PG's statistics views (`pg_stat_statements`, `pg_stat_user_indexes`, `pg_stat_activity`, `EXPLAIN`) by running SQL through the in-cluster helper with kubectl: `kubectl exec -n zava-demo deploy/zava-api -- node bin/run-sql.js "<SQL>"`. Never restart pods or scale the cluster for this alert. |
| `Zava-category-latency-metric` | The app's own custom METRIC (`zava.products.category.query.duration_ms` in `AppMetrics`) for a non-probe category breached the latency threshold. Treat this as a first-class corroborating signal for the SAME slow-query incident as `Zava-products-query-slow` (the `AppRequests` log signal) and the `AppDependencies` PostgreSQL-call latency (the trace signal) — logs + metrics + traces agreeing points at the database query, not pods/CPU/memory. Diagnose at PG exactly as for `Zava-products-query-slow`. |
| `Zava-db-cpu-saturation` | PostgreSQL server CPU is saturated (platform metric). On its own it can be organic load, but co-firing with the slow-query signals above corroborates a database-side bottleneck (e.g. heavy scans). Inspect PG activity and statistics views before considering any compute change; do not scale the cluster for this alert. |
| `Zava-http-5xx-errors` | Composite signal. First rule out the conditions above — a 5xx spike is usually a downstream effect of a DB outage, network partition, or slow-query bottleneck. If none of those correlate, treat it as a possible **bad deploy**: check recent rollout history (`kubectl rollout history deployment/zava-api -n zava-demo`) and recent deployment changes / `KubeEvents` (`ScalingReplicaSet`). A 5xx regression whose onset lines up with a recent rollout is a deployment regression — roll back to the previous good revision (see permitted actions). |

## Permitted autonomous actions

- Start / restart / parameter-set on PostgreSQL Flexible Server.
- Delete a NetworkPolicy in `zava-demo` whose egress blocks PG, and delete a matching NSG deny rule on the AKS subnet.
- Restart deployments in `zava-demo`.
- Roll back a deployment in `zava-demo` to its previous revision (`kubectl rollout undo`) when a 5xx regression correlates with a recent rollout.
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
    'RunKubectlReadCommand'
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


