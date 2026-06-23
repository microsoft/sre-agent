// Symptom-only alert rules + PagerDuty action group.
// IMPORTANT: alert names/descriptions describe the OBSERVED SYMPTOM only and must
// never reveal the root cause (NSG / LB / AppGW / app) — that is the SRE Agent's job.
@description('Azure region for the alert rules (must be a real region, not global).')
param location string
@description('Resource name suffix token.')
param resourceToken string
@description('Tags applied to all resources.')
param tags object = {}
@description('Log Analytics workspace resource id (alert scope).')
param logAnalyticsWorkspaceId string
@description('PagerDuty "Microsoft Azure" integration URL. Leave empty to skip the PD receiver.')
@secure()
param pagerDutyWebhookUrl string = ''

var hasPagerDuty = !empty(pagerDutyWebhookUrl)

resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: 'ag-zava-pagerduty-${resourceToken}'
  location: 'global'
  tags: tags
  properties: {
    groupShortName: 'zavaPD'
    enabled: true
    webhookReceivers: hasPagerDuty ? [
      {
        name: 'pagerduty'
        serviceUri: pagerDutyWebhookUrl
        useCommonAlertSchema: true
      }
    ] : []
  }
}

resource quizLaunchFailing 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: 'Zava-quiz-launch-failing'
  location: location
  tags: tags
  properties: {
    description: 'Students are unable to launch quizzes from the portal.'
    severity: 1
    enabled: true
    evaluationFrequency: 'PT5M'
    windowSize: 'PT5M'
    scopes: [ logAnalyticsWorkspaceId ]
    criteria: {
      allOf: [
        {
          query: 'ContainerAppConsoleLogs_CL\n| where ContainerAppName_s == "learner-portal"\n| where Log_s has "quiz_launch_failed"\n| summarize AggregatedValue = count() by bin(TimeGenerated, 5m)'
          metricMeasureColumn: 'AggregatedValue'
          timeAggregation: 'Total'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: { numberOfEvaluationPeriods: 1, minFailingPeriodsToAlert: 1 }
        }
      ]
    }
    skipQueryValidation: true
    autoMitigate: false
    actions: { actionGroups: [ actionGroup.id ] }
  }
}

resource portal5xxElevated 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: 'Zava-portal-5xx-elevated'
  location: location
  tags: tags
  properties: {
    description: 'Elevated rate of failed responses from the student portal.'
    severity: 2
    enabled: true
    evaluationFrequency: 'PT5M'
    windowSize: 'PT5M'
    scopes: [ logAnalyticsWorkspaceId ]
    criteria: {
      allOf: [
        {
          query: 'ContainerAppConsoleLogs_CL\n| where ContainerAppName_s == "learner-portal"\n| where Log_s has_any ("unavailable", "502", "503")\n| summarize AggregatedValue = count() by bin(TimeGenerated, 5m)'
          metricMeasureColumn: 'AggregatedValue'
          timeAggregation: 'Total'
          operator: 'GreaterThan'
          threshold: 5
          failingPeriods: { numberOfEvaluationPeriods: 1, minFailingPeriodsToAlert: 1 }
        }
      ]
    }
    skipQueryValidation: true
    autoMitigate: false
    actions: { actionGroups: [ actionGroup.id ] }
  }
}

resource quizApiLatencyElevated 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: 'Zava-quiz-api-latency-elevated'
  location: location
  tags: tags
  properties: {
    description: 'Quiz responses are slower than usual for students.'
    severity: 2
    enabled: true
    evaluationFrequency: 'PT5M'
    windowSize: 'PT15M'
    scopes: [ logAnalyticsWorkspaceId ]
    criteria: {
      allOf: [
        {
          query: 'ContainerAppConsoleLogs_CL\n| where ContainerAppName_s == "assessment-api"\n| where Log_s has "ms="\n| extend ms = toint(extract(@"ms=(\\d+)", 1, Log_s))\n| where isnotnull(ms)\n| summarize AggregatedValue = percentile(ms, 95) by bin(TimeGenerated, 5m)'
          metricMeasureColumn: 'AggregatedValue'
          timeAggregation: 'Average'
          operator: 'GreaterThan'
          threshold: 500
          failingPeriods: { numberOfEvaluationPeriods: 1, minFailingPeriodsToAlert: 1 }
        }
      ]
    }
    skipQueryValidation: true
    autoMitigate: false
    actions: { actionGroups: [ actionGroup.id ] }
  }
}

resource gradeExportsFailing 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: 'Zava-grade-exports-failing'
  location: location
  tags: tags
  properties: {
    description: 'Zava reporting: nightly grade exports are failing to produce export files.'
    severity: 2
    enabled: true
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    scopes: [ logAnalyticsWorkspaceId ]
    criteria: {
      allOf: [
        {
          query: 'Syslog\n| where ProcessName == "zava-export"\n| where SyslogMessage has "FAILED"\n| summarize AggregatedValue = count() by bin(TimeGenerated, 5m)'
          metricMeasureColumn: 'AggregatedValue'
          timeAggregation: 'Total'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: { numberOfEvaluationPeriods: 1, minFailingPeriodsToAlert: 1 }
        }
      ]
    }
    skipQueryValidation: true
    autoMitigate: false
    // Intentionally NOT wired to the PagerDuty action group. The disk scenario's break-disk.ps1
    // pages PagerDuty with a clean, symptom-only incident (the same pattern as every other lane),
    // so this rule stays as Azure Monitor portal evidence only — otherwise PagerDuty would also
    // receive the raw common-alert-schema payload and show a second, unreadable incident.
    actions: {}
  }
}

output actionGroupId string = actionGroup.id
output actionGroupName string = actionGroup.name
output pagerDutyConfigured bool = hasPagerDuty