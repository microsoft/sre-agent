$script:SreAgentRegionsDocUrl = 'https://learn.microsoft.com/azure/sre-agent/supported-regions'
$script:SreAgentRegionsFile = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'supported-regions.json'

function Resolve-AzureSubscription {
    param([string]$Subscription)

    if ($Subscription) { return $Subscription }

    $resolved = (az account show --query id -o tsv 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $resolved) {
        throw "No Azure subscription selected. Run 'az login' and 'az account set --subscription <id>', or pass -Subscription."
    }
    return $resolved
}

function Get-SreAgentRegions {
    param([Parameter(Mandatory)][string]$Subscription)

    $advertisedJson = az provider show `
        --subscription $Subscription `
        --namespace Microsoft.App `
        --query "resourceTypes[?resourceType=='agents'].locations | [0]" `
        -o json 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to query Azure SRE Agent regions for subscription '$Subscription'."
    }

    $advertised = @($advertisedJson | ConvertFrom-Json)
    if ($advertised.Count -eq 0) {
        throw "Azure SRE Agent returned no available regions for subscription '$Subscription'. See $script:SreAgentRegionsDocUrl"
    }

    $locationsJson = az rest `
        --method GET `
        --url "https://management.azure.com/subscriptions/$Subscription/locations?api-version=2022-12-01" `
        --query 'value[].{name:name,displayName:displayName}' `
        -o json 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to resolve Azure region names for subscription '$Subscription'."
    }

    $locations = @($locationsJson | ConvertFrom-Json)
    $regions = @($locations |
        Where-Object { $advertised -contains $_.displayName } |
        Select-Object -ExpandProperty name -Unique |
        Sort-Object)
    if ($regions.Count -eq 0) {
        throw "Azure SRE Agent returned no canonical regions for subscription '$Subscription'. See $script:SreAgentRegionsDocUrl"
    }
    return $regions
}

function Get-SreAgentRegionsOrFallback {
    param([Parameter(Mandatory)][string]$Subscription)

    try {
        return @(Get-SreAgentRegions -Subscription $Subscription)
    }
    catch {
        Write-Warning "$($_.Exception.Message) Using the checked-in region list. See $script:SreAgentRegionsDocUrl"
        return @(Get-Content $script:SreAgentRegionsFile -Raw | ConvertFrom-Json)
    }
}

function Assert-SreAgentRegion {
    param(
        [Parameter(Mandatory)][string]$Subscription,
        [Parameter(Mandatory)][string]$Region
    )

    $regions = @(Get-SreAgentRegions -Subscription $Subscription)
    if ($regions -notcontains $Region) {
        throw "Region '$Region' is not available for Azure SRE Agent in subscription '$Subscription'. Available regions: $($regions -join ', '). See $script:SreAgentRegionsDocUrl"
    }
}