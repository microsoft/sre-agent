// ── Container Registry with Managed Identity pull ──

param location string
param workloadName string
param tags object

resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: replace('acr${workloadName}', '-', '')
  location: location
  tags: tags
  sku: { name: 'Basic' }
  properties: {
    adminUserEnabled: false
  }
}

output registryName string = acr.name
output registryLoginServer string = acr.properties.loginServer
output registryId string = acr.id
