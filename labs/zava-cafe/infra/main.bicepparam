using './main.bicep'

param environmentName = readEnvironmentVariable('AZURE_ENV_NAME', 'zavacafe')
param location = readEnvironmentVariable('AZURE_LOCATION', 'westus2')
param prefix = 'zava'
param alertEmail = readEnvironmentVariable('ALERT_EMAIL', '')
param aadAdminLogin = readEnvironmentVariable('AAD_ADMIN_LOGIN', '')
param aadAdminObjectId = readEnvironmentVariable('AAD_ADMIN_OBJECT_ID', '')
