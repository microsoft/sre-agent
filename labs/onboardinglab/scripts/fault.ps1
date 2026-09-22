[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('inject', 'reset')]
    [string] $Action,

    [string] $Subscription,

    [string] $ResourceGroup,

    [string] $NetworkSecurityGroupName,

    [string] $AppName,

    [ValidateSet('app-service', 'app-service-postgresql')]
    [string] $WorkloadOption,

    [string] $NamePrefix
)

$ErrorActionPreference = 'Stop'
$labRoot = Split-Path $PSScriptRoot -Parent
$ticketingAppRoot = Join-Path $labRoot 'ticketingapp-source'

$script:AzdAvailable = $null

function Test-AzdAvailable {
    if ($null -eq $script:AzdAvailable) {
        $script:AzdAvailable = [bool](Get-Command azd -ErrorAction SilentlyContinue)
    }
    return $script:AzdAvailable
}

# Prefer an explicitly supplied value, then fall back to the azd environment.
# azd is not present in every environment (for example an agent sandbox), so the
# lab must stay usable by passing the values directly.
function Get-LabValue {
    param(
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][string] $ParameterName,
        [string] $Override
    )

    if (-not [string]::IsNullOrWhiteSpace($Override)) { return $Override.Trim() }

    if (-not (Test-AzdAvailable)) {
        throw "Missing $Name and azd is not installed. Pass -$ParameterName explicitly."
    }

    $value = & azd -C $ticketingAppRoot env get-value $Name
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($value)) {
        throw "Missing $Name. Complete azd up in this lab first, or pass -$ParameterName explicitly."
    }
    return $value.Trim()
}

$subId  = Get-LabValue -Name 'AZURE_SUBSCRIPTION_ID' -ParameterName 'Subscription' -Override $Subscription
$rgName = Get-LabValue -Name 'AZURE_RESOURCE_GROUP' -ParameterName 'ResourceGroup' -Override $ResourceGroup
$selectedOption = $WorkloadOption
if ([string]::IsNullOrWhiteSpace($selectedOption)) {
    if (Test-AzdAvailable) {
        $selectedOption = Get-LabValue -Name 'LAB_WORKLOAD_OPTION' -ParameterName 'WorkloadOption'
    }
    else {
        $selectedOption = (& az group show --subscription $subId --name $rgName `
            --query tags.onboardingLabWorkloadOption --output tsv).Trim()
    }
}
if ($selectedOption -notin @('app-service', 'app-service-postgresql')) {
    throw "Unsupported LAB_WORKLOAD_OPTION: $selectedOption"
}
$fault = ($Action -eq 'inject').ToString().ToLowerInvariant()

if ($Action -eq 'inject') {
    $alertRuleName = "$(Get-LabValue -Name 'LAB_NAME_PREFIX' -ParameterName 'NamePrefix' -Override $NamePrefix)-checkout-failures"
    $alertRuleId = "/subscriptions/$subId/resourceGroups/$rgName/providers/microsoft.insights/scheduledqueryrules/$alertRuleName"
    $endTime = [DateTime]::UtcNow
    $startTime = $endTime.AddDays(-7)
    $timeRange = [uri]::EscapeDataString("$($startTime.ToString('o'))/$($endTime.ToString('o'))")
    $alertsUrl = "https://management.azure.com/subscriptions/$subId/providers/Microsoft.AlertsManagement/alerts?api-version=2019-03-01&customTimeRange=$timeRange"
    $armToken = & az account get-access-token --subscription $subId --resource 'https://management.azure.com/' `
        --query accessToken --only-show-errors --output tsv 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace(($armToken -join ''))) {
        throw 'Unable to obtain an ARM token before injecting the fault.'
    }
    $headers = @{ Authorization = 'Bearer ' + ($armToken -join '').Trim() }
    try { $alerts = (Invoke-RestMethod -Uri $alertsUrl -Method Get -Headers $headers).value }
    catch { throw 'Unable to inspect prior checkout alerts before injecting the fault.' }

    $priorAlerts = @($alerts | Where-Object { $_.properties.essentials.alertRule -ieq $alertRuleId })
    foreach ($alert in $priorAlerts) {
        $essentials = $alert.properties.essentials
        if ($essentials.alertState -ieq 'Closed') { continue }
        if ($essentials.monitorCondition -ine 'Resolved') {
            throw 'A prior checkout alert is still fired. Reset the fault, generate successful traffic, and wait for the alert to resolve before reinjecting.'
        }
        $changeStateUrl = "https://management.azure.com$($alert.id)/changestate?api-version=2019-03-01&newState=Closed"
        $body = @{ comments = 'Closed by the Azure SRE Agent Onboarding Lab fault helper before a new rehearsal.' } | ConvertTo-Json -Compress
        try {
            $null = Invoke-RestMethod -Uri $changeStateUrl -Method Post -Headers $headers `
                -ContentType 'application/json' -Body $body
        }
        catch { throw 'Unable to close the prior checkout alert before injecting the fault.' }
    }
    $headers.Clear()
    $armToken = $null
}

if ($selectedOption -eq 'app-service') {
    $checkoutAppName = $AppName
    if ([string]::IsNullOrWhiteSpace($checkoutAppName)) {
        $checkoutAppName = (& az webapp list --subscription $subId --resource-group $rgName `
            --query "[?tags.workloadOption=='app-service'].name | [0]" --output tsv).Trim()
    }
    if ([string]::IsNullOrWhiteSpace($checkoutAppName)) { throw 'Could not discover the App Service checkout app.' }
    & az webapp config appsettings set --subscription $subId --resource-group $rgName `
        --name $checkoutAppName --settings "APP_FAULT_ENABLED=$fault" --output none
    if ($LASTEXITCODE -ne 0) { throw 'App Service fault update failed.' }
}
else {
    $nsgName = $NetworkSecurityGroupName
    if ([string]::IsNullOrWhiteSpace($nsgName)) {
        $nsgName = (& az network nsg list --subscription $subId --resource-group $rgName `
            --query "[?contains(name, '-app-nsg')].name | [0]" --output tsv).Trim()
    }
    if ([string]::IsNullOrWhiteSpace($nsgName)) { throw 'Could not discover the PostgreSQL fault NSG.' }
    # This deployment owns one rule only, never the app, agent, or task configuration.
    & az deployment group create --subscription $subId --resource-group $rgName `
        --name onboardinglab-fault --template-file (Join-Path $labRoot 'fault.bicep') `
        --parameters "networkSecurityGroupName=$nsgName" "injectDatabaseFault=$fault" --output none
    if ($LASTEXITCODE -ne 0) { throw 'Database fault rule deployment failed.' }
}
Write-Host "Fault $Action completed. Generate new checkout traffic to verify the result."