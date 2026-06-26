@description('Azure region for monitoring resources.')
param location string

@description('Unique suffix for globally unique resource names.')
param uniqueSuffix string

@description('PostgreSQL flexible server name to attach diagnostic settings to.')
param postgresServerName string

@description('Resource group ID — scope for activity-log-based alerts.')
param resourceGroupId string

var lawName = 'law-Zava-${uniqueSuffix}'
var aiName = 'ai-Zava-${uniqueSuffix}'

// Demo workspace design:
// - retentionInDays = 30 (PerGB2018 SKU floor)
// - No workspaceCapping.dailyQuotaGb — alerts must always be able to fire.
//   Volume is bounded at the SDK layer instead (logger.js ships warn/error
//   only; auto-instrumentation handles AppRequests).
// - High-volume App Insights tables pinned to the 4-day per-table minimum
//   below to keep storage cost low.
resource law 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: lawName
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
    features: {
      immediatePurgeDataOn30Days: true
    }
  }
}

// Per-table retention overrides — workspace floor is 30 days but individual
// tables can go as low as 4 days. Trim the high-volume App Insights tables
// so demo logs roll off quickly (~1 day's worth of useful history is enough).
var shortLivedTables = [
  'AppTraces'
  'AppRequests'
  'AppDependencies'
  'AppPerformanceCounters'
  'AppPageViews'
  'AppBrowserTimings'
  'AppMetrics'
  'AppSystemEvents'
  'AppAvailabilityResults'
]

resource shortRetention 'Microsoft.OperationalInsights/workspaces/tables@2022-10-01' = [for tableName in shortLivedTables: {
  parent: law
  name: tableName
  properties: {
    retentionInDays: 4
    totalRetentionInDays: 4
  }
}]

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: aiName
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: law.id
    // For workspace-based App Insights (IngestionMode=LogAnalytics) the
    // component's RetentionInDays is effectively a no-op — the workspace
    // and per-table settings above are what actually govern retention.
    // Set here only because the API requires it.
    RetentionInDays: 30
    IngestionMode: 'LogAnalytics'
  }
}

// Action group (empty — SRE Agent polls Azure Monitor directly, but alerts need a target)
resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: 'ag-Zava-sre-${uniqueSuffix}'
  location: 'global'
  properties: {
    groupShortName: 'Zava-sre'
    enabled: true
  }
}

// Alert: HTTP 5xx errors — app-layer / bad-deploy regression (Scenario 4).
//
// Fires purely on the 5xx failed-request count — NO DB self-suppression. We don't
// dedupe: a DB outage that also produces 5xx will open BOTH a `postgres-unreachable`
// thread and this app thread (each real symptom surfaces its own investigation; the
// application runbook rules out DB/perf first). Symptom-only description (see AGENTS.md).
resource alert5xx 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: 'Zava-http-5xx-errors'
  location: location
  properties: {
    severity: 2
    enabled: true
    // PT5M (not PT1M): at 1-minute evaluation the SRE agent acknowledges this alert
    // but does not open an autonomous investigation; 5-minute evaluation dispatches
    // reliably (see alertDbUnreachable / alertProductsSlow for the same rationale).
    evaluationFrequency: 'PT5M'
    windowSize: 'PT5M'
    scopes: [law.id]
    criteria: {
      allOf: [
        {
          query: '''
            AppRequests
            | where TimeGenerated > ago(5m)
            | where AppRoleName == 'zava-api'
            | where Success == false and toint(ResultCode) >= 500
            | summarize ErrorCount = count()
          '''
          timeAggregation: 'Total'
          metricMeasureColumn: 'ErrorCount'
          operator: 'GreaterThan'
          threshold: 5
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    actions: {
      actionGroups: [actionGroup.id]
    }
    autoMitigate: true
    description: 'Zava Demo: zava-api returned more than 5 HTTP 5xx responses in the last 5 minutes.'
  }
}


// Diagnostic settings: pipe PostgreSQL logs to Log Analytics for SRE Agent query access
resource pgServer 'Microsoft.DBforPostgreSQL/flexibleServers@2024-08-01' existing = {
  name: postgresServerName
}

resource pgDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'pg-to-law'
  scope: pgServer
  properties: {
    workspaceId: law.id
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

output logAnalyticsWorkspaceId string = law.id
output logAnalyticsWorkspaceName string = law.name
// NOT @secure() — see main.bicep for why (azd env get-value drops secure outputs,
// breaking the post-provision.ps1 substitution into k8s Secrets).
output appInsightsConnectionString string = appInsights.properties.ConnectionString
output appInsightsResourceId string = appInsights.id
output appInsightsName string = appInsights.name
output appInsightsAppId string = appInsights.properties.AppId

// Alert: PostgreSQL unreachable from the app — covers BOTH Scenario 1 (server
// stopped) and Scenario 2 (network partition). One symptom-based alert, not two.
//
// Empirically, BOTH a stopped PG Flexible Server and a NetworkPolicy/NSG
// block present at the app as connection TIMEOUTS — a deallocated private endpoint
// and a dropped packet both time out (measured ~1650 timeout traces vs ~42
// ECONNREFUSED on a stop). So the failure mode CANNOT be distinguished by error
// text. We alert on the symptom ("zava-api cannot reach PostgreSQL") and let the
// SRE Agent diagnose the cause from ARM state: PG `Stopped` -> start it; PG `Ready`
// but unreachable -> find the blocking Kubernetes NetworkPolicy / NSG rule. Routes
// to `zava-database` via titleContains:'postgres'. The database response plan has
// merge DISABLED so the agent won't fold the two DB scenarios into one thread. NOTE:
// both scenarios share THIS one rule, so Azure Monitor won't emit a fresh alert
// instance while the prior one is still Fired. The database-incidents runbook has the
// agent CLOSE this alert as its final step once recovery is verified (using its
// Contributor changestate right), so back-to-back runs dispatch fresh; autoMitigate
// (~15-30 min) is the fallback if the agent doesn't close it.
resource alertDbUnreachable 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: 'postgres-unreachable'
  location: location
  properties: {
    severity: 1
    enabled: true
    // PT5M (not PT1M): verified that at 1-minute evaluation the SRE agent acknowledges
    // this alert but does not open an autonomous investigation; at 5-minute evaluation
    // (matching the http-5xx alert) it dispatches and remediates end-to-end. The DB-outage
    // signal is unambiguous, so the slightly later fire is well within demo tolerance.
    evaluationFrequency: 'PT5M'
    windowSize: 'PT5M'
    scopes: [law.id]
    criteria: {
      allOf: [
        {
          // OTel logger.emit() lands in AppTraces (severity 17 = ERROR). The
          // node-postgres driver surfaces both ECONNREFUSED (active refusal) and
          // timeout phrasings; match either as "unreachable".
          query: '''
            AppTraces
            | where TimeGenerated > ago(5m)
            | where AppRoleName == 'zava-api' and SeverityLevel >= 3
            | where Message has_any ("ECONNREFUSED", "ETIMEDOUT", "connection refused", "timeout exceeded when trying to connect", "connection timeout", "connection terminated")
               or tostring(Properties) has_any ("ECONNREFUSED", "ETIMEDOUT", "connection refused", "timeout exceeded when trying to connect", "connection timeout", "connection terminated")
            | summarize ErrorCount = count()
          '''
          timeAggregation: 'Total'
          metricMeasureColumn: 'ErrorCount'
          operator: 'GreaterThan'
          threshold: 3
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    actions: {
      actionGroups: [actionGroup.id]
    }
    autoMitigate: true
    // Symptom-only by design — do NOT add cause/remediation/scenario hints here.
    description: 'Zava Demo: zava-api logged more than 3 PostgreSQL connectivity failures (connection refused or timeout) in the last 5 minutes — the database is unreachable from the application.'
  }
}

// Alert: Products endpoint slow (scheduled-query alert against AppRequests).
//
// Why log-search and not metric: the App Insights pre-aggregated `requests/duration`
// metric does NOT expose request/name as a splittable dimension on workspace-based
// components, so we can't isolate /api/products/category/* at the metric layer. A
// role-wide average gets diluted to ~5-10 ms by the high-frequency /livez and
// /api/health probes (1s self-probe + K8s liveness) and never crosses a meaningful
// threshold even when category endpoints are 20x slower. Trying to filter probes
// out at the OTel SDK layer (instrumentationOptions.http.ignoreIncomingRequestHook)
// silently breaks useAzureMonitor's HTTP instrumentation registration and drops
// AppRequests entirely — confirmed empirically, do not retry that path.
//
// Tradeoff: PT5M window (vs PT1M) is for sample-size stability, not API
// limits — at PT1M the avg over ~60 probe hits + a handful of real requests
// jitters too much to set a clean threshold. Fires ~3-5 min after the break
// instead of ~2 min, which is well within the demo's tolerance.
resource alertProductsSlow 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: 'Zava-products-query-slow'
  location: location
  properties: {
    severity: 2
    enabled: true
    // PT5M (not PT1M): same dispatch reason as postgres-unreachable — at 1-minute
    // evaluation the SRE agent acknowledges this alert but does not open an autonomous
    // investigation; 5-minute evaluation dispatches reliably (matches the http-5xx alert).
    evaluationFrequency: 'PT5M'
    windowSize: 'PT5M'
    scopes: [law.id]
    criteria: {
      allOf: [
        {
          query: '''AppRequests
| where AppRoleName == 'zava-api'
| where Name startswith 'GET /api/products/category/' and Name !contains '__probe'
| summarize AvgDurationMs = avg(DurationMs) by Name
| where AvgDurationMs > 30'''
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          // Fire as soon as ANY category endpoint averages above 30 ms over 5 min.
          // With the index in place, baseline is ~3 ms; index drop pushes the
          // 120k-row category scan to ~80-200 ms, so AvgDurationMs > 30 lights up
          // within one or two evaluation cycles.
          threshold: 0
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    actions: {
      actionGroups: [actionGroup.id]
    }
    autoMitigate: true
    // Symptom-only by design — do NOT name a suspected index or table here.
    description: 'Zava Demo: at least one /api/products/category/<X> endpoint averaged above 30ms over 5 minutes (healthy baseline ~3ms).'
  }
}

// Alert: Unknown-incident demo trigger (DISABLED by default).
//
// Exercises the `zava-unknown` catch-all response plan + the `general-triage`
// skill with no real failure. The title carries the `Zava-` prefix (so it stays
// inside the demo's bounded unknown bucket) but matches NONE of the known routing
// tokens (db / query-slow / http-5xx), so it falls through to general triage.
// To demo: enable it, then write a tag on the resource group to fire it:
//   az monitor activity-log alert update -g <rg> -n Zava-unknown-test --enabled true
//   az tag update --operation merge --tags zava-drill=on --resource-id <rg-id>
// Disable again afterwards.
resource alertUnknownTest 'Microsoft.Insights/activityLogAlerts@2023-01-01-preview' = {
  name: 'Zava-unknown-test'
  location: 'global'
  properties: {
    enabled: false
    scopes: [resourceGroupId]
    condition: {
      allOf: [
        { field: 'category', equals: 'Administrative' }
        { field: 'operationName', equals: 'Microsoft.Resources/tags/write' }
        { field: 'status', equals: 'Succeeded' }
      ]
    }
    actions: {
      actionGroups: [{ actionGroupId: actionGroup.id }]
    }
    description: 'Zava Demo: a tag was written on the resource group.'
  }
}
