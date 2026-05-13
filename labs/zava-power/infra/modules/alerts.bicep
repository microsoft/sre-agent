// ── Azure Monitor Alert Rules for PowerGrid Services ──

param location string
param workloadName string
param tags object
param logAnalyticsWorkspaceId string
param appInsightsId string

// ── Action Group (email + webhook placeholder) ──
resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: 'ag-${workloadName}-sre'
  location: 'global'
  tags: tags
  properties: {
    groupShortName: 'SREAlert'
    enabled: true
  }
}

// ── Alert: HTTP 5xx errors ──
resource http5xxAlert 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: 'alert-${workloadName}-http-5xx'
  location: location
  tags: tags
  properties: {
    displayName: 'PowerGrid — HTTP 5xx Errors Detected'
    description: 'Fires when any PowerGrid service returns 5xx errors'
    severity: 2
    enabled: true
    evaluationFrequency: 'PT5M'
    windowSize: 'PT5M'
    scopes: [appInsightsId]
    criteria: {
      allOf: [
        {
          query: 'requests | where resultCode startswith "5" | summarize count() by bin(timestamp, 5m)'
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 5
          failingPeriods: { numberOfEvaluationPeriods: 1, minFailingPeriodsToAlert: 1 }
        }
      ]
    }
    actions: {
      actionGroups: [actionGroup.id]
    }
  }
}

// ── Alert: High response time ──
resource latencyAlert 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: 'alert-${workloadName}-high-latency'
  location: location
  tags: tags
  properties: {
    displayName: 'PowerGrid — High Response Time Detected'
    description: 'Fires when avg response time exceeds 3 seconds'
    severity: 3
    enabled: true
    evaluationFrequency: 'PT5M'
    windowSize: 'PT5M'
    scopes: [appInsightsId]
    criteria: {
      allOf: [
        {
          query: 'requests | summarize avg(duration) by bin(timestamp, 5m) | where avg_duration > 3000'
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: { numberOfEvaluationPeriods: 1, minFailingPeriodsToAlert: 1 }
        }
      ]
    }
    actions: {
      actionGroups: [actionGroup.id]
    }
  }
}

// ── Alert: Container restart (disabled until data flows) ──
// Note: ContainerAppSystemLogs table may not have data until containers
// have been running for a while. Enable this alert after initial deployment.
// resource restartAlert 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
//   name: 'alert-${workloadName}-container-restart'
//   ...
// }

output actionGroupId string = actionGroup.id
