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

You operate with your own managed identity (Entra) — AKS RBAC Cluster Admin, Reader + Monitoring Reader + Contributor on the resource group, Reader at subscription scope for cross-alert and Service Health context, and PostgreSQL Entra admin. These are sufficient: do NOT attempt `az role assignment create` (it is denied — if you think you need a role you lack, your diagnosis is wrong, back up). Use the built-in `RunKubectlReadCommand` and `RunKubectlWriteCommand` system tools for Kubernetes; they accept the same kubectl commands as a terminal. Use the read tool for inspection and the write tool for `delete`, `rollout`, and `exec` operations. Do not replace them with terminal-native kubectl, login repair, kubeconfig setup, or Python wrappers. Run PostgreSQL SQL through the in-cluster helper with the write tool: `kubectl exec -n zava-demo deploy/zava-api -- node bin/run-sql.js '<SQL>'`. Never install DB clients (`psql`, `psycopg2`) or open a raw socket to PostgreSQL. Reach ARM over the control plane; reach Azure Monitor (Log Analytics / Application Insights) with your Monitor query tools — they work normally (this deployment locks the agent's Monitor access to the AMPLS private endpoint by default, and your tools operate fine over it). Filter every App Insights / Log Analytics query by `AppRoleName == 'zava-api'` — the workspace is shared with your own ARM-poll telemetry.'''

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
| `Ready` (app still can't connect) | A network block. | Two enforcement surfaces sit between the app and PG: an NSG deny rule on the AKS subnet (often a RED HERRING — PG's private access uses a platform-managed delegated subnet) and a Kubernetes **NetworkPolicy** in `zava-demo` (usually the real cause). Inspect both with `az network nsg rule list` and `RunKubectlReadCommand`, then delete the offending NetworkPolicy with `RunKubectlWriteCommand` (and any matching NSG deny rule on the AKS subnet). |

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

`Zava-products-query-slow` fires when a `/api/products/category/<X>` endpoint averages above its latency threshold (healthy baseline ~3 ms). The bottleneck is almost always at the DATABASE (missing/disabled index, plan regression, statistics drift), NOT pods/CPU/memory — never restart pods or scale the cluster for this alert.

## Corroborate across logs + metrics + traces (REQUIRED — these are paired with the alert, not separate alerts)
1. **Log** (the alert): `AppRequests | where AppRoleName == 'zava-api' | where Name startswith 'GET /api/products/category/' and Name !contains '__probe' | summarize avg(DurationMs) by Name`.
2. **Custom metric**: `AppMetrics | where Name == 'zava.products.category.query.duration_ms' | extend Category = tostring(Properties['category']) | where Category != '__probe' | summarize sum(Sum)/sum(ItemCount) by Category`.
3. **PG saturation metric**: `AzureMetrics` for `cpu_percent` on the PG server (heavy seq scans drive CPU up).
4. **Trace**: `AppDependencies` PostgreSQL-call latency.
Agreement across all four points at the database query, not the app tier.

## Cross-alert guard
Load `incident-correlation` to check fired-alert history before assigning a shared root cause; alert-rule inventory cannot tell you what fired. A co-firing 5xx is NOT corroboration for a slow-query diagnosis. Split `AppDependencies` by target and result code: slow but successful PostgreSQL calls establish this latency fault, but they cannot explain HTTP 500s whose failed dependencies are only app-local. Different mechanisms mean independent incidents, even when their alert times and resource group match. If the other alert is already acknowledged, report the relationship but leave its remediation to that thread.

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

`Zava-http-5xx-errors` fires when zava-api returns >5 HTTP 5xx in 5 min. It does NOT self-suppress on DB errors, so a DB outage (which also returns 5xx) can fire this alert too — therefore your FIRST step is to rule out a DB/perf root cause. If PostgreSQL is healthy and there is no slow-query symptom, this is an APP-layer regression.

## Investigate
1. Briefly confirm it is not DB/perf after all: PG `state == Ready`, no ECONNREFUSED/ETIMEDOUT traces, `/api/products` latency normal. If a DB or slow-query symptom is actually present, defer to the database / performance runbook.
2. App regressions are usually shipped by a deploy. Every change to the `zava-api` Deployment pod template creates a new ReplicaSet **revision**. Check whether the 5xx onset lines up with a recent rollout using `RunKubectlReadCommand` for `kubectl rollout history deployment/zava-api -n zava-demo` and `KubeEvents` (Azure Monitor) (`ScalingReplicaSet` timestamps). Note the liveness AND readiness probes both hit `/livez` (shallow, no DB call), so pods stay Ready through an app-route regression and the platform looks healthy while the app is broken; `/api/health` is a separate app health endpoint (it pings the DB) and can also stay green for a route-only regression — deployment correlation is the tie.

Load `incident-correlation` to check fired-alert history; alert-rule inventory cannot tell you what fired. Shared timing is not a mechanism: split `AppDependencies` by target and result code before claiming the other alert caused this one. A slow-query alert with successful PostgreSQL dependencies does not explain HTTP 500s whose failed dependency is app-local. If the other alert is already acknowledged, report the relationship but leave its remediation to that thread.

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

// Cross-alert correlation ("is this the tree or the forest?").
//
// This skill exists because the platform CANNOT hand the agent a forest view.
// Every response plan here runs `mergeEnabled: false`, and Azure Monitor merging
// is same-alert-rule-only, so each fired alert opens its OWN isolated thread with
// no visibility into what else fired. Structural isolation is the default. The
// only way an investigation sees the wider picture is if it PULLS it.
//
// Deliberately NOT put in the alert `description` fields (AGENTS.md forbids
// semantics there, and a per-alert string can't express a cross-alert idea), and
// NOT duplicated into all four incidentFilters (four copies = drift). The cheap
// always-on trigger lives in `sre-config/custom-instructions.md`, applied to the
// agent-global customInstructions surface by scripts/setup-sre-agent.ps1 (Step 2c);
// this skill carries the expensive procedure and loads only when that trigger fires.
// That split is the token-cost design: ~200 always-on tokens, full method on demand.
var correlationSkill = {
  description: 'Use during a Zava incident when the dispatched alert may be only part of the story: another alert fired nearby, the evidence does not add up, remediation did not hold, or a symptom appears to precede its cause. Enumerates other Azure Monitor alerts, disabled alert rules that may hide the causal signal, and Azure Service Health, then distinguishes one causal chain from independent faults that merely overlapped.'
  tools: [
    'RunAzCliReadCommands'
    'SearchMemory'
  ]
  skillContent: '''## Cross-alert correlation runbook (Zava)

Resource Group `@@RG@@`.

You were dispatched on ONE alert. That alert is a filter someone wrote in advance, on one signal, with one threshold — it is evidence, not a conclusion, and it cannot tell you whether it is the cause, a symptom, or a coincidence. Every response plan in this deployment has merge DISABLED, so a single root cause opens several INDEPENDENT threads that cannot see each other. Nobody assembles the forest for you. Pull it.

## 1. What else fired? (the forest)

`az graph query` is usually unavailable (resource-graph extension absent). Use the Alerts Management REST API:

`az rest --method get --url "https://management.azure.com/subscriptions/<sub>/providers/Microsoft.AlertsManagement/alerts?api-version=2019-05-05-preview&timeRange=1d&pageCount=250" --query "value[].{ruleId:properties.essentials.alertRule, rg:properties.essentials.targetResourceGroup, sev:properties.essentials.severity, cond:properties.essentials.monitorCondition, start:properties.essentials.startDateTime, target:properties.essentials.targetResource}" -o json`

- `pageCount` MUST be 1..250 (larger returns BadRequest). `timeRange` accepts 1h/1d/7d/30d only.
- `RunAzCliReadCommands` rejects shell pipes and `&&` — issue one command per call.
- `alertRule` is already the full rule resource ID in this API; the projection names it `ruleId`.
- For LOG alerts `targetResource` is the Log Analytics WORKSPACE, not the app or DB. Use `rg` / `ruleId` to identify the environment; do not group by `targetResource`.
- This fired-alert feed and the rule inventory in step 2 answer different questions. Never conclude "nothing else fired" from `scheduledQueryRules` or `az monitor metrics alert list`.

## 2. Which alerts SHOULD have fired but did not? (the silent cause)

A missing alert is a finding. Enumerate the rule INVENTORY, not just fired alerts:

`az monitor metrics alert list -g @@RG@@ --query "[].{name:name, enabled:enabled, scopes:scopes}" -o json`
`az rest --method get --url "https://management.azure.com/subscriptions/<sub>/resourceGroups/@@RG@@/providers/microsoft.insights/scheduledQueryRules?api-version=2023-03-15-preview" --query "value[].{name:name, enabled:properties.enabled, window:properties.windowSize, freq:properties.evaluationFrequency}" -o json`

If a rule sits on the resource you are investigating and is `enabled: false`, the causal signal is MUTED — query that metric directly rather than concluding the resource was healthy. This deployment ships `Zava-db-cpu-saturation` disabled on purpose; PG CPU can be pegged at 90% with no DB alert anywhere.

## 3. Is the platform itself the cause?

Azure Service Health, subscription-scoped — covers regional outages and planned maintenance:

`az rest --method get --url "https://management.azure.com/subscriptions/<sub>/providers/Microsoft.ResourceHealth/events?api-version=2022-10-01&queryStartTime=<ISO8601>" --query "value[].{type:properties.eventType, level:properties.eventLevel, status:properties.status, title:properties.title, start:properties.impactStartTime}" -o json`

`eventType` is `ServiceIssue` (outage), `PlannedMaintenance`, or `HealthAdvisory`. Per-resource view:
`az rest --method get --url "https://management.azure.com/subscriptions/<sub>/resourceGroups/@@RG@@/providers/Microsoft.ResourceHealth/availabilityStatuses?api-version=2023-07-01-preview" --query "value[].{res:id, avail:properties.availabilityState, summary:properties.summary}" -o json`

Check this BEFORE concluding "platform health event" from absence of evidence. A `PlannedMaintenance` event naming PostgreSQL turns a guess into a fact, and it changes the remediation: you wait and document instead of chasing config.

## 4. TWO RULES — violate these and correlation makes you WORSE, not better

Filter every App Insights query by `AppRoleName == 'zava-api'`; the workspace also contains the agent's own ARM-poll telemetry.

**Alert fire order is NOT causal order.** Every dispatching rule here is `PT5M` window / `PT5M` evaluation, so detection latency is up to 5 min plus ingestion lag. A symptom alert can fire BEFORE the cause alert. Any gap under ~7 minutes proves nothing about ordering. Establish onset from raw telemetry in 1-2 minute buckets, never from alert timestamps.

**Co-firing is NOT causation.** Two alerts seconds apart can be two unrelated faults. Before claiming a causal chain, confirm the mechanism in telemetry:

| Observation | Reading |
|---|---|
| HTTP 500, failed dependencies ONLY on `localhost:3001`, zero PG dependency failures | app-layer regression |
| HTTP 503, failed dependencies against the PG target | DB unreachable |
| No dependency FAILURES but PG `cpu_percent` high and latency up | DB saturation — slow but SUCCESSFUL queries, so failure-based signals stay clean |

The single fastest discriminator is one `dependencies` query split by `target` alongside `resultCode`. If two co-firing alerts have different mechanisms, they are independent — report them as separate incidents and do not merge the narrative.

**Environment containment:** alerts from a DIFFERENT resource group are a different Zava stack. Same-RG co-firing only identifies the candidate environment; it does NOT suggest a shared cause. Cross-RG simultaneity may justify checking for a platform event (step 3), but still proves nothing by itself. Never merge findings across resource groups without that check.

## 5. Report

State plainly which it was: (a) one cause, several alerts; (b) several independent causes that overlapped; or (c) this alert is the whole story. If (c), say so in one line and move on — a correlation sweep that finds nothing is a successful sweep, not wasted work.

If an independent alert is already `Acknowledged`, its own thread is active. Attach the correlation finding to your report, but do not execute that other domain's remediation from this thread; concurrent duplicate writes can conflict.

## Boundaries
Read-only. This skill never remediates — hand off to `database-incidents`, `performance-incidents`, or `application-incidents` with the correlation context attached.
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
  // Merge OFF on every plan — no agent-side deduplication. We want each scenario to
  // open its OWN investigation thread, not fold into a prior one (dedup hid real
  // incidents in testing). NOTE: the two DB scenarios still share the one
  // `postgres-unreachable` rule, so back-to-back runs need the prior alert to
  // auto-resolve first (Azure Monitor won't emit a fresh instance while it's Fired)
  // — see monitoring.bicep alertDbUnreachable. That is an Azure Monitor stateful-alert
  // behavior, independent of this (already-off) agent merge setting.
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
