#requires -Version 7.0
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

function Get-LabValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Name,
        [switch] $Optional
    )

    $labRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $value = & azd -C $labRoot env get-value $Name 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace(($value -join "`n"))) {
        if ($Optional) { return $null }
        throw "Missing azd value $Name. Complete the preceding lab deployment in this azd environment first."
    }
    return ($value -join "`n").Trim()
}

function Invoke-LabDeployment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [guid] $SubscriptionId,
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $ResourceGroup,
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Name,
        [Parameter(Mandatory)]
        [string] $TemplateFile,
        [Parameter(Mandatory)]
        [hashtable] $Parameters
    )

    if (-not (Test-Path -LiteralPath $TemplateFile -PathType Leaf)) {
        throw 'The required lab template is missing. Add the template before deploying.'
    }

    $armParameters = @{}
    foreach ($key in $Parameters.Keys) {
        $armParameters[$key] = @{ value = $Parameters[$key] }
    }
    $parameterFile = [System.IO.Path]::GetTempFileName()
    try {
        @{
            '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
            contentVersion = '1.0.0.0'
            parameters = $armParameters
        } | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $parameterFile -Encoding utf8

        $result = & az deployment group create --subscription $SubscriptionId --resource-group $ResourceGroup `
            --name $Name --template-file $TemplateFile --parameters "@$parameterFile" `
            --mode Incremental --only-show-errors --output json 2>$null
        if ($LASTEXITCODE -ne 0) {
            throw "Lab deployment $Name failed. Review the deployment in Azure; no automatic retry was attempted."
        }
        try {
            $deployment = ($result -join "`n") | ConvertFrom-Json -AsHashtable
        }
        catch {
            throw 'Azure CLI returned an invalid deployment response.'
        }
        if ($deployment.properties.provisioningState -ne 'Succeeded') {
            throw "Lab deployment $Name did not report success. Review it in Azure before continuing."
        }
        return $deployment.properties.outputs
    }
    finally {
        Remove-Item -LiteralPath $parameterFile -Force
    }
}