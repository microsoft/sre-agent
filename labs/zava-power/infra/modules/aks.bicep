// ── AKS Cluster (Alternative compute option) ──

param location string
param workloadName string
param tags object
param logAnalyticsWorkspaceId string
param containerRegistryName string

resource aksIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-${workloadName}-aks'
  location: location
  tags: tags
}

resource aks 'Microsoft.ContainerService/managedClusters@2024-02-01' = {
  name: 'aks-${workloadName}'
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${aksIdentity.id}': {} }
  }
  properties: {
    dnsPrefix: 'aks-${workloadName}'
    kubernetesVersion: '1.29'
    agentPoolProfiles: [
      {
        name: 'system'
        count: 3
        vmSize: 'Standard_B4ms'
        mode: 'System'
        osType: 'Linux'
        osSKU: 'AzureLinux'
      }
    ]
    addonProfiles: {
      omsagent: {
        enabled: true
        config: { logAnalyticsWorkspaceResourceID: logAnalyticsWorkspaceId }
      }
    }
    networkProfile: {
      networkPlugin: 'azure'
      networkPolicy: 'azure'
    }
  }
}

// AcrPull for AKS kubelet identity
resource acrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(aks.id, containerRegistryName, 'AcrPull')
  properties: {
    principalId: aks.properties.identityProfile.kubeletidentity.objectId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')
  }
}

output aksName string = aks.name
output aksId string = aks.id
