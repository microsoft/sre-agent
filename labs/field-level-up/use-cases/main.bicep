targetScope = 'resourceGroup'

@minLength(1)
@description('Name of the existing SRE Agent in this resource group, already configured for Azure Monitor incidents.')
param sreAgentName string

@description('Resource ID of the existing checkout App Service.')
param checkoutAppId string

@description('Resource ID of the existing PostgreSQL Flexible Server.')
param postgresServerId string

@description('Resource ID of the existing checkout Application Insights component.')
param applicationInsightsId string

@description('Application ID of the existing checkout Application Insights component.')
param applicationInsightsAppId string

@minLength(1)
@description('Existing authenticated GitHub repository URL for automatic incident follow-ups; no credentials.')
param githubRepositoryUrl string

@minLength(1)
@description('Recipients for automatic incident email follow-ups.')
param emailRecipients string[]

@minLength(1)
@description('Name of the existing authenticated email connector attached only to the commander.')
param emailConnectorName string

@description('Azure Monitor alert location; use the location of the Application Insights component.')
param location string = resourceGroup().location

@minLength(1)
@maxLength(80)
@description('Stable prefix for the checkout alert title; use a distinct prefix for this environment.')
param namePrefix string

@description('Explicit opt-in after setup verifies telemetry, Azure Monitor scanning, access, skills, Task delegation and authenticated follow-up connections.')
param enableIncidents bool = false

@allowed([
  1
  2
])
@description('Azure Monitor severity; the single response plan accepts both Sev1 and Sev2.')
param alertSeverity int = 2

var checkoutAlertTitle = '${namePrefix}-checkout-failures'

module configuration '../modules/sre-agent-configuration.bicep' = {
  params: {
    sreAgentName: sreAgentName
    checkoutAppId: checkoutAppId
    postgresServerId: postgresServerId
    applicationInsightsId: applicationInsightsId
    applicationInsightsAppId: applicationInsightsAppId
    githubRepositoryUrl: githubRepositoryUrl
    emailRecipients: emailRecipients
    emailConnectorName: emailConnectorName
    incidentAlertTitle: checkoutAlertTitle
    enableIncidents: enableIncidents
  }
}

// The existing agent polls Azure Monitor alerts; no action group or webhook is created here.
resource checkoutAlert 'Microsoft.Insights/scheduledQueryRules@2023-12-01' = {
  name: checkoutAlertTitle
  location: location
  kind: 'LogAlert'
  properties: {
    displayName: checkoutAlertTitle
    description: 'Failed POST /checkout requests in the last five minutes; investigate before attributing a root cause.'
    enabled: enableIncidents
    severity: alertSeverity
    evaluationFrequency: 'PT5M'
    windowSize: 'PT5M'
    scopes: [
      applicationInsightsId
    ]
    targetResourceTypes: [
      'Microsoft.Insights/components'
    ]
    criteria: {
      allOf: [
        {
          query: '''
requests
| where timestamp >= ago(5m)
| where name == "POST /checkout" and success == false
'''
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    autoMitigate: true
  }
  dependsOn: [
    configuration
  ]
}

output configuredSubagents array = configuration.outputs.configuredSubagents
output configuredSkills array = configuration.outputs.configuredSkills
output incidentFilterName string = configuration.outputs.incidentFilterName
output scheduledTaskName string = configuration.outputs.scheduledTaskName
output checkoutAlertName string = checkoutAlert.name
output checkoutAlertId string = checkoutAlert.id
output incidentsEnabled bool = enableIncidents