using './main.bicep'

param environmentName = readEnvironmentVariable('AZURE_ENV_NAME', 'zavaitsupport')
param location = readEnvironmentVariable('AZURE_LOCATION', 'westus2')
param prefix = 'zavaits'
