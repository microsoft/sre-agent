// Zava Learning — SRE Agent lab. Subscription-scoped entry point: creates the
// resource group and provisions ALL platform resources EXCEPT the SRE Agent
// (the SRE Agent is provisioned separately against this resource group).
targetScope = 'subscription'

@minLength(1)
@maxLength(64)
@description('Name of the azd environment (used to derive resource names).')
param environmentName string

@minLength(1)
@description('Primary Azure region for all resources.')
param location string

@description('Region for the PostgreSQL flexible server (separate because the offer is restricted in many regions for this subscription; westus3 is permitted).')
param dbLocation string = 'westus3'

@description('PagerDuty "Microsoft Azure" integration URL (optional; wires the alert action group to PagerDuty).')
@secure()
param pagerDutyWebhookUrl string = ''

@description('Container images per service. Defaults to placeholder until azd deploy / acr build runs.')
param portalImage string = 'mcr.microsoft.com/k8se/quickstart:latest'
param courseApiImage string = 'mcr.microsoft.com/k8se/quickstart:latest'
param assessmentApiImage string = 'mcr.microsoft.com/k8se/quickstart:latest'

// --- Demo fault toggles (healthy defaults). The chaos/break-*.ps1 scripts flip the
// corresponding value in main.parameters.json (a "bad release") and deploy it, so the
// fault genuinely originates from IaC. The SRE Agent mitigates live, then opens an IaC
// PR returning these to their healthy values. ---
@description('Inject the legacy cross-subnet DENY rule on the ACA NSG (connectivity fault).')
param injectLegacyDeny bool = false
@description('App Gateway backend health probe path (healthy: /health).')
param portalHealthProbePath string = '/health'
@description('Assessment API replica floor (healthy: 1).')
param assessmentMinReplicas int = 1
@description('Assessment API replica ceiling (healthy: 3).')
param assessmentMaxReplicas int = 3

// --- Per-lane fault toggles (parallel lanes; healthy defaults) ---
@description('nsg lane: inject the DENY on the isolated nsg-lane subnet NSG.')
param injectLegacyDenyNsgLane bool = false
@description('Seed standing NSG audit loopholes (VM NSG over-permissive rules + an orphaned NSG) for the weekly NSG audit to find. Benign in this lab; default false.')
param seedAuditFindings bool = false
@description('appgw lane: health probe path for the quiz-appgw backend (healthy: /health).')
param appgwLaneProbePath string = '/health'
@description('app lane: quiz-app replica floor (healthy: 1; break sets 0).')
param appLaneMinReplicas int = 1
@description('app lane: quiz-app replica ceiling (healthy: 3; break sets 0).')
param appLaneMaxReplicas int = 3

// --- Lane image params (perf lane "bad deploy" flips quizPerfImage to the :v1.1 tag) ---
@description('Clean DB-backed quiz-service image used by the lanes.')
param quizServiceImage string = 'mcr.microsoft.com/k8se/quickstart:latest'
@description('perf lane image (healthy: clean quiz-service; break: quiz-service:v1.1 slow).')
param quizPerfImage string = 'mcr.microsoft.com/k8se/quickstart:latest'
@description('gradebook-api image.')
param gradebookApiImage string = 'mcr.microsoft.com/k8se/quickstart:latest'

// --- Database credentials (generated at deploy; never committed) ---
@secure()
@description('PostgreSQL administrator password.')
param dbAdminPassword string
@secure()
@description('Password for the dedicated app_pool DB role (pool lane).')
param dbPoolPassword string
@secure()
@description('Admin password for the reporting-worker VM (disk scenario).')
param vmAdminPassword string
@description('Public IP of the deploying machine (adds a Postgres firewall rule for seeding). Empty to skip.')
param deployerIp string = ''

var resourceToken = toLower(uniqueString(subscription().id, environmentName, location))
var tags = {
  'azd-env-name': environmentName
  solution: 'zava-learning'
}

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: 'rg-zava-learning-${environmentName}'
  location: location
  tags: tags
}

module monitoring 'modules/monitoring.bicep' = {
  name: 'monitoring'
  scope: rg
  params: { location: location, resourceToken: resourceToken, tags: tags }
}

module identity 'modules/identity.bicep' = {
  name: 'identity'
  scope: rg
  params: { location: location, resourceToken: resourceToken, tags: tags }
}

module db 'modules/db.bicep' = {
  name: 'db'
  scope: rg
  params: {
    location: dbLocation
    resourceToken: resourceToken
    tags: tags
    administratorPassword: dbAdminPassword
    deployerIp: deployerIp
  }
}

module keyvault 'modules/keyvault.bicep' = {
  name: 'keyvault'
  scope: rg
  params: {
    location: location
    resourceToken: resourceToken
    tags: tags
    identityPrincipalId: identity.outputs.identityPrincipalId
    dbAdminPassword: dbAdminPassword
    dbPoolPassword: dbPoolPassword
  }
}

module network 'modules/network.bicep' = {
  name: 'network'
  scope: rg
  params: {
    location: location
    resourceToken: resourceToken
    tags: tags
    injectLegacyDeny: injectLegacyDeny
    injectLegacyDenyNsgLane: injectLegacyDenyNsgLane
    seedAuditFindings: seedAuditFindings
  }
}

module aca 'modules/aca.bicep' = {
  name: 'aca'
  scope: rg
  params: {
    location: location
    resourceToken: resourceToken
    tags: tags
    acaSubnetId: network.outputs.acaSubnetId
    identityId: identity.outputs.identityId
    registryLoginServer: identity.outputs.registryLoginServer
    logAnalyticsCustomerId: monitoring.outputs.logAnalyticsCustomerId
    logAnalyticsWorkspaceName: monitoring.outputs.logAnalyticsWorkspaceName
    appInsightsConnectionString: monitoring.outputs.appInsightsConnectionString
    portalImage: portalImage
    courseApiImage: courseApiImage
    assessmentApiImage: assessmentApiImage
    assessmentMinReplicas: assessmentMinReplicas
    assessmentMaxReplicas: assessmentMaxReplicas
    nsgLaneSubnetId: network.outputs.nsgLaneSubnetId
    appLaneMinReplicas: appLaneMinReplicas
    appLaneMaxReplicas: appLaneMaxReplicas
    quizServiceImage: quizServiceImage
    quizPerfImage: quizPerfImage
    gradebookApiImage: gradebookApiImage
    pgFqdn: db.outputs.fqdn
    pgAdminLogin: db.outputs.administratorLogin
    pgMainDatabase: db.outputs.mainDatabase
    pgQueryDatabase: db.outputs.queryDatabase
    secretUriDbPassword: keyvault.outputs.secretUriDbPassword
    secretUriSecretLane: keyvault.outputs.secretUriSecretLane
    secretUriPoolPassword: keyvault.outputs.secretUriPoolPassword
  }
}

module dns 'modules/dns.bicep' = {
  name: 'dns'
  scope: rg
  params: {
    resourceToken: resourceToken
    tags: tags
    defaultDomain: aca.outputs.defaultDomain
    environmentStaticIp: aca.outputs.environmentStaticIp
    vnetId: network.outputs.vnetId
  }
}

// Private DNS zone for the 2nd (nsg-lane) ACA environment so the App Gateway can resolve
// the quiz-nsg backend FQDN.
module dnsNsg 'modules/dns.bicep' = {
  name: 'dns-nsglane'
  scope: rg
  params: {
    resourceToken: '${resourceToken}n'
    tags: tags
    defaultDomain: aca.outputs.nsgLaneDefaultDomain
    environmentStaticIp: aca.outputs.nsgLaneStaticIp
    vnetId: network.outputs.vnetId
  }
}

// Parallel lanes fronted by the App Gateway, one frontend port each. The appgw lane's
// probe path is the breakable parameter; all others are healthy /health.
var appGwLanes = [
  { name: 'quiz-nsg',    port: 8081, fqdn: aca.outputs.nsgLaneFqdn,           probePath: '/health' }
  { name: 'quiz-appgw',  port: 8082, fqdn: aca.outputs.mainLaneFqdns[0].fqdn, probePath: appgwLaneProbePath }
  { name: 'quiz-app',    port: 8083, fqdn: aca.outputs.mainLaneFqdns[1].fqdn, probePath: '/health' }
  { name: 'quiz-perf',   port: 8084, fqdn: aca.outputs.mainLaneFqdns[2].fqdn, probePath: '/health' }
  { name: 'quiz-query',  port: 8085, fqdn: aca.outputs.mainLaneFqdns[3].fqdn, probePath: '/health' }
  { name: 'quiz-pool',   port: 8086, fqdn: aca.outputs.mainLaneFqdns[4].fqdn, probePath: '/health' }
  { name: 'quiz-secret', port: 8087, fqdn: aca.outputs.mainLaneFqdns[5].fqdn, probePath: '/health' }
]

module appgw 'modules/appgw.bicep' = {
  name: 'appgw'
  scope: rg
  params: {
    location: location
    resourceToken: resourceToken
    tags: tags
    appGwSubnetId: network.outputs.appGwSubnetId
    backendFqdn: aca.outputs.portalFqdn
    portalHealthProbePath: portalHealthProbePath
    lanes: appGwLanes
  }
  dependsOn: [ dns, dnsNsg ]
}

module alerts 'modules/alerts.bicep' = {
  name: 'alerts'
  scope: rg
  params: {
    location: location
    resourceToken: resourceToken
    tags: tags
    logAnalyticsWorkspaceId: monitoring.outputs.logAnalyticsWorkspaceId
    pagerDutyWebhookUrl: pagerDutyWebhookUrl
  }
}

// Reporting-worker VM (disk scenario): nightly grade-export worker whose data disk chaos
// fills to trigger the symptom-only "grade exports failing" alert.
module vm 'modules/vm.bicep' = {
  name: 'vm'
  scope: rg
  params: {
    location: location
    resourceToken: resourceToken
    tags: tags
    subnetId: network.outputs.vmSubnetId
    logAnalyticsWorkspaceId: monitoring.outputs.logAnalyticsWorkspaceId
    adminPassword: vmAdminPassword
  }
}

output AZURE_RESOURCE_GROUP string = rg.name
output AZURE_LOCATION string = location
output AZURE_CONTAINER_REGISTRY_ENDPOINT string = identity.outputs.registryLoginServer
output AZURE_CONTAINER_REGISTRY_NAME string = identity.outputs.registryName
output AZURE_CONTAINER_ENVIRONMENT_NAME string = aca.outputs.environmentName
output AZURE_MANAGED_IDENTITY_ID string = identity.outputs.identityId
output ACA_NSG_NAME string = network.outputs.acaNsgName
output APPGW_SUBNET_PREFIX string = network.outputs.appGwSubnetPrefix
output PORTAL_INTERNAL_FQDN string = aca.outputs.portalFqdn
output APPGW_PUBLIC_FQDN string = appgw.outputs.publicFqdn
output APPGW_PUBLIC_IP string = appgw.outputs.publicIpAddress
output POSTGRES_FQDN string = db.outputs.fqdn
output POSTGRES_ADMIN_LOGIN string = db.outputs.administratorLogin
output POSTGRES_MAIN_DATABASE string = db.outputs.mainDatabase
output POSTGRES_QUERY_DATABASE string = db.outputs.queryDatabase
output KEY_VAULT_NAME string = keyvault.outputs.vaultName
output NSG_LANE_NSG_NAME string = network.outputs.nsgLaneNsgName
output NSG_LANE_ENV_NAME string = aca.outputs.nsgLaneEnvName
output LOG_ANALYTICS_WORKSPACE_ID string = monitoring.outputs.logAnalyticsWorkspaceId
output APPLICATIONINSIGHTS_NAME string = monitoring.outputs.appInsightsName
output PAGERDUTY_CONFIGURED bool = alerts.outputs.pagerDutyConfigured
output REPORTING_VM_NAME string = vm.outputs.vmName
