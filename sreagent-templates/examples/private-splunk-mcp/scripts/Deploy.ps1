[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Bicep', 'Terraform')][string]$Backend,
    [string]$ResourceGroup,
    [string]$ParametersFile,
    [string]$TfVarsFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Validation.ps1')
$ExampleDir = Split-Path -Parent $PSScriptRoot

function Get-ParameterValue {
    param($Document, [string]$Name, $Default)
    $value = Get-OptionalProperty (Get-OptionalProperty (Get-OptionalProperty $Document 'parameters') $Name) 'value'
    if ($null -eq $value -or $value -eq '') { return $Default }
    return $value
}

function Get-TfVar {
    param([string]$Content, [string]$Name, [string]$Default = '')
    $match = [regex]::Match($Content, "(?m)^\s*$Name\s*=\s*`"([^`"]*)`"")
    if (-not $match.Success) { return $Default }
    return $match.Groups[1].Value
}

if ($Backend -eq 'Bicep') {
    if (-not $ResourceGroup -or -not $ParametersFile) { throw 'Bicep requires -ResourceGroup and -ParametersFile.' }
    $parameters = Get-Content $ParametersFile -Raw | ConvertFrom-Json
    $topology = Get-ParameterValue $parameters 'topology' ''
    $agentLocation = Get-ParameterValue $parameters 'agentLocation' 'eastus2'
    $splunkLocation = Get-ParameterValue $parameters 'splunkLocation' $agentLocation
    $agentVnet = Get-ParameterValue $parameters 'agentVnetAddressPrefix' '10.100.0.0/16'
    $splunkVnet = Get-ParameterValue $parameters 'splunkVnetAddressPrefix' $agentVnet
    $agentSubnet = Get-ParameterValue $parameters 'agentSubnetPrefix' '10.100.0.0/27'
    $splunkSubnet = Get-ParameterValue $parameters 'splunkSubnetPrefix' '10.100.1.0/24'
    $privateIp = Get-ParameterValue $parameters 'splunkPrivateIp' '10.100.1.4'
    $sshKey = Get-ParameterValue $parameters 'adminSshPublicKey' ''
    Test-DeploymentInputs $topology $agentLocation $splunkLocation $agentVnet $splunkVnet $agentSubnet $splunkSubnet $privateIp $sshKey
    az group create --name $ResourceGroup --location $agentLocation --output none
    if ($LASTEXITCODE -ne 0) { throw 'Failed to create or validate the resource group.' }
    $deploymentName = "private-splunk-$topology-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    az deployment group create --resource-group $ResourceGroup --name $deploymentName --template-file (Join-Path $ExampleDir 'bicep/main.bicep') --parameters "@$ParametersFile" --output json
    if ($LASTEXITCODE -ne 0) { throw 'Bicep deployment failed.' }
    return
}

if (-not $TfVarsFile) { throw 'Terraform requires -TfVarsFile.' }
$tfvars = Get-Content $TfVarsFile -Raw
$topology = Get-TfVar $tfvars 'topology'
$agentLocation = Get-TfVar $tfvars 'agent_location' 'eastus2'
$splunkLocation = Get-TfVar $tfvars 'splunk_location' $agentLocation
$agentVnet = Get-TfVar $tfvars 'agent_vnet_address_prefix' '10.100.0.0/16'
$splunkVnet = Get-TfVar $tfvars 'splunk_vnet_address_prefix' $agentVnet
$agentSubnet = Get-TfVar $tfvars 'agent_subnet_prefix' '10.100.0.0/27'
$splunkSubnet = Get-TfVar $tfvars 'splunk_subnet_prefix' '10.100.1.0/24'
$privateIp = Get-TfVar $tfvars 'splunk_private_ip' '10.100.1.4'
$sshKey = Get-TfVar $tfvars 'admin_ssh_public_key'
Test-DeploymentInputs $topology $agentLocation $splunkLocation $agentVnet $splunkVnet $agentSubnet $splunkSubnet $privateIp $sshKey
$TfVarsFile = (Resolve-Path $TfVarsFile).Path
$TerraformDir = Join-Path $ExampleDir 'terraform'
terraform "-chdir=$TerraformDir" init
if ($LASTEXITCODE -ne 0) { throw 'terraform init failed.' }
terraform "-chdir=$TerraformDir" apply "-var-file=$TfVarsFile"
if ($LASTEXITCODE -ne 0) { throw 'terraform apply failed.' }
