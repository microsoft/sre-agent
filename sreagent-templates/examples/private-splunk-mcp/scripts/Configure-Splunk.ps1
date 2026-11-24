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
$containerName = 'packages'
$blobName = 'splunk-mcp-server.tgz'
$runCommandName = "configure-private-splunk-$suffix"
$bootstrapScript = Get-Content (Join-Path $PSScriptRoot 'vm-bootstrap.sh') -Raw
$bootstrapScriptBase64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($bootstrapScript))
$runCommandScript = "printf '%s' '$bootstrapScriptBase64' | base64 -d | bash -s -- `"`$@`""
$packageUrl = $null
$registryPassword = $null
$previousStorageKey = $env:AZURE_STORAGE_KEY

try {
    $vmLocation = az vm show --resource-group $ResourceGroup --name $VmName --query location --output tsv
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to read the VM location.'
    }

    az storage account create --resource-group $ResourceGroup --name $storageAccount --location $vmLocation --sku Standard_LRS --kind StorageV2 --allow-blob-public-access false --output none
    if ($LASTEXITCODE -ne 0) {
        throw 'Failed to create the temporary transfer storage account.'
    }

    $env:AZURE_STORAGE_KEY = az storage account keys list --resource-group $ResourceGroup --account-name $storageAccount --query '[0].value' --output tsv
    if ($LASTEXITCODE -ne 0 -or -not $env:AZURE_STORAGE_KEY) {
        throw 'Unable to retrieve the temporary storage account key.'
    }

    az storage container create --account-name $storageAccount --name $containerName --auth-mode key --output none
    if ($LASTEXITCODE -ne 0) {
        throw 'Failed to create the temporary blob container.'
    }

    az storage blob upload --account-name $storageAccount --container-name $containerName --name $blobName --file $PackagePath --auth-mode key --overwrite --output none
    if ($LASTEXITCODE -ne 0) {
        throw 'Failed to upload the MCP package to the temporary storage account.'
    }

    $expiry = (Get-Date).ToUniversalTime().AddHours(1).ToString('yyyy-MM-ddTHH:mmZ')
    $sas = az storage blob generate-sas --account-name $storageAccount --container-name $containerName --name $blobName --permissions r --expiry $expiry --https-only --auth-mode key --output tsv
    if ($LASTEXITCODE -ne 0 -or -not $sas) {
        throw 'Failed to generate the package SAS.'
    }
    $env:AZURE_STORAGE_KEY = $previousStorageKey
    $packageUrl = "https://$storageAccount.blob.core.windows.net/$containerName/$blobName`?$sas"
    $passwordBase64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($password))
    $packageUrlBase64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($packageUrl))
    $protectedParameters = @("splunkPasswordBase64=$passwordBase64", "packageUrlBase64=$packageUrlBase64")

    if ($AcrName) {
        $registryServer = az acr show --name $AcrName --query loginServer --output tsv
        if ($LASTEXITCODE -ne 0 -or -not $registryServer) {
            throw "Unable to read ACR '$AcrName'."
        }

        $registryUsername = az acr credential show --name $AcrName --query username --output tsv
        if ($LASTEXITCODE -ne 0 -or -not $registryUsername) {
            throw "Unable to read the admin username for ACR '$AcrName'. Confirm that its admin account is enabled."
        }

        $registryPassword = az acr credential show --name $AcrName --query 'passwords[0].value' --output tsv
        if ($LASTEXITCODE -ne 0 -or -not $registryPassword) {
            throw "Unable to read the admin password for ACR '$AcrName'. Confirm that its admin account is enabled."
        }

        $registryPasswordBase64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($registryPassword))
        $protectedParameters += @("registryServer=$registryServer", "registryUsername=$registryUsername", "registryPasswordBase64=$registryPasswordBase64")
    }

    $parameters = @("enableLabHttp=$($EnableLabHttp.IsPresent.ToString().ToLowerInvariant())")
    $runCommandArguments = @(
        'vm', 'run-command', 'create',
        '--resource-group', $ResourceGroup,
        '--vm-name', $VmName,
        '--location', $vmLocation,
        '--run-command-name', $runCommandName,
        '--script', $runCommandScript,
        '--parameters'
    ) + $parameters + @(
        '--protected-parameters'
    ) + $protectedParameters + @(
        '--timeout-in-seconds', '1800',
        '--output', 'none'
    )
    & az @runCommandArguments
    if ($LASTEXITCODE -ne 0) {
        throw 'Splunk configuration failed.'
    }

    $runCommandResult = az vm run-command show --resource-group $ResourceGroup --vm-name $VmName --run-command-name $runCommandName --instance-view --query '{exitCode:instanceView.exitCode,error:instanceView.error}' --output json | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or $runCommandResult.exitCode -ne 0) {
        throw "Splunk configuration failed on the VM: $($runCommandResult.error)"
    }

    Write-Host 'Splunk and the MCP app are installed.'
    if ($EnableLabHttp) {
        Write-Warning 'Splunk MCP is using plaintext HTTP inside the isolated private lab.'
    }
    Write-Host 'Next: validate the private route, mint an encrypted MCP token, and configure the SRE Agent connector as described in README.md.'
}
finally {
    az vm run-command delete --resource-group $ResourceGroup --vm-name $VmName --run-command-name $runCommandName --yes 2>$null | Out-Null
    az storage account delete --resource-group $ResourceGroup --name $storageAccount --yes 2>$null | Out-Null
    $env:AZURE_STORAGE_KEY = $previousStorageKey
    $password = $null
    $packageUrl = $null
    $registryPassword = $null
}
