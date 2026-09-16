[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('inject', 'reset')]
    [string] $Action
)

$ErrorActionPreference = 'Stop'
$labRoot = Split-Path $PSScriptRoot -Parent
$ticketingAppRoot = Join-Path $labRoot 'ticketingapp-source'

function Get-LabValue([string] $Name) {
    $value = & azd -C $ticketingAppRoot env get-value $Name
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($value)) {
        throw "Missing $Name. Complete azd up in this lab first."
    }
    return $value.Trim()
}

$subscription = Get-LabValue 'AZURE_SUBSCRIPTION_ID'
$resourceGroup = Get-LabValue 'AZURE_RESOURCE_GROUP'
$nsg = Get-LabValue 'LAB_NSG_NAME'
$fault = ($Action -eq 'inject').ToString().ToLowerInvariant()

if ($Action -eq 'inject') {
    $alertRuleName = "$(Get-LabValue 'LAB_NAME_PREFIX')-checkout-failures"
    $alertRuleId = "/subscriptions/$subscription/resourceGroups/$resourceGroup/providers/microsoft.insights/scheduledqueryrules/$alertRuleName"
    $endTime = [DateTime]::UtcNow
    $startTime = $endTime.AddDays(-7)
    $timeRange = [uri]::EscapeDataString("$($startTime.ToString('o'))/$($endTime.ToString('o'))")
    $alertsUrl = "https://management.azure.com/subscriptions/$subscription/providers/Microsoft.AlertsManagement/alerts?api-version=2019-03-01&customTimeRange=$timeRange"
    $armToken = & az account get-access-token --subscription $subscription --resource 'https://management.azure.com/' `
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

# This deployment owns one rule only, never the app, agent, or task configuration.
& az deployment group create --subscription $subscription --resource-group $resourceGroup `
    --name onboardinglab-fault --template-file (Join-Path $labRoot 'fault.bicep') `
    --parameters "networkSecurityGroupName=$nsg" "injectDatabaseFault=$fault" --output none
if ($LASTEXITCODE -ne 0) { throw 'Fault rule deployment failed.' }
Write-Host "Fault $Action completed. Generate new checkout traffic to verify the result."