// ──────────────────────────────────────────────────────────────
// Zava — Zava Café SRE Agent Lab — Resource Group resources
// Adapted from the source ZavaCafe-SREAgent-fresh main.bicep
// + adds: managed identity, SRE Agent, monitoring module wiring.
// ──────────────────────────────────────────────────────────────

targetScope = 'resourceGroup'

// ── Parameters ──────────────────────────────────────────────

@description('Name of the environment (from azd)')
param environmentName string

@description('Azure region for all resources')
param location string

@description('Naming prefix for all resources')
param prefix string = 'zava'

@description('Alert notification email address (optional)')
param alertEmail string = ''

@description('Entra ID user/group login (UPN) to set as SQL Server admin')
param aadAdminLogin string

@description('Entra ID user/group object ID to set as SQL Server admin')
param aadAdminObjectId string

// ── Variables ───────────────────────────────────────────────

var resourceToken = take(uniqueString(resourceGroup().id, environmentName, prefix), 8)
var sqlServerName = 'sql-${prefix}-${resourceToken}'
var sqlDatabaseName = 'sqldb-${prefix}'
var lawName = 'law-${prefix}-${resourceToken}'
var appInsightsName = 'ai-${prefix}-${resourceToken}'
var aspName = 'asp-${prefix}-${resourceToken}'
var appName = 'app-${prefix}-${resourceToken}'
var dashboardName = 'dash-${prefix}-${resourceToken}'
var identityName = 'id-sre-${prefix}-${resourceToken}'
var agentName = 'sre-agent-zava-cafe-${resourceToken}'

// ── 1. SQL Server ───────────────────────────────────────────

resource sqlServer 'Microsoft.Sql/servers@2023-08-01-preview' = {
  name: sqlServerName
  location: location
  properties: {
    version: '12.0'
    publicNetworkAccess: 'Enabled'
    administrators: {
      administratorType: 'ActiveDirectory'
      principalType: 'User'
      login: aadAdminLogin
      sid: aadAdminObjectId
      tenantId: tenant().tenantId
      azureADOnlyAuthentication: true
    }
  }
}

resource sqlDatabase 'Microsoft.Sql/servers/databases@2023-08-01-preview' = {
  parent: sqlServer
  name: sqlDatabaseName
  location: location
  sku: {
    name: 'Basic'
    tier: 'Basic'
    capacity: 5
  }
  properties: {
    collation: 'SQL_Latin1_General_CP1_CI_AS'
    maxSizeBytes: 2147483648
  }
}

resource sqlFirewallAzure 'Microsoft.Sql/servers/firewallRules@2023-08-01-preview' = {
  parent: sqlServer
  name: 'AllowAzureServices'
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress: '0.0.0.0'
  }
}

// ── 2. Monitoring (LAW + App Insights) — via module ─────────

module monitoring 'modules/monitoring.bicep' = {
  name: 'monitoring'
  params: {
    location: location
    logAnalyticsName: lawName
    appInsightsName: appInsightsName
  }
}

// ── 3. Managed Identity for SRE Agent ───────────────────────

module identity 'modules/identity.bicep' = {
  name: 'identity'
  params: {
    location: location
    identityName: identityName
  }
}

// ── 4. App Service Plan (Linux) ──────────────────────────

@description('App Service Plan SKU name (e.g. P0v3, P1v3, S1, B1). Default S1 to avoid Premium V3 quota dependency.')
param appServicePlanSku string = 'S1'

@description('App Service Plan SKU tier (e.g. Premium0V3, PremiumV3, Standard, Basic).')
param appServicePlanTier string = 'Standard'

resource appServicePlan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: aspName
  location: location
  kind: 'linux'
  sku: {
    name: appServicePlanSku
    tier: appServicePlanTier
    capacity: 1
  }
  properties: {
    reserved: true
  }
}

// ── 5. Web App — Main App (.NET 8) ──────────────────────────

resource webApp 'Microsoft.Web/sites@2023-12-01' = {
  name: appName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: appServicePlan.id
    httpsOnly: true
    siteConfig: {
      linuxFxVersion: 'DOTNETCORE|8.0'
      alwaysOn: true
      healthCheckPath: '/health'
      appSettings: [
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: monitoring.outputs.appInsightsConnectionString
        }
        {
          name: 'ApplicationInsightsAgent_EXTENSION_VERSION'
          value: '~3'
        }
        {
          name: 'AZURE_SQL_SERVER'
          value: sqlServer.properties.fullyQualifiedDomainName
        }
        {
          name: 'AZURE_SQL_DATABASE'
          value: sqlDatabaseName
        }
      ]
      connectionStrings: [
        {
          name: 'DefaultConnection'
          connectionString: 'Server=tcp:${sqlServer.properties.fullyQualifiedDomainName},1433;Database=${sqlDatabaseName};Authentication=Active Directory Default;Encrypt=True;TrustServerCertificate=False;'
          type: 'SQLAzure'
        }
      ]
    }
  }
}

// ── 8. Action Group + Alerts ────────────────────────────────

resource actionGroup 'Microsoft.Insights/actionGroups@2023-09-01-preview' = if (!empty(alertEmail)) {
  name: 'ag-${prefix}-sre'
  location: 'global'
  properties: {
    groupShortName: '${prefix}SRE'
    enabled: true
    emailReceivers: [
      {
        name: 'SRE Team'
        emailAddress: alertEmail
        useCommonAlertSchema: true
      }
    ]
  }
}

resource alertDtu 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: 'alert-${prefix}-dtu-high'
  location: 'global'
  properties: {
    description: 'SQL Database DTU usage exceeds 80%'
    severity: 2
    enabled: true
    scopes: [ sqlDatabase.id ]
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'HighDTU'
          metricName: 'dtu_consumption_percent'
          metricNamespace: 'Microsoft.Sql/servers/databases'
          operator: 'GreaterThan'
          threshold: 80
          timeAggregation: 'Average'
          criterionType: 'StaticThresholdCriterion'
        }
      ]
    }
    actions: !empty(alertEmail) ? [ { actionGroupId: actionGroup.id } ] : []
  }
}

resource alertHttp5xx 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: 'alert-${prefix}-http-5xx'
  location: 'global'
  properties: {
    description: 'App Service returning HTTP 5xx errors'
    severity: 1
    enabled: true
    scopes: [ webApp.id ]
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'Http5xx'
          metricName: 'Http5xx'
          metricNamespace: 'Microsoft.Web/sites'
          operator: 'GreaterThan'
          threshold: 5
          timeAggregation: 'Total'
          criterionType: 'StaticThresholdCriterion'
        }
      ]
    }
    actions: !empty(alertEmail) ? [ { actionGroupId: actionGroup.id } ] : []
  }
}

resource alertHealthCheck 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: 'alert-${prefix}-health-check'
  location: 'global'
  properties: {
    description: 'App Service health check failing'
    severity: 1
    enabled: true
    scopes: [ webApp.id ]
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'HealthCheckFailure'
          metricName: 'HealthCheckStatus'
          metricNamespace: 'Microsoft.Web/sites'
          operator: 'LessThan'
          threshold: 100
          timeAggregation: 'Average'
          criterionType: 'StaticThresholdCriterion'
        }
      ]
    }
    actions: !empty(alertEmail) ? [ { actionGroupId: actionGroup.id } ] : []
  }
}

// ── 9. Azure Portal Dashboard ───────────────────────────────

resource dashboard 'Microsoft.Portal/dashboards@2020-09-01-preview' = {
  name: dashboardName
  location: location
  tags: {
    'hidden-title': 'Zava Operations Dashboard'
  }
  properties: {
    lenses: [
      {
        order: 0
        parts: [
          {
            position: { x: 0, y: 0, colSpan: 16, rowSpan: 2 }
            metadata: {
              type: 'Extension/HubsExtension/PartType/MarkdownPart'
              inputs: []
              settings: {
                content: {
                  content: '## Zava Operations Dashboard\n**Real-time monitoring** for SQL Database, App Service, and Application Insights.\n\n_Resource Group:_ `${resourceGroup().name}` | _Region:_ `${location}`'
                  title: 'Zava Operations Dashboard'
                  subtitle: 'Enterprise Monitoring'
                  markdownSource: 1
                }
              }
            }
          }
          {
            position: { x: 0, y: 2, colSpan: 8, rowSpan: 4 }
            metadata: {
              type: 'Extension/HubsExtension/PartType/MonitorChartPart'
              inputs: [
                {
                  name: 'options'
                  value: {
                    chart: {
                      metrics: [
                        {
                          resourceMetadata: { id: sqlDatabase.id }
                          name: 'dtu_consumption_percent'
                          aggregationType: 4
                          namespace: 'Microsoft.Sql/servers/databases'
                          metricVisualization: { displayName: 'DTU percentage' }
                        }
                      ]
                      title: 'SQL Database — DTU Usage'
                      visualization: { chartType: 2 }
                    }
                  }
                }
              ]
              settings: {}
            }
          }
          {
            position: { x: 8, y: 2, colSpan: 8, rowSpan: 4 }
            metadata: {
              type: 'Extension/HubsExtension/PartType/MonitorChartPart'
              inputs: [
                {
                  name: 'options'
                  value: {
                    chart: {
                      metrics: [
                        {
                          resourceMetadata: { id: webApp.id }
                          name: 'HttpResponseTime'
                          aggregationType: 4
                          namespace: 'Microsoft.Web/sites'
                          metricVisualization: { displayName: 'Response Time' }
                        }
                      ]
                      title: 'App Service — Response Time'
                      visualization: { chartType: 2 }
                    }
                  }
                }
              ]
              settings: {}
            }
          }
          {
            position: { x: 0, y: 6, colSpan: 8, rowSpan: 4 }
            metadata: {
              type: 'Extension/HubsExtension/PartType/MonitorChartPart'
              inputs: [
                {
                  name: 'options'
                  value: {
                    chart: {
                      metrics: [
                        {
                          resourceMetadata: { id: webApp.id }
                          name: 'Http5xx'
                          aggregationType: 1
                          namespace: 'Microsoft.Web/sites'
                          metricVisualization: { displayName: 'HTTP 5xx Errors' }
                        }
                      ]
                      title: 'App Service — HTTP 5xx Errors'
                      visualization: { chartType: 2 }
                    }
                  }
                }
              ]
              settings: {}
            }
          }
          {
            position: { x: 8, y: 6, colSpan: 8, rowSpan: 4 }
            metadata: {
              type: 'Extension/HubsExtension/PartType/MonitorChartPart'
              inputs: [
                {
                  name: 'options'
                  value: {
                    chart: {
                      metrics: [
                        {
                          resourceMetadata: { id: webApp.id }
                          name: 'HealthCheckStatus'
                          aggregationType: 4
                          namespace: 'Microsoft.Web/sites'
                          metricVisualization: { displayName: 'Health Check Status' }
                        }
                      ]
                      title: 'App Service — Health Check'
                      visualization: { chartType: 2 }
                    }
                  }
                }
              ]
              settings: {}
            }
          }
        ]
      }
    ]
  }
}

// ── 10. SRE Agent ───────────────────────────────────────────

module sreAgent 'modules/sre-agent.bicep' = {
  name: 'sre-agent'
  params: {
    location: location
    agentName: agentName
    identityId: identity.outputs.identityId
    identityPrincipalId: identity.outputs.identityPrincipalId
    appInsightsAppId: monitoring.outputs.appInsightsAppId
    appInsightsConnectionString: monitoring.outputs.appInsightsConnectionString
    appInsightsId: monitoring.outputs.appInsightsId
    managedResourceGroupId: resourceGroup().id
  }
}

// ── Outputs ─────────────────────────────────────────────────

output sqlServerFqdn string = sqlServer.properties.fullyQualifiedDomainName
output sqlDatabaseName string = sqlDatabaseName
output appUrl string = 'https://${webApp.properties.defaultHostName}'
output appName string = webApp.name
output webAppName string = webApp.name
output webAppPrincipalId string = webApp.identity.principalId
output appInsightsConnectionString string = monitoring.outputs.appInsightsConnectionString
output identityPrincipalId string = identity.outputs.identityPrincipalId
output agentName string = sreAgent.outputs.agentName
output agentEndpoint string = sreAgent.outputs.agentEndpoint
output agentPortalUrl string = sreAgent.outputs.agentPortalUrl
