[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ResourceGroup,

    [Parameter(Mandatory)]
    [string]$VmName,

    [Parameter(Mandatory)]
    [string]$PackagePath,

    [string]$AcrName,

    [switch]$EnableLabHttp
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path $PackagePath -PathType Leaf)) {
    throw "MCP package not found: $PackagePath"
}

$securePassword = Read-Host 'Splunk administrator password' -AsSecureString
$password = [System.Net.NetworkCredential]::new('', $securePassword).Password
$suffixSource = [System.Text.Encoding]::UTF8.GetBytes("$ResourceGroup-$VmName-$([Guid]::NewGuid())")
$suffixHash = [System.Security.Cryptography.SHA256]::HashData($suffixSource)
$suffix = ([Convert]::ToHexString($suffixHash)).ToLowerInvariant().Substring(0, 13)
$storageAccount = "stsplunk$suffix"
$transferResourceGroup = "splunk-transfer-$suffix"
$containerName = 'packages'
$blobName = Split-Path $PackagePath -Leaf
$runCommandName = "configure-private-splunk-$suffix"
$bootstrapScript = Get-Content (Join-Path $PSScriptRoot 'vm-bootstrap.sh') -Raw
$packageUrl = $null
$registryPassword = $null

try {
    $vmLocation = az vm show --resource-group $ResourceGroup --name $VmName --query location --output tsv
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to read the VM location.'
    }

    az group create --name $transferResourceGroup --location $vmLocation --output none
    az storage account create --resource-group $transferResourceGroup --name $storageAccount --location $vmLocation --sku Standard_LRS --kind StorageV2 --allow-blob-public-access false --output none
    az storage container create --account-name $storageAccount --name $containerName --auth-mode login --output none
    az storage blob upload --account-name $storageAccount --container-name $containerName --name $blobName --file $PackagePath --auth-mode login --overwrite --output none

    $expiry = (Get-Date).ToUniversalTime().AddHours(1).ToString('yyyy-MM-ddTHH:mmZ')
    $sas = az storage blob generate-sas --account-name $storageAccount --container-name $containerName --name $blobName --permissions r --expiry $expiry --https-only --auth-mode login --as-user --output tsv
    $packageUrl = "https://$storageAccount.blob.core.windows.net/$containerName/$blobName`?$sas"
    $protectedParameters = @("splunkPassword=$password", "packageUrl=$packageUrl")

    if ($AcrName) {
        $registryServer = az acr show --name $AcrName --query loginServer --output tsv
        $registryUsername = az acr credential show --name $AcrName --query username --output tsv
        $registryPassword = az acr credential show --name $AcrName --query 'passwords[0].value' --output tsv
        $protectedParameters += @("registryServer=$registryServer", "registryUsername=$registryUsername", "registryPassword=$registryPassword")
    }

    $parameters = @("enableLabHttp=$($EnableLabHttp.IsPresent.ToString().ToLowerInvariant())")
    az vm run-command create --resource-group $ResourceGroup --vm-name $VmName --location $vmLocation --run-command-name $runCommandName --script $bootstrapScript --parameters $parameters --protected-parameters $protectedParameters --timeout-in-seconds 1800 --output none
    if ($LASTEXITCODE -ne 0) {
        throw 'Splunk configuration failed.'
    }

    Write-Host 'Splunk and the MCP app are installed.'
    if ($EnableLabHttp) {
        Write-Warning 'Splunk MCP is using plaintext HTTP inside the isolated private lab.'
    }
    Write-Host 'Next: validate the private route, mint an encrypted MCP token, and configure the SRE Agent connector as described in README.md.'
}
finally {
    az vm run-command delete --resource-group $ResourceGroup --vm-name $VmName --run-command-name $runCommandName --yes 2>$null | Out-Null
    az group delete --name $transferResourceGroup --yes --no-wait 2>$null | Out-Null
    $password = $null
    $packageUrl = $null
    $registryPassword = $null
}
