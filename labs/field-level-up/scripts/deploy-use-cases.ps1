#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $GitHubRepositoryUrl,
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string[]] $EmailRecipients,
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $EmailConnectorName,
    [switch] $EnableIncidents,
    [ValidateSet(1, 2)]
    [int] $AlertSeverity = 2,
    [switch] $ConfirmConnectionsReady
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
. (Join-Path $PSScriptRoot 'internal/LabEnvironment.ps1')
$labRoot = Split-Path $PSScriptRoot -Parent

$repositoryUri = $null
if (-not [uri]::TryCreate($GitHubRepositoryUrl, [UriKind]::Absolute, [ref]$repositoryUri) -or
    $repositoryUri.Scheme -ne 'https' -or $repositoryUri.UserInfo -or $repositoryUri.Query -or $repositoryUri.Fragment -or
    $repositoryUri.Host -ine 'github.com' -or $repositoryUri.Port -ne 443 -or
    $GitHubRepositoryUrl -notmatch '^https://github\.com(?::443)?/[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_][A-Za-z0-9_.-]*/?\z') {
    throw 'Supply https://github.com/owner/repository without credentials, encoded segments, query or fragment.'
}
foreach ($recipient in $EmailRecipients) {
    try { $address = [System.Net.Mail.MailAddress]::new($recipient) }
    catch { throw 'Each email recipient must be a valid email address.' }
    if ($address.Address -cne $recipient -or $recipient -match '[\r\n]') {
        throw 'Supply plain email addresses, without display names or surrounding whitespace.'
    }
}
if ([string]::IsNullOrWhiteSpace($EmailConnectorName)) { throw 'Supply the existing email connector name.' }
if ($EnableIncidents -and -not $ConfirmConnectionsReady) {
    throw 'Before enabling incidents, verify telemetry, Azure Monitor scanning, access, skills, Task delegation, and GitHub/email authentication; then pass -ConfirmConnectionsReady. No OAuth setup is automated.'
}

$subscription = [guid](Get-LabValue 'AZURE_SUBSCRIPTION_ID')
$resourceGroup = Get-LabValue 'AZURE_RESOURCE_GROUP'
$agentName = Get-LabValue 'SRE_AGENT_NAME'
$agentId = Get-LabValue 'SRE_AGENT_RESOURCE_ID'
$expectedId = "/subscriptions/$subscription/resourceGroups/$resourceGroup/providers/Microsoft.App/agents/$agentName"
if ($agentName -notmatch '^[A-Za-z0-9][A-Za-z0-9-]*\z' -or $agentId -ine $expectedId) {
    throw 'The azd agent identity must belong to the lab subscription and resource group. Review the environment manually.'
}
$parameters = @{
    sreAgentName = $agentName
    checkoutAppId = Get-LabValue 'CHECKOUT_APP_ID'
    postgresServerId = Get-LabValue 'POSTGRES_SERVER_ID'
    applicationInsightsId = Get-LabValue 'APPLICATION_INSIGHTS_ID'
    applicationInsightsAppId = Get-LabValue 'APPLICATION_INSIGHTS_APP_ID'
    githubRepositoryUrl = $GitHubRepositoryUrl
    emailRecipients = $EmailRecipients
    emailConnectorName = $EmailConnectorName
    namePrefix = Get-LabValue 'LAB_NAME_PREFIX'
    location = Get-LabValue 'AZURE_LOCATION'
    enableIncidents = [bool]$EnableIncidents
    alertSeverity = $AlertSeverity
}
if ($EnableIncidents) {
    # Check only: activation must not implicitly install or repair permission policy.
    & (Join-Path $labRoot 'agent-setup/apply-permissions.ps1') -SubscriptionId $subscription -ResourceId $agentId -CheckOnly
}

$null = Invoke-LabDeployment -SubscriptionId $subscription -ResourceGroup $resourceGroup `
    -Name 'field-level-up-use-cases' -TemplateFile (Join-Path $labRoot 'use-cases/main.bicep') -Parameters $parameters
Write-Host "Use-case templates deployed. Incidents enabled: $([bool]$EnableIncidents). No email or GitHub issue was sent by this script."