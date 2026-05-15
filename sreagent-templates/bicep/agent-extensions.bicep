// modules/agent-extensions.bicep
//
// Two input layers:
//   (1) Toggle params (enable*) + their conditional inputs synthesize one
//       built-in entry each (e.g. builtInConnectors).
//   (2) Caller-supplied arrays (connectors, hooks, etc.) — advanced authoring.
// The two layers are concat-merged before the resource loop, so a customer
// can flip a toggle, fill in two strings, and skip array authoring entirely.
//
// Note: only sub-resource types currently registered with the regional SRE
// Agent ARM RP are deployed here. Script-only types (repos, repoInstructions,
// knowledge, plugin marketplaces/installations) live in apply-extras.sh.

param agentName string

// ── Caller arrays (advanced) ──
param subagents array = []
param tools array = []
param skills array = []
param scheduledTasks array = []
param incidentFilters array = []
param connectors array = []
param hooks array = []
param commonPrompts array = []
param pluginConfigs array = []

// ── Toggles (forwarded from main.bicep) ──
param enableAppInsightsConnector bool = false
param appInsightsResourceId string = ''
param appInsightsAppId string = ''
param enableLogAnalyticsConnector bool = false
param lawResourceId string = ''
param enableAzureMonitorConnector bool = false
param azureMonitorLookbackDays int = 7
param enableDailyHealthCheckTask bool = false
param enableDenyProdDeletesHook bool = false
param enableSafetyRulesPrompt bool = false

// ─────────── Synthesize built-in entries from toggles ───────────
// Connector shape (2025-05-01-preview, typed):
//   properties: { dataConnectorType, dataSource, extendedProperties, identity }
// identity: 'system' = system-assigned MI, '' = none, '<UAMI resourceId>' = user-assigned.

var builtInConnectors = concat(
  enableAppInsightsConnector ? [
    {
      name: 'app-insights'
      properties: {
        dataConnectorType: 'AppInsights'
        dataSource: appInsightsResourceId
        extendedProperties: {
          armResourceId: appInsightsResourceId
          resource: { name: empty(appInsightsResourceId) ? '' : last(split(appInsightsResourceId, '/')) }
          appId: appInsightsAppId
        }
        identity: 'system'
      }
    }
  ] : [],
  enableLogAnalyticsConnector ? [
    {
      name: 'log-analytics'
      properties: {
        dataConnectorType: 'LogAnalytics'
        dataSource: lawResourceId
        extendedProperties: {
          armResourceId: lawResourceId
          resource: { name: empty(lawResourceId) ? '' : last(split(lawResourceId, '/')) }
        }
        identity: 'system'
      }
    }
  ] : [],
  enableAzureMonitorConnector ? [
    {
      name: 'azure-monitor'
      properties: {
        dataConnectorType: 'AzureMonitor'
        dataSource: subscription().id
        extendedProperties: {
          armResourceId: subscription().id
          lookbackDays: azureMonitorLookbackDays
        }
        identity: 'system'
      }
    }
  ] : []
)

var builtInScheduledTasks = enableDailyHealthCheckTask ? [
  {
    metadata: { name: 'daily-health-check' }
    spec: {
      description: 'Daily 8am health summary (toggle-generated).'
      schedule: '0 8 * * *'
      prompt: 'Summarize the last 24h of incidents and SLO burn for all services this agent watches.'
      enabled: true
      mode: 'Review'
    }
  }
] : []

var builtInHooks = enableDenyProdDeletesHook ? [
  {
    metadata: { name: 'deny-prod-deletes' }
    spec: {
      eventType: 'PreToolUse'
      hookType: 'Prompt'
      matcher: { toolPattern: '^(delete_|remove_).*' }
      permissionDecision: 'deny'
      hookBody: {
        prompt: 'If the tool targets a production resource (name contains "prod" or "prd"), deny. Otherwise allow.'
      }
      enabled: true
    }
  }
] : []

var builtInCommonPrompts = enableSafetyRulesPrompt ? [
  {
    metadata: { name: 'safety-rules' }
    spec: {
      prompt: '## Safety rules\n\n- Never restart services without paging the on-call.\n- Always confirm subscription before destructive ops.\n- For any High accessLevel action, require human review even if actionMode=Automatic.'
    }
  }
] : []

// ─────────── Merge built-in + caller-supplied ───────────

var allConnectors      = concat(builtInConnectors,     connectors)
var allScheduledTasks  = concat(builtInScheduledTasks, scheduledTasks)
var allHooks           = concat(builtInHooks,          hooks)
var allCommonPrompts   = concat(builtInCommonPrompts,  commonPrompts)

// ─────────── Resource loops ───────────

resource parent 'Microsoft.App/agents@2025-05-01-preview' existing = {
  name: agentName
}

// ─────────── NOT deployed via Bicep ───────────────────────────
// All child resources except connectors are now deployed via data-plane
// (apply-extras.sh) to avoid ARM tenant restrictions that block 3P tenants.
// This includes: skills, subagents, tools, commonPrompts, scheduledTasks,
// incidentFilters, hooks, pluginConfigs.

// Connectors (working typed shape — see comment above builtInConnectors).
#disable-next-line BCP081
@batchSize(1)
resource connectorRes 'Microsoft.App/agents/connectors@2025-05-01-preview' = [for c in allConnectors: {
  parent: parent
  name: c.name
  properties: c.properties
}]

output pendingHooks         array = allHooks
output pendingPluginConfigs array = pluginConfigs
