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
SPLUNK_PASSWORD=""
SCHEME="${scheme:-}"
DAYS="${days:-}"
if [[ -n "${splunkPasswordBase64:-}" ]]; then
  SPLUNK_PASSWORD="$(printf '%s' "$splunkPasswordBase64" | base64 -d)"
fi
for argument in "$@"; do
  case "$argument" in
    splunkPasswordBase64=*) SPLUNK_PASSWORD="$(printf '%s' "${argument#*=}" | base64 -d)" ;;
    scheme=*) SCHEME="${argument#*=}" ;;
    days=*) DAYS="${argument#*=}" ;;
  esac
done
response="$(curl -sk -u "admin:${SPLUNK_PASSWORD}" "${SCHEME}://127.0.0.1:8089/services/mcp_token?username=admin&expires_on=%2B${DAYS}d")"
python3 -c 'import json,sys; data=json.load(sys.stdin); token=data.get("token"); assert token, "Token missing from response"; print(token)' <<<"$response"
'@
$script = $script.Replace("`r`n", "`n")
$scriptBase64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($script))
$runCommandScript = "printf '%s' '$scriptBase64' | base64 -d | bash -s -- `"`$@`""

try {
    $vmLocation = az vm show --resource-group $ResourceGroup --name $VmName --query location --output tsv
    if ($LASTEXITCODE -ne 0 -or -not $vmLocation) {
        throw 'Unable to read the VM location.'
    }

    $passwordBase64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($password))
    $runCommandArguments = @(
        'vm', 'run-command', 'create',
        '--resource-group', $ResourceGroup,
        '--vm-name', $VmName,
        '--location', $vmLocation,
        '--run-command-name', $runCommandName,
        '--script', $runCommandScript,
        '--parameters', "scheme=$Scheme", "days=$Days",
        '--protected-parameters', "splunkPasswordBase64=$passwordBase64",
        '--timeout-in-seconds', '300',
        '--output', 'none'
    )
    & az @runCommandArguments
    if ($LASTEXITCODE -ne 0) {
        throw 'MCP token creation failed.'
    }

    $runCommandResult = az vm run-command show --resource-group $ResourceGroup --vm-name $VmName --run-command-name $runCommandName --instance-view --query '{exitCode:instanceView.exitCode,output:instanceView.output,error:instanceView.error}' --output json | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or $runCommandResult.exitCode -ne 0) {
        throw "MCP token creation failed on the VM: $($runCommandResult.error)"
    }

    $token = $runCommandResult.output
    if ($LASTEXITCODE -ne 0 -or -not $token) {
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
