#requires -Version 7.0
$ErrorActionPreference = 'Stop'
$root = Join-Path ([IO.Path]::GetTempPath()) "onboarding-setup-test-$([guid]::NewGuid())"
$lab = Join-Path $root 'labs\onboardinglab'
$null = New-Item -ItemType Directory -Path (Join-Path $lab 'scripts') -Force
$null = New-Item -ItemType Directory -Path (Join-Path $lab 'ticketingapp-source') -Force
$shared = Join-Path $root 'sreagent-templates\bin\ps'
$bicep = Join-Path $root 'sreagent-templates\bicep'
$null = New-Item -ItemType Directory -Path $shared, $bicep -Force
Copy-Item (Join-Path $PSScriptRoot '..\scripts\setup.ps1') (Join-Path $lab 'scripts\setup.ps1')
Copy-Item (Join-Path $PSScriptRoot '..\agent-recipe') (Join-Path $lab 'agent-recipe') -Recurse
$global:SetupCalls = [System.Collections.Generic.List[string]]::new()
$global:SetupExisting = $false
$global:SetupHook = ''
$global:SetupFailVerify = $false
$global:SetupCore = ''
$global:SetupRepository = ''
$global:SetupRecipients = ''
$global:SetupAgentName = 'setup-test-agent'
$global:SetupWorkflowOptions = $null
$global:SetupFailWorkflow = $false

function global:azd {
    $global:LASTEXITCODE = 0
    $name = $args[-1]
    if ($args -contains 'set') { $global:SetupCalls.Add('save-output'); return }
    switch ($name) {
        'AZURE_SUBSCRIPTION_ID' { '00000000-0000-0000-0000-000000000001' }
        'AZURE_RESOURCE_GROUP' { 'rg-setup-test' }
        'AZURE_LOCATION' { 'swedencentral' }
        'AZURE_ENV_NAME' { 'setup-test' }
        'APPLICATION_INSIGHTS_ID' { '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg-setup-test/providers/Microsoft.Insights/components/test' }
        'APPLICATION_INSIGHTS_APP_ID' { '00000000-0000-0000-0000-000000000002' }
        'ONBOARDING_CONFIGURE_AGENT' {
            if (-not $global:SetupHook) { $global:LASTEXITCODE = 1 }
            $global:SetupHook
        }
        'ONBOARDING_AGENT_NAME' { $global:SetupAgentName }
        'ONBOARDING_CORE_ONLY' { $global:SetupCore }
        'ONBOARDING_GITHUB_REPOSITORY_URL' { $global:SetupRepository }
        'ONBOARDING_EMAIL_RECIPIENTS' { $global:SetupRecipients }
        default { throw "Unexpected environment read: $name" }
    }
}
function global:az {
    $global:LASTEXITCODE = 0
    if (($args -join ' ') -notlike 'resource list*') { throw "Unexpected Azure write/read: $args" }
    if ($global:SetupExisting) { '[{"name":"setup-test-agent"}]' } else { '[]' }
}

@'
param($RecipePath,$Subscription,$Set,$Output,[switch]$NonInteractive,[switch]$NoTelemetry)
$null=New-Item -ItemType Directory -Path $Output -Force
Copy-Item (Join-Path $RecipePath '*') $Output -Recurse
$global:SetupCalls.Add('generate')
'@ | Set-Content (Join-Path $shared 'New-Agent.ps1')
@'
param($ConfigDir,$Output)
$global:SetupCalls.Add('assemble')
'@ | Set-Content (Join-Path $bicep 'Assemble-Agent.ps1')
@'
param($InputPath,$DeploymentName,$Subscription,[switch]$NoTelemetry)
$global:SetupCalls.Add('deploy')
'@ | Set-Content (Join-Path $shared 'Deploy-Agent.ps1')
@'
param($SubscriptionId,$ResourceGroup,$AgentName,$Expected)
$global:SetupCalls.Add('verify')
if ($global:SetupFailVerify) { throw 'Required configuration missing' }
'@ | Set-Content (Join-Path $shared 'Verify-Agent.ps1')
@'
param($Subscription,$AgentName,$Template,[switch]$EnableSourceCode,[switch]$EnableGitHubIssues,[switch]$EnableEmail,$GitHubRepository,$EmailRecipients)
$global:SetupCalls.Add('workflow')
$global:SetupWorkflowOptions = @{
    source = [bool]$EnableSourceCode; issues = [bool]$EnableGitHubIssues; email = [bool]$EnableEmail
    repository = $GitHubRepository; recipients = $EmailRecipients
}
if ($global:SetupFailWorkflow) { throw 'Selected connections are not authenticated.' }
'@ | Set-Content (Join-Path $lab 'scripts\install-workflow-template.ps1')

try {
    $script = Join-Path $lab 'scripts\setup.ps1'
    & $script -FromAzdHook
    if ($global:SetupCalls.Count) { throw 'Unselected hook performed setup.' }
    if ($LASTEXITCODE -ne 0) { throw 'Missing optional hook setting must produce a successful skip.' }
    $failed = $false
    try { & $script -AgentName setup-test-agent -Stage Preview } catch { $failed = $true }
    if (-not $failed -or $global:SetupCalls.Count) { throw 'The standard lab must request a repository before generation.' }
    & $script -AgentName setup-test-agent -Stage Preview -CoreOnly
    if (($global:SetupCalls -join ',') -ne 'generate,assemble') { throw 'Preview must generate/assemble only.' }
    $global:SetupCalls.Clear()
    & $script -AgentName setup-test-agent -Stage Apply -CoreOnly
    if (($global:SetupCalls -join ',') -ne 'deploy,workflow,save-output,save-output,save-output,verify') { throw 'Wrong new-agent stage order.' }
    $global:SetupCalls.Clear()
    $global:SetupExisting = $true
    & $script -AgentName setup-test-agent -Stage Apply -CoreOnly
    if ($global:SetupCalls -contains 'deploy' -or $global:SetupCalls -contains 'workflow') { throw 'Existing agent configuration was overwritten.' }
    $global:SetupFailVerify = $true
    $global:SetupCalls.Clear()
    $failed = $false
    try { & $script -AgentName setup-test-agent -Stage Apply -CoreOnly } catch { $failed = $true }
    if (-not $failed -or $global:SetupCalls -contains 'deploy') { throw 'Failed verification must stop without deployment.' }
    $failed = $false
    try { & $script -AgentName setup-test-agent -Stage Preview -GitHubRepositoryUrl https://github.com/example/lab } catch { $failed = $true }
    if (-not $failed) { throw 'Changed setup selection was not rejected.' }
    & $script -AgentName optional-test-agent -Stage Preview -GitHubRepositoryUrl https://github.com/example/lab
    $config = Join-Path $lab 'ticketingapp-source\.azure\setup-test\optional-test-agent'
    $expected = Get-Content (Join-Path $config 'expected-config.json') -Raw | ConvertFrom-Json
    if ('office365' -notin $expected.managedConnectors -or 'sre-agent' -notin $expected.repos) { throw 'Selected extensions missing from expected config.' }
    if ('SendOutlookEmail' -notin $expected.toolPermissions.ask -or 'CreateGithubIssue' -notin $expected.toolPermissions.ask) { throw 'Optional writes lack approval policy.' }
    if (-not (Test-Path (Join-Path $config 'config\connectorv2\outlook.yaml'))) { throw 'Selected connector missing.' }
    $global:SetupFailVerify = $false
    $global:SetupCalls.Clear()
    $failed = $false
    try { & $script -AgentName optional-test-agent -Stage Connect -GitHubRepositoryUrl https://github.com/example/lab } catch { $failed = $true }
    if (-not $failed -or $global:SetupCalls.Count) { throw 'Connect must require approved email recipients before calling the installer.' }
    & $script -AgentName optional-test-agent -Stage Connect -GitHubRepositoryUrl https://github.com/example/lab -EmailRecipients learner@example.com
    if (($global:SetupCalls -join ',') -ne 'verify,workflow,verify') { throw 'Connect must verify, activate selected integrations, and verify without deployment.' }
    $options = $global:SetupWorkflowOptions
    if (-not ($options.source -and $options.issues -and $options.email) -or
        $options.repository -ne 'https://github.com/example/lab' -or $options.recipients -ne 'learner@example.com') {
        throw 'Connect did not forward the standard integration selection and approved destinations.'
    }
    $global:SetupFailWorkflow = $true
    $failed = $false
    try { & $script -AgentName optional-test-agent -Stage Connect -GitHubRepositoryUrl https://github.com/example/lab -EmailRecipients learner@example.com } catch { $failed = $true }
    if (-not $failed) { throw 'Connection validation failure was hidden.' }
    $global:SetupFailWorkflow = $false
    $global:SetupCalls.Clear()
    foreach ($invalid in @(
        @{ Stage = 'Connect'; CoreOnly = $true },
        @{ Stage = 'Preview'; CoreOnly = $true; GitHubRepositoryUrl = 'https://github.com/example/lab' }
    )) {
        $failed = $false
        try { & $script -AgentName setup-test-agent @invalid } catch { $failed = $true }
        if (-not $failed -or $global:SetupCalls.Count) { throw 'Conflicting core-only inputs were accepted.' }
    }
    $global:SetupHook = 'true'
    $global:SetupRepository = 'https://github.com/example/lab'
    $global:SetupAgentName = 'hook-standard-agent'
    $global:SetupExisting = $false
    & $script -FromAzdHook
    $hookExpected = Get-Content (Join-Path $lab 'ticketingapp-source\.azure\setup-test\hook-standard-agent\expected-config.json') -Raw | ConvertFrom-Json
    if ('office365' -notin $hookExpected.managedConnectors -or 'sre-agent' -notin $hookExpected.repos) {
        throw 'The opted-in azd hook did not prepare the standard integrations.'
    }
    $global:SetupCalls.Clear()
    $global:SetupAgentName = 'setup-test-agent'
    $global:SetupExisting = $true
    $global:SetupCore = 'true'
    & $script -FromAzdHook
    if ($global:SetupCalls -contains 'deploy' -or $global:SetupCalls -contains 'workflow') { throw 'Core-only hook changed an existing agent.' }
    Write-Host 'PASS: standard GitHub/Outlook defaults, consent-stage contract, explicit core-only fallback, safe hooks and existing-agent preservation.'
}
finally {
    Remove-Item Function:\az, Function:\azd
    Remove-Item -LiteralPath $root -Recurse -Force
}
