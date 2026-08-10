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
    // the delegated agent subnet, with ALL egress forced (UDR) through the Azure
    // Firewall. The firewall allow-list is deliberately minimal — the control plane
    // (ARM, Entra, Microsoft Graph) and Microsoft Learn over public service tags,
    // plus the AKS API server over the hub/spoke for the built-in RunKubectl*
    // system tools. Azure Monitor is private-only by default (lockAgentToPrivateMonitor):
    // public AzureMonitor is dropped and the agent reaches Log Analytics / App
    // Insights over the AMPLS private endpoint; the agent remains fully functional
    // over it. It does NOT permit a raw socket to PostgreSQL:5432, so SQL runs
    // through an in-cluster pod, not the sandbox.
    vnetConfiguration: {
      subnetResourceId: agentSubnetId
    }
    sandboxConfiguration: {
      egress: {
        mode: 'AzureVNet'
        vnetConfiguration: {
          usePrivateDnsResolution: true
        }
        // Remote (Streamable-HTTP) MCP servers — the microsoft-learn connector
        // below. We deliberately leave this OFF (the default). When TRUE, the
        // platform routes the MCP runtime endpoint (learn.microsoft.com/api/mcp)
        // as Rewrite{RoutingMode=Platform} — a platform broker that egresses
        // OUTSIDE the customer VNet, bypassing the hub Azure Firewall. That's an
        // egress escape hatch and contradicts this lab's "every connection gated
        // by our firewall" thesis (below). With it false, the MCP host instead
        // falls under AzureVNet's default-Allow and egresses through the VNet →
        // forced-tunnel → hub Azure Firewall, where the allow-microsoft-learn
        // collection (vnet.bicep) permits learn.microsoft.com AND
        // raw.githubusercontent.com (the in-sandbox mcp-broker fetches its server
        // bits there during the tools/list handshake). So BOTH the bits and the
        // runtime stream are governed by our firewall — no platform bypass. (The
        // only true pod-side bypass is the platform ExperimentalSettings flag
        // HttpMcpInSandbox, which defaults to the locked-down in-sandbox broker
        // and isn't exposed here.)
        allowHttpMcpServerNetworkAccess: false
        allowedCodeRepositories: []
        // Maximum lockdown: no bypass categories are allow-listed (allowedHosts/
        // Registries/CodeRepositories empty). Egress mode is AzureVNet, so the agent
        // gets REAL VNet egress (not an HTTP-proxy) — but every connection is gated by
        // the Azure Firewall above. Its rules permit ARM/Entra/Graph + Microsoft Learn
        // (public service tags) and the AKS API server over the hub/spoke (TCP 443;
        // the agent VNet has the AKS private-DNS zone linked + a firewall rule +
        // SNAT). Azure Monitor is private-only by default
        // (public AzureMonitor dropped; agent linked to the AMPLS private DNS) — the
        // agent remains fully functional over it. Everything else is denied by
        // design — the agent still cannot open a raw socket to PostgreSQL:5432.
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
  name: 'learn-docs'
  properties: {
    dataConnectorType: 'Mcp'
    dataSource: 'placeholder'
    extendedProperties: {
      type: 'http'
      endpoint: 'https://learn.microsoft.com/api/mcp'
      selectedTools: [
        'learn-docs_microsoft_docs_search'
        'learn-docs_microsoft_code_sample_search'
        'learn-docs_microsoft_docs_fetch'
      ]
      toolsVisibleToMetaAgent: [
        'learn-docs_microsoft_docs_search'
        'learn-docs_microsoft_code_sample_search'
        'learn-docs_microsoft_docs_fetch'
      ]
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
//
// Granular, domain-scoped skills + a general-triage skill for the "unknown"
// bucket. Skills are auto-selected by DESCRIPTION (not linked to filters; max 5
// concurrent), so each description names its alerts/symptoms concretely. Each
// runbook restates the load-bearing constraints (identity/grants, HTTP(S)-proxy
// egress, in-cluster SQL, telemetry filter) because the base64 envelopes are
// independent. @@RG@@ is substituted with the resource group name at deploy time.

var sharedContext = '''Resource Group `@@RG@@`. App namespace `zava-demo`. Deployments `zava-api` / `zava-storefront`. App Insights cloud_RoleName `zava-api`.

You operate with your own managed identity (Entra) — AKS RBAC Cluster Admin, Reader + Monitoring Reader + Contributor on the resource group, Reader at subscription scope for cross-alert and Service Health context, and PostgreSQL Entra admin. Do not create role assignments. Use the built-in `RunKubectlReadCommand` and `RunKubectlWriteCommand` system tools for Kubernetes. Use the read tool for inspection and the write tool for `delete`, `rollout`, and `exec` operations. Run PostgreSQL SQL through the in-cluster helper with the write tool: `kubectl exec -n zava-demo deploy/zava-api -- node bin/run-sql.js '<SQL>'`. Do not install DB clients or open a raw socket to PostgreSQL. Reach ARM over the control plane and Azure Monitor through the configured query tools. Filter every App Insights / Log Analytics query by `AppRoleName == 'zava-api'` because the workspace also contains the agent's ARM-poll telemetry.'''

var databaseSkill = {
  description: 'Use for Zava PostgreSQL AVAILABILITY incidents — alert `postgres-unreachable` (zava-api cannot reach PostgreSQL; connection refused or, more often, timeout). Diagnose the cause from ARM state — stopped server vs network partition — and remediate: restart the server, or remove the in-cluster Kubernetes NetworkPolicy / matching NSG deny rule that blocks PG egress.'
  tools: [
    'RunAzCliReadCommands'
    'RunAzCliWriteCommands'
    'RunKubectlReadCommand'
    'RunKubectlWriteCommand'
    'SearchMemory'
    'learn-docs_microsoft_docs_search'
    'learn-docs_microsoft_docs_fetch'
  ]
  skillContent: '''## Database availability runbook (Zava)

@@SHARED@@

You diagnose from telemetry, then remediate within the permitted-action boundary; outside it, summarize and stop.

The alert `postgres-unreachable` means zava-api cannot reach PostgreSQL — it logged connection failures (refused or, far more often, **timeouts**). A stopped server and a network block BOTH look like timeouts at the app, so **diagnose the cause from ARM state, not the error text**:

| PG ARM `state` | Cause | Action |
|---|---|---|
| `Stopped` | The server was stopped. | **Start it**: `az postgres flexible-server start`. |
| `Ready` (app still can't connect) | A network block. | Inspect the AKS-subnet NSG and Kubernetes **NetworkPolicy** resources in `zava-demo`, account for PostgreSQL delegated-subnet behavior, and remove the configuration that blocks PostgreSQL egress. |

## Permitted autonomous actions
- Start / restart / parameter-set on PostgreSQL Flexible Server.
- Delete a NetworkPolicy in `zava-demo` whose egress blocks PG, and delete a matching NSG deny rule on the AKS subnet.

## Out of scope (summarize + stop)
- `DROP`, DML, schema migrations, role/grant changes; cluster scale / node deletion / VNet changes; any IAM modification.

## Verify
PG `state == Ready`; zava-api connection-error traces stop.

## Close the loop (resolve the alert)
After confirming recovery, **resolve the `postgres-unreachable` alert you were handling** instead of waiting for Azure Monitor's auto-mitigate. Auto-mitigate lags ~15-30 min, and while the alert lingers in a fired state Azure Monitor dedupes the NEXT distinct database incident into this same alert instance — so no new investigation dispatches until it clears. Closing it yourself keeps the loop tight. Take the alert's ARM id from your incident context (form `/subscriptions/.../providers/Microsoft.AlertsManagement/alerts/<guid>`); if you don't have it, list open ones with `az rest --method GET --url "https://management.azure.com/subscriptions/<sub>/providers/Microsoft.AlertsManagement/alerts?api-version=2018-05-05&alertRule=postgres-unreachable"`. Then close it:
`az rest --method POST --url "https://management.azure.com<ALERT_ID>/changestate?api-version=2018-05-05&newState=Closed"`
(your Contributor role grants `Microsoft.AlertsManagement/alerts/changestate/action`).
'''
  additionalFiles: []
  sourcePluginInstallation: null
}

var performanceSkill = {
  description: 'Use for Zava query-LATENCY / slow-endpoint incidents — alert `Zava-products-query-slow` (a /api/products/category endpoint breached its latency threshold). Diagnose the PostgreSQL query path, check nearby alerts with `incident-correlation`, and do not treat a co-firing 5xx as the same cause without a direct dependency-failure mechanism. Apply read-mostly DDL (CREATE INDEX) via the in-cluster SQL helper when the query plan proves it is needed.'
  tools: [
    'RunAzCliReadCommands'
    'RunAzCliWriteCommands'
    'RunKubectlReadCommand'
    'RunKubectlWriteCommand'
    'SearchMemory'
    'learn-docs_microsoft_docs_search'
    'learn-docs_microsoft_docs_fetch'
  ]
  skillContent: '''## Query-performance runbook (Zava)

@@SHARED@@

`Zava-products-query-slow` fires when a `/api/products/category/<X>` endpoint averages above its latency threshold (healthy baseline ~3 ms). Inspect the PostgreSQL query path, including indexes, plans, and statistics, before changing AKS capacity.

## Corroborate across logs, metrics, and traces
1. **Log** (the alert): `AppRequests | where AppRoleName == 'zava-api' | where Name startswith 'GET /api/products/category/' and Name !contains '__probe' | summarize avg(DurationMs) by Name`.
2. **Custom metric**: `AppMetrics | where Name == 'zava.products.category.query.duration_ms' | extend Category = tostring(Properties['category']) | where Category != '__probe' | summarize sum(Sum)/sum(ItemCount) by Category`.
3. **PG saturation metric**: `AzureMetrics` for `cpu_percent` on the PG server (heavy seq scans drive CPU up).
4. **Trace**: `AppDependencies` PostgreSQL-call latency.
Use agreement across these signals to locate the bottleneck.

## Cross-alert guard
Load `incident-correlation` when nearby alerts require comparison. Split
`AppDependencies` by target and result code. Slow successful PostgreSQL calls and
app-local HTTP 500 failures indicate different mechanisms. If the other alert is
already acknowledged, report the relationship and leave remediation to that thread.

## Diagnose at PostgreSQL (in-cluster SQL helper)
Use `RunKubectlWriteCommand` to execute `kubectl exec -n zava-demo deploy/zava-api -- node bin/run-sql.js '<SQL>'`. Inspect `pg_stat_user_indexes` (low/zero `idx_scan` on a hot table is a strong signal), `pg_stat_user_tables` (high `seq_scan`), `pg_stat_statements` (top mean-time), and `EXPLAIN`.

## Permitted autonomous actions
- Read-mostly DDL on PostgreSQL via the in-cluster helper: `CREATE INDEX CONCURRENTLY IF NOT EXISTS`, `ANALYZE`, `REINDEX CONCURRENTLY`.

## Out of scope (summarize + stop)
- `DROP`, DML, schema migrations; pod restarts / cluster scale for this alert; any IAM modification.

## Verify
The category endpoint's avg latency returns to baseline; `idx_scan` climbs on the new index; the alert auto-mitigates.
'''
  additionalFiles: []
  sourcePluginInstallation: null
}

var applicationSkill = {
  description: 'Use for Zava APPLICATION-layer HTTP 5xx incidents — alert `Zava-http-5xx-errors` (zava-api returning HTTP 5xx). Rule out a direct DB failure path, check nearby alerts with `incident-correlation`, and correlate the 5xx onset with a recent rollout. Do not attribute it to a co-firing latency alert unless dependency failures prove that mechanism.'
  tools: [
    'RunAzCliReadCommands'
    'RunAzCliWriteCommands'
    'RunKubectlReadCommand'
    'RunKubectlWriteCommand'
    'SearchMemory'
    'learn-docs_microsoft_docs_search'
    'learn-docs_microsoft_docs_fetch'
  ]
  skillContent: '''## Application 5xx runbook (Zava)

@@SHARED@@

`Zava-http-5xx-errors` fires when zava-api returns more than five HTTP 5xx responses
in five minutes. Because database outages can also produce 5xx responses, first
check PostgreSQL availability and query latency.

## Investigate
1. Confirm PG `state == Ready`, review connection-failure traces, and check `/api/products` latency. If database availability or query latency is affected, use the matching domain runbook.
2. Compare the 5xx onset with recent `zava-api` rollout history and `ScalingReplicaSet` events. Liveness, readiness, and `/api/health` can remain healthy during a route-specific regression.

Load `incident-correlation` when nearby alerts require comparison. Confirm a shared
mechanism in dependency telemetry before assigning a common cause. If the other alert
is already acknowledged, report the relationship and leave remediation to that thread.

## Permitted autonomous actions
- Roll back a `zava-demo` deployment to its previous revision with `RunKubectlWriteCommand` (`kubectl rollout undo deployment/zava-api -n zava-demo`) when a 5xx regression correlates with a recent rollout.
- Restart deployments in `zava-demo`.

## Out of scope (summarize + stop)
- Schema/role/IAM changes; cluster scale / node deletion / VNet changes.

## Verify
`GET /api/products` returns 200; 5xx rate returns to baseline; the alert auto-mitigates.
'''
  additionalFiles: []
  sourcePluginInstallation: null
}

var generalTriageSkill = {
  description: 'Use for ANY Zava incident that does not match a specific known scenario — novel / unknown alerts routed to the unknown response plan. Triage from first principles: identify the impacted resource, gather telemetry, form hypotheses, and propose a remediation for human approval (this path runs in Review mode). Do not auto-remediate beyond clearly read-only/safe steps.'
  tools: [
    'RunAzCliReadCommands'
    'SearchMemory'
    'learn-docs_microsoft_docs_search'
    'learn-docs_microsoft_docs_fetch'
  ]
  skillContent: '''## General triage runbook (Zava — unknown incidents)

@@SHARED@@

This is the catch-all for incidents that do NOT match a known scenario (PostgreSQL availability, query performance, or application 5xx). You run in REVIEW mode: investigate thoroughly and PROPOSE actions for human approval — do not autonomously change resources beyond read-only/safe inspection.

## Approach (first principles)
1. Parse the alert: which rule fired, severity, the impacted Azure resource (`alertTargetIDs` / scope) and the symptom in the description.
2. Establish blast radius and a baseline: is the app serving traffic (`AppRequests` success rate for `AppRoleName == 'zava-api'`), is PostgreSQL `Ready`, are pods healthy (via `KubeEvents` in Azure Monitor — this skill is read-only, so use telemetry rather than `kubectl`)?
3. Gather the relevant telemetry for the impacted resource (Azure Monitor metrics/logs, `KubeEvents`, recent `az monitor activity-log` changes, the hub firewall `AZFW*` logs if egress-related).
4. Form 1–3 ranked hypotheses with the evidence for each.
5. Propose a concrete, least-privilege remediation and the verification step — then stop for approval. If it maps to a known scenario after all, recommend the matching skill.

## Boundaries
Read-only investigation is always allowed. Any mutating action requires approval (Review mode). Never `az role assignment create`. Never `DROP` / DML / schema / IAM changes.
'''
  additionalFiles: []
  sourcePluginInstallation: null
}

var proactiveHealthSkill = {
  description: 'Use when a human operator asks for a proactive health check of the Zava Athletic API — request success rate, latency, exception patterns, PostgreSQL state — to detect anomalies before they become alerts. Hands off to the matching domain skill (database / performance / application) if a known failure mode is found; otherwise completes silently.'
  tools: [
    'RunAzCliReadCommands'
    'SearchMemory'
    'ExecutePythonCode'
    'learn-docs_microsoft_code_sample_search'
    'learn-docs_microsoft_docs_fetch'
    'learn-docs_microsoft_docs_search'
  ]
  skillContent: '''## Proactive Health Check

Pull current signals; complete silently if everything is in baseline.

Always filter App Insights queries by `AppRoleName == 'zava-api'` — the workspace is shared with SRE Agent's own ARM polling, which dominates unfiltered queries.

What "baseline" means for Zava:

1. Request success rate >99% on `/api/*` over the last 15 minutes; single-digit ms avg/p95 on `/api/products*`.
2. Zero `ECONNREFUSED` / `ETIMEDOUT` / "timeout exceeded when trying to connect" exceptions or traces from `zava-api` in the last 15 minutes.
3. PostgreSQL Flexible Server `state == Ready`.

If any of those is missed, hand off to the matching domain skill: `database-incidents` (connectivity), `performance-incidents` (latency), or `application-incidents` (5xx). If everything is in baseline, complete silently.
'''
  additionalFiles: []
  sourcePluginInstallation: null
}

// Read-only correlation procedure for investigations that need context beyond the
// initial alert. Global custom instructions identify when to use this skill; the
// detailed method remains here so it loads only when relevant.
var correlationSkill = {
  description: 'Use during a Zava incident when nearby alerts or conflicting evidence require correlation. Review fired alerts, relevant disabled rules, Azure Service Health, and telemetry to determine whether conditions share a mechanism or should remain independent.'
  tools: [
    'RunAzCliReadCommands'
    'SearchMemory'
  ]
  skillContent: '''## Incident correlation runbook (Zava)

Resource Group `@@RG@@`.

Use this read-only skill when an investigation needs context beyond its initial
alert. This sample opens each alert in a separate thread, so review nearby signals
before assigning a shared cause.

## 1. Review fired alerts

Use the Alerts Management REST API:

`az rest --method get --url "https://management.azure.com/subscriptions/<sub>/providers/Microsoft.AlertsManagement/alerts?api-version=2019-05-05-preview&timeRange=1d&pageCount=250" --query "value[].{ruleId:properties.essentials.alertRule, rg:properties.essentials.targetResourceGroup, sev:properties.essentials.severity, cond:properties.essentials.monitorCondition, start:properties.essentials.startDateTime, target:properties.essentials.targetResource}" -o json`

- `pageCount` must be 1..250. `timeRange` accepts 1h, 1d, 7d, or 30d.
- `RunAzCliReadCommands` rejects shell pipes and `&&` — issue one command per call.
- For log alerts, use `rg` and `ruleId` to identify the environment because
  `targetResource` can be the Log Analytics workspace.

## 2. Review relevant alert rules

Inventory enabled and disabled rules separately from fired-alert history:

`az monitor metrics alert list -g @@RG@@ --query "[].{name:name, enabled:enabled, scopes:scopes}" -o json`
`az rest --method get --url "https://management.azure.com/subscriptions/<sub>/resourceGroups/@@RG@@/providers/microsoft.insights/scheduledQueryRules?api-version=2023-03-15-preview" --query "value[].{name:name, enabled:properties.enabled, window:properties.windowSize, freq:properties.evaluationFrequency}" -o json`

If a relevant rule is disabled, query its underlying metric directly. This sample
includes a disabled `Zava-db-cpu-saturation` rule for that demonstration.

## 3. Check Azure Service Health

Query subscription-scoped events for service issues, planned maintenance, and
health advisories:

`az rest --method get --url "https://management.azure.com/subscriptions/<sub>/providers/Microsoft.ResourceHealth/events?api-version=2022-10-01&queryStartTime=<ISO8601>" --query "value[].{type:properties.eventType, level:properties.eventLevel, status:properties.status, title:properties.title, start:properties.impactStartTime}" -o json`

Per-resource availability:
`az rest --method get --url "https://management.azure.com/subscriptions/<sub>/resourceGroups/@@RG@@/providers/Microsoft.ResourceHealth/availabilityStatuses?api-version=2023-07-01-preview" --query "value[].{res:id, avail:properties.availabilityState, summary:properties.summary}" -o json`

## 4. Confirm the mechanism

Filter every App Insights query by `AppRoleName == 'zava-api'`; the workspace also contains the agent's own ARM-poll telemetry.

Alert timestamps show overlap but do not establish causal order. Use raw telemetry
in 1-2 minute buckets to compare onset.

Before assigning a shared cause, confirm a common mechanism:

| Observation | Reading |
|---|---|
| HTTP 500, failed dependencies ONLY on `localhost:3001`, zero PG dependency failures | app-layer regression |
| HTTP 503, failed dependencies against the PG target | DB unreachable |
| No dependency failures but PG `cpu_percent` and latency are high | DB saturation with successful slow queries |

Split dependency telemetry by `target` and `resultCode`. If the mechanisms differ,
report the conditions as independent.

Treat alerts from another resource group as a separate Zava environment. Cross-resource
group timing can justify a Service Health check but is not sufficient for correlation.

## 5. Report

State whether the evidence supports one cause across several alerts, independent
causes, or an isolated alert. If an independent alert is already acknowledged,
include the relationship in the report and leave remediation to its existing thread.

## Boundaries
Read-only. Use the relevant domain skill for remediation.
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
resource skillDatabase 'Microsoft.App/agents/skills@2025-05-01-preview' = {
  parent: sreAgent
  name: 'database-incidents'
  properties: {
    value: base64(string(union(databaseSkill, {
      skillContent: replace(replace(databaseSkill.skillContent, '@@SHARED@@', sharedContext), '@@RG@@', rgName)
    })))
  }
}

#disable-next-line BCP081
resource skillPerformance 'Microsoft.App/agents/skills@2025-05-01-preview' = {
  parent: sreAgent
  name: 'performance-incidents'
  properties: {
    value: base64(string(union(performanceSkill, {
      skillContent: replace(replace(performanceSkill.skillContent, '@@SHARED@@', sharedContext), '@@RG@@', rgName)
    })))
  }
}

#disable-next-line BCP081
resource skillApplication 'Microsoft.App/agents/skills@2025-05-01-preview' = {
  parent: sreAgent
  name: 'application-incidents'
  properties: {
    value: base64(string(union(applicationSkill, {
      skillContent: replace(replace(applicationSkill.skillContent, '@@SHARED@@', sharedContext), '@@RG@@', rgName)
    })))
  }
}

#disable-next-line BCP081
resource skillGeneralTriage 'Microsoft.App/agents/skills@2025-05-01-preview' = {
  parent: sreAgent
  name: 'general-triage'
  properties: {
    value: base64(string(union(generalTriageSkill, {
      skillContent: replace(replace(generalTriageSkill.skillContent, '@@SHARED@@', sharedContext), '@@RG@@', rgName)
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

// Sixth skill. The "max 5 concurrent" limit is on skills ACTIVE in a thread, not
// on skills defined — a domain skill plus this correlation skill is 2 of 5, which
// is the intended pairing.
#disable-next-line BCP081
resource skillCorrelation 'Microsoft.App/agents/skills@2025-05-01-preview' = {
  parent: sreAgent
  name: 'incident-correlation'
  properties: {
    value: base64(string(union(correlationSkill, {
      skillContent: replace(correlationSkill.skillContent, '@@RG@@', rgName)
    })))
  }
}

// --- Incident filters (a.k.a. response plans) ------------------------------
// Granular routing: one filter per known DOMAIN (database / performance /
// application) plus an UNKNOWN catch-all. handlingAgent 'meta_agent' -> the agent
// picks a skill by description (skills are NOT linked to filters), so the filter
// names/tokens and the skill descriptions are kept aligned.
//
// Overlapping matches have no customer-controlled priority or specificity rule:
// the runtime uses the first matching plan in mutable filter order. Treat that
// choice as undefined and keep routes NON-OVERLAPPING. Each known filter matches
// one alert token; the fallback positively matches this demo's `Zava` prefix and
// explicitly excludes every known token. It therefore cannot sweep in unrelated
// subscription alerts and runs in REVIEW mode — investigate + propose, don't
// auto-act on a novel incident.

var defaultPriorities = [
  'Sev0'
  'Sev1'
  'Sev2'
  'Sev3'
  // Sev4 included so activity-log alerts (which default to Sev4 Informational
  // when severity isn't set on the rule, e.g. Zava-unknown-test) still route.
  'Sev4'
]

var databaseFilter = {
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
  handlingAgent: 'meta_agent'
  handlingAgents: null
  owningTeamId: ''
  owningTeamIds: []
  maxAutomatedInvestigationAttempts: 3
  // Keep demo alerts in separate threads so Scenario 5 can compare concurrent
  // investigations. The database scenarios share one stateful Azure Monitor alert
  // and close it after recovery to support repeat runs.
  mergeEnabled: false
  mergeWindowHours: 3
  isEnabled: true
  icmFilterSettings: null
  azMonitorFilterSettings: {
    targetResourceType: ''
    targetResource: ''
  }
}

var performanceFilter = {
  incidentPlatform: 'AzMonitor'
  impactedService: ''
  priorities: defaultPriorities
  incidentType: ''
  alertId: ''
  titleContains: 'query-slow'
  titleContainsAll: []
  titleContainsAny: []
  titleNotContains: []
  agentMode: 'autonomous'
  handlingAgent: 'meta_agent'
  handlingAgents: null
  owningTeamId: ''
  owningTeamIds: []
  maxAutomatedInvestigationAttempts: 3
  // Merge OFF — no dedup; every perf incident opens its own thread.
  mergeEnabled: false
  mergeWindowHours: 3
  isEnabled: true
  icmFilterSettings: null
  azMonitorFilterSettings: {
    targetResourceType: ''
    targetResource: ''
  }
}

var applicationFilter = {
  incidentPlatform: 'AzMonitor'
  impactedService: ''
  priorities: defaultPriorities
  incidentType: ''
  alertId: ''
  titleContains: 'http-5xx'
  titleContainsAll: []
  titleContainsAny: []
  titleNotContains: []
  agentMode: 'autonomous'
  handlingAgent: 'meta_agent'
  handlingAgents: null
  owningTeamId: ''
  owningTeamIds: []
  maxAutomatedInvestigationAttempts: 3
  // Merge OFF — no dedup; every 5xx incident opens its own thread.
  mergeEnabled: false
  mergeWindowHours: 3
  isEnabled: true
  icmFilterSettings: null
  azMonitorFilterSettings: {
    targetResourceType: ''
    targetResource: ''
  }
}

// Unknown / catch-all bucket. Positively bounded to Zava-named alerts, excludes
// every known routing token, and runs in Review mode with fewer auto-attempts.
// Exercise it with the (disabled-by-default)
// `Zava-unknown-test` alert in monitoring.bicep.
var unknownFilter = {
  incidentPlatform: 'AzMonitor'
  impactedService: ''
  priorities: defaultPriorities
  incidentType: ''
  alertId: ''
  titleContains: 'Zava'
  titleContainsAll: []
  titleContainsAny: []
  titleNotContains: [
    'postgres'
    'query-slow'
    'http-5xx'
  ]
  agentMode: 'review'
  handlingAgent: 'meta_agent'
  handlingAgents: null
  owningTeamId: ''
  owningTeamIds: []
  maxAutomatedInvestigationAttempts: 2
  // Merge OFF — no dedup; every novel incident opens its own (Review-mode) thread.
  mergeEnabled: false
  mergeWindowHours: 3
  isEnabled: true
  icmFilterSettings: null
  azMonitorFilterSettings: {
    targetResourceType: ''
    targetResource: ''
  }
}

#disable-next-line BCP081
resource filterDatabase 'Microsoft.App/agents/incidentFilters@2025-05-01-preview' = {
  parent: sreAgent
  name: 'zava-database'
  properties: {
    value: base64(string(databaseFilter))
  }
}

#disable-next-line BCP081
resource filterPerformance 'Microsoft.App/agents/incidentFilters@2025-05-01-preview' = {
  parent: sreAgent
  name: 'zava-performance'
  properties: {
    value: base64(string(performanceFilter))
  }
}

#disable-next-line BCP081
resource filterApplication 'Microsoft.App/agents/incidentFilters@2025-05-01-preview' = {
  parent: sreAgent
  name: 'zava-application'
  properties: {
    value: base64(string(applicationFilter))
  }
}

#disable-next-line BCP081
resource filterUnknown 'Microsoft.App/agents/incidentFilters@2025-05-01-preview' = {
  parent: sreAgent
  name: 'zava-unknown'
  properties: {
    value: base64(string(unknownFilter))
  }
}

output agentName string = sreAgent.name
output agentId string = sreAgent.id
output agentEndpoint string = sreAgent.properties.agentEndpoint
output agentSystemPrincipalId string = sreAgent.identity.principalId
// Deep-link straight to this agent's blade so the operator lands on the
// Threads tab without having to pick the agent from a list.
output agentPortalUrl string = 'https://sre.azure.com/agents${sreAgent.id}'
