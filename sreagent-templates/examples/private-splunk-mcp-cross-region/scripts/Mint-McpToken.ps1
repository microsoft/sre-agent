[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ResourceGroup,

    [Parameter(Mandatory)]
    [string]$VmName,

    [ValidateSet('http', 'https')]
    [string]$Scheme = 'https',

    [ValidateRange(1, 180)]
    [int]$Days = 7,

    [string]$Username = 'admin'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Remove-TokenRunCommand {
    param(
        [string]$Location,
        [string]$RunCommandName,
        [bool]$ConfirmedCreated
    )

    $resourceExists = $ConfirmedCreated
    if (-not $resourceExists) {
        $showOutput = & az vm run-command show --resource-group $ResourceGroup --vm-name $VmName --run-command-name $RunCommandName --instance-view --output none 2>&1
        if ($LASTEXITCODE -eq 0) {
            $resourceExists = $true
        }
        elseif (($showOutput -join "`n") -match 'ResourceNotFound|could not be found') {
            $global:LASTEXITCODE = 0
            return $null
        }
    }

    $scrubbed = $false
    if ($resourceExists) {
        $scrubArguments = @(
            'vm', 'run-command', 'create',
            '--resource-group', $ResourceGroup,
            '--vm-name', $VmName,
            '--location', $Location,
            '--run-command-name', $RunCommandName,
            '--script', 'true',
            '--timeout-in-seconds', '60',
            '--output', 'none'
        )
        $scrubOutput = & az @scrubArguments 2>&1
        $scrubbed = $LASTEXITCODE -eq 0
    }

    $deleted = $false
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $deleteOutput = & az vm run-command delete --resource-group $ResourceGroup --vm-name $VmName --run-command-name $RunCommandName --yes 2>&1
        if ($LASTEXITCODE -eq 0 -or ($deleteOutput -join "`n") -match 'ResourceNotFound|could not be found') {
            $deleted = $true
            break
        }

        if ($attempt -lt 3) {
            Start-Sleep -Seconds ($attempt * 5)
        }
    }

    if ($deleted) {
        $verifyOutput = & az vm run-command show --resource-group $ResourceGroup --vm-name $VmName --run-command-name $RunCommandName --instance-view --output none 2>&1
        if ($LASTEXITCODE -eq 0 -or ($verifyOutput -join "`n") -notmatch 'ResourceNotFound|could not be found') {
            $deleted = $false
        }
    }

    if ($deleted) {
        $global:LASTEXITCODE = 0
        return $null
    }

    $message = "Managed Run Command cleanup failed for '$RunCommandName' on VM '$VmName' in resource group '$ResourceGroup'. " +
        "Delete it manually: az vm run-command delete --resource-group '$ResourceGroup' --vm-name '$VmName' --run-command-name '$RunCommandName' --yes."
    if (-not $scrubbed) {
        $message += ' The command output could still contain the minted token. Treat it as compromised and revoke or replace it before retrying.'
    }
    return $message
}

$securePassword = Read-Host 'Splunk administrator password' -AsSecureString
$password = [System.Net.NetworkCredential]::new('', $securePassword).Password
$runCommandName = "mint-splunk-mcp-token-$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())-$((Get-Random -Maximum 10000))"
$runCommandAttempted = $false
$runCommandCreated = $false
$vmLocation = $null
$token = $null
$primaryError = $null
$cleanupFailure = $null
$script = @'
set -euo pipefail
SPLUNK_PASSWORD=""
SCHEME="${scheme:-}"
DAYS="${days:-}"
TOKEN_USERNAME="${username:-admin}"
if [[ -n "${splunkPasswordBase64:-}" ]]; then
  SPLUNK_PASSWORD="$(printf '%s' "$splunkPasswordBase64" | base64 -d)"
fi
for argument in "$@"; do
  case "$argument" in
    splunkPasswordBase64=*) SPLUNK_PASSWORD="$(printf '%s' "${argument#*=}" | base64 -d)" ;;
    scheme=*) SCHEME="${argument#*=}" ;;
    days=*) DAYS="${argument#*=}" ;;
    username=*) TOKEN_USERNAME="${argument#*=}" ;;
  esac
done
response="$(curl -sk -u "admin:${SPLUNK_PASSWORD}" --get \
  --data-urlencode "username=${TOKEN_USERNAME}" \
  --data-urlencode "expires_on=+${DAYS}d" \
  "${SCHEME}://127.0.0.1:8089/services/mcp_token")"
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
        '--parameters', "scheme=$Scheme", "days=$Days", "username=$Username",
        '--protected-parameters', "splunkPasswordBase64=$passwordBase64",
        '--timeout-in-seconds', '300',
        '--output', 'none'
    )
    $runCommandAttempted = $true
    & az @runCommandArguments
    if ($LASTEXITCODE -ne 0) {
        throw 'MCP token creation failed.'
    }
    $runCommandCreated = $true

    $runCommandResult = az vm run-command show --resource-group $ResourceGroup --vm-name $VmName --run-command-name $runCommandName --instance-view --query '{exitCode:instanceView.exitCode,output:instanceView.output,error:instanceView.error}' --output json | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or $runCommandResult.exitCode -ne 0) {
        throw "MCP token creation failed on the VM: $($runCommandResult.error)"
    }

    $token = $runCommandResult.output
    if ($LASTEXITCODE -ne 0 -or -not $token) {
        throw 'MCP token creation returned no token.'
    }
}
catch {
    $primaryError = $_
}
finally {
    if ($runCommandAttempted) {
        $cleanupFailure = Remove-TokenRunCommand -Location $vmLocation -RunCommandName $runCommandName -ConfirmedCreated $runCommandCreated
    }
    $securePassword = $null
    $password = $null
    $passwordBase64 = $null
    $runCommandArguments = $null
}

if ($null -ne $primaryError) {
    if ($cleanupFailure) {
        Write-Warning $cleanupFailure
    }
    throw $primaryError
}

if ($cleanupFailure) {
    $token = $null
    throw $cleanupFailure
}

Write-Host ''
Write-Host 'Encrypted MCP token (shown once; store it securely and do not commit it):'
Write-Host $token.Trim()
$token = $null
