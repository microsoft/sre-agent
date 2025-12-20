@description('Name of the App Service')
param appServiceName string

@description('Location for all resources')
param location string = resourceGroup().location

@description('App Service Plan SKU')
@allowed([
  'F1'
  'B1'
  'B2'
  'S1'
  'S2'
  'P1v2'
])
param appServicePlanSku string = 'S1'

@description('Log Analytics Workspace name')
param workspaceName string = '${appServiceName}-workspace'

// App Service Plan
resource appServicePlan 'Microsoft.Web/serverfarms@2023-01-01' = {
  name: '${appServiceName}-plan'
  location: location
  sku: {
    name: appServicePlanSku
  }
  properties: {
    reserved: false
  }
}

// Log Analytics Workspace
resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: workspaceName
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

// Application Insights
resource applicationInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: '${appServiceName}-ai'
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalyticsWorkspace.id
  }
}

// App Service
resource appService 'Microsoft.Web/sites@2023-01-01' = {
  name: appServiceName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: appServicePlan.id
    httpsOnly: true
    siteConfig: {
      netFrameworkVersion: 'v9.0'
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      alwaysOn: true
      appSettings: [
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: applicationInsights.properties.ConnectionString
        }
        {
          name: 'ApplicationInsightsAgent_EXTENSION_VERSION'
          value: '~3'
        }
        {
          name: 'PerformanceSettings__EnableSlowEndpoints'
          value: 'false'
        }
        {
          name: 'PerformanceSettings__ResponseTimeThresholdMs'
          value: '1000'
        }
      ]
      healthCheckPath: '/health'
    }
  }
}

// Staging Slot
resource stagingSlot 'Microsoft.Web/sites/slots@2023-01-01' = {
  parent: appService
  name: 'staging'
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: appServicePlan.id
    siteConfig: {
      netFrameworkVersion: 'v9.0'
      alwaysOn: true
      appSettings: [
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: applicationInsights.properties.ConnectionString
        }
        {
          name: 'ApplicationInsightsAgent_EXTENSION_VERSION'
          value: '~3'
        }
        {
          name: 'PerformanceSettings__EnableSlowEndpoints'
          value: 'false'
        }
        {
          name: 'PerformanceSettings__ResponseTimeThresholdMs'
          value: '1000'
        }
      ]
      healthCheckPath: '/health'
    }
  }
}

// Action Group for Alerts
resource alertActionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: '${appServiceName}-action-group'
  location: 'global'
  properties: {
    groupShortName: 'SREDemoAG'
    enabled: true
    emailReceivers: []
    smsReceivers: []
    webhookReceivers: []
  }
}

// Slot Swap Activity Log Alert - triggers when a deployment slot swap occurs
resource slotSwapAlert 'Microsoft.Insights/activityLogAlerts@2020-10-01' = {
  name: '${appServiceName}-slot-swap-alert'
  location: 'global'
  properties: {
    description: 'Alert when a deployment slot swap occurs. Use this to trigger post-deployment health checks.'
    enabled: true
    scopes: [
      resourceGroup().id
    ]
    condition: {
      allOf: [
        {
          field: 'category'
          equals: 'Administrative'
        }
        {
          field: 'operationName'
          equals: 'Microsoft.Web/sites/slots/slotsswap/action'
        }
        {
          field: 'status'
          equals: 'Succeeded'
        }
        {
          field: 'resourceId'
          containsAny: [
            appService.id
          ]
        }
      ]
    }
    actions: {
      actionGroups: [
        {
          actionGroupId: alertActionGroup.id
        }
      ]
    }
  }
}

// Output values
output appServiceName string = appService.name
output appServiceUrl string = 'https://${appService.properties.defaultHostName}'
output stagingUrl string = 'https://${appServiceName}-staging.azurewebsites.net'
output applicationInsightsName string = applicationInsights.name
output applicationInsightsConnectionString string = applicationInsights.properties.ConnectionString
output applicationInsightsInstrumentationKey string = applicationInsights.properties.InstrumentationKey
output resourceGroupName string = resourceGroup().name
