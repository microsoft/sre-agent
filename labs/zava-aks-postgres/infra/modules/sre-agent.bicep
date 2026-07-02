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
    // plus the AKS API server over the hub/spoke (so the agent uses native
    // `kubectl`). Azure Monitor is private-only by default (lockAgentToPrivateMonitor):
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
        // (public service tags) and the AKS API server over the hub/spoke (TCP 443 —
        // native kubectl is enabled; the agent VNet has the AKS private-DNS zone
        // linked + a firewall rule + SNAT). Azure Monitor is private-only by default
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
//
// Granular, domain-scoped skills + a general-triage skill for the "unknown"
// bucket. Skills are auto-selected by DESCRIPTION (not linked to filters; max 5
// concurrent), so each description names its alerts/symptoms concretely. Each
// runbook restates the load-bearing constraints (identity/grants, HTTP(S)-proxy
// egress, in-cluster SQL, telemetry filter) because the base64 envelopes are
// independent. @@RG@@ is substituted with the resource group name at deploy time.

var sharedContext = '''Resource Group `@@RG@@`. App namespace `zava-demo`. Deployments `zava-api` / `zava-storefront`. App Insights cloud_RoleName `zava-api`.

You operate with your own managed identity (Entra) — AKS RBAC Cluster Admin, Reader + Monitoring Reader + Contributor on the resource group, and PostgreSQL Entra admin. These are sufficient: do NOT attempt `az role assignment create` (it is denied — if you think you need a role you lack, your diagnosis is wrong, back up). Your sandbox egress is forced through an Azure Firewall (allow-list: ARM, Entra, Microsoft Graph, Microsoft Learn over public service tags, plus the AKS API server over the hub/spoke; Azure Monitor is reached privately via the AMPLS private endpoint by default) AND a TLS-inspecting forward proxy that re-signs certificates. This cluster is wired for native `kubectl` (the agent VNet has the AKS private-DNS zone linked and a firewall rule + SNAT to the API server): you run `kubectl` yourself as a bash command in your sandbox terminal (`RunInTerminal`). One-time setup per session: (1) `az aks get-credentials -g @@RG@@ -n <aks-cluster> --overwrite-existing` (find the cluster via `az aks list -g @@RG@@ --query "[0].name" -o tsv`); (2) `kubelogin convert-kubeconfig -l azurecli` — non-interactive managed-identity auth (the DEFAULT device-code flow hangs; do not use it); (3) trust the egress proxy by merging its CA `/etc/ssl/certs/adc-egress-proxy-ca.crt` into the kubeconfig cluster's `certificate-authority-data`. Then `kubectl get nodes` works; run kubectl in your terminal for pods, logs, events, NetworkPolicies, rollouts, and the in-cluster SQL helper `kubectl exec -n zava-demo deploy/zava-api -- node bin/run-sql.js '<SQL>'`. Never install DB clients (`psql`, `psycopg2`) or open a raw socket to PostgreSQL. Reach ARM over the control plane; reach Azure Monitor (Log Analytics / Application Insights) with your Monitor query tools — they work normally (this deployment locks the agent's Monitor access to the AMPLS private endpoint by default, and your tools operate fine over it). Filter every App Insights / Log Analytics query by `AppRoleName == 'zava-api'` — the workspace is shared with your own ARM-poll telemetry.'''

var databaseSkill = {
  description: 'Use for Zava PostgreSQL AVAILABILITY incidents — alert `postgres-unreachable` (zava-api cannot reach PostgreSQL; connection refused or, more often, timeout). Diagnose the cause from ARM state — stopped server vs network partition — and remediate: restart the server, or remove the in-cluster Kubernetes NetworkPolicy / matching NSG deny rule that blocks PG egress.'
  tools: [
    'RunAzCliReadCommands'
    'RunAzCliWriteCommands'
    'RunInTerminal'
    'SearchMemory'
    'microsoft-learn_microsoft_docs_search'
    'microsoft-learn_microsoft_docs_fetch'
  ]
  skillContent: '''## Database availability runbook (Zava)

@@SHARED@@

You diagnose from telemetry, then remediate within the permitted-action boundary; outside it, summarize and stop.

The alert `postgres-unreachable` means zava-api cannot reach PostgreSQL — it logged connection failures (refused or, far more often, **timeouts**). A stopped server and a network block BOTH look like timeouts at the app, so **diagnose the cause from ARM state, not the error text**:

| PG ARM `state` | Cause | Action |
|---|---|---|
| `Stopped` | The server was stopped. | **Start it**: `az postgres flexible-server start`. |
| `Ready` (app still can't connect) | A network block. | Two enforcement surfaces sit between the app and PG: an NSG deny rule on the AKS subnet (often a RED HERRING — PG's private access uses a platform-managed delegated subnet) and a Kubernetes **NetworkPolicy** in `zava-demo` (usually the real cause). Inspect both — `az network nsg rule list` and `kubectl get networkpolicy -A -o yaml` (run in your terminal) — then delete the offending NetworkPolicy with `kubectl delete networkpolicy <name> -n zava-demo` (and any matching NSG deny rule on the AKS subnet). |

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
  description: 'Use for Zava query-LATENCY / slow-endpoint incidents — alert `Zava-products-query-slow` (a /api/products/category endpoint breached its latency threshold). The bottleneck is at PostgreSQL (missing/disabled index, plan regression), not pods/CPU. Corroborate with the custom latency metric + PG CPU, then apply read-mostly DDL (CREATE INDEX) via the in-cluster SQL helper.'
  tools: [
    'RunAzCliReadCommands'
    'RunAzCliWriteCommands'
    'RunInTerminal'
    'SearchMemory'
    'microsoft-learn_microsoft_docs_search'
    'microsoft-learn_microsoft_docs_fetch'
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

## Diagnose at PostgreSQL (in-cluster SQL helper)
`kubectl exec -n zava-demo deploy/zava-api -- node bin/run-sql.js '<SQL>'` — run kubectl in your terminal, set up per shared context. Inspect `pg_stat_user_indexes` (low/zero `idx_scan` on a hot table is a strong signal), `pg_stat_user_tables` (high `seq_scan`), `pg_stat_statements` (top mean-time), and `EXPLAIN`.

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
  description: 'Use for Zava APPLICATION-layer HTTP 5xx incidents — alert `Zava-http-5xx-errors` (zava-api returning HTTP 5xx). This is typically an app/route regression such as a bad deploy, but a DB outage also produces 5xx, so FIRST rule out DB/perf; if PG is healthy, correlate the 5xx onset with a recent rollout and roll back to the previous good revision.'
  tools: [
    'RunAzCliReadCommands'
    'RunAzCliWriteCommands'
    'RunInTerminal'
    'SearchMemory'
    'microsoft-learn_microsoft_docs_search'
    'microsoft-learn_microsoft_docs_fetch'
  ]
  skillContent: '''## Application 5xx runbook (Zava)

@@SHARED@@

`Zava-http-5xx-errors` fires when zava-api returns >5 HTTP 5xx in 5 min. It does NOT self-suppress on DB errors, so a DB outage (which also returns 5xx) can fire this alert too — therefore your FIRST step is to rule out a DB/perf root cause. If PostgreSQL is healthy and there is no slow-query symptom, this is an APP-layer regression.

## Investigate
1. Briefly confirm it is not DB/perf after all: PG `state == Ready`, no ECONNREFUSED/ETIMEDOUT traces, `/api/products` latency normal. If a DB or slow-query symptom is actually present, defer to the database / performance runbook.
2. App regressions are usually shipped by a deploy. Every change to the `zava-api` Deployment pod template creates a new ReplicaSet **revision**. Check whether the 5xx onset lines up with a recent rollout: native `kubectl rollout history deployment/zava-api -n zava-demo` and `KubeEvents` (Azure Monitor) (`ScalingReplicaSet` timestamps). Note the liveness AND readiness probes both hit `/livez` (shallow, no DB call), so pods stay Ready through an app-route regression and the platform looks healthy while the app is broken; `/api/health` is a separate app health endpoint (it pings the DB) and can also stay green for a route-only regression — deployment correlation is the tie.

## Permitted autonomous actions
- Roll back a `zava-demo` deployment to its previous revision (native `kubectl rollout undo deployment/zava-api -n zava-demo`) when a 5xx regression correlates with a recent rollout.
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
    'microsoft-learn_microsoft_docs_search'
    'microsoft-learn_microsoft_docs_fetch'
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
    'microsoft-learn_microsoft_code_sample_search'
    'microsoft-learn_microsoft_docs_fetch'
    'microsoft-learn_microsoft_docs_search'
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

// --- Incident filters (a.k.a. response plans) ------------------------------
// Granular routing: one filter per known DOMAIN (database / performance /
// application) plus an UNKNOWN catch-all. handlingAgent 'default' -> the agent
// picks a skill by description (skills are NOT linked to filters), so the filter
// names/tokens and the skill descriptions are kept aligned.
//
// There is NO documented precedence when multiple filters match, so the buckets
// are made NON-OVERLAPPING: each known filter matches one alert token, and the
// unknown filter excludes all known tokens via titleNotContains. The unknown
// bucket is bounded to the demo's own alerts (titleContainsAny 'Zava' / 'postgres')
// so it can't sweep in unrelated subscription noise, and runs in REVIEW mode with
// deep investigation — investigate + propose, don't auto-act on a novel incident.

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
  handlingAgent: 'default'
  handlingAgents: null
  owningTeamId: ''
  owningTeamIds: []
  maxAutomatedInvestigationAttempts: 3
  deepInvestigationEnabled: false
  // Merge OFF on every plan — no agent-side deduplication. We want each scenario to
  // open its OWN investigation thread, not fold into a prior one (dedup hid real
  // incidents in testing). NOTE: the two DB scenarios still share the one
  // `postgres-unreachable` rule, so back-to-back runs need the prior alert to
  // auto-resolve first (Azure Monitor won't emit a fresh instance while it's Fired)
  // — see monitoring.bicep alertDbUnreachable. That is an Azure Monitor stateful-alert
  // behavior, independent of this (already-off) agent merge setting.
  mergeEnabled: false
  mergeWindowHours: 0
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
  handlingAgent: 'default'
  handlingAgents: null
  owningTeamId: ''
  owningTeamIds: []
  maxAutomatedInvestigationAttempts: 3
  deepInvestigationEnabled: false
  // Merge OFF — no dedup; every perf incident opens its own thread.
  mergeEnabled: false
  mergeWindowHours: 0
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
  handlingAgent: 'default'
  handlingAgents: null
  owningTeamId: ''
  owningTeamIds: []
  maxAutomatedInvestigationAttempts: 3
  deepInvestigationEnabled: false
  // Merge OFF — no dedup; every 5xx incident opens its own thread.
  mergeEnabled: false
  mergeWindowHours: 0
  isEnabled: true
  icmFilterSettings: null
  azMonitorFilterSettings: {
    targetResourceType: ''
    targetResource: ''
  }
}

// Unknown / catch-all bucket. Bounded to demo-named alerts (Zava* / postgres*),
// excludes every known routing token, runs in Review mode with deep investigation
// and fewer auto-attempts. Exercise it with the (disabled-by-default)
// `Zava-unknown-test` alert in monitoring.bicep.
var unknownFilter = {
  incidentPlatform: 'AzMonitor'
  impactedService: ''
  priorities: defaultPriorities
  incidentType: ''
  alertId: ''
  titleContains: ''
  titleContainsAll: []
  titleContainsAny: [
    'Zava'
    'postgres'
  ]
  titleNotContains: [
    'postgres'
    'query-slow'
    'http-5xx'
  ]
  agentMode: 'review'
  handlingAgent: 'default'
  handlingAgents: null
  owningTeamId: ''
  owningTeamIds: []
  maxAutomatedInvestigationAttempts: 2
  deepInvestigationEnabled: true
  // Merge OFF — no dedup; every novel incident opens its own (Review-mode) thread.
  mergeEnabled: false
  mergeWindowHours: 0
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


