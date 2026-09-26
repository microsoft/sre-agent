param namePrefix string
param location string
param splunkSubnetId string
param splunkPrivateIp string
param privateDnsZoneName string
param splunkDnsRecordName string
param vmSize string
param adminUsername string
param adminSshPublicKey string
param tags object

resource privateDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' existing = {
  name: privateDnsZoneName
}

resource splunkDnsRecord 'Microsoft.Network/privateDnsZones/A@2024-06-01' = {
  parent: privateDnsZone
  name: splunkDnsRecordName
  properties: {
    ttl: 300
    aRecords: [
      {
        ipv4Address: splunkPrivateIp
      }
    ]
  }
}

resource vmNic 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: '${namePrefix}-vm-nic'
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Static'
          privateIPAddress: splunkPrivateIp
          subnet: {
            id: splunkSubnetId
          }
        }
      }
    ]
  }
}

resource splunkVm 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: '${namePrefix}-vm'
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: '0001-com-ubuntu-server-jammy'
        sku: '22_04-lts-gen2'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Premium_LRS'
        }
      }
    }
    osProfile: {
      computerName: '${namePrefix}-vm'
      adminUsername: adminUsername
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: adminSshPublicKey
            }
          ]
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: vmNic.id
        }
      ]
    }
    securityProfile: {
      securityType: 'TrustedLaunch'
      uefiSettings: {
        secureBootEnabled: true
        vTpmEnabled: true
      }
    }
  }
}

var hostname = '${splunkDnsRecordName}.${privateDnsZone.name}'

output splunkVmId string = splunkVm.id
output splunkVmName string = splunkVm.name
output splunkPrivateIp string = splunkPrivateIp
output splunkHostname string = hostname
output splunkEndpointCandidates object = {
  privateTestHttp: 'http://${hostname}:8080'
  mcpHttps: 'https://${hostname}:8089/services/mcp'
  mcpHttpLabOnly: 'http://${hostname}:8089/services/mcp'
}
