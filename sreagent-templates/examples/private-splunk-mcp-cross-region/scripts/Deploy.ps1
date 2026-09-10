[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Bicep', 'Terraform')]
    [string]$Backend,

    [string]$ResourceGroup,

    [string]$ParametersFile,

    [string]$TfVarsFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ExampleDir = Split-Path -Parent $PSScriptRoot

if ($Backend -eq 'Bicep') {
    if (-not $ResourceGroup -or -not $ParametersFile) {
        throw 'Bicep requires -ResourceGroup and -ParametersFile.'
    }

    $parameters = Get-Content $ParametersFile -Raw | ConvertFrom-Json
    $location = $parameters.parameters.agentLocation.value
    if (-not $location) {
        $location = 'eastus2'
    }

    az group create --name $ResourceGroup --location $location --output none
    if ($LASTEXITCODE -ne 0) {
        throw 'Failed to create or validate the resource group.'
    }

    $deploymentName = "private-splunk-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    az deployment group create --resource-group $ResourceGroup --name $deploymentName --template-file (Join-Path $ExampleDir 'bicep/main.bicep') --parameters "@$ParametersFile" --output json
    if ($LASTEXITCODE -ne 0) {
        throw 'Bicep deployment failed.'
    }
    return
}

if (-not $TfVarsFile) {
    throw 'Terraform requires -TfVarsFile.'
}

$TfVarsFile = (Resolve-Path $TfVarsFile).Path
$TerraformDir = Join-Path $ExampleDir 'terraform'
terraform "-chdir=$TerraformDir" init
if ($LASTEXITCODE -ne 0) {
    throw 'terraform init failed.'
}

terraform "-chdir=$TerraformDir" apply "-var-file=$TfVarsFile"
if ($LASTEXITCODE -ne 0) {
    throw 'terraform apply failed.'
}
