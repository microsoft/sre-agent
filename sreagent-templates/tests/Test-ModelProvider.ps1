$ErrorActionPreference = 'Stop'

$TemplatesDirectory = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$RepositoryDirectory = (Resolve-Path (Join-Path $TemplatesDirectory '..')).Path
$RecipeDirectory = Join-Path $RepositoryDirectory 'labs/onboardinglab/agent-recipe'
$TemporaryDirectory = Join-Path ([System.IO.Path]::GetTempPath()) "model-provider-$([guid]::NewGuid())"
$Subscription = '00000000-0000-0000-0000-000000000000'
$CommonSet = @{
    agentName        = 'provider-test'
    resourceGroup    = 'rg-provider-test'
    location         = 'swedencentral'
    appInsightsId    = "/subscriptions/$Subscription/resourceGroups/rg-provider-test/providers/Microsoft.Insights/components/app"
    appInsightsAppId = '00000000-0000-0000-0000-000000000001'
    githubRepo       = 'https://github.com/example/repo.git'
}

New-Item -ItemType Directory -Path $TemporaryDirectory | Out-Null
try {
    $newAgent = Join-Path $TemplatesDirectory 'bin/ps/New-Agent.ps1'
    & $newAgent -RecipePath $RecipeDirectory -Subscription $Subscription -Set $CommonSet `
        -Output (Join-Path $TemporaryDirectory 'default') -NonInteractive -NoTelemetry | Out-Null

    $anthropicSet = $CommonSet.Clone()
    $anthropicSet.modelProvider = 'Anthropic'
    & $newAgent -RecipePath $RecipeDirectory -Subscription $Subscription -Set $anthropicSet `
        -Output (Join-Path $TemporaryDirectory 'anthropic') -NonInteractive -NoTelemetry | Out-Null

    $foundrySet = $CommonSet.Clone()
    $foundrySet.modelProvider = 'Azure OpenAI'
    & $newAgent -RecipePath $RecipeDirectory -Subscription $Subscription -Set $foundrySet `
        -Output (Join-Path $TemporaryDirectory 'foundry') -NonInteractive -NoTelemetry | Out-Null

    $default = Get-Content (Join-Path $TemporaryDirectory 'default/agent.json') -Raw | ConvertFrom-Json
    $anthropic = Get-Content (Join-Path $TemporaryDirectory 'anthropic/agent.json') -Raw | ConvertFrom-Json
    $foundry = Get-Content (Join-Path $TemporaryDirectory 'foundry/agent.json') -Raw | ConvertFrom-Json
    if ($default.defaultModelProvider -ne 'Anthropic' -or $anthropic.defaultModelProvider -ne 'Anthropic') {
        throw 'The onboarding recipe must default to Anthropic.'
    }
    if ($foundry.defaultModelProvider -ne 'MicrosoftFoundry') {
        throw 'Azure OpenAI must generate the MicrosoftFoundry API value.'
    }

    $default.defaultModelProvider = 'Azure OpenAI'
    $default | ConvertTo-Json -Depth 20 | Set-Content (Join-Path $TemporaryDirectory 'default/agent.json')
    $assembleOutput = Join-Path $TemporaryDirectory 'assembled'
    & (Join-Path $TemplatesDirectory 'bicep/Assemble-Agent.ps1') `
        -ConfigDir (Join-Path $TemporaryDirectory 'default') -Output $assembleOutput | Out-Null
    $parameters = Get-Content "$assembleOutput.parameters.json" -Raw | ConvertFrom-Json
    if ($parameters.parameters.defaultModelProvider.value -ne 'MicrosoftFoundry') {
        throw 'PowerShell assembly must normalize stale Azure OpenAI values to MicrosoftFoundry.'
    }

    Write-Host 'PASS: PowerShell defaults to Anthropic and normalizes Azure OpenAI to MicrosoftFoundry'
} finally {
    Remove-Item $TemporaryDirectory -Recurse -Force -ErrorAction SilentlyContinue
}
