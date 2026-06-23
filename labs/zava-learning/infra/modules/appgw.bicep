// Application Gateway v2 fronting the learner-portal Container App AND the parallel quiz
// lanes. Public entry point for students; the portal is served on :80, and each fault lane
// gets its own frontend PORT -> listener -> backend pool -> probe -> rule so all scenarios
// can run in parallel, each independently reachable and independently health-checked.
@description('Azure region for all resources.')
param location string
@description('Resource name suffix token.')
param resourceToken string
@description('Tags applied to all resources.')
param tags object = {}
@description('App Gateway subnet id.')
param appGwSubnetId string
@description('Backend FQDN (portal internal ACA FQDN).')
param backendFqdn string
@description('''Backend health probe path. Healthy default is /health (served by the
portal). chaos/break-appgw.ps1 sets this to a path the portal does not serve so the
gateway marks the backend unhealthy and returns 502s; the SRE Agent must restore it.''')
param portalHealthProbePath string = '/health'

@description('''Parallel lanes. Each item: { name, port, fqdn, probePath }. The gateway adds
a frontend port + HTTP listener + backend pool + health probe + HTTPS backend setting +
routing rule per lane. The appgw lane's probePath is the breakable fault parameter.''')
param lanes array = []

var appGwName = 'agw-zava-${resourceToken}'

// For-expressions can't be used directly inside concat(), so build each per-lane array as
// a variable first, then concat with the portal base entry in the resource.
var laneFrontendPorts = [for lane in lanes: {
  name: 'port-${lane.name}'
  properties: { port: lane.port }
}]
var laneBackendPools = [for lane in lanes: {
  name: '${lane.name}-pool'
  properties: { backendAddresses: [ { fqdn: lane.fqdn } ] }
}]
var laneProbes = [for lane in lanes: {
  name: '${lane.name}-health'
  properties: {
    protocol: 'Https'
    host: lane.fqdn
    path: lane.probePath
    interval: 30
    timeout: 30
    unhealthyThreshold: 3
    pickHostNameFromBackendHttpSettings: false
    match: { statusCodes: [ '200-399' ] }
  }
}]
var laneHttpSettings = [for lane in lanes: {
  name: '${lane.name}-https'
  properties: {
    port: 443
    protocol: 'Https'
    cookieBasedAffinity: 'Disabled'
    pickHostNameFromBackendAddress: true
    requestTimeout: 30
    probe: {
      id: resourceId('Microsoft.Network/applicationGateways/probes', appGwName, '${lane.name}-health')
    }
  }
}]
var laneListeners = [for lane in lanes: {
  name: '${lane.name}-listener'
  properties: {
    frontendIPConfiguration: {
      id: resourceId('Microsoft.Network/applicationGateways/frontendIPConfigurations', appGwName, 'frontend')
    }
    frontendPort: {
      id: resourceId('Microsoft.Network/applicationGateways/frontendPorts', appGwName, 'port-${lane.name}')
    }
    protocol: 'Http'
  }
}]
var laneRules = [for (lane, i) in lanes: {
  name: '${lane.name}-rule'
  properties: {
    ruleType: 'Basic'
    priority: 200 + i
    httpListener: {
      id: resourceId('Microsoft.Network/applicationGateways/httpListeners', appGwName, '${lane.name}-listener')
    }
    backendAddressPool: {
      id: resourceId('Microsoft.Network/applicationGateways/backendAddressPools', appGwName, '${lane.name}-pool')
    }
    backendHttpSettings: {
      id: resourceId('Microsoft.Network/applicationGateways/backendHttpSettingsCollection', appGwName, '${lane.name}-https')
    }
  }
}]

resource publicIp 'Microsoft.Network/publicIPAddresses@2023-11-01' = {
  name: 'pip-agw-zava-${resourceToken}'
  location: location
  tags: tags
  sku: { name: 'Standard' }
  properties: {
    publicIPAllocationMethod: 'Static'
    dnsSettings: { domainNameLabel: 'zava-${resourceToken}' }
  }
}

resource appGw 'Microsoft.Network/applicationGateways@2023-11-01' = {
  name: appGwName
  location: location
  tags: tags
  properties: {
    sku: { name: 'Standard_v2', tier: 'Standard_v2', capacity: 1 }
    gatewayIPConfigurations: [
      {
        name: 'gwip'
        properties: { subnet: { id: appGwSubnetId } }
      }
    ]
    frontendIPConfigurations: [
      {
        name: 'frontend'
        properties: { publicIPAddress: { id: publicIp.id } }
      }
    ]
    frontendPorts: concat([
      { name: 'port80', properties: { port: 80 } }
    ], laneFrontendPorts)
    backendAddressPools: concat([
      {
        name: 'portal-pool'
        properties: { backendAddresses: [ { fqdn: backendFqdn } ] }
      }
    ], laneBackendPools)
    probes: concat([
      {
        name: 'portal-health'
        properties: {
          protocol: 'Https'
          host: backendFqdn
          path: portalHealthProbePath
          interval: 30
          timeout: 30
          unhealthyThreshold: 3
          pickHostNameFromBackendHttpSettings: false
          match: { statusCodes: [ '200-399' ] }
        }
      }
    ], laneProbes)
    backendHttpSettingsCollection: concat([
      {
        name: 'portal-https'
        properties: {
          port: 443
          protocol: 'Https'
          cookieBasedAffinity: 'Disabled'
          pickHostNameFromBackendAddress: true
          requestTimeout: 30
          probe: {
            id: resourceId('Microsoft.Network/applicationGateways/probes', appGwName, 'portal-health')
          }
        }
      }
    ], laneHttpSettings)
    httpListeners: concat([
      {
        name: 'http-listener'
        properties: {
          frontendIPConfiguration: {
            id: resourceId('Microsoft.Network/applicationGateways/frontendIPConfigurations', appGwName, 'frontend')
          }
          frontendPort: {
            id: resourceId('Microsoft.Network/applicationGateways/frontendPorts', appGwName, 'port80')
          }
          protocol: 'Http'
        }
      }
    ], laneListeners)
    requestRoutingRules: concat([
      {
        name: 'portal-rule'
        properties: {
          ruleType: 'Basic'
          priority: 100
          httpListener: {
            id: resourceId('Microsoft.Network/applicationGateways/httpListeners', appGwName, 'http-listener')
          }
          backendAddressPool: {
            id: resourceId('Microsoft.Network/applicationGateways/backendAddressPools', appGwName, 'portal-pool')
          }
          backendHttpSettings: {
            id: resourceId('Microsoft.Network/applicationGateways/backendHttpSettingsCollection', appGwName, 'portal-https')
          }
        }
      }
    ], laneRules)
  }
}

output appGwName string = appGw.name
output appGwId string = appGw.id
output publicIpAddress string = publicIp.properties.ipAddress
output publicFqdn string = publicIp.properties.dnsSettings.fqdn
