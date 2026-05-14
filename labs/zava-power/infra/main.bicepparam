using './main.bicep'

param location = readEnvironmentVariable('AZURE_LOCATION', 'eastus2')
param workloadName = readEnvironmentVariable('POWERGRID_WORKLOAD_NAME', 'powergrid')
param computePlatform = readEnvironmentVariable('COMPUTE_PLATFORM', 'aca')
param deployArcVm = bool(readEnvironmentVariable('DEPLOY_ARC_VM', 'false'))
param imageTag = readEnvironmentVariable('IMAGE_TAG', 'latest')
param rbacTier = readEnvironmentVariable('RBAC_TIER', 'custom')
param agentOperatorRoleId = readEnvironmentVariable('AGENT_OPERATOR_ROLE_ID', '')
