// ============================================================
// Monitoring module — Log Analytics + Diagnostic Settings
// Exports Activity Logs to LAW for compliance queries
// ============================================================

@description('Location for all resources')
param location string

@description('Environment name for naming')
param environmentName string

@description('Tags for all resources')
param tags object

@description('Container App resource ID for alert scoping')
param containerAppId string

@description('Container App name')
param containerAppName string

// ---- Log Analytics Workspace (for Activity Log queries via Kusto MCP) ----
resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: 'law-compliance-${environmentName}'
  location: location
  tags: tags
  properties: {
    retentionInDays: 90
    sku: {
      name: 'PerGB2018'
    }
    features: {
      enableLogAccessUsingOnlyResourcePermissions: false
    }
  }
}

// ---- Diagnostic Settings: Send Activity Logs to LAW ----
// NOTE: This is a subscription-level diagnostic setting.
// It must be deployed at subscription scope. For this module (resource group scope),
// we document the az CLI command in the post-deploy script instead.
// The az CLI command is:
//   az monitor diagnostic-settings subscription create \
//     --name "activity-to-law" \
//     --workspace $(logAnalyticsWorkspace.id) \
//     --logs '[{"categoryGroup":"allLogs","enabled":true}]'

// ---- Azure Monitor Alert: Container App deployment detected ----
resource deploymentAlert 'Microsoft.Insights/activityLogAlerts@2020-10-01' = {
  name: 'alert-containerapp-deployment-${environmentName}'
  location: 'global'
  tags: tags
  properties: {
    enabled: true
    description: 'Fires when a Container App write operation (deployment) is detected'
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
          equals: 'Microsoft.App/containerApps/write'
        }
        {
          field: 'status'
          equals: 'Succeeded'
        }
      ]
    }
    actions: {
      actionGroups: [
        {
          actionGroupId: actionGroup.id
        }
      ]
    }
  }
}

// ---- Action Group (placeholder — can be connected to SRE Agent webhook) ----
resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: 'ag-compliance-${environmentName}'
  location: 'global'
  tags: tags
  properties: {
    groupShortName: 'compliance'
    enabled: true
    // Add SRE Agent webhook or email here
    emailReceivers: []
    webhookReceivers: []
  }
}

// ============================================================
// Outputs
// ============================================================
output logAnalyticsWorkspaceId string = logAnalyticsWorkspace.id
output logAnalyticsWorkspaceCustomerId string = logAnalyticsWorkspace.properties.customerId
output logAnalyticsWorkspaceKey string = logAnalyticsWorkspace.listKeys().primarySharedKey
output alertRuleId string = deploymentAlert.id
output actionGroupId string = actionGroup.id
