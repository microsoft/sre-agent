// ── Observability: Log Analytics + App Insights + Managed Grafana ──

param location string
param workloadName string
param tags object

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: 'law-${workloadName}'
  location: location
  tags: tags
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: 'ai-${workloadName}'
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalytics.id
  }
}

resource grafana 'Microsoft.Dashboard/grafana@2023-09-01' = {
  name: 'grafana-${workloadName}'
  location: location
  tags: tags
  sku: { name: 'Standard' }
  identity: { type: 'SystemAssigned' }
  properties: {
    zoneRedundancy: 'Disabled'
    publicNetworkAccess: 'Enabled'
    grafanaIntegrations: {
      azureMonitorWorkspaceIntegrations: []
    }
  }
}

// Grafana needs Monitoring Reader on the resource group
resource grafanaMonitoringReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(grafana.id, 'Monitoring Reader')
  properties: {
    principalId: grafana.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '43d0d8ad-25c7-4714-9337-8ba259a9fe05')
  }
}

output logAnalyticsWorkspaceId string = logAnalytics.id
output logAnalyticsWorkspaceName string = logAnalytics.name
output appInsightsId string = appInsights.id
output appInsightsAppId string = appInsights.properties.AppId
output appInsightsConnectionString string = appInsights.properties.ConnectionString
output grafanaEndpoint string = grafana.properties.endpoint
