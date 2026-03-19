// ============================================================
// Monitoring Module — Log Analytics + Alert Rules + Diagnostics
// ============================================================

param location string
param environmentName string
param tags object
param vmAppId string
param vmDbId string
param vmAppName string
param vmDbName string

// Log Analytics Workspace
resource law 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: 'law-${environmentName}'
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

// VM metrics are collected via Azure Monitor Agent (installed on VM)
// CPU and memory metrics available via platform metrics without custom DCR

// CPU Alert — App VM
resource cpuAlertApp 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: 'alert-cpu-high-${vmAppName}'
  location: 'global'
  tags: tags
  properties: {
    description: 'CPU usage exceeds 85% for 5 minutes on ${vmAppName}'
    severity: 2
    enabled: true
    scopes: [vmAppId]
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'HighCPU'
          metricName: 'Percentage CPU'
          operator: 'GreaterThan'
          threshold: 85
          timeAggregation: 'Average'
          criterionType: 'StaticThresholdCriterion'
        }
      ]
    }
  }
}

// Memory Alert — App VM
resource memAlertApp 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: 'alert-mem-high-${vmAppName}'
  location: 'global'
  tags: tags
  properties: {
    description: 'Memory usage exceeds 90% for 5 minutes on ${vmAppName}'
    severity: 2
    enabled: true
    scopes: [vmAppId]
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'HighMemory'
          metricName: 'Available Memory Bytes'
          operator: 'LessThan'
          threshold: 209715200  // 200 MB
          timeAggregation: 'Average'
          criterionType: 'StaticThresholdCriterion'
        }
      ]
    }
  }
}

output logAnalyticsWorkspaceId string = law.id
output logAnalyticsWorkspaceCustomerId string = law.properties.customerId
