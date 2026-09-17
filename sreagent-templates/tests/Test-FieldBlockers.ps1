<#
.SYNOPSIS
    Offline regressions for deployment cleanup, Python selection and verification.
.DESCRIPTION
    All Azure and data-plane calls are mocked. Deployment runs against an isolated
    fixture tree with a private Temp root and an unrelated sentinel.
#>
param([string]$Mode, [string]$Case, [string]$FixtureRoot)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path $PSScriptRoot -Parent

if ($Mode -eq 'deploy') {
    $env:TEMP = Join-Path $FixtureRoot 'temp'
    $env:TMP = $env:TEMP
    $env:TMPDIR = $env:TEMP
    function global:az {
        $global:LASTEXITCODE = 0
        switch -Wildcard ($args -join ' ') {
            'account show*' { '{"id":"test-sub","name":"test subscription"}'; return }
            'group exists*' { 'false'; return }
            'resource show*' { return }
            'deployment sub what-if*' { $global:LASTEXITCODE = 7; 'what-if fixture failure'; return }
            'deployment sub create*' {
                if ($Case -eq 'arm-failure') { $global:LASTEXITCODE = 1; '{"properties":{"provisioningState":"Failed"}}'; return }
                '{"properties":{"provisioningState":"Succeeded","duration":"PT1S","outputs":{"agentPortalUrl":{"value":"https://stale.invalid"},"resourceGroupPortalUrl":{"value":"https://example.invalid/rg"},"agentDataPlaneUrl":{"value":"https://example.invalid"},"managedIdentityId":{"value":""}}}}'
                return
            }
            default { throw "Unexpected Azure command: $args" }
        }
    }
    $options = @{ InputPath = (Join-Path $FixtureRoot 'input'); NoTelemetry = $true }
    if ($Case -eq 'legacy') { $options.InputPath = Join-Path $FixtureRoot 'input\agent.parameters.json' }
    if ($Case -eq 'dry-run') { $options.DryRun = $true }
    if ($Case -in @('real-assembly','real-assembly-error')) { $options.DryRun = $true }
    if ($Case -eq 'what-if') { $options.WhatIf_ = $true }
    & (Join-Path $FixtureRoot 'bin\ps\Deploy-Agent.ps1') @options
    exit $LASTEXITCODE
}

if ($Mode -eq 'verify') {
    function global:az {
        $global:LASTEXITCODE = 0
        if ($args[0] -eq 'account') {
            if ($Case -eq 'token-failure') { $global:LASTEXITCODE = 1 }
            'offline-test-token'; return
        }
        if (($args -join ' ') -match '/DataConnectors\?') {
            if ($Case -eq 'arm-read-failure') { $global:LASTEXITCODE = 3; return }
            '{"value":[]}'; return
        }
        if ($Case -eq 'initial-arm-failure') { $global:LASTEXITCODE = 1 }
        if ($Case -eq 'initial-arm-json') { 'not JSON'; return }
        '{"properties":{"agentEndpoint":"https://example.invalid","actionConfiguration":{"accessLevel":"Low","mode":"Review"},"upgradeChannel":"Preview","defaultModel":{"provider":"Anthropic"}}}'
    }
    function global:Invoke-WebRequest {
        param($Uri, $Headers, $TimeoutSec, [switch]$SkipHttpErrorCheck)
        $body = '{"value":[]}'
        $status = 200
        if ($Uri.EndsWith('/github/domains')) { $body = '{"values":[]}' }
        if ($Uri.EndsWith('/repos')) {
            switch ($Case) {
                'empty-array' { $body = '[]' }
                'empty-envelope' { $body = '{"value":[]}' }
                'repo-array' { $body = '[{"name":"repo","properties":{"branch":"main"}}]' }
                'repo-envelope' { $body = '{"value":[{"name":"repo","properties":{"branch":"main"}}]}' }
                'missing-branch' { $body = '[{"name":"repo"}]' }
                'http-error' { $status = 403; $body = '{"error":{"message":"Forbidden"}}' }
                'html-error' { $body = '<html>gateway error</html>' }
                'error-object' { $body = '{"error":{"code":"Denied"}}' }
                'bad-envelope' { $body = '{"value":{}}' }
                'empty-body' { $body = '' }
                'null-body' { $body = 'null' }
                'transport-error' { throw 'offline connection failure' }
                'optional-empty' { $body = '[]' }
                'optional-http-error' { $status = 403; $body = '{}' }
                default { $body = '[]' }
            }
        }
        [PSCustomObject]@{ StatusCode = $status; Content = $body }
    }
    & (Join-Path $root 'bin\ps\Verify-Agent.ps1') -Subscription test-sub -ResourceGroup test-rg -AgentName test-agent -Expected $FixtureRoot
    exit $LASTEXITCODE
}

if ($Mode -eq 'extras') {
    function global:az {
        $global:LASTEXITCODE = 0
        if ($args[0] -eq 'account') { 'offline-test-token'; return }
        if ($args[0] -ne 'rest' -or $args[2] -ne 'GET') { throw "Unexpected Azure command: $args" }
        '{"properties":{"agentEndpoint":"https://example.invalid"},"identity":{"userAssignedIdentities":{}}}'
    }
    function global:Invoke-RestMethod {
        param($TimeoutSec, $Uri, $Method, $Headers, $Body, $ContentType)
        if ($Method -ne 'Put' -or $Uri -notmatch '/commonprompts/(first|second)$') { throw "Unexpected HTTP request: $Method $Uri" }
        Write-Host "ATTEMPT $Uri"
        if ($Uri.EndsWith('/first') -and $Case -eq 'put-failure') { throw 'HTTP 403 fixture denial' }
        return @{}
    }
    & (Join-Path $root 'bicep\Apply-Extras.ps1') -Subscription test-sub -ResourceGroup test-rg -AgentName test-agent -ExtrasFile (Join-Path $FixtureRoot 'extras.json')
    exit $LASTEXITCODE
}

if ($Mode -eq 'python') {
    . (Join-Path $root 'bin\ps\Check-Prerequisites.ps1')
    function Get-Command {
        param($Name, $CommandType, [switch]$All, $ErrorAction)
        if ($Name -in @('python', 'python3')) {
            [PSCustomObject]@{ Source = (Join-Path $FixtureRoot "$Name.ps1") }
        } else { Microsoft.PowerShell.Core\Get-Command $Name -ErrorAction $ErrorAction }
    }
    $selected = Resolve-PythonWithYaml
    if ($selected -ne (Join-Path $FixtureRoot 'python.ps1')) { throw "Wrong interpreter: $selected" }
    if (-not (Test-Prerequisites -IncludePython)) { throw 'Prerequisite check rejected working Python.' }
    if ((Get-Alias python3).Definition -ne $selected) { throw 'Legacy callers do not use the selected interpreter.' }
    Write-Host 'PASS: working Python fallback and caller alias'
    exit 0
}

$temporary = Join-Path ([IO.Path]::GetTempPath()) "sre-field-tests-$([guid]::NewGuid())"
New-Item -ItemType Directory -Path $temporary | Out-Null
$checks = 0
try {
    $deploySource = Get-Content (Join-Path $root 'bin\ps\Deploy-Agent.ps1') -Raw
    if ($deploySource -match '\$CleanupFiles|Split-Path \$AssembleTmp -Parent') { throw 'Unsafe cleanup code must never run.' }

    foreach ($caseName in @('dry-run', 'early-exit', 'assembly-throw', 'assembly-exit', 'what-if', 'arm-failure', 'success', 'extras-failure', 'strict-verify-failure', 'legacy', 'real-assembly', 'real-assembly-error')) {
        $fixture = Join-Path $temporary $caseName
        foreach ($dir in @('bin\ps', 'bicep', 'input', 'temp')) {
            New-Item -ItemType Directory -Path (Join-Path $fixture $dir) -Force | Out-Null
        }
        $sentinel = Join-Path $fixture 'temp\unrelated-sentinel.txt'
        Set-Content $sentinel 'preserve me'
        Set-Content (Join-Path $fixture 'bin\ps\Deploy-Agent.ps1') $deploySource
        Set-Content (Join-Path $fixture 'bin\ps\Check-Prerequisites.ps1') 'function Test-Prerequisites { param([switch]$IncludePython) return $true }'
        Set-Content (Join-Path $fixture 'bin\ps\Region-Utils.ps1') 'function Resolve-AzureSubscription { param($Subscription) return "test-sub" }; function Assert-SreAgentRegion { param($Subscription, $Region) }'
        Set-Content (Join-Path $fixture 'bin\ps\Diff-Agent.ps1') $(if ($caseName -eq 'early-exit') { 'exit 0' } else { 'exit 2' })
        Set-Content (Join-Path $fixture 'bin\ps\Verify-Agent.ps1') $(if ($caseName -eq 'strict-verify-failure') { 'exit 9' } else { 'exit 0' })
        Set-Content (Join-Path $fixture 'bicep\main.bicep') '// offline fixture'
        Set-Content (Join-Path $fixture 'input\agent.json') '{}'
        if ($caseName -eq 'strict-verify-failure') {
            Set-Content (Join-Path $fixture 'input\expected-config.json') '{"strictVerification":true}'
        }
        $assembly = @'
param($ConfigDir, $Output)
$values = @{
    location='eastus2'; agentName='test-agent'; agentResourceGroupName='test-rg'
    targetResourceGroups=@(); accessLevel='Low'; actionMode='Review'
    upgradeChannel='Preview'; defaultModelProvider='Anthropic'; monthlyAgentUnitLimit=10000
    enableWebhookBridge=$false; enableLogAnalyticsConnector=$false
    enableAppInsightsConnector=$false; enableAzureMonitorConnector=$false
    connectors=@(); skills=@(); subagents=@()
}
$parameters = @{}
foreach ($key in $values.Keys) { $parameters[$key] = @{ value = $values[$key] } }
@{ parameters = $parameters } | ConvertTo-Json -Depth 20 | Set-Content "$Output.parameters.json"
$extras = @{}
foreach ($key in @('skills','subagents','tools','hooks','commonPrompts','incidentPlatforms','incidentFilters','scheduledTasks','httpTriggers','repos','knowledgeItems','knowledge','pluginConfigs','connectorV2')) { $extras[$key] = @() }
if ((Split-Path (Split-Path $ConfigDir -Parent) -Leaf) -eq 'extras-failure') { $extras.commonPrompts = @(@{name='prompt'}) }
$extras | ConvertTo-Json -Depth 20 | Set-Content "$Output.extras.json"
'@
        if ($caseName -eq 'assembly-throw') { $assembly = 'param($ConfigDir, $Output); Set-Content "$Output.partial" "partial"; throw "assembly fixture failure"' }
        if ($caseName -eq 'assembly-exit') { $assembly = 'param($ConfigDir, $Output); Set-Content "$Output.partial" "partial"; exit 8' }
        Set-Content (Join-Path $fixture 'bicep\Assemble-Agent.ps1') $assembly
        Set-Content (Join-Path $fixture 'bicep\Apply-Extras.ps1') 'exit 6'
        if ($caseName -eq 'legacy') {
            & (Join-Path $fixture 'bicep\Assemble-Agent.ps1') -ConfigDir (Join-Path $fixture 'input') -Output (Join-Path $fixture 'input\agent')
        }
        if ($caseName -in @('real-assembly','real-assembly-error')) {
            Copy-Item (Join-Path $root 'bicep\Assemble-Agent.ps1') (Join-Path $fixture 'bicep\Assemble-Agent.ps1')
            Copy-Item (Join-Path $root 'bin\ps\Check-Prerequisites.ps1') (Join-Path $fixture 'bin\ps\Check-Prerequisites.ps1')
            Copy-Item (Join-Path $root 'bin\ps\Invoke-Jq.ps1') (Join-Path $fixture 'bin\ps\Invoke-Jq.ps1')
            Copy-Item (Join-Path $root 'recipes\minimal\*') (Join-Path $fixture 'input') -Recurse -Force
            if ($caseName -eq 'real-assembly-error') { Set-Content (Join-Path $fixture 'input\admin-settings.json') 'invalid JSON' }
        }
        $output = & pwsh -NoProfile -File $PSCommandPath -Mode deploy -Case $caseName -FixtureRoot $fixture 2>&1 | Out-String
        $code = $LASTEXITCODE
        $expectedCode = switch ($caseName) {
            'assembly-throw' { 1 }; 'assembly-exit' { 1 }; 'real-assembly-error' { 1 }; 'what-if' { 7 }
            'arm-failure' { 1 }; 'extras-failure' { 6 }; 'strict-verify-failure' { 9 }; default { 0 }
        }
        if ($code -ne $expectedCode) { throw "Deploy $caseName exit $code, expected ${expectedCode}:`n$output" }
        if (-not (Test-Path $sentinel) -or (Get-Content $sentinel) -ne 'preserve me') { throw "Deploy $caseName removed unrelated Temp data." }
        if (@(Get-ChildItem (Join-Path $fixture 'temp')).Count -ne 1) { throw "Deploy $caseName leaked scratch files." }
        if ($caseName -eq 'legacy' -and -not (Test-Path (Join-Path $fixture 'input\agent.parameters.json'))) { throw 'Legacy parameters were removed.' }
        if ($caseName -notin @('legacy','assembly-throw','assembly-exit','real-assembly-error') -and -not (Test-Path (Join-Path $fixture 'input\input.extras.json'))) { throw "Deploy $caseName did not preserve assembled extras." }
        if ($caseName -in @('success','extras-failure') -and $output -notmatch 'https://sre.azure.com/agents/subscriptions/test-sub/resourceGroups/test-rg/providers/Microsoft.App/agents/test-agent') { throw 'Deployment portal route is stale.' }
        $checks++
    }

    foreach ($caseName in @('initial-arm-failure','initial-arm-json','token-failure')) {
        $output = & pwsh -NoProfile -File $PSCommandPath -Mode verify -Case $caseName -FixtureRoot $temporary 2>&1 | Out-String
        if ($LASTEXITCODE -ne 1 -or $output -notmatch 'FAIL:') { throw "Initial verification error $caseName was hidden:`n$output" }
        $checks++
    }

    foreach ($caseName in @('empty-array','empty-envelope','repo-array','repo-envelope','missing-branch','http-error','html-error','error-object','bad-envelope','empty-body','null-body','transport-error','optional-empty','optional-http-error','arm-read-failure')) {
        $fixture = Join-Path $temporary "verify-$caseName"
        New-Item -ItemType Directory -Path $fixture | Out-Null
        $expected = @{ connectors=@(); knowledgeSources=@(); managedConnectors=@(); skills=@(); subagents=@(); hooks=@(); commonPrompts=@(); scheduledTasks=@(); responsePlans=@(); repos=@('repo'); repoBranches=@{repo='main'} }
        if ($caseName -in @('optional-empty','optional-http-error')) { $expected.repos=@(); $expected.repoBranches=@{} }
        $expected | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $fixture 'expected-config.json')
        $output = & pwsh -NoProfile -File $PSCommandPath -Mode verify -Case $caseName -FixtureRoot $fixture 2>&1 | Out-String
        $code = $LASTEXITCODE
        $expectedCode = if ($caseName -in @('repo-array','repo-envelope','optional-empty')) { 0 } else { 1 }
        if ($code -ne $expectedCode -or $output -notmatch 'Results: \d+ passed, \d+ failed') { throw "Verify $caseName failed to produce results (exit ${code}):`n$output" }
        if ($output -notmatch 'Agent exists.*PASS' -or $output -notmatch 'Repo') { throw "Verify $caseName lost prior checks." }
        if ($caseName -in @('http-error','html-error','error-object','bad-envelope','empty-body','null-body','transport-error','optional-http-error','arm-read-failure') -and $output -notmatch 'unavailable') { throw "Verify $caseName masked an API failure." }
        if ($caseName -eq 'http-error' -and $output -notmatch 'HTTP 403') { throw 'HTTP status was not reported.' }
        if ($output -notmatch 'https://sre.azure.com/agents/subscriptions/test-sub/resourceGroups/test-rg/providers/Microsoft.App/agents/test-agent') { throw 'Verifier portal route is stale.' }
        $checks++
    }

    foreach ($caseName in @('put-failure','put-success')) {
        $fixture = Join-Path $temporary $caseName
        New-Item -ItemType Directory -Path $fixture | Out-Null
        @{ commonPrompts = @(@{name='first'; properties=@{}}, @{name='second'; properties=@{}}) } |
            ConvertTo-Json -Depth 10 | Set-Content (Join-Path $fixture 'extras.json')
        $output = & pwsh -NoProfile -File $PSCommandPath -Mode extras -Case $caseName -FixtureRoot $fixture 2>&1 | Out-String
        $expectedCode = if ($caseName -eq 'put-failure') { 1 } else { 0 }
        if ($LASTEXITCODE -ne $expectedCode -or $output -notmatch 'ok commonprompts/second') { throw "Apply extras $caseName failed:`n$output" }
        if ($caseName -eq 'put-failure' -and ($output -notmatch 'PUT commonprompts/first - HTTP 403' -or $output -match '(?m)^Done\.$')) { throw 'Extras failure was hidden.' }
        $checks++
    }

    $fixture = Join-Path $temporary 'python'
    New-Item -ItemType Directory -Path $fixture | Out-Null
    Set-Content (Join-Path $fixture 'python.ps1') '$global:LASTEXITCODE=0; "sre-python-ready"'
    foreach ($probe in @('$global:LASTEXITCODE=9009; "Windows Store alias"', '$global:LASTEXITCODE=1; "No module named yaml"', 'throw "Cannot start interpreter"')) {
        Set-Content (Join-Path $fixture 'python3.ps1') $probe
        $output = & pwsh -NoProfile -File $PSCommandPath -Mode python -FixtureRoot $fixture 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) { throw "Python fallback failed:`n$output" }
        $checks++
    }
    Set-Content (Join-Path $fixture 'python.ps1') '$global:LASTEXITCODE=1; "No module named yaml"'
    $output = & pwsh -NoProfile -File $PSCommandPath -Mode python -FixtureRoot $fixture 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0 -or $output -notmatch 'Python 3 with PyYAML is required') { throw 'Missing PyYAML was not reported.' }
    $checks++
    Write-Host "PASS: $checks offline field-blocker regressions"
} finally {
    Remove-Item -LiteralPath $temporary -Recurse -Force
}
