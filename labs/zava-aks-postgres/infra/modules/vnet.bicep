@description('Azure region for the network resources.')
param location string

@description('Unique suffix for resource names.')
param uniqueSuffix string

@description('''Lock the agent to PRIVATE-ONLY Azure Monitor (default true). When true, the public
`AzureMonitor` service tag is dropped from the firewall L4 allow-list and the agent reaches Monitor
via the AMPLS private endpoint (10.10.2.0/27, rule allow-agent-to-ampls) + the linked private-DNS
zones. The agent remains fully functional under this lockdown (Monitor queries, native kubectl, and
incident remediation all work). See the main.bicep param doc.''')
param lockAgentToPrivateMonitor bool = true

// ===========================================================================
// Hub-and-spoke network for the SRE Agent demo
// ===========================================================================
// This lab models a realistic enterprise topology instead of one flat VNet, so
// the SRE Agent is shown running VNet-injected in its own spoke and reaching
// everything it needs through a shared HUB firewall — the way customers actually
// run hub-and-spoke (often with ExpressRoute/VPN to on-prem).
//
//   HUB  vnet-Zava-hub-*            10.10.0.0/22   (shared edge / security)
//     ├─ AzureFirewallSubnet        10.10.0.0/26   Azure Firewall — the single egress
//     │                                            point AND the "network device" the
//     │                                            agent interrogates (see below).
//     ├─ GatewaySubnet              10.10.1.0/27   RESERVED for an ExpressRoute/VPN
//     │                                            gateway (hub→on-prem). Not deployed:
//     │                                            a real ExpressRoute circuit must be
//     │                                            provisioned by a connectivity
//     │                                            provider and can't be self-contained
//     │                                            in a demo. Reserving the subnet keeps
//     │                                            the topology honest and makes adding a
//     │                                            gateway a one-resource change.
//     └─ pe-subnet                  10.10.2.0/27   Azure Monitor Private Link Scope
//                                                  (AMPLS) private endpoint lands here.
//
//   SPOKE 1 — platform  vnet-Zava-platform-*  10.20.0.0/16  (the application workload)
//     ├─ aks-subnet                 10.20.0.0/20   AKS nodes/pods (NSG attached;
//     │                                            Scenario 2's red-herring deny rule
//     │                                            lands on this NSG).
//     └─ db-subnet                  10.20.16.0/24  PostgreSQL Flexible Server delegation.
//
//   SPOKE 2 — agent     vnet-Zava-agent-*      10.30.0.0/24  (the SRE Agent)
//     └─ agent-subnet               10.30.0.0/27   Microsoft.App/environments delegation;
//                                                  ALL egress forced to the hub firewall
//                                                  via a UDR (0.0.0.0/0 → firewall private
//                                                  IP) over peering.
//
// WHY THIS IS SAFE / BEHAVIOR-PRESERVING: the agent never needed raw L3 reach to
// AKS or PostgreSQL. The AKS API server is PRIVATE and reached through
// `az aks command invoke` (ARM); PostgreSQL SQL runs from an in-cluster pod via
// the same path; everything else (ARM, Entra, Azure Monitor, Microsoft Learn) is
// allow-listed HTTPS. The agent's sandbox egress is HTTP(S)-proxy-brokered
// (allow-listed HTTPS only — it cannot open raw TCP to private VNet IPs). So
// putting the agent in its own spoke changes only WHICH firewall inspects its
// egress, not how it operates. See sre-config/knowledge-base/zava-architecture.md.
//
// Canonical references this hand-rolled module follows (kept registry-free so the
// demo is self-contained): Azure CAF hub-spoke
// https://learn.microsoft.com/azure/architecture/networking/architecture/hub-spoke
// Container Apps custom VNet + forced tunneling (UDR → firewall)
// https://learn.microsoft.com/azure/container-apps/user-defined-routes
// (equivalent AVM modules: avm/ptn/network/hub-networking, avm/res/network/azure-firewall).

var hubVnetName = 'vnet-Zava-hub-${uniqueSuffix}'
var platformVnetName = 'vnet-Zava-platform-${uniqueSuffix}'
var agentVnetName = 'vnet-Zava-agent-${uniqueSuffix}'
var nsgName = 'nsg-aks-${uniqueSuffix}'

// First usable address in AzureFirewallSubnet (Azure reserves .0-.3 of the
// subnet). Kept in sync with the AzureFirewallSubnet prefix (10.10.0.0/26).
var firewallPrivateIp = '10.10.0.4'

resource nsg 'Microsoft.Network/networkSecurityGroups@2024-01-01' = {
  name: nsgName
  location: location
  properties: {
    securityRules: [
      {
        // Intentionally permissive: this demo needs to reproduce egress patterns
        // (PostgreSQL on 5432, ACR pulls, ARM control plane). A locked-down NSG
        // would mask the failure modes the SRE Agent is supposed to diagnose —
        // Scenario 2 specifically depends on being able to add/remove a deny
        // rule against this open baseline. Do NOT tighten without rewriting the
        // break/fix scenarios.
        name: 'allow-all-outbound'
        properties: {
          priority: 1000
          direction: 'Outbound'
          access: 'Allow'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
    ]
  }
}

// Forced tunneling for the SRE Agent subnet: all egress (0.0.0.0/0) is routed to
// the HUB Azure Firewall over VNet peering. The peering installs a more-specific
// system route for the hub prefix (10.10.0.0/22), so traffic to the firewall's
// private IP reaches it directly; everything else default-routes to the firewall.
// disableBgpRoutePropagation keeps a gateway-learned 0.0.0.0/0 from competing.
resource agentRouteTable 'Microsoft.Network/routeTables@2024-05-01' = {
  name: 'rt-agent-${uniqueSuffix}'
  location: location
  properties: {
    disableBgpRoutePropagation: true
    routes: [
      {
        name: 'default-to-hub-firewall'
        properties: {
          addressPrefix: '0.0.0.0/0'
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: firewallPrivateIp
        }
      }
    ]
  }
}

// --------------------------------------------------------------------------
// Hub VNet — shared edge/security services
// --------------------------------------------------------------------------
resource hubVnet 'Microsoft.Network/virtualNetworks@2024-01-01' = {
  name: hubVnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: ['10.10.0.0/22']
    }
    subnets: [
      {
        // Required exact name; Azure Firewall needs a /26 or larger.
        name: 'AzureFirewallSubnet'
        properties: {
          addressPrefix: '10.10.0.0/26'
        }
      }
      {
        // Required exact name. Reserved for a future ExpressRoute/VPN gateway
        // (hub→on-prem). Left empty on purpose — see header note on ExpressRoute.
        name: 'GatewaySubnet'
        properties: {
          addressPrefix: '10.10.1.0/27'
        }
      }
      {
        // Private endpoint for the Azure Monitor Private Link Scope (AMPLS).
        name: 'pe-subnet'
        properties: {
          addressPrefix: '10.10.2.0/27'
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
    ]
  }
}

// --------------------------------------------------------------------------
// Platform spoke — the application workload (AKS + PostgreSQL)
// --------------------------------------------------------------------------
resource platformVnet 'Microsoft.Network/virtualNetworks@2024-01-01' = {
  name: platformVnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: ['10.20.0.0/16']
    }
    subnets: [
      {
        name: 'aks-subnet'
        properties: {
          addressPrefix: '10.20.0.0/20'
          networkSecurityGroup: { id: nsg.id }
          serviceEndpoints: [
            { service: 'Microsoft.Storage' }
          ]
        }
      }
      {
        name: 'db-subnet'
        properties: {
          addressPrefix: '10.20.16.0/24'
          delegations: [
            {
              name: 'postgres-delegation'
              properties: {
                serviceName: 'Microsoft.DBforPostgreSQL/flexibleServers'
              }
            }
          ]
        }
      }
    ]
  }
}

// --------------------------------------------------------------------------
// Agent spoke — the VNet-injected SRE Agent
// --------------------------------------------------------------------------
resource agentVnet 'Microsoft.Network/virtualNetworks@2024-01-01' = {
  name: agentVnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: ['10.30.0.0/24']
    }
    subnets: [
      {
        // SRE Agent workload subnet — delegated to Microsoft.App/environments so
        // the agent's sandbox is injected here, with all egress forced through
        // the hub Azure Firewall (route table above). Minimum size is /27.
        name: 'agent-subnet'
        properties: {
          addressPrefix: '10.30.0.0/27'
          routeTable: { id: agentRouteTable.id }
          delegations: [
            {
              name: 'agent-delegation'
              properties: {
                serviceName: 'Microsoft.App/environments'
              }
            }
          ]
        }
      }
    ]
  }
}

// --------------------------------------------------------------------------
// VNet peering — hub <-> each spoke (bidirectional; two resources per link).
// allowForwardedTraffic lets the firewall forward traffic that didn't originate
// in the local VNet. No gateway is deployed, so the gateway-transit flags are
// false; flip allowGatewayTransit (hub) / useRemoteGateways (spoke) once a real
// ExpressRoute/VPN gateway lands in GatewaySubnet.
// --------------------------------------------------------------------------
resource peerHubToPlatform 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-05-01' = {
  parent: hubVnet
  name: 'hub-to-platform'
  properties: {
    remoteVirtualNetwork: { id: platformVnet.id }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
    allowGatewayTransit: false
    useRemoteGateways: false
  }
}

resource peerPlatformToHub 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-05-01' = {
  parent: platformVnet
  name: 'platform-to-hub'
  properties: {
    remoteVirtualNetwork: { id: hubVnet.id }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
    allowGatewayTransit: false
    useRemoteGateways: false
  }
}

resource peerHubToAgent 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-05-01' = {
  parent: hubVnet
  name: 'hub-to-agent'
  properties: {
    remoteVirtualNetwork: { id: agentVnet.id }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
    allowGatewayTransit: false
    useRemoteGateways: false
  }
}

resource peerAgentToHub 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-05-01' = {
  parent: agentVnet
  name: 'agent-to-hub'
  properties: {
    remoteVirtualNetwork: { id: hubVnet.id }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
    allowGatewayTransit: false
    useRemoteGateways: false
  }
}

// Public IP for the Azure Firewall frontend (the only public ingress in the hub).
resource firewallPip 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: 'afw-pip-Zava-${uniqueSuffix}'
  location: location
  sku: {
    name: 'Standard'
    tier: 'Regional'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

// Firewall policy: default-deny egress with a precise allow-list. DNS proxy is on
// so the firewall resolves FQDNs for the application rules. Threat intel denies
// known-bad destinations.
resource firewallPolicy 'Microsoft.Network/firewallPolicies@2024-05-01' = {
  name: 'afw-policy-Zava-${uniqueSuffix}'
  location: location
  properties: {
    sku: { tier: 'Standard' }
    dnsSettings: {
      enableProxy: true
    }
    threatIntelMode: 'Deny'
    // SNAT all traffic, including private destinations. This is what lets the
    // agent reach the PRIVATE AKS API server with native kubectl: the API
    // server's NSG only admits the `VirtualNetwork` service tag, and the agent
    // spoke is NOT directly peered to the platform spoke — so without SNAT the
    // agent's 10.30.x.x source would be denied and the return path asymmetric.
    // SNATing to the firewall's hub IP (10.10.x.x — directly peered = part of
    // the platform NSG's VirtualNetwork tag) makes the API server accept it AND
    // reply through the firewall symmetrically (stateful). Remove this together
    // with the `allow-agent-to-aks-api` rule below to revert to a command-invoke-
    // only, maximally-locked-down posture.
    snat: {
      privateRanges: ['255.255.255.255/32']
    }
  }
}

// Allow-list = exactly what the VNet-injected SRE Agent needs to operate:
// DNS, ARM / Entra / Microsoft Graph, Azure Monitor (App Insights + Log
// Analytics queries), and Microsoft Learn (the agent's learn MCP / docs tools).
// `az aks command invoke` and all azcli operations ride ARM, so they work
// through these rules without exposing the cluster API server publicly.
// AzureCloud is deliberately NOT used (it covers ~65k prefixes including
// third-party SaaS); precise service tags are used instead. The source is the
// agent spoke's subnet (10.30.0.0/27).
//
// To let the agent reach a NETWORK DEVICE or other private service DIRECTLY, its
// management endpoint must be HTTPS and its FQDN added BOTH here (an application
// rule) AND to the agent's sandbox egress allow-list — the sandbox proxy only
// speaks allow-listed HTTPS, never raw TCP. Azure-native "devices" (this Azure
// Firewall, NSGs, Route Server) need no new rule: the agent
// reads them over ARM, which is already allowed.
resource ruleCollectionGroup 'Microsoft.Network/firewallPolicies/ruleCollectionGroups@2024-05-01' = {
  parent: firewallPolicy
  name: 'DefaultNetworkRuleCollectionGroup'
  properties: {
    priority: 200
    ruleCollections: [
      {
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        name: 'allow-essential-dns'
        priority: 100
        action: { type: 'Allow' }
        rules: [
          {
            ruleType: 'NetworkRule'
            name: 'allow-azure-dns'
            description: 'DNS resolution via Azure DNS (required for the firewall DNS proxy)'
            ipProtocols: ['UDP', 'TCP']
            sourceAddresses: ['10.30.0.0/27']
            destinationAddresses: ['168.63.129.16']
            destinationPorts: ['53']
          }
        ]
      }
      {
        // Native-kubectl enablement: lets the VNet-injected agent reach the
        // PRIVATE AKS API server (10.20.0.4, in the platform spoke's aks-subnet)
        // on 443. Combined with (a) linking the AKS private-DNS zone to the agent
        // VNet (a post-deploy step — the zone is AKS-managed in the MC_* RG) and
        // (b) the SNAT on the policy above, this is what makes native `kubectl`
        // work from the agent. Omit this collection (and the SNAT) for a
        // command-invoke-only, maximally-locked-down lab.
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        name: 'allow-agent-to-aks-api'
        priority: 210
        action: { type: 'Allow' }
        rules: [
          {
            ruleType: 'NetworkRule'
            name: 'agent-to-apiserver'
            description: 'Agent subnet -> AKS API server (enables native kubectl)'
            ipProtocols: ['TCP']
            sourceAddresses: ['10.30.0.0/27']
            destinationAddresses: ['10.20.0.0/20']
            destinationPorts: ['443']
          }
        ]
      }
      {
        // Private-monitoring path (DEFAULT — lockAgentToPrivateMonitor=true). Lets
        // the agent reach the AMPLS private endpoint (hub pe-subnet 10.10.2.0/27)
        // for App Insights / Log Analytics; the agent remains fully functional over
        // it. NOTE: 10.10.2.0/27 is inside the hub address space
        // (10.10.0.0/22), which the agent<->hub peering routes DIRECTLY —
        // longest-prefix match beats the 0.0.0.0/0 UDR to the firewall — so this
        // traffic actually bypasses the firewall and this allow rule is
        // belt-and-suspenders. Add a /27 UDR -> firewall if you want it inspected.
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        name: 'allow-agent-to-ampls'
        priority: 215
        action: { type: 'Allow' }
        rules: [
          {
            ruleType: 'NetworkRule'
            name: 'agent-to-ampls-pe'
            description: 'Agent subnet -> AMPLS private endpoint (private Azure Monitor)'
            ipProtocols: ['TCP']
            sourceAddresses: ['10.30.0.0/27']
            destinationAddresses: ['10.10.2.0/27']
            destinationPorts: ['443']
          }
        ]
      }
      {
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        name: 'allow-azure-service-tags'
        priority: 105
        action: { type: 'Allow' }
        rules: [
          {
            ruleType: 'NetworkRule'
            name: 'allow-azure-services-l4'
            description: 'L4 access to Azure services via precise service tags (NOT AzureCloud)'
            ipProtocols: ['TCP']
            sourceAddresses: ['10.30.0.0/27']
            // AzureMonitor is dropped by DEFAULT (lockAgentToPrivateMonitor=true)
            // so the agent reaches Monitor only over the AMPLS private endpoint —
            // private-only / maximum restraint; the agent remains fully functional
            // over the private path. Set the param false to re-add the public tag.
            destinationAddresses: lockAgentToPrivateMonitor ? [
              'AzureResourceManager'
              'AzureActiveDirectory'
            ] : [
              'AzureResourceManager'
              'AzureActiveDirectory'
              'AzureMonitor'
            ]
            destinationPorts: ['443']
          }
        ]
      }
      {
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        name: 'allow-agent-azure-services'
        priority: 150
        action: { type: 'Allow' }
        rules: [
          {
            ruleType: 'ApplicationRule'
            name: 'allow-arm-aad-graph'
            description: 'FQDN access to ARM, Entra ID, and Microsoft Graph'
            sourceAddresses: ['10.30.0.0/27']
            protocols: [{ protocolType: 'Https', port: 443 }]
            targetFqdns: [
              'management.azure.com'
              'login.microsoftonline.com'
              'graph.microsoft.com'
            ]
          }
        ]
      }
      {
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        name: 'allow-microsoft-learn'
        priority: 200
        action: { type: 'Allow' }
        rules: [
          {
            ruleType: 'ApplicationRule'
            name: 'allow-learn-microsoft-com'
            description: 'Microsoft Learn docs + MCP runtime endpoint (the agent looks up Azure/AKS/PostgreSQL guidance here)'
            sourceAddresses: ['10.30.0.0/27']
            protocols: [{ protocolType: 'Https', port: 443 }]
            targetFqdns: [
              'learn.microsoft.com'
              '*.learn.microsoft.com'
            ]
          }
          {
            ruleType: 'ApplicationRule'
            name: 'allow-github-raw-mcp-bits'
            // The Streamable-HTTP Microsoft Learn MCP connector fetches its server
            // bits from raw.githubusercontent.com (the microsoftdocs/mcp repo) over
            // the VNet during the tools/list handshake. Without this the connector
            // shows "no active connection" and surfaces zero tools — even though
            // learn.microsoft.com itself is reachable. Scoped to the single host the
            // agent actually hits (verified in AZFWApplicationRule denials) — no
            // *.githubusercontent.com wildcard. This is a Standard firewall, so L7
            // matching is FQDN/SNI only; to pin the exact repo PATH
            // (raw.githubusercontent.com/microsoftdocs/mcp/*) you'd need Azure
            // Firewall Premium + TLS inspection (targetUrls). See README caveats.
            description: 'GitHub raw content — the Microsoft Learn MCP connector fetches its server bits here to complete the tool-discovery handshake'
            sourceAddresses: ['10.30.0.0/27']
            protocols: [{ protocolType: 'Https', port: 443 }]
            targetFqdns: [
              'raw.githubusercontent.com'
            ]
          }
        ]
      }
    ]
  }
}

resource firewall 'Microsoft.Network/azureFirewalls@2024-05-01' = {
  name: 'afw-Zava-${uniqueSuffix}'
  location: location
  properties: {
    sku: {
      name: 'AZFW_VNet'
      tier: 'Standard'
    }
    firewallPolicy: { id: firewallPolicy.id }
    ipConfigurations: [
      {
        name: 'fw-ipconfig'
        properties: {
          subnet: { id: '${hubVnet.id}/subnets/AzureFirewallSubnet' }
          publicIPAddress: { id: firewallPip.id }
        }
      }
    ]
  }
  dependsOn: [
    ruleCollectionGroup
  ]
}

// PostgreSQL private DNS zone — linked to the PLATFORM spoke, where both the AKS
// pods and the delegated db-subnet live and resolve the server's private FQDN.
resource privateDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: '${uniqueSuffix}.private.postgres.database.azure.com'
  location: 'global'
}

resource privateDnsVnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: privateDnsZone
  name: 'platform-link'
  location: 'global'
  properties: {
    virtualNetwork: { id: platformVnet.id }
    registrationEnabled: false
  }
}

// Workload outputs (names preserved for back-compat with main.bicep / scripts).
output vnetName string = platformVnet.name
output nsgName string = nsg.name
output aksSubnetId string = '${platformVnet.id}/subnets/aks-subnet'
output dbSubnetId string = '${platformVnet.id}/subnets/db-subnet'
output agentSubnetId string = '${agentVnet.id}/subnets/agent-subnet'
output privateDnsZoneId string = privateDnsZone.id

// Hub-and-spoke outputs (consumed by the AMPLS + firewall-diagnostics modules).
output hubVnetName string = hubVnet.name
output hubVnetId string = hubVnet.id
output platformVnetId string = platformVnet.id
output agentVnetId string = agentVnet.id
output peSubnetId string = '${hubVnet.id}/subnets/pe-subnet'
output firewallName string = firewall.name
output firewallId string = firewall.id
output firewallPrivateIp string = firewallPrivateIp
