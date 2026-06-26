@description('Azure region (the AMPLS itself is global; this is used for the private endpoint).')
param location string

@description('Unique suffix for resource names.')
param uniqueSuffix string

@description('Resource ID of the Log Analytics workspace to bring into the private link scope.')
param logAnalyticsWorkspaceResourceId string

@description('Resource ID of the Application Insights component to bring into the private link scope.')
param appInsightsResourceId string

@description('Resource ID of the subnet (in the hub) where the AMPLS private endpoint NIC lands.')
param peSubnetId string

@description('Resource ID of the hub VNet (its private DNS links are always created).')
param hubVnetId string

@description('Resource ID of the platform (workload) spoke VNet.')
param platformVnetId string

@description('Resource ID of the agent spoke VNet.')
param agentVnetId string

@description('''Also link the Azure Monitor private DNS zones to the PLATFORM (workload) spoke.
Default false on purpose: linking the workload spoke forces its app-telemetry FQDNs to resolve to
the private endpoint, which only works if every endpoint in the App Insights connection string is
served by the AMPLS zones. The regional App Insights INGESTION host (e.g.
<region>-N.in.applicationinsights.azure.com) is a documented gap — it can resolve into the private
zone without a matching record, return NXDOMAIN, and silently stop the app shipping telemetry. This
lab doesn\'t validate the workload\'s private path. The agent is locked to the private path
independently via lockAgentToPrivateMonitor. Set this true only after validating the workload\'s
ingestion endpoints against the private zones.''')
param linkWorkloadVnetsToPrivateMonitor bool = false

@description('''Link the Azure Monitor private DNS zones to the AGENT spoke (default true) so the
SRE Agent resolves Log Analytics / App Insights to the AMPLS private endpoint. Pairs with the
firewall dropping the public `AzureMonitor` tag (vnet.bicep lockAgentToPrivateMonitor).
The agent remains fully functional under this lockdown — its Monitor queries and end-to-end
incident handling work over the private path. Set false to keep the public Monitor path.''')
param lockAgentToPrivateMonitor bool = true

@description('AMPLS ingestion access mode. Open = the VNet can also reach Monitor resources outside this scope; PrivateOnly = only in-scope resources (can break other Monitor access region-wide).')
@allowed([
  'Open'
  'PrivateOnly'
])
param ingestionAccessMode string = 'Open'

@description('AMPLS query access mode. See ingestionAccessMode for the Open vs PrivateOnly trade-off.')
@allowed([
  'Open'
  'PrivateOnly'
])
param queryAccessMode string = 'Open'

// ===========================================================================
// Azure Monitor Private Link Scope (AMPLS)
// ===========================================================================
// This is the "private network ingress/egress" path for Azure Monitor. AMPLS
// connects a VNet privately (over Azure Private Link) to a defined set of Azure
// Monitor resources — here the Log Analytics workspace and the Application
// Insights component — so ingestion and queries can stay on private IPs / the
// Azure backbone instead of public Monitor endpoints.
//
//   AMPLS (boundary) ── scopedResources ──► Log Analytics workspace + App Insights
//        │
//        └── one private endpoint (groupId 'azuremonitor') in the hub pe-subnet
//             └── private DNS zones map the Monitor FQDNs to the PE's private IP
//
// One private endpoint to the AMPLS covers every scoped resource (you do NOT
// create a PE per workspace/component). The AGENT is locked to this private path
// by default (lockAgentToPrivateMonitor): its DNS zones are linked and the
// firewall drops the public AzureMonitor tag. AMPLS access modes stay 'Open' so
// the resource itself still serves operators/queries from outside the scope;
// flip to 'PrivateOnly' for resource-level lockdown too (riskier — can block
// operator public queries region-wide).
//
// Docs: https://learn.microsoft.com/azure/azure-monitor/fundamentals/private-link-security
//       https://learn.microsoft.com/azure/azure-monitor/fundamentals/private-link-configure
// (Equivalent AVM module: avm/res/insights/private-link-scope.)

var amplsName = 'ampls-Zava-${uniqueSuffix}'
var privateEndpointName = 'pe-azmonitor-${uniqueSuffix}'

// The five private DNS zones Azure Monitor / AMPLS requires. The blob zone is
// needed for the agent solution-pack / ingestion storage path on scopes created
// after Apr 2021.
var privateDnsZoneNames = [
  'privatelink.monitor.azure.com'
  'privatelink.oms.opinsights.azure.com'
  'privatelink.ods.opinsights.azure.com'
  'privatelink.agentsvc.azure-automation.net'
  'privatelink.blob.${environment().suffixes.storage}'
]

resource ampls 'Microsoft.Insights/privateLinkScopes@2023-06-01-preview' = {
  name: amplsName
  location: 'global'
  properties: {
    accessModeSettings: {
      ingestionAccessMode: ingestionAccessMode
      queryAccessMode: queryAccessMode
    }
  }
}

// scopedResources are pinned to 2021-07-01-preview (matching the AVM module):
// the 2023-06-01-preview API requires a `kind` discriminator ('Resource' /
// 'platformMetrics') and ARM rejects the link without it. 2021-07-01-preview
// links a plain resource by ID — which is all we need. The AMPLS parent above
// stays on 2023-06-01-preview for its `accessModeSettings` property.
resource lawScoped 'Microsoft.Insights/privateLinkScopes/scopedResources@2021-07-01-preview' = {
  parent: ampls
  name: 'law-${uniqueString(logAnalyticsWorkspaceResourceId)}'
  properties: {
    linkedResourceId: logAnalyticsWorkspaceResourceId
  }
}

resource appiScoped 'Microsoft.Insights/privateLinkScopes/scopedResources@2021-07-01-preview' = {
  parent: ampls
  name: 'appi-${uniqueString(appInsightsResourceId)}'
  properties: {
    linkedResourceId: appInsightsResourceId
  }
  // Serialize the two scopedResource writes — concurrent writes to the same
  // private link scope can race ("Conflict").
  dependsOn: [lawScoped]
}

resource privateEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: privateEndpointName
  location: location
  properties: {
    subnet: { id: peSubnetId }
    privateLinkServiceConnections: [
      {
        name: '${privateEndpointName}-conn'
        properties: {
          privateLinkServiceId: ampls.id
          groupIds: ['azuremonitor']
        }
      }
    ]
  }
  // Serialize the PE AFTER the AMPLS scoped-resource writes. The PE connects to
  // the AMPLS private link service; creating it while the scopedResources are
  // still being committed has been observed to fail with a transient
  // `InternalServerError` (which aborts the whole monolithic provision). Waiting
  // for the scope to settle makes the one-shot `azd up` more reliable.
  dependsOn: [lawScoped, appiScoped]
}

resource privateDnsZones 'Microsoft.Network/privateDnsZones@2024-06-01' = [
  for zoneName in privateDnsZoneNames: {
    name: zoneName
    location: 'global'
  }
]

// The hub always links the Monitor zones (harmless — nothing critical in the hub
// resolves Monitor). The pe-subnet lives here, so this is also where resolution
// to the PE is most natural.
resource hubLinks 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = [
  for (zoneName, i) in privateDnsZoneNames: {
    parent: privateDnsZones[i]
    name: 'hub-link'
    location: 'global'
    properties: {
      registrationEnabled: false
      virtualNetwork: { id: hubVnetId }
    }
  }
]

// Opt-in: link the workload (platform) spoke so its Azure Monitor traffic
// resolves to the private endpoint. Off by default — see the param note (linking
// it risks NXDOMAIN on the app's regional ingestion host; not validated here).
resource platformLinks 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = [
  for (zoneName, i) in privateDnsZoneNames: if (linkWorkloadVnetsToPrivateMonitor) {
    parent: privateDnsZones[i]
    name: 'platform-link'
    location: 'global'
    properties: {
      registrationEnabled: false
      virtualNetwork: { id: platformVnetId }
    }
  }
]

// The agent spoke is linked by default (lockAgentToPrivateMonitor) so the SRE
// Agent resolves + queries Monitor over the private endpoint only. Also linked
// when the workload-wide toggle is on.
resource agentLinks 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = [
  for (zoneName, i) in privateDnsZoneNames: if (lockAgentToPrivateMonitor || linkWorkloadVnetsToPrivateMonitor) {
    parent: privateDnsZones[i]
    name: 'agent-link'
    location: 'global'
    properties: {
      registrationEnabled: false
      virtualNetwork: { id: agentVnetId }
    }
  }
]

resource privateDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: privateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      for (zoneName, i) in privateDnsZoneNames: {
        name: replace(zoneName, '.', '-')
        properties: {
          privateDnsZoneId: privateDnsZones[i].id
        }
      }
    ]
  }
}

output amplsName string = ampls.name
output amplsId string = ampls.id
output privateEndpointName string = privateEndpoint.name
