#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [guid]$Subscription,
    [Parameter(Mandatory)]
    [ValidatePattern('^[a-z0-9]+$')]
    [string]$Location
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

function Read-AzureJson {
    param([string[]]$Arguments)
    $result = & az @Arguments --only-show-errors --output json
    if ($LASTEXITCODE -ne 0) {
        throw "Azure preflight failed: az $($Arguments -join ' '). No resources were deployed."
    }
    try { return ($result -join "`n") | ConvertFrom-Json }
    catch { throw "Azure preflight returned invalid JSON for: az $($Arguments -join ' ')." }
}

foreach ($command in @('az', 'azd', 'node', 'npm', 'jq')) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        throw "Missing $command. Run the documented prerequisite setup, then retry."
    }
}
$account = Read-AzureJson -Arguments @('account', 'show', '--subscription', "$Subscription")
if ($account.id -ne "$Subscription" -or $account.state -ne 'Enabled') {
    throw 'The selected subscription is not enabled or its identity could not be verified.'
}
$provider = Read-AzureJson -Arguments @('provider', 'show', '--subscription', "$Subscription", '--namespace', 'Microsoft.App')
$agentType = @($provider.resourceTypes | Where-Object resourceType -eq 'agents')
$available = @($agentType.locations | ForEach-Object { ($_ -replace '\s', '').ToLowerInvariant() })
if ($Location -notin $available) {
    throw "SRE Agent is not advertised in $Location for this subscription. Choose a supported location."
}
$capabilities = @(Read-AzureJson -Arguments @(
    'postgres', 'flexible-server', 'list-skus', '--subscription', "$Subscription", '--location', $Location
))
$versions = @($capabilities | ForEach-Object { $_.supportedServerVersions } | ForEach-Object { $_.name })
$editions = @($capabilities | ForEach-Object { $_.supportedServerEditions })
$skus = @($editions | ForEach-Object { $_.supportedServerSkus } | ForEach-Object { $_.name })
if ('16' -notin $versions -or 'Standard_B1ms' -notin $skus) {
    $reasons = @($capabilities | ForEach-Object { $_.reason } | Where-Object { $_ })
    throw "PostgreSQL 16 / Standard_B1ms is not advertised in $Location for this subscription. $($reasons -join ' ') No resources were deployed."
}
foreach ($namespace in @('Microsoft.App', 'Microsoft.Web', 'Microsoft.Network', 'Microsoft.DBforPostgreSQL', 'Microsoft.Insights', 'Microsoft.OperationalInsights', 'Microsoft.AlertsManagement', 'Microsoft.ManagedIdentity')) {
    $registration = Read-AzureJson -Arguments @('provider', 'show', '--subscription', "$Subscription", '--namespace', $namespace)
    if ($registration.registrationState -ne 'Registered') {
        throw "Provider $namespace is $($registration.registrationState). Ask the subscription owner to approve registration, then retry."
    }
}
[pscustomobject]@{
    Subscription = $account.id
    Location = $Location
    PostgreSql = '16 / Standard_B1ms advertised'
    ProviderRegistration = 'Ready'
    RemainingChecks = 'Deployment approval, role-assignment permission, App Service capacity, cost owner and ARM validation are still required.'
}
