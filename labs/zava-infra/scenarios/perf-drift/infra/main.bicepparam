using './main.bicep'

param environmentName = readEnvironmentVariable('AZURE_ENV_NAME', 'ebc-demo')
param location = readEnvironmentVariable('AZURE_LOCATION', 'eastus2')
param vmAdminPassword = readEnvironmentVariable('VM_ADMIN_PASSWORD', '')
