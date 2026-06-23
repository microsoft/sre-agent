// VNet with an Application Gateway subnet and a VNet-integrated Container Apps
// infrastructure subnet. The ACA subnet carries an NSG that ships CLEAN; the
// connectivity fault is injected at demo time by chaos/break-nsg.ps1.
@description('Azure region for all resources.')
param location string
@description('Resource name suffix token.')
param resourceToken string
@description('Tags applied to all resources.')
param tags object = {}

@description('VNet address space.')
param vnetAddressPrefix string = '10.20.0.0/16'
@description('Application Gateway subnet prefix.')
param appGwSubnetPrefix string = '10.20.1.0/24'
@description('Container Apps infrastructure subnet prefix (min /23).')
param acaSubnetPrefix string = '10.20.2.0/23'
@description('NSG-lane Container Apps subnet prefix (min /23). Hosts the isolated 2nd ACA env so the nsg scenario can break ONLY its own lane.')
param nsgLaneSubnetPrefix string = '10.20.4.0/23'
@description('Reporting-worker VM subnet prefix. Hosts the nightly grade-export worker VM (disk scenario).')
param vmSubnetPrefix string = '10.20.6.0/24'

@description('''Demo fault toggle. When true, ships a high-priority (100) "legacy
segmentation" DENY rule on the Container Apps NSG that beats the ALLOW at 200 and
blocks the App Gateway subnet from reaching the apps. Healthy default is false;
chaos/break-nsg.ps1 sets this true (a "bad release") so the SRE Agent must spot the
priority inversion, mitigate live, and open an IaC PR to set it back to false.''')
param injectLegacyDeny bool = false

@description('''Parallel "lanes" variant of injectLegacyDeny. Ships the same DENY on the
ISOLATED nsg-lane NSG only, so the nsg scenario can run in parallel without taking down
the other lanes. Healthy default is false.''')
param injectLegacyDenyNsgLane bool = false

@description('''Seed STANDING network-governance "loopholes" for the weekly NSG audit to find:
overly-permissive management/any-any rules + a broad data-port rule on the (no-public-path)
reporting-VM NSG, plus an ORPHANED, unattached NSG carrying shadowed/duplicate/legacy rules.
These are deliberately benign (no public route reaches them) but are exactly the misconfigurations
a real reviewer flags. Default false; chaos/seed-audit-findings.ps1 sets this true and applies the
same rules live, and chaos/reset-audit-findings.ps1 sets it back to false.''')
param seedAuditFindings bool = false

@description('Extra App Gateway frontend ports exposed to the Internet for the parallel lanes (one per lane).')
param laneFrontendPorts array = [ 8081, 8082, 8083, 8084, 8085, 8086, 8087 ]

// NSG for the Application Gateway subnet — required inbound for AppGW v2.
resource appGwNsg 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: 'nsg-appgw-${resourceToken}'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'Allow-GatewayManager'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'GatewayManager'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '65200-65535'
        }
      }
      {
        name: 'Allow-AzureLoadBalancer'
        properties: {
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: '*'
          sourceAddressPrefix: 'AzureLoadBalancer'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
      {
        name: 'Allow-Web-Inbound'
        properties: {
          priority: 120
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRanges: union([ '80', '443' ], map(laneFrontendPorts, p => string(p)))
        }
      }
    ]
  }
}

// NSG for the Container Apps subnet. Ships clean: default rules permit intra-VNet
// traffic (AppGW -> ACA). The demo fault (injectLegacyDeny) ships a higher-priority
// DENY via IaC at deploy time.
var allowAppGwToApps = {
  name: 'Allow-AppGw-To-Apps'
  properties: {
    priority: 200
    direction: 'Inbound'
    access: 'Allow'
    protocol: 'Tcp'
    sourceAddressPrefix: appGwSubnetPrefix
    sourcePortRange: '*'
    destinationAddressPrefix: '*'
    destinationPortRanges: [ '80', '443' ]
  }
}
var legacyCrossSubnetDeny = {
  name: 'legacy-cross-subnet-deny'
  properties: {
    priority: 100
    direction: 'Inbound'
    access: 'Deny'
    protocol: '*'
    sourceAddressPrefix: appGwSubnetPrefix
    sourcePortRange: '*'
    destinationAddressPrefix: '*'
    destinationPortRange: '*'
    description: 'Legacy network segmentation rule.'
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Standing NSG audit "loopholes" (seedAuditFindings). Benign in this lab — the
// reporting-VM subnet has no public route and the orphaned NSG is attached to
// nothing — but they are exactly the over-permissive / shadowed / stale / orphaned
// rules a real weekly NSG audit must flag. Kept out of all 7 web lanes on purpose.
var auditSshFromInternet = {
  name: 'temp-ssh-from-internet'
  properties: {
    priority: 200
    direction: 'Inbound'
    access: 'Allow'
    protocol: 'Tcp'
    sourceAddressPrefix: 'Internet'
    sourcePortRange: '*'
    destinationAddressPrefix: '*'
    destinationPortRange: '22'
    description: 'TEMP break-glass INC-4471 2025-08-14 - REMOVE after troubleshooting'
  }
}
var auditRdpFromAny = {
  name: 'allow-rdp-any'
  properties: {
    priority: 210
    direction: 'Inbound'
    access: 'Allow'
    protocol: 'Tcp'
    sourceAddressPrefix: '*'
    sourcePortRange: '*'
    destinationAddressPrefix: '*'
    destinationPortRange: '3389'
    description: 'Remote desktop access.'
  }
}
var auditAnyAnyLegacy = {
  name: 'allow-any-any-legacy'
  properties: {
    priority: 4000
    direction: 'Inbound'
    access: 'Allow'
    protocol: '*'
    sourceAddressPrefix: '*'
    sourcePortRange: '*'
    destinationAddressPrefix: '*'
    destinationPortRange: '*'
    description: 'Legacy catch-all - migrated from on-prem firewall.'
  }
}
var auditPostgresBroad = {
  name: 'allow-postgres-broad'
  properties: {
    priority: 220
    direction: 'Inbound'
    access: 'Allow'
    protocol: 'Tcp'
    sourceAddressPrefix: '10.0.0.0/8'
    sourcePortRange: '*'
    destinationAddressPrefix: '*'
    destinationPortRange: '5432'
    description: 'Database access for reporting.'
  }
}
var vmAuditRules = [ auditSshFromInternet, auditRdpFromAny, auditPostgresBroad, auditAnyAnyLegacy ]

resource acaNsg 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: 'nsg-aca-${resourceToken}'
  location: location
  tags: tags
  properties: {
    securityRules: injectLegacyDeny ? [ legacyCrossSubnetDeny, allowAppGwToApps ] : [ allowAppGwToApps ]
  }
}

// NSG for the ISOLATED nsg-lane subnet (2nd ACA env). Identical clean baseline; the
// parallel nsg scenario ships the DENY here (injectLegacyDenyNsgLane) so only that lane
// breaks while the other lanes keep serving.
resource nsgLaneNsg 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: 'nsg-nsglane-${resourceToken}'
  location: location
  tags: tags
  properties: {
    securityRules: injectLegacyDenyNsgLane ? [ legacyCrossSubnetDeny, allowAppGwToApps ] : [ allowAppGwToApps ]
  }
}

// NSG for the reporting-worker VM subnet. No inbound Internet needed: chaos and the SRE
// Agent reach the VM via `az vm run-command` (control plane), not SSH. Ships closed.
resource vmNsg 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: 'nsg-vm-${resourceToken}'
  location: location
  tags: tags
  properties: {
    securityRules: seedAuditFindings ? vmAuditRules : []
  }
}

// Orphaned NSG (seedAuditFindings): created but attached to no subnet and no NIC, carrying
// duplicate/overlapping web rules, a shadowed allow, and a never-matching legacy deny. An
// unattached NSG with dead rules is a classic audit finding (config drift / cleanup gap).
resource legacyUnusedNsg 'Microsoft.Network/networkSecurityGroups@2023-11-01' = if (seedAuditFindings) {
  name: 'nsg-legacy-unused-${resourceToken}'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'allow-http-dup'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '80'
          description: 'Duplicate web rule (overlaps allow-http-dup2).'
        }
      }
      {
        name: 'allow-http-dup2'
        properties: {
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '80'
          description: 'Overlapping duplicate of allow-http-dup.'
        }
      }
      {
        name: 'shadowed-allow-8080'
        properties: {
          priority: 300
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '8080'
          description: 'Shadowed by deny-all-legacy at priority 200.'
        }
      }
      {
        name: 'deny-all-legacy'
        properties: {
          priority: 200
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: '10.250.0.0/16'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
          description: 'Legacy deny for a decommissioned subnet (never matches).'
        }
      }
    ]
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: 'vnet-zava-${resourceToken}'
  location: location
  tags: tags
  properties: {
    addressSpace: { addressPrefixes: [ vnetAddressPrefix ] }
    subnets: [
      {
        name: 'appgw-subnet'
        properties: {
          addressPrefix: appGwSubnetPrefix
          networkSecurityGroup: { id: appGwNsg.id }
        }
      }
      {
        name: 'aca-infra-subnet'
        properties: {
          addressPrefix: acaSubnetPrefix
          networkSecurityGroup: { id: acaNsg.id }
          delegations: [
            {
              name: 'aca-delegation'
              properties: { serviceName: 'Microsoft.App/environments' }
            }
          ]
        }
      }
      {
        name: 'nsglane-subnet'
        properties: {
          addressPrefix: nsgLaneSubnetPrefix
          networkSecurityGroup: { id: nsgLaneNsg.id }
          delegations: [
            {
              name: 'aca-delegation'
              properties: { serviceName: 'Microsoft.App/environments' }
            }
          ]
        }
      }
      {
        name: 'vm-subnet'
        properties: {
          addressPrefix: vmSubnetPrefix
          networkSecurityGroup: { id: vmNsg.id }
        }
      }
    ]
  }
}

output vnetId string = vnet.id
output vnetName string = vnet.name
output appGwSubnetId string = vnet.properties.subnets[0].id
output acaSubnetId string = vnet.properties.subnets[1].id
output nsgLaneSubnetId string = vnet.properties.subnets[2].id
output vmSubnetId string = vnet.properties.subnets[3].id
output acaNsgName string = acaNsg.name
output nsgLaneNsgName string = nsgLaneNsg.name
output appGwSubnetPrefix string = appGwSubnetPrefix
