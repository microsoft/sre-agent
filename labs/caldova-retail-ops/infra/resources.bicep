@description('Region for the web app and monitoring resources.')
param location string

@description('Region for the Azure SRE Agent.')
param agentLocation string

@description('App Service plan SKU.')
param appServicePlanSku string

param tags object

var suffix = uniqueString(resourceGroup().id)
var webAppName = 'caldova-webapp-${suffix}'
var planName = 'caldova-plan-${suffix}'
var workspaceName = 'caldova-logs-${suffix}'
var insightsName = 'caldova-insights-${suffix}'
var availabilityName = 'caldova-availability-${suffix}'
var failedRequestAlertName = 'caldova-failed-requests-${suffix}'
var availabilityAlertName = 'caldova-availability-alert-${suffix}'

// The lab's product-search fault: a forward-dated catalog setting activates a
// search-index wave that has not been built yet. Product browsing still works.
var faultSettingName = 'Catalog__AsOfDate'
var faultSettingValue = '2099-12-15'

// Lightweight probes that keep steady background traffic flowing into
// Application Insights for the investigation and the live report.
var availabilityTests = [
  { suffix: '', path: '/api/ping' }
  { suffix: '-version', path: '/api/version' }
  { suffix: '-health', path: '/api/health' }
  { suffix: '-status', path: '/api/status' }
  { suffix: '-checkout', path: '/api/checkout' }
  { suffix: '-reports', path: '/api/reports?day=1' }
  { suffix: '-recommendations', path: '/api/recommendations?customerId=RETURNING-0001' }
  { suffix: '-store-locator', path: '/api/store-locator' }
  { suffix: '-inventory-summary', path: '/api/inventory-summary' }
  { suffix: '-about', path: '/about.html' }
  { suffix: '-contact', path: '/contact.html' }
  { suffix: '-index', path: '/index.html' }
]

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: workspaceName
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

resource insights 'Microsoft.Insights/components@2020-02-02' = {
  name: insightsName
  location: location
  kind: 'web'
  tags: tags
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: workspace.id
    IngestionMode: 'LogAnalytics'
    SamplingPercentage: 100
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

// Replace the platform-created anomaly rule so only the explicit alerts below fire.
resource failureAnomalies 'Microsoft.AlertsManagement/smartDetectorAlertRules@2021-04-01' = {
  name: 'Failure Anomalies - ${insightsName}'
  location: 'global'
  tags: tags
  properties: {
    description: 'Disabled; this lab uses explicit request-failure and availability alerts.'
    state: 'Disabled'
    severity: 'Sev3'
    frequency: 'PT1M'
    detector: {
      id: 'FailureAnomaliesDetector'
    }
    scope: [
      insights.id
    ]
    actionGroups: {
      groupIds: []
    }
  }
}

resource plan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: planName
  location: location
  kind: 'app'
  tags: tags
  sku: {
    name: appServicePlanSku
    capacity: 1
  }
  properties: {
    reserved: false
  }
}

resource webApp 'Microsoft.Web/sites@2024-04-01' = {
  name: webAppName
  location: location
  kind: 'app'
  tags: union(tags, { 'azd-service-name': 'web' })
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    clientAffinityEnabled: false
    siteConfig: {
      netFrameworkVersion: 'v8.0'
      metadata: [
        {
          name: 'CURRENT_STACK'
          value: 'dotnet'
        }
      ]
      use32BitWorkerProcess: false
      alwaysOn: true
      minTlsVersion: '1.2'
      scmMinTlsVersion: '1.2'
      ftpsState: 'Disabled'
      httpLoggingEnabled: true
      detailedErrorLoggingEnabled: true
      requestTracingEnabled: true
      appSettings: [
        {
          name: faultSettingName
          value: faultSettingValue
        }
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: insights.properties.ConnectionString
        }
        {
          name: 'ApplicationInsightsAgent_EXTENSION_VERSION'
          value: '~2'
        }
        {
          name: 'XDT_MicrosoftApplicationInsights_Mode'
          value: 'recommended'
        }
        {
          name: 'MicrosoftAppInsights_AdaptiveSamplingTelemetryProcessor_MinSamplingPercentage'
          value: '100'
        }
      ]
    }
  }
}

resource ftpPublishing 'Microsoft.Web/sites/basicPublishingCredentialsPolicies@2024-04-01' = {
  parent: webApp
  name: 'ftp'
  properties: {
    allow: false
  }
}

resource scmPublishing 'Microsoft.Web/sites/basicPublishingCredentialsPolicies@2024-04-01' = {
  parent: webApp
  name: 'scm'
  properties: {
    allow: false
  }
}

resource webAppLogs 'Microsoft.Web/sites/config@2024-04-01' = {
  parent: webApp
  name: 'logs'
  properties: {
    httpLogs: {
      fileSystem: {
        enabled: true
        retentionInDays: 3
        retentionInMb: 35
      }
    }
    applicationLogs: {
      fileSystem: {
        level: 'Information'
      }
    }
    detailedErrorMessages: {
      enabled: true
    }
    failedRequestsTracing: {
      enabled: true
    }
  }
}

resource webAppDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'workspace'
  scope: webApp
  properties: {
    workspaceId: workspace.id
    logAnalyticsDestinationType: 'Dedicated'
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

resource webTests 'Microsoft.Insights/webtests@2022-06-15' = [for test in availabilityTests: {
  name: '${availabilityName}${test.suffix}'
  location: location
  kind: 'standard'
  tags: union(tags, { 'hidden-link:${insights.id}': 'Resource' })
  properties: {
    SyntheticMonitorId: '${availabilityName}${test.suffix}'
    Name: '${availabilityName}${test.suffix}'
    Description: 'Probe ${test.path} without fetching dependent assets.'
    Enabled: true
    Frequency: 300
    Timeout: 30
    Kind: 'standard'
    RetryEnabled: false
    Locations: [
      { Id: 'us-ca-sjc-azr' }
      { Id: 'us-tx-sn1-azr' }
      { Id: 'us-va-ash-azr' }
    ]
    Request: {
      RequestUrl: 'https://${webApp.properties.defaultHostName}${test.path}'
      HttpVerb: 'GET'
      FollowRedirects: true
      ParseDependentRequests: false
    }
    ValidationRules: {
      ExpectedHttpStatusCode: 200
      IgnoreHttpStatusCode: false
      SSLCheck: true
      SSLCertRemainingLifetimeCheck: 7
    }
  }
}]

resource failedRequestAlert 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: failedRequestAlertName
  location: 'global'
  tags: tags
  properties: {
    description: 'More than 3 failed server requests over the last 15 minutes.'
    severity: 2
    enabled: true
    scopes: [
      insights.id
    ]
    evaluationFrequency: 'PT1M'
    windowSize: 'PT15M'
    autoMitigate: true
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'FailedRequests'
          criterionType: 'StaticThresholdCriterion'
          metricNamespace: 'microsoft.insights/components'
          metricName: 'requests/failed'
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 3
        }
      ]
    }
    actions: []
  }
}

resource availabilityAlerts 'Microsoft.Insights/metricAlerts@2018-03-01' = [for (test, i) in availabilityTests: {
  name: '${availabilityAlertName}${test.suffix}'
  location: 'global'
  tags: tags
  properties: {
    description: 'The availability test for ${test.path} fails in at least two of three locations.'
    severity: 2
    enabled: true
    scopes: [
      webTests[i].id
      insights.id
    ]
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    autoMitigate: true
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.WebtestLocationAvailabilityCriteria'
      webTestId: webTests[i].id
      componentId: insights.id
      failedLocationCount: 2
    }
    actions: []
  }
}]

module sreAgent 'modules/sre-agent.bicep' = {
  name: 'caldova-sre-agent'
  params: {
    agentName: 'caldova-sreagent-${suffix}'
    identityName: 'caldova-sre-mi-${suffix}'
    location: agentLocation
    tags: tags
    workspaceId: workspace.id
    workspaceName: workspace.name
    workspaceCustomerId: workspace.properties.customerId
    applicationInsightsId: insights.id
    applicationInsightsName: insights.name
    applicationInsightsAppId: insights.properties.AppId
  }
}

output webAppName string = webApp.name
output webAppUrl string = 'https://${webApp.properties.defaultHostName}'
output applicationInsightsName string = insights.name
output logAnalyticsWorkspaceName string = workspace.name
output sreAgentName string = sreAgent.outputs.agentName
output sreAgentResourceId string = sreAgent.outputs.agentId
output sreAgentPrincipalId string = sreAgent.outputs.principalId
output sreAgentPortalUrl string = sreAgent.outputs.portalUrl
