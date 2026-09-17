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
        'ONBOARDING_AGENT_NAME' { 'setup-test-agent' }
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
param($Subscription,$AgentName,$Template)
$global:SetupCalls.Add('workflow')
'@ | Set-Content (Join-Path $lab 'scripts\install-workflow-template.ps1')

try {
    $script = Join-Path $lab 'scripts\setup.ps1'
    & $script -FromAzdHook
    if ($global:SetupCalls.Count) { throw 'Unselected hook performed setup.' }
    if ($LASTEXITCODE -ne 0) { throw 'Missing optional hook setting must produce a successful skip.' }
    & $script -AgentName setup-test-agent -Stage Preview
    if (($global:SetupCalls -join ',') -ne 'generate,assemble') { throw 'Preview must generate/assemble only.' }
    $global:SetupCalls.Clear()
    & $script -AgentName setup-test-agent -Stage Apply
    if (($global:SetupCalls -join ',') -ne 'deploy,workflow,save-output,save-output,save-output,verify') { throw 'Wrong new-agent stage order.' }
    $global:SetupCalls.Clear()
    $global:SetupExisting = $true
    & $script -AgentName setup-test-agent -Stage Apply
    if ($global:SetupCalls -contains 'deploy' -or $global:SetupCalls -contains 'workflow') { throw 'Existing agent configuration was overwritten.' }
    $global:SetupFailVerify = $true
    $global:SetupCalls.Clear()
    $failed = $false
    try { & $script -AgentName setup-test-agent -Stage Apply } catch { $failed = $true }
    if (-not $failed -or $global:SetupCalls -contains 'deploy') { throw 'Failed verification must stop without deployment.' }
    $failed = $false
    try { & $script -AgentName setup-test-agent -Stage Preview -EnableEmail } catch { $failed = $true }
    if (-not $failed) { throw 'Changed setup selection was not rejected.' }
    & $script -AgentName optional-test-agent -Stage Preview -EnableEmail -EnableGitHubIssues -GitHubRepositoryUrl https://github.com/example/lab
    $config = Join-Path $lab 'ticketingapp-source\.azure\setup-test\optional-test-agent'
    $expected = Get-Content (Join-Path $config 'expected-config.json') -Raw | ConvertFrom-Json
    if ('office365' -notin $expected.managedConnectors -or 'ticketingapp-source' -notin $expected.repos) { throw 'Selected extensions missing from expected config.' }
    if ('SendOutlookEmail' -notin $expected.toolPermissions.ask -or 'CreateGithubIssue' -notin $expected.toolPermissions.ask) { throw 'Optional writes lack approval policy.' }
    if (-not (Test-Path (Join-Path $config 'config\connectorv2\outlook.yaml'))) { throw 'Selected connector missing.' }
    Write-Host 'PASS: setup opt-in, preview, stage order, drift refusal, failure propagation and optional configuration.'
}
finally {
    Remove-Item Function:\az, Function:\azd
    Remove-Item -LiteralPath $root -Recurse -Force
}
