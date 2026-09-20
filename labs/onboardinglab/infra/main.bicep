targetScope = 'resourceGroup'

@description('Region for the onboarding workload.')
param location string

@description('Stable prefix for workload resource names.')
@minLength(3)
@maxLength(20)
param namePrefix string

@description('Name of the existing final SRE Agent.')
param agentName string

@description('Name of the existing user-assigned identity used by the agent.')
param agentIdentityName string

param tags object = {
  workload: 'onboardinglab'
}

module workload '../ticketingapp-source/modules/workload.bicep' = {
  name: 'onboardinglab-workload'
  params: {
    location: location
    namePrefix: namePrefix
    tags: tags
  }
}

module agentConfiguration 'modules/sre-agent.bicep' = {
  name: 'onboardinglab-agent-configuration'
  params: {
    agentName: agentName
    identityName: agentIdentityName
    workloadAppInsightsId: workload.outputs.applicationInsightsId
  }
}

output checkoutAppName string = workload.outputs.checkoutAppName
output checkoutUrl string = workload.outputs.checkoutUrl
output applicationInsightsId string = workload.outputs.applicationInsightsId
output applicationInsightsAppId string = workload.outputs.applicationInsightsAppId
output networkSecurityGroupName string = workload.outputs.networkSecurityGroupName
output logAnalyticsWorkspaceId string = workload.outputs.logAnalyticsWorkspaceId
output agentId string = agentConfiguration.outputs.agentId
output agentEndpoint string = agentConfiguration.outputs.agentEndpoint
