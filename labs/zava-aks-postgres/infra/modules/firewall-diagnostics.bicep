@description('Name of the Azure Firewall to attach diagnostic settings to.')
param firewallName string

@description('Resource ID of the Log Analytics workspace that receives the firewall logs.')
param logAnalyticsWorkspaceId string

// ===========================================================================
// Azure Firewall diagnostic settings — the "network device telemetry" path
// ===========================================================================
// The hub Azure Firewall is the demo's stand-in for a "network device": it is a
// real stateful firewall/NVA with a first-class programmatic surface. This wires
// its diagnostic logs into Log Analytics so the SRE Agent can interrogate it the
// INDIRECT way — querying what the device actually observed:
//
//   AZFWNetworkRule      — L4 allow/deny per network rule
//   AZFWApplicationRule  — L7 FQDN allow/deny per application rule
//   AZFWNatRule          — DNAT rule hits
//   AZFWDnsQuery         — DNS proxy queries
//   AZFWThreatIntel      — threat-intel deny hits
//
// logAnalyticsDestinationType: 'Dedicated' makes the firewall write these
// resource-specific (AZFW*) tables instead of the generic AzureDiagnostics blob,
// which is what the agent's KQL in the knowledge base targets.
//
// The DIRECT path needs no infra here: the agent reads the firewall's policy /
// rules / effective routes over ARM with its managed identity (it already holds
// Reader on the resource group), e.g. `az network firewall policy show`.
//
// Docs: https://learn.microsoft.com/azure/firewall/monitor-firewall-reference

resource firewall 'Microsoft.Network/azureFirewalls@2024-05-01' existing = {
  name: firewallName
}

resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'azfw-to-law'
  scope: firewall
  properties: {
    workspaceId: logAnalyticsWorkspaceId
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
