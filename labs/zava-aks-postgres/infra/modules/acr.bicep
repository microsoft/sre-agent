@description('Azure region for the container registry.')
param location string

@description('Unique suffix for globally unique resource names.')
param uniqueSuffix string

var acrName = 'acrzava${uniqueSuffix}'

resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: acrName
  location: location
  sku: {
    name: 'Basic'
  }
  properties: {
    adminUserEnabled: false
  }
}

output acrName string = acr.name
output acrLoginServer string = acr.properties.loginServer
output acrId string = acr.id
