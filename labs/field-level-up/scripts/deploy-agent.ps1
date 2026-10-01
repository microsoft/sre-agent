#requires -Version 7.0
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
. (Join-Path $PSScriptRoot 'internal/LabEnvironment.ps1')
$labRoot = Split-Path $PSScriptRoot -Parent

$subscription = [guid](Get-LabValue 'AZURE_SUBSCRIPTION_ID')
$resourceGroup = Get-LabValue 'AZURE_RESOURCE_GROUP'
$templateFile = Join-Path $labRoot 'agent-setup/main.bicep'
if (-not (Test-Path -LiteralPath $templateFile -PathType Leaf)) {
    throw 'The Part 2 agent template is missing. Add it before deploying.'
}

# Do not change the user's active subscription. Graph must use the target tenant's user.
$accountJson = & az account show --subscription $subscription --only-show-errors --output json 2>$null
if ($LASTEXITCODE -ne 0) { throw 'Sign in to Azure CLI with access to the lab subscription.' }
try { $account = ($accountJson -join "`n") | ConvertFrom-Json }
catch { throw 'Unable to read the lab subscription account.' }
$activeTenant = & az account show --query tenantId --only-show-errors --output tsv 2>$null
if ($LASTEXITCODE -ne 0 -or $account.user.type -ne 'user' -or
    [string]::IsNullOrWhiteSpace($account.tenantId) -or
    ($activeTenant -join '').Trim() -ne $account.tenantId) {
    throw 'Sign in as a user and select an Azure CLI account in the lab subscription tenant, then rerun.'
}

$principalId = Get-LabValue 'AZURE_PRINCIPAL_ID' -Optional
$signedInUser = & az ad signed-in-user show --query id --only-show-errors --output tsv 2>$null
if ($LASTEXITCODE -ne 0) { throw 'Unable to resolve the signed-in user in the lab subscription tenant.' }
$signedInUserId = [guid](($signedInUser -join '').Trim())
if ($principalId -and [guid]$principalId -ne $signedInUserId) {
    throw 'AZURE_PRINCIPAL_ID differs from the signed-in user. Review the azd identity manually before deploying.'
}
if (-not $principalId) { $principalId = $signedInUserId.ToString() }

$applicationInsightsId = Get-LabValue 'APPLICATION_INSIGHTS_ID'
$insightsPrefix = "/subscriptions/$subscription/resourceGroups/$resourceGroup/providers/Microsoft.Insights/components/"
if ($applicationInsightsId -notmatch ('^' + [regex]::Escape($insightsPrefix) + '[A-Za-z0-9_.()-]+\z')) {
    throw 'APPLICATION_INSIGHTS_ID must identify an Application Insights component in the lab resource group.'
}
$parameters = @{
    location = Get-LabValue 'AZURE_LOCATION'
    namePrefix = Get-LabValue 'LAB_NAME_PREFIX'
    principalId = $principalId
    applicationInsightsName = $applicationInsightsId.Split('/')[-1]
    checkoutAppId = Get-LabValue 'CHECKOUT_APP_ID'
    postgresServerId = Get-LabValue 'POSTGRES_SERVER_ID'
    networkSecurityGroupName = Get-LabValue 'LAB_NSG_NAME'
}
$outputs = Invoke-LabDeployment -SubscriptionId $subscription -ResourceGroup $resourceGroup `
    -Name 'field-level-up-agent' -TemplateFile $templateFile -Parameters $parameters

$environmentOutputs = [ordered]@{
    SRE_AGENT_NAME = 'agentName'
    SRE_AGENT_RESOURCE_ID = 'agentId'
    SRE_AGENT_URL = 'agentUrl'
    SRE_AGENT_ENDPOINT = 'agentEndpoint'
}
foreach ($outputName in $environmentOutputs.Values) {
    if ($outputs[$outputName].value -isnot [string] -or [string]::IsNullOrWhiteSpace($outputs[$outputName].value)) {
        throw "The agent deployment is missing output $outputName. No azd values have been updated."
    }
}
$expectedId = "/subscriptions/$subscription/resourceGroups/$resourceGroup/providers/Microsoft.App/agents/$($outputs.agentName.value)"
if ($outputs.agentName.value -notmatch '^[A-Za-z0-9][A-Za-z0-9-]*\z' -or $outputs.agentId.value -ine $expectedId) {
    throw 'The deployment returned an unexpected agent identity. No azd values have been updated.'
}
foreach ($entry in $environmentOutputs.GetEnumerator()) {
    & azd -C $labRoot env set $entry.Key $outputs[$entry.Value].value --no-prompt 1>$null 2>$null
    if ($LASTEXITCODE -ne 0) { throw "Unable to save $($entry.Key) in azd. Review the environment before continuing." }
}

& (Join-Path $labRoot 'agent-setup/apply-permissions.ps1') -SubscriptionId $subscription -ResourceId $expectedId
Write-Host 'Agent deployment and permission setup completed. Verify source Code Access, then connect GitHub issue access and email manually before enabling incidents.'