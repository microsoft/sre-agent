// ──────────────────────────────────────────────────────────────
// Zava — IT Support SRE Agent Lab — Resource Group resources
// Container Apps + ACR + monitoring + SRE Agent.
// ──────────────────────────────────────────────────────────────

targetScope = 'resourceGroup'

@description('Name of the environment (from azd)')
param environmentName string

@description('Azure region for all resources')
param location string

@description('Naming prefix for all resources')
param prefix string = 'zavaits'

// ── Variables ───────────────────────────────────────────────

var resourceToken = take(uniqueString(resourceGroup().id, environmentName, prefix), 8)
var lawName = 'law-${prefix}-${resourceToken}'
var appInsightsName = 'ai-${prefix}-${resourceToken}'
var acrName = take(replace('acr${prefix}${resourceToken}', '-', ''), 50)
var acaEnvName = 'cae-${prefix}-${resourceToken}'
var itPortalAppName = 'ca-${prefix}-itportal'
var warrantyAppName = 'ca-${prefix}-warranty'
var identityName = 'id-sre-${prefix}-${resourceToken}'
var appsIdentityName = 'id-apps-${prefix}-${resourceToken}'
var agentName = 'sre-zava-its-${resourceToken}'

// Public placeholder image used until post-provision pushes the real images.
var placeholderImage = 'mcr.microsoft.com/k8se/quickstart:latest'

// ── Monitoring (LAW + App Insights) ─────────────────────────

module monitoring 'modules/monitoring.bicep' = {
  name: 'monitoring'
  params: {
    location: location
    logAnalyticsName: lawName
    appInsightsName: appInsightsName
  }
}

// ── Managed Identity for the SRE Agent ──────────────────────

module identity 'modules/identity.bicep' = {
  name: 'identity'
  params: {
    location: location
    identityName: identityName
  }
}

// ── Container Registry ──────────────────────────────────────

resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: acrName
  location: location
  sku: { name: 'Basic' }
  properties: {
    adminUserEnabled: true
  }
}

// ── Managed Identity for Container Apps (AcrPull) ───────────

resource appsIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' = {
  name: appsIdentityName
  location: location
}

resource acrPullRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(acr.id, appsIdentity.id, 'AcrPull')
  scope: acr
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')
    principalId: appsIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// ── Container Apps Environment ──────────────────────────────

resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: lawName
  dependsOn: [ monitoring ]
}

resource acaEnv 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: acaEnvName
  location: location
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalyticsWorkspace.properties.customerId
        sharedKey: logAnalyticsWorkspace.listKeys().primarySharedKey
      }
    }
  }
}

// ── Container App: laptop-request-site (Node.js) ────────────

resource itPortalApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: itPortalAppName
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${appsIdentity.id}': {} }
  }
  properties: {
    managedEnvironmentId: acaEnv.id
    configuration: {
      ingress: {
        external: true
        targetPort: 8080
        transport: 'auto'
      }
      registries: [
        {
          server: acr.properties.loginServer
          identity: appsIdentity.id
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'laptop-request-site'
          image: placeholderImage
          resources: { cpu: json('0.25'), memory: '0.5Gi' }
          env: [
            {
              name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
              value: monitoring.outputs.appInsightsConnectionString
            }
          ]
        }
      ]
      scale: { minReplicas: 1, maxReplicas: 2 }
    }
  }
  dependsOn: [
    acrPullRole
  ]
}

// ── Container App: warranty-tool (Python) ───────────────────

resource warrantyApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: warrantyAppName
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${appsIdentity.id}': {} }
  }
  properties: {
    managedEnvironmentId: acaEnv.id
    configuration: {
      ingress: {
        external: true
        targetPort: 8000
        transport: 'auto'
      }
      registries: [
        {
          server: acr.properties.loginServer
          identity: appsIdentity.id
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'warranty-tool'
          image: placeholderImage
          resources: { cpu: json('0.25'), memory: '0.5Gi' }
          env: [
            {
              name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
              value: monitoring.outputs.appInsightsConnectionString
            }
          ]
        }
      ]
      scale: { minReplicas: 1, maxReplicas: 2 }
    }
  }
  dependsOn: [
    acrPullRole
  ]
}

// ── SRE Agent ───────────────────────────────────────────────

module sreAgent 'modules/sre-agent.bicep' = {
  name: 'sre-agent'
  params: {
    location: location
    agentName: agentName
    identityId: identity.outputs.identityId
    identityPrincipalId: identity.outputs.identityPrincipalId
    appInsightsAppId: monitoring.outputs.appInsightsAppId
    appInsightsConnectionString: monitoring.outputs.appInsightsConnectionString
    appInsightsId: monitoring.outputs.appInsightsId
    managedResourceGroupId: resourceGroup().id
  }
}

// ── Outputs ─────────────────────────────────────────────────

output containerRegistryName string = acr.name
output containerRegistryLoginServer string = acr.properties.loginServer
output acaEnvName string = acaEnv.name
output itPortalAppName string = itPortalApp.name
output itPortalUrl string = 'https://${itPortalApp.properties.configuration.ingress.fqdn}'
output warrantyAppName string = warrantyApp.name
output warrantyApiUrl string = 'https://${warrantyApp.properties.configuration.ingress.fqdn}'
output appInsightsConnectionString string = monitoring.outputs.appInsightsConnectionString
output identityPrincipalId string = identity.outputs.identityPrincipalId
output agentName string = sreAgent.outputs.agentName
output agentEndpoint string = sreAgent.outputs.agentEndpoint
output agentPortalUrl string = sreAgent.outputs.agentPortalUrl
