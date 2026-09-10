[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ResourceGroup,

    [Parameter(Mandatory)]
    [string]$VmName,

    [ValidateSet('http', 'https')]
    [string]$Scheme = 'https',

    [ValidateRange(1, 180)]
    [int]$Days = 7
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$securePassword = Read-Host 'Splunk administrator password' -AsSecureString
$password = [System.Net.NetworkCredential]::new('', $securePassword).Password
$runCommandName = "mint-splunk-mcp-token-$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())-$((Get-Random -Maximum 10000))"
$token = $null
$script = @'
set -euo pipefail
for argument in "$@"; do
  case "$argument" in
    splunkPassword=*) SPLUNK_PASSWORD="${argument#*=}" ;;
    scheme=*) SCHEME="${argument#*=}" ;;
    days=*) DAYS="${argument#*=}" ;;
  esac
done
response="$(curl -sk -u "admin:${SPLUNK_PASSWORD}" "${SCHEME}://127.0.0.1:8089/services/mcp_token?username=admin&expires_on=%2B${DAYS}d")"
python3 -c 'import json,sys; data=json.load(sys.stdin); token=data.get("token"); assert token, "Token missing from response"; print(token)' <<<"$response"
'@

try {
    $vmLocation = az vm show --resource-group $ResourceGroup --name $VmName --query location --output tsv
    az vm run-command create --resource-group $ResourceGroup --vm-name $VmName --location $vmLocation --run-command-name $runCommandName --script $script --parameters "scheme=$Scheme" "days=$Days" --protected-parameters "splunkPassword=$password" --timeout-in-seconds 300 --output none
    if ($LASTEXITCODE -ne 0) {
        throw 'MCP token creation failed.'
    }

    $token = az vm run-command show --resource-group $ResourceGroup --vm-name $VmName --run-command-name $runCommandName --instance-view --query instanceView.output --output tsv
    if (-not $token) {
        throw 'MCP token creation returned no token.'
    }

    Write-Host ''
    Write-Host 'Encrypted MCP token (shown once; store it securely and do not commit it):'
    Write-Host $token.Trim()
}
finally {
    az vm run-command delete --resource-group $ResourceGroup --vm-name $VmName --run-command-name $runCommandName --yes 2>$null | Out-Null
    $password = $null
    $token = $null
}
