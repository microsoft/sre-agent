// ── Azure Container Apps Environment + PowerGrid Services ──

param location string
param workloadName string
param tags object
param logAnalyticsWorkspaceId string
param appInsightsConnectionString string
param containerRegistryName string
param imageTag string

@description('Use a public bootstrap image instead of ACR images. Required on first deploy because postprovision builds the real images AFTER bicep runs. Set to false on subsequent deploys via USE_BOOTSTRAP_IMAGE=false.')
param useBootstrapImage bool = true

@description('Public placeholder image used when useBootstrapImage=true.')
param bootstrapImage string = 'mcr.microsoft.com/k8se/quickstart:latest'

// Per-service image: bootstrap on first deploy, ACR on subsequent deploys.
var images = {
  portal: useBootstrapImage ? bootstrapImage : '${containerRegistryName}.azurecr.io/portal-web:${imageTag}'
  outage: useBootstrapImage ? bootstrapImage : '${containerRegistryName}.azurecr.io/outage-api:${imageTag}'
  meter:  useBootstrapImage ? bootstrapImage : '${containerRegistryName}.azurecr.io/meter-api:${imageTag}'
  grid:   useBootstrapImage ? bootstrapImage : '${containerRegistryName}.azurecr.io/grid-status-api:${imageTag}'
  notify: useBootstrapImage ? bootstrapImage : '${containerRegistryName}.azurecr.io/notification-svc:${imageTag}'
}

// ── Managed Identity for all apps ──
resource appIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-${workloadName}-apps'
  location: location
  tags: tags
}

// ── AcrPull role for the managed identity ──
resource acrPullRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(appIdentity.id, containerRegistryName, 'AcrPull')
  properties: {
    principalId: appIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')
  }
}

// ── Container Apps Environment ──
resource acaEnv 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: 'cae-${workloadName}'
  location: location
  tags: tags
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: reference(logAnalyticsWorkspaceId, '2023-09-01').customerId
        sharedKey: listKeys(logAnalyticsWorkspaceId, '2023-09-01').primarySharedKey
      }
    }
  }
}

// ── portal-web ──
resource portalWeb 'Microsoft.App/containerApps@2024-03-01' = {
  name: 'ca-${workloadName}-portal'
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${appIdentity.id}': {} }
  }
  properties: {
    managedEnvironmentId: acaEnv.id
    configuration: {
      ingress: { external: true, targetPort: 8080, transport: 'auto' }
      registries: [
        {
          server: '${containerRegistryName}.azurecr.io'
          identity: appIdentity.id
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'portal-web'
          image: images.portal
          resources: { cpu: json('0.25'), memory: '0.5Gi' }
          env: [
            { name: 'OUTAGE_API_URL', value: 'https://ca-${workloadName}-outage.${acaEnv.properties.defaultDomain}' }
            { name: 'METER_API_URL', value: 'https://ca-${workloadName}-meter.${acaEnv.properties.defaultDomain}' }
            { name: 'GRID_API_URL', value: 'https://ca-${workloadName}-grid.${acaEnv.properties.defaultDomain}' }
          ]
        }
      ]
      scale: { minReplicas: 1, maxReplicas: 3 }
    }
  }
}

// ── outage-api ──
resource outageApi 'Microsoft.App/containerApps@2024-03-01' = {
  name: 'ca-${workloadName}-outage'
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${appIdentity.id}': {} }
  }
  properties: {
    managedEnvironmentId: acaEnv.id
    configuration: {
      ingress: { external: true, targetPort: 8080, transport: 'auto' }
      registries: [
        {
          server: '${containerRegistryName}.azurecr.io'
          identity: appIdentity.id
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'outage-api'
          image: images.outage
          resources: { cpu: json('0.25'), memory: '0.5Gi' }
          env: [
            { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: appInsightsConnectionString }
          ]
        }
      ]
      scale: { minReplicas: 1, maxReplicas: 3 }
    }
  }
}

// ── meter-api ──
resource meterApi 'Microsoft.App/containerApps@2024-03-01' = {
  name: 'ca-${workloadName}-meter'
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${appIdentity.id}': {} }
  }
  properties: {
    managedEnvironmentId: acaEnv.id
    configuration: {
      ingress: { external: true, targetPort: 8080, transport: 'auto' }
      registries: [
        {
          server: '${containerRegistryName}.azurecr.io'
          identity: appIdentity.id
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'meter-api'
          image: images.meter
          resources: { cpu: json('0.5'), memory: '1Gi' }
          env: [
            { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: appInsightsConnectionString }
          ]
        }
      ]
      scale: { minReplicas: 1, maxReplicas: 3 }
    }
  }
}

// ── grid-status-api ──
resource gridStatusApi 'Microsoft.App/containerApps@2024-03-01' = {
  name: 'ca-${workloadName}-grid'
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${appIdentity.id}': {} }
  }
  properties: {
    managedEnvironmentId: acaEnv.id
    configuration: {
      ingress: { external: true, targetPort: 8080, transport: 'auto' }
      registries: [
        {
          server: '${containerRegistryName}.azurecr.io'
          identity: appIdentity.id
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'grid-status-api'
          image: images.grid
          resources: { cpu: json('0.25'), memory: '0.5Gi' }
          env: [
            { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: appInsightsConnectionString }
          ]
        }
      ]
      scale: { minReplicas: 1, maxReplicas: 3 }
    }
  }
}

// ── notification-svc ──
resource notificationSvc 'Microsoft.App/containerApps@2024-03-01' = {
  name: 'ca-${workloadName}-notify'
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${appIdentity.id}': {} }
  }
  properties: {
    managedEnvironmentId: acaEnv.id
    configuration: {
      ingress: { external: false, targetPort: 8080, transport: 'auto' }
      registries: [
        {
          server: '${containerRegistryName}.azurecr.io'
          identity: appIdentity.id
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'notification-svc'
          image: images.notify
          resources: { cpu: json('0.25'), memory: '0.5Gi' }
          env: [
            { name: 'REQUIRED_CONFIG', value: 'enabled' }
          ]
        }
      ]
      scale: { minReplicas: 1, maxReplicas: 2 }
    }
  }
}

output portalUrl string = 'https://${portalWeb.properties.configuration.ingress.fqdn}'
output outageApiUrl string = 'https://${outageApi.properties.configuration.ingress.fqdn}'
output meterApiUrl string = 'https://${meterApi.properties.configuration.ingress.fqdn}'
output gridApiUrl string = 'https://${gridStatusApi.properties.configuration.ingress.fqdn}'
output environmentName string = acaEnv.name
