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

// Alert: HTTP 5xx errors
resource alert5xx 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: 'Zava-http-5xx-errors'
  location: 'global'
  properties: {
    severity: 2
    enabled: true
    scopes: [appInsights.id]
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'http5xx'
          metricName: 'requests/failed'
          metricNamespace: 'microsoft.insights/components'
          operator: 'GreaterThan'
          threshold: 5
          timeAggregation: 'Count'
          criterionType: 'StaticThresholdCriterion'
        }
      ]
    }
    actions: [
      { actionGroupId: actionGroup.id }
    ]
    autoMitigate: true
    description: 'Zava Demo: HTTP 5xx error rate exceeded threshold'
  }
}

// Alert: Response time degradation
resource alertSlowResponse 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: 'Zava-slow-response-time'
  location: 'global'
  properties: {
    severity: 3
    enabled: true
    scopes: [appInsights.id]
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'slowResponse'
          metricName: 'requests/duration'
          metricNamespace: 'microsoft.insights/components'
          operator: 'GreaterThan'
          threshold: 5000
          timeAggregation: 'Average'
          criterionType: 'StaticThresholdCriterion'
        }
      ]
    }
    actions: [
      { actionGroupId: actionGroup.id }
    ]
    autoMitigate: true
    description: 'Zava Demo: Average response time exceeded 5 seconds'
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

// --- Infrastructure-level alerts (fire without app traffic) ---

// Alert: NSG rule changes (someone added/deleted a deny rule)
resource alertNsgChange 'Microsoft.Insights/activityLogAlerts@2023-01-01-preview' = {
  name: 'Zava-nsg-change'
  location: 'global'
  properties: {
    enabled: true
    scopes: [resourceGroupId]
    condition: {
      allOf: [
        {
          field: 'category'
          equals: 'Administrative'
        }
        {
          field: 'operationName'
          equals: 'Microsoft.Network/networkSecurityGroups/securityRules/write'
        }
      ]
    }
    actions: {
      actionGroups: [{ actionGroupId: actionGroup.id }]
    }
    description: 'Zava Demo: NSG security rule was created or modified'
  }
}

// Alert: NSG rule deleted
resource alertNsgDelete 'Microsoft.Insights/activityLogAlerts@2023-01-01-preview' = {
  name: 'Zava-nsg-rule-deleted'
  location: 'global'
  properties: {
    enabled: true
    scopes: [resourceGroupId]
    condition: {
      allOf: [
        {
          field: 'category'
          equals: 'Administrative'
        }
        {
          field: 'operationName'
          equals: 'Microsoft.Network/networkSecurityGroups/securityRules/delete'
        }
      ]
    }
    actions: {
      actionGroups: [{ actionGroupId: actionGroup.id }]
    }
    description: 'Zava Demo: NSG security rule was deleted'
  }
}

// Alert: PostgreSQL server down (ECONNREFUSED) — Scenario 1.
//
// Split from a previous combined ECONNREFUSED+ETIMEDOUT rule so each failure mode
// has its own incident lifecycle. With a single rule, Scenario 1 (server stopped)
// would fire + auto-mitigate, then Scenario 2 (network blocked) would re-attach
// to the closed incident instead of opening a new one — and the SRE Agent would
// never get dispatched for Scenario 2. Both rules route to `zava-db-response`
// via titleContains:'postgres' (see infra/modules/sre-agent.bicep).
resource alertDbServerDown 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: 'postgres-server-down'
  location: location
  properties: {
    severity: 1
    enabled: true
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    scopes: [law.id]
    criteria: {
      allOf: [
        {
          // OTel logger.emit() lands in AppTraces (severity 17 = ERROR).
          // It does NOT land in AppExceptions (which requires recordException
          // on a span). The Zava API logs DB failures via logger (logging/logger.js),
          // so we query AppTraces here. The node-postgres driver reports
          // "ECONNREFUSED" verbatim in its error message when the server is stopped.
          query: '''
            AppTraces
            | where TimeGenerated > ago(5m)
            | where AppRoleName == 'zava-api' and SeverityLevel >= 3
            | where Message has_any ("ECONNREFUSED", "connection refused")
               or tostring(Properties) has_any ("ECONNREFUSED", "connection refused")
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
    // The alert payload is part of the incident context the SRE Agent reads, and
    // recipes in this string undo the de-spoon-fed runbook. See AGENTS.md.
    description: 'Zava Demo: zava-api logged more than 3 ECONNREFUSED-class PostgreSQL connection failures in the last 5 minutes.'
  }
}

// Alert: PostgreSQL network blocked (ETIMEDOUT) — Scenario 2.
// See note on alertDbServerDown above for why these are split into two rules.
resource alertDbNetworkBlocked 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: 'postgres-network-blocked'
  location: location
  properties: {
    severity: 1
    enabled: true
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    scopes: [law.id]
    criteria: {
      allOf: [
        {
          // Same as alertDbServerDown — query AppTraces (OTel logs), not AppExceptions.
          // node-postgres reports network timeouts as "timeout exceeded when trying
          // to connect" (NOT the raw ETIMEDOUT errno), so we have to match that
          // exact phrase in addition to the generic strings.
          //
          // Mutual exclusion with `postgres-server-down`: a stopped PG produces
          // ECONNREFUSED first, then ETIMEDOUTs as connection attempts pile up.
          // To prevent this rule from firing on a PG-stop (and pre-poisoning the
          // S2 incident slot), require ETIMEDOUT-class errors AND zero *recent*
          // (< 2 min) ECONNREFUSED-class errors. The 2-minute lookback (rather
          // than the full 5-minute window) is deliberate: a stale ECONNREFUSED
          // from a brief PG blip 4 minutes ago must NOT mask a fresh network
          // partition that started 30 seconds ago. See AGENTS.md.
          query: '''
            AppTraces
            | where TimeGenerated > ago(5m)
            | where AppRoleName == 'zava-api' and SeverityLevel >= 3
            | extend Combined = strcat(Message, ' ', tostring(Properties))
            | extend IsTimeout = Combined has_any ("ETIMEDOUT", "timeout exceeded when trying to connect", "connection timeout", "connection terminated")
            | extend IsRecentRefused = (Combined has_any ("ECONNREFUSED", "connection refused")) and TimeGenerated > ago(2m)
            | summarize TimeoutCount = countif(IsTimeout), RecentRefusedCount = countif(IsRecentRefused)
            | extend ErrorCount = iff(RecentRefusedCount == 0, TimeoutCount, 0)
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
    description: 'Zava Demo: zava-api logged more than 3 PostgreSQL connection-timeout traces (ETIMEDOUT / "timeout exceeded when trying to connect" / "connection terminated") in the last 5 minutes.'
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
    evaluationFrequency: 'PT1M'
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

// Alert: PostgreSQL server stopped (Activity Log — detects az postgres flexible-server stop)
// Named without "Zava-" prefix so the "postgres" response plan filter matches exclusively
resource alertPgStopped 'Microsoft.Insights/activityLogAlerts@2023-01-01-preview' = {
  name: 'postgres-server-stopped'
  location: 'global'
  properties: {
    enabled: true
    scopes: [resourceGroupId]
    condition: {
      allOf: [
        {
          field: 'category'
          equals: 'Administrative'
        }
        {
          field: 'operationName'
          equals: 'Microsoft.DBforPostgreSQL/flexibleServers/stop/action'
        }
        {
          field: 'status'
          equals: 'Succeeded'
        }
      ]
    }
    actions: {
      actionGroups: [{ actionGroupId: actionGroup.id }]
    }
    description: 'Zava Demo: PostgreSQL server was stopped'
  }
}
