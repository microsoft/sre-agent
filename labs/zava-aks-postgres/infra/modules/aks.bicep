@description('Azure region for the AKS cluster.')
param location string

@description('Unique suffix for globally unique resource names.')
param uniqueSuffix string

@description('Resource ID of the AKS subnet.')
param subnetId string

@description('Log Analytics workspace resource ID for Container Insights (omsagent addon).')
param logAnalyticsWorkspaceId string

@description('Container registry resource ID — used to grant AKS kubelet AcrPull.')
param acrId string

var clusterName = 'aks-Zava-${uniqueSuffix}'

resource aks 'Microsoft.ContainerService/managedClusters@2024-09-01' = {
  name: clusterName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    dnsPrefix: 'Zava-${uniqueSuffix}'
    aadProfile: {
      managed: true
      enableAzureRBAC: true
    }
    networkProfile: {
      networkPlugin: 'azure'
      networkPolicy: 'azure'
      serviceCidr: '10.2.0.0/16'
      dnsServiceIP: '10.2.0.10'
    }
    // Enterprise hardening: private API server. The control plane is
    // unreachable from the public internet — both human operators and the
    // SRE Agent reach it through `az aks command invoke` (Azure-proxied
    // kubectl). Cluster Admin RBAC for the agent identities is granted in
    // `sre-agent.bicep`.
    apiServerAccessProfile: {
      enablePrivateCluster: true
      privateDNSZone: 'system'
      enablePrivateClusterPublicFQDN: false
    }
    oidcIssuerProfile: {
      enabled: true
    }
    securityProfile: {
      workloadIdentity: {
        enabled: true
      }
    }
    // GeneralPurpose (not Burstable) for the same reason as the PG server:
    // CPU-credit throttle on Burstable SKUs surfaces as latency that the
    // agent can't distinguish from the failure modes the demo wants to teach.
    // See postgresql.bicep for the IOPS/credit-floor numbers.
    agentPoolProfiles: [
      {
        name: 'apppool2'
        count: 3
        vmSize: 'Standard_D2ds_v5'
        osType: 'Linux'
        mode: 'System'
        vnetSubnetID: subnetId
        enableAutoScaling: false
      }
    ]
    addonProfiles: {
      omsagent: {
        enabled: true
        config: {
          logAnalyticsWorkspaceResourceID: logAnalyticsWorkspaceId
        }
      }
      // Enable Azure Policy add-on inline so the subscription's
      // deployIfNotExists policy sees compliance during AKS creation
      // and skips the trailing 3-deployment, ~10-minute remediation tail.
      azurepolicy: {
        enabled: true
      }
    }
    // Container Insights (omsagent addon above) ships kube-state-metrics, pod
    // inventory, container logs, and node perf to Log Analytics. KQL tables:
    // KubePodInventory, KubeEvents, ContainerLogV2, InsightsMetrics, Perf.
  }
}

// ACR pull role for AKS kubelet identity
resource acrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(aks.id, acrId, 'acrpull')
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d') // AcrPull
    principalId: aks.properties.identityProfile.kubeletidentity.objectId
    principalType: 'ServicePrincipal'
  }
}

output clusterName string = aks.name
output clusterResourceId string = aks.id
output clusterPrivateFqdn string = aks.properties.privateFQDN
output kubeletPrincipalId string = aks.properties.identityProfile.kubeletidentity.objectId
output oidcIssuerUrl string = aks.properties.oidcIssuerProfile.issuerURL
