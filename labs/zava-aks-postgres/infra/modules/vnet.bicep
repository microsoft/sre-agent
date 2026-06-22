@description('Azure region for the VNet and NSG.')
param location string

@description('Unique suffix for resource names.')
param uniqueSuffix string

var vnetName = 'vnet-Zava-${uniqueSuffix}'
var nsgName = 'nsg-aks-${uniqueSuffix}'

// First usable address in AzureFirewallSubnet (Azure reserves .0-.3 of the subnet).
// Kept in sync with the AzureFirewallSubnet prefix below.
var firewallPrivateIp = '10.3.1.4'

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

// Public IP for the Azure Firewall frontend (the only public ingress in the VNet).
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

// Forced tunneling for the SRE Agent subnet only: all egress (0.0.0.0/0) is
// routed to the Azure Firewall. Intra-VNet traffic (10.0.0.0/8) keeps the more
// specific system route, so the agent still reaches AKS / PG privately. The AKS
// and DB subnets are deliberately NOT routed through the firewall — AKS manages
// its own egress and the demo's break/fix scenarios run against the open NSG.
resource agentRouteTable 'Microsoft.Network/routeTables@2024-05-01' = {
  name: 'rt-agent-${uniqueSuffix}'
  location: location
  properties: {
    disableBgpRoutePropagation: true
    routes: [
      {
        name: 'default-to-azure-firewall'
        properties: {
          addressPrefix: '0.0.0.0/0'
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: firewallPrivateIp
        }
      }
    ]
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2024-01-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: ['10.0.0.0/8']
    }
    subnets: [
      {
        name: 'aks-subnet'
        properties: {
          addressPrefix: '10.0.0.0/16'
          networkSecurityGroup: { id: nsg.id }
          serviceEndpoints: [
            { service: 'Microsoft.Storage' }
          ]
        }
      }
      {
        name: 'db-subnet'
        properties: {
          addressPrefix: '10.1.0.0/24'
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
      {
        // SRE Agent workload subnet — delegated to Microsoft.App/environments so
        // the agent's sandbox is injected here, with all egress forced through
        // the Azure Firewall (route table above). Minimum size is /27.
        name: 'agent-subnet'
        properties: {
          addressPrefix: '10.3.0.0/27'
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
      {
        // Required name for the Azure Firewall. Minimum size is /26.
        name: 'AzureFirewallSubnet'
        properties: {
          addressPrefix: '10.3.1.0/26'
        }
      }
    ]
  }
}

resource privateDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: '${uniqueSuffix}.private.postgres.database.azure.com'
  location: 'global'
}

resource privateDnsVnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: privateDnsZone
  name: 'vnet-link'
  location: 'global'
  properties: {
    virtualNetwork: { id: vnet.id }
    registrationEnabled: false
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
  }
}

// Allow-list = exactly what the VNet-injected SRE Agent needs to operate:
// DNS, ARM / Entra / Microsoft Graph, Azure Monitor (App Insights + Log
// Analytics queries), and Microsoft Learn (the agent's learn MCP / docs tools).
// `az aks command invoke` and all azcli operations ride ARM, so they work
// through these rules without exposing the cluster API server publicly.
// AzureCloud is deliberately NOT used (it covers ~65k prefixes including
// third-party SaaS); precise service tags are used instead.
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
            sourceAddresses: ['10.3.0.0/27']
            destinationAddresses: ['168.63.129.16']
            destinationPorts: ['53']
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
            sourceAddresses: ['10.3.0.0/27']
            destinationAddresses: [
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
            sourceAddresses: ['10.3.0.0/27']
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
            description: 'Microsoft Learn docs + MCP (the agent looks up Azure/AKS/PostgreSQL guidance here)'
            sourceAddresses: ['10.3.0.0/27']
            protocols: [{ protocolType: 'Https', port: 443 }]
            targetFqdns: [
              'learn.microsoft.com'
              '*.learn.microsoft.com'
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
          subnet: { id: vnet.properties.subnets[3].id }
          publicIPAddress: { id: firewallPip.id }
        }
      }
    ]
  }
  dependsOn: [
    ruleCollectionGroup
  ]
}

output vnetName string = vnet.name
output vnetId string = vnet.id
output aksSubnetId string = vnet.properties.subnets[0].id
output dbSubnetId string = vnet.properties.subnets[1].id
output agentSubnetId string = vnet.properties.subnets[2].id
output nsgName string = nsg.name
output privateDnsZoneId string = privateDnsZone.id
