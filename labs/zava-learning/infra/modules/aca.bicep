// Internal, VNet-integrated Container Apps environment hosting the three
// learning services. learner-portal is exposed at the VNet boundary (fronted by
// App Gateway); the two APIs are environment-internal only.
@description('Azure region for all resources.')
param location string
@description('Resource name suffix token.')
param resourceToken string
@description('Tags applied to all resources.')
param tags object = {}

@description('Subnet id for the Container Apps infrastructure.')
param acaSubnetId string
@description('User-assigned identity resource id (for ACR pull).')
param identityId string
@description('ACR login server.')
param registryLoginServer string
@description('Log Analytics customer id.')
param logAnalyticsCustomerId string
@description('Log Analytics workspace name (same RG) for the shared key lookup.')
param logAnalyticsWorkspaceName string
@description('Application Insights connection string.')
param appInsightsConnectionString string
@description('Container image for each service (placeholder until azd deploy).')
param portalImage string = 'mcr.microsoft.com/k8se/quickstart:latest'
param courseApiImage string = 'mcr.microsoft.com/k8se/quickstart:latest'
param assessmentApiImage string = 'mcr.microsoft.com/k8se/quickstart:latest'

@description('''Assessment API replica bounds. Healthy default is 1..3.
chaos/break-app.ps1 sets both to 0 (scale-to-zero) so quiz launches 502; the SRE
Agent must restore the replica floor (mitigate live + IaC PR back to 1..3).''')
param assessmentMinReplicas int = 1
param assessmentMaxReplicas int = 3

// ── Parallel "lanes" ──────────────────────────────────────────────────────────
// Each lane is a self-contained copy of the assessment API (serves /health and
// /quiz/*) fronted by the existing App Gateway on its own port. One fault per lane
// so all four scenarios can run at once, each independently observable/recoverable.
@description('Subnet id for the isolated nsg-lane Container Apps environment (2nd env).')
param nsgLaneSubnetId string

@description('''quiz-app (app lane) replica bounds. Healthy default 1..3;
chaos/break-app.ps1 sets both to 0 so only the app lane returns 502.''')
param appLaneMinReplicas int = 1
param appLaneMaxReplicas int = 3

@description('Image for the DB-backed quiz-service lanes (placeholder until post-provision builds it).')
param quizServiceImage string = 'mcr.microsoft.com/k8se/quickstart:latest'
@description('''Image for the perf lane specifically. Healthy = the clean quiz-service image;
chaos/break-perf.ps1 sets this to the quiz-service:v1.1 (slow) tag (a real bad deploy).''')
param quizPerfImage string = 'mcr.microsoft.com/k8se/quickstart:latest'
@description('Image for gradebook-api (placeholder until post-provision builds it).')
param gradebookApiImage string = 'mcr.microsoft.com/k8se/quickstart:latest'

// ── Database wiring (Postgres + Key Vault) ───────────────────────────────────
@description('PostgreSQL fully-qualified domain name.')
param pgFqdn string
@description('PostgreSQL admin login (used by the baseline + most lanes).')
param pgAdminLogin string
@description('Login for the dedicated app_pool role (pool lane).')
param pgPoolLogin string = 'app_pool'
@description('Shared database name (baseline + all lanes except query).')
param pgMainDatabase string
@description('Query-lane database name (own DB so its index drop is isolated).')
param pgQueryDatabase string
@description('Key Vault secret URI for the real DB password (baseline + most lanes).')
param secretUriDbPassword string
@description('Key Vault secret URI for the secret-lane DB password copy.')
param secretUriSecretLane string
@description('Key Vault secret URI for the app_pool role password (pool lane).')
param secretUriPoolPassword string

resource env 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: 'cae-zava-${resourceToken}'
  location: location
  tags: tags
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalyticsCustomerId
        sharedKey: listKeys(resourceId('Microsoft.OperationalInsights/workspaces', logAnalyticsWorkspaceName), '2023-09-01').primarySharedKey
      }
    }
    vnetConfiguration: {
      internal: true
      infrastructureSubnetId: acaSubnetId
    }
    workloadProfiles: [
      { name: 'Consumption', workloadProfileType: 'Consumption' }
    ]
  }
}

var commonIdentity = {
  type: 'UserAssigned'
  userAssignedIdentities: {
    '${identityId}': {}
  }
}
var commonRegistries = [
  { server: registryLoginServer, identity: identityId }
]

resource courseApi 'Microsoft.App/containerApps@2024-03-01' = {
  name: 'course-api'
  location: location
  tags: union(tags, { 'azd-service-name': 'course-api' })
  identity: commonIdentity
  properties: {
    managedEnvironmentId: env.id
    configuration: {
      activeRevisionsMode: 'Single'
      registries: commonRegistries
      ingress: {
        external: false
        targetPort: 8080
        transport: 'auto'
      }
    }
    template: {
      containers: [
        {
          name: 'course-api'
          image: courseApiImage
          resources: { cpu: json('0.5'), memory: '1Gi' }
          env: [
            { name: 'PORT', value: '8080' }
            { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: appInsightsConnectionString }
          ]
        }
      ]
      scale: { minReplicas: 1, maxReplicas: 3 }
    }
  }
}

resource assessmentApi 'Microsoft.App/containerApps@2024-03-01' = {
  name: 'assessment-api'
  location: location
  tags: union(tags, { 'azd-service-name': 'assessment-api' })
  identity: commonIdentity
  properties: {
    managedEnvironmentId: env.id
    configuration: {
      activeRevisionsMode: 'Single'
      registries: commonRegistries
      ingress: {
        external: false
        targetPort: 8080
        transport: 'auto'
      }
    }
    template: {
      containers: [
        {
          name: 'assessment-api'
          image: assessmentApiImage
          resources: { cpu: json('0.5'), memory: '1Gi' }
          env: [
            { name: 'PORT', value: '8080' }
            { name: 'COURSE_API_URL', value: 'https://course-api.internal.${env.properties.defaultDomain}' }
            { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: appInsightsConnectionString }
          ]
        }
      ]
      scale: { minReplicas: assessmentMinReplicas, maxReplicas: assessmentMaxReplicas }
    }
  }
  dependsOn: [ courseApi ]
}

resource portal 'Microsoft.App/containerApps@2024-03-01' = {
  name: 'learner-portal'
  location: location
  tags: union(tags, { 'azd-service-name': 'learner-portal' })
  identity: commonIdentity
  properties: {
    managedEnvironmentId: env.id
    configuration: {
      activeRevisionsMode: 'Single'
      registries: commonRegistries
      ingress: {
        external: true
        targetPort: 8080
        transport: 'auto'
      }
    }
    template: {
      containers: [
        {
          name: 'learner-portal'
          image: portalImage
          resources: { cpu: json('0.5'), memory: '1Gi' }
          env: [
            { name: 'PORT', value: '8080' }
            { name: 'COURSE_API_URL', value: 'https://course-api.internal.${env.properties.defaultDomain}' }
            { name: 'ASSESSMENT_API_URL', value: 'https://assessment-api.internal.${env.properties.defaultDomain}' }
            { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: appInsightsConnectionString }
          ]
        }
      ]
      scale: { minReplicas: 1, maxReplicas: 3 }
    }
  }
  dependsOn: [ assessmentApi ]
}

// ── gradebook-api (DB-backed, environment-internal) ───────────────────────────
resource gradebookApi 'Microsoft.App/containerApps@2024-03-01' = {
  name: 'gradebook-api'
  location: location
  tags: union(tags, { 'azd-service-name': 'gradebook-api' })
  identity: commonIdentity
  properties: {
    managedEnvironmentId: env.id
    configuration: {
      activeRevisionsMode: 'Single'
      registries: commonRegistries
      secrets: [ { name: 'pg-password', keyVaultUrl: secretUriDbPassword, identity: identityId } ]
      ingress: { external: false, targetPort: 8080, transport: 'auto' }
    }
    template: {
      containers: [
        {
          name: 'gradebook-api'
          image: gradebookApiImage
          resources: { cpu: json('0.25'), memory: '0.5Gi' }
          env: [
            { name: 'PORT', value: '8080' }
            { name: 'PGHOST', value: pgFqdn }
            { name: 'PGPORT', value: '5432' }
            { name: 'PGDATABASE', value: pgMainDatabase }
            { name: 'PGUSER', value: pgAdminLogin }
            { name: 'PGPASSWORD', secretRef: 'pg-password' }
            { name: 'PG_SSL', value: 'require' }
            { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: appInsightsConnectionString }
          ]
        }
      ]
      scale: { minReplicas: 1, maxReplicas: 2 }
    }
  }
}

// ── Parallel quiz lanes in the MAIN environment ───────────────────────────────
// Each is the same DB-backed quiz-service image, differing only in which DB/role/secret
// it uses — so each fault is isolated to one lane. external:true => reachable over the
// VNet by the App Gateway (same pattern as the portal).
var mainLanes = [
  { appName: 'quiz-appgw',  image: quizServiceImage, database: pgMainDatabase,  user: pgAdminLogin, secretUri: secretUriDbPassword,   minReplicas: 1,                 maxReplicas: 3 }
  { appName: 'quiz-app',    image: quizServiceImage, database: pgMainDatabase,  user: pgAdminLogin, secretUri: secretUriDbPassword,   minReplicas: appLaneMinReplicas, maxReplicas: appLaneMaxReplicas }
  { appName: 'quiz-perf',   image: quizPerfImage,    database: pgMainDatabase,  user: pgAdminLogin, secretUri: secretUriDbPassword,   minReplicas: 1,                 maxReplicas: 3 }
  { appName: 'quiz-query',  image: quizServiceImage, database: pgQueryDatabase, user: pgAdminLogin, secretUri: secretUriDbPassword,   minReplicas: 1,                 maxReplicas: 3 }
  { appName: 'quiz-pool',   image: quizServiceImage, database: pgMainDatabase,  user: pgPoolLogin,  secretUri: secretUriPoolPassword, minReplicas: 1,                 maxReplicas: 3 }
  { appName: 'quiz-secret', image: quizServiceImage, database: pgMainDatabase,  user: pgAdminLogin, secretUri: secretUriSecretLane,   minReplicas: 1,                 maxReplicas: 3 }
]

resource quizLanes 'Microsoft.App/containerApps@2024-03-01' = [for lane in mainLanes: {
  name: lane.appName
  location: location
  tags: union(tags, { 'azd-service-name': lane.appName })
  identity: commonIdentity
  properties: {
    managedEnvironmentId: env.id
    configuration: {
      activeRevisionsMode: 'Single'
      registries: commonRegistries
      secrets: [ { name: 'pg-password', keyVaultUrl: lane.secretUri, identity: identityId } ]
      ingress: { external: true, targetPort: 8080, transport: 'auto' }
    }
    template: {
      containers: [
        {
          name: lane.appName
          image: lane.image
          resources: { cpu: json('0.25'), memory: '0.5Gi' }
          env: [
            { name: 'PORT', value: '8080' }
            { name: 'PGHOST', value: pgFqdn }
            { name: 'PGPORT', value: '5432' }
            { name: 'PGDATABASE', value: lane.database }
            { name: 'PGUSER', value: lane.user }
            { name: 'PGPASSWORD', secretRef: 'pg-password' }
            { name: 'PG_SSL', value: 'require' }
            { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: appInsightsConnectionString }
          ]
        }
      ]
      scale: { minReplicas: lane.minReplicas, maxReplicas: lane.maxReplicas }
    }
  }
}]

// ── nsg lane: its OWN environment in a dedicated NSG-controlled subnet ─────────
// One ACA env = one subnet = one NSG, so the NSG-misconfig fault must target this env's
// subnet to stay isolated from the other lanes.
resource envNsg 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: 'cae-zava-nsglane-${resourceToken}'
  location: location
  tags: tags
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalyticsCustomerId
        sharedKey: listKeys(resourceId('Microsoft.OperationalInsights/workspaces', logAnalyticsWorkspaceName), '2023-09-01').primarySharedKey
      }
    }
    vnetConfiguration: {
      internal: true
      infrastructureSubnetId: nsgLaneSubnetId
    }
    workloadProfiles: [
      { name: 'Consumption', workloadProfileType: 'Consumption' }
    ]
  }
}

resource quizNsg 'Microsoft.App/containerApps@2024-03-01' = {
  name: 'quiz-nsg'
  location: location
  tags: union(tags, { 'azd-service-name': 'quiz-nsg' })
  identity: commonIdentity
  properties: {
    managedEnvironmentId: envNsg.id
    configuration: {
      activeRevisionsMode: 'Single'
      registries: commonRegistries
      secrets: [ { name: 'pg-password', keyVaultUrl: secretUriDbPassword, identity: identityId } ]
      ingress: { external: true, targetPort: 8080, transport: 'auto' }
    }
    template: {
      containers: [
        {
          name: 'quiz-nsg'
          image: quizServiceImage
          resources: { cpu: json('0.25'), memory: '0.5Gi' }
          env: [
            { name: 'PORT', value: '8080' }
            { name: 'PGHOST', value: pgFqdn }
            { name: 'PGPORT', value: '5432' }
            { name: 'PGDATABASE', value: pgMainDatabase }
            { name: 'PGUSER', value: pgAdminLogin }
            { name: 'PGPASSWORD', secretRef: 'pg-password' }
            { name: 'PG_SSL', value: 'require' }
            { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: appInsightsConnectionString }
          ]
        }
      ]
      scale: { minReplicas: 1, maxReplicas: 3 }
    }
  }
}

output environmentId string = env.id
output environmentName string = env.name
output defaultDomain string = env.properties.defaultDomain
output environmentStaticIp string = env.properties.staticIp
output portalFqdn string = portal.properties.configuration.ingress.fqdn
output portalAppName string = portal.name
output mainLaneFqdns array = [for (lane, i) in mainLanes: { name: lane.appName, fqdn: quizLanes[i].properties.configuration.ingress.fqdn }]
output nsgLaneFqdn string = quizNsg.properties.configuration.ingress.fqdn
output nsgLaneEnvName string = envNsg.name
output nsgLaneDefaultDomain string = envNsg.properties.defaultDomain
output nsgLaneStaticIp string = envNsg.properties.staticIp
