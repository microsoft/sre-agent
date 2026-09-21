targetScope = 'subscription'

@description('Name of the azd environment. Used for tags and stable unique names.')
@minLength(1)
@maxLength(64)
param environmentName string

@description('Region supporting Linux App Service B1 and PostgreSQL B1ms.')
param location string

@description('Selects the App Service or App Service plus PostgreSQL lab scenarios.')
@allowed([
  'app-service'
  'app-service-postgresql'
])
param workloadOption string

@description('Optional. Name of an existing resource group to deploy the lab workload into. Leave empty to create rg-flu-<token>. Use this when the resource group was pre-created (for example by the lab bootstrap script), possibly in a different region than the workload.')
param resourceGroupName string = ''

var resourceToken = uniqueString(subscription().subscriptionId, environmentName, location)
var tags = {
  'azd-env-name': environmentName
  workload: 'onboardinglab'
}

var useExistingGroup = !empty(resourceGroupName)
var labGroupName = useExistingGroup ? resourceGroupName : 'rg-flu-${resourceToken}'

resource labGroup 'Microsoft.Resources/resourceGroups@2024-03-01' = if (!useExistingGroup) {
  name: labGroupName
  location: location
  tags: tags
}

module workload 'modules/workload.bicep' = {
  scope: resourceGroup(labGroupName)
  dependsOn: [ labGroup ]
  params: {
    location: location
    namePrefix: 'flu-${resourceToken}'
    workloadOption: workloadOption
    tags: tags
  }
}

output AZURE_RESOURCE_GROUP string = labGroupName
output AZURE_LOCATION string = location
output SERVICE_CHECKOUT_NAME string = workload.outputs.checkoutAppName
output SERVICE_CHECKOUT_ENDPOINT_URL string = workload.outputs.checkoutUrl
output LAB_WORKLOAD_OPTION string = workload.outputs.workloadOption
output LAB_NSG_NAME string = workload.outputs.networkSecurityGroupName
output LAB_NAME_PREFIX string = 'flu-${resourceToken}'
output CHECKOUT_APP_ID string = workload.outputs.checkoutAppId
output POSTGRES_SERVER_ID string = workload.outputs.postgresServerId
output APPLICATION_INSIGHTS_ID string = workload.outputs.applicationInsightsId
output APPLICATION_INSIGHTS_APP_ID string = workload.outputs.applicationInsightsAppId
output LOG_ANALYTICS_WORKSPACE_ID string = workload.outputs.logAnalyticsWorkspaceId