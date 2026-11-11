targetScope = 'resourceGroup'

@allowed([
  'same-region'
  'cross-region'
])
param topology string

@minLength(3)
@maxLength(24)
param namePrefix string = 'sre-splunk'

param agentLocation string = 'eastus2'
param splunkLocation string = agentLocation
param agentVnetAddressPrefix string = '10.100.0.0/16'
param splunkVnetAddressPrefix string = agentVnetAddressPrefix
param agentSubnetPrefix string = '10.100.0.0/27'
param splunkSubnetPrefix string = '10.100.1.0/24'
param splunkPrivateIp string = '10.100.1.4'
param privateDnsZoneName string = 'lab.internal'
param splunkDnsRecordName string = 'splunk-mcp'
param vmSize string = 'Standard_D4as_v5'
param adminUsername string = 'azureuser'
param adminSshPublicKey string
param tags object = {}

var agentVnetOctets = split(split(agentVnetAddressPrefix, '/')[0], '.')
var splunkVnetOctets = split(split(splunkVnetAddressPrefix, '/')[0], '.')
var agentSubnetOctets = split(split(agentSubnetPrefix, '/')[0], '.')
var splunkSubnetOctets = split(split(splunkSubnetPrefix, '/')[0], '.')
var privateIpOctets = split(splunkPrivateIp, '.')
var agentVnetKey = '${agentVnetOctets[0]}.${agentVnetOctets[1]}'
var splunkVnetKey = '${splunkVnetOctets[0]}.${splunkVnetOctets[1]}'
var agentSubnetVnetKey = '${agentSubnetOctets[0]}.${agentSubnetOctets[1]}'
var splunkSubnetVnetKey = '${splunkSubnetOctets[0]}.${splunkSubnetOctets[1]}'
var agentSubnetKey = '${agentSubnetVnetKey}.${agentSubnetOctets[2]}'
var splunkSubnetKey = '${splunkSubnetVnetKey}.${splunkSubnetOctets[2]}'
var privateIpSubnetKey = '${privateIpOctets[0]}.${privateIpOctets[1]}.${privateIpOctets[2]}'
var privateIpHost = int(privateIpOctets[3])
var normalizedAgentLocation = toLower(replace(agentLocation, ' ', ''))
var normalizedSplunkLocation = toLower(replace(splunkLocation, ' ', ''))
var sshParts = split(trim(adminSshPublicKey), ' ')
var validSshType = startsWith(adminSshPublicKey, 'ssh-rsa ') || startsWith(adminSshPublicKey, 'ssh-ed25519 ') || startsWith(adminSshPublicKey, 'ecdsa-sha2-nistp256 ') || startsWith(adminSshPublicKey, 'ecdsa-sha2-nistp384 ') || startsWith(adminSshPublicKey, 'ecdsa-sha2-nistp521 ')

assert validRegions = topology == 'same-region'
  ? normalizedAgentLocation == normalizedSplunkLocation
  : normalizedAgentLocation != normalizedSplunkLocation
assert expectedCidrSizes = endsWith(agentVnetAddressPrefix, '/16') && endsWith(splunkVnetAddressPrefix, '/16') && endsWith(agentSubnetPrefix, '/27') && endsWith(splunkSubnetPrefix, '/24')
assert agentSubnetContained = agentVnetKey == agentSubnetVnetKey
assert splunkSubnetContained = splunkVnetKey == splunkSubnetVnetKey
assert validTopologyNetworks = topology == 'same-region'
  ? agentVnetAddressPrefix == splunkVnetAddressPrefix && agentSubnetKey != splunkSubnetKey
  : agentVnetKey != splunkVnetKey
assert usableSplunkPrivateIp = privateIpSubnetKey == splunkSubnetKey && privateIpHost >= 4 && privateIpHost <= 254
assert validSshPublicKey = validSshType && length(sshParts) >= 2 && length(sshParts[1]) >= 16

module foundation 'modules/foundation.bicep' = {
  name: 'foundation'
  params: {
    namePrefix: namePrefix
    location: splunkLocation
    agentSubnetPrefix: agentSubnetPrefix
    privateDnsZoneName: privateDnsZoneName
    tags: tags
  }
}

module sameRegion 'modules/same-region-network.bicep' = if (topology == 'same-region') {
  name: 'same-region-network'
  params: {
    namePrefix: namePrefix
    location: agentLocation
    vnetAddressPrefix: agentVnetAddressPrefix
    agentSubnetPrefix: agentSubnetPrefix
    splunkSubnetPrefix: splunkSubnetPrefix
    splunkNsgId: foundation.outputs.splunkNsgId
    natGatewayId: foundation.outputs.natGatewayId
    privateDnsZoneName: foundation.outputs.privateDnsZoneName
    tags: tags
  }
}

module crossRegion 'modules/cross-region-network.bicep' = if (topology == 'cross-region') {
  name: 'cross-region-network'
  params: {
    namePrefix: namePrefix
    agentLocation: agentLocation
    splunkLocation: splunkLocation
    agentVnetAddressPrefix: agentVnetAddressPrefix
    splunkVnetAddressPrefix: splunkVnetAddressPrefix
    agentSubnetPrefix: agentSubnetPrefix
    splunkSubnetPrefix: splunkSubnetPrefix
    splunkNsgId: foundation.outputs.splunkNsgId
    natGatewayId: foundation.outputs.natGatewayId
    privateDnsZoneName: foundation.outputs.privateDnsZoneName
    tags: tags
  }
}

var agentSubnetId = topology == 'same-region' ? sameRegion!.outputs.agentSubnetId : crossRegion!.outputs.agentSubnetId
var splunkSubnetId = topology == 'same-region' ? sameRegion!.outputs.splunkSubnetId : crossRegion!.outputs.splunkSubnetId
var agentVnetId = topology == 'same-region' ? sameRegion!.outputs.agentVnetId : crossRegion!.outputs.agentVnetId
var splunkVnetId = topology == 'same-region' ? sameRegion!.outputs.splunkVnetId : crossRegion!.outputs.splunkVnetId

module workload 'modules/workload.bicep' = {
  name: 'workload'
  params: {
    namePrefix: namePrefix
    location: splunkLocation
    splunkSubnetId: splunkSubnetId
    splunkPrivateIp: splunkPrivateIp
    privateDnsZoneName: foundation.outputs.privateDnsZoneName
    splunkDnsRecordName: splunkDnsRecordName
    vmSize: vmSize
    adminUsername: adminUsername
    adminSshPublicKey: adminSshPublicKey
    tags: tags
  }
}

output agentSubnetId string = agentSubnetId
output agentVnetId string = agentVnetId
output splunkVnetId string = splunkVnetId
output splunkVmId string = workload.outputs.splunkVmId
output splunkVmName string = workload.outputs.splunkVmName
output splunkPrivateIp string = workload.outputs.splunkPrivateIp
output splunkHostname string = workload.outputs.splunkHostname
output splunkEndpointCandidates object = workload.outputs.splunkEndpointCandidates
output splunkPrivateHostname string = workload.outputs.splunkHostname
output splunkHttpsMcpEndpoint string = workload.outputs.splunkEndpointCandidates.mcpHttps
output privateTestEndpoint string = workload.outputs.splunkEndpointCandidates.privateTestHttp
