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

function Get-OptionalProperty {
    param($InputObject, [string]$Name)

    if ($null -eq $InputObject) {
        return $null
    }

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

function Get-ParameterValue {
    param($Document, [string]$Name)

    return Get-OptionalProperty (Get-OptionalProperty (Get-OptionalProperty $Document 'parameters') $Name) 'value'
}

$ExampleDir = Split-Path -Parent $PSScriptRoot

if ($Backend -eq 'Bicep') {
    if (-not $ResourceGroup -or -not $ParametersFile) {
        throw 'Bicep requires -ResourceGroup and -ParametersFile.'
    }

    $parameters = Get-Content $ParametersFile -Raw | ConvertFrom-Json
    $location = Get-ParameterValue $parameters 'agentLocation'
    if (-not $location) {
        $location = 'eastus2'
    }

    $splunkLocation = Get-ParameterValue $parameters 'splunkLocation'
    if (-not $splunkLocation) {
        $splunkLocation = 'centralus'
    }

    if ($location -eq $splunkLocation) {
        throw "agentLocation and splunkLocation must be different to exercise cross-region connectivity (both are '$location')."
    }

    $sshKey = Get-ParameterValue $parameters 'adminSshPublicKey'
    if ($sshKey -notmatch '^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp(256|384|521)) [A-Za-z0-9+/]+={0,3}( .*)?$') {
        throw "adminSshPublicKey must be a valid OpenSSH public key. Replace the placeholder in $ParametersFile."
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
