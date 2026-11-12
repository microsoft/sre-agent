#requires -Version 7.0
param([string]$Case, [string]$FixtureRoot)

$ErrorActionPreference = 'Stop'
$templates = Split-Path $PSScriptRoot -Parent

foreach ($file in @('logic-app-bridge.bicep', 'main.bicep')) {
    $source = Get-Content -LiteralPath (Join-Path $templates "bicep\$file") -Raw
    if ($source -match '(?m)^\s*output\s+(logicAppCallbackUrl|webhookBridgeUrl)\b' -or
        $source -match '(?m)^\s*output\b[^\r\n]*listCallbackUrl\s*\(') {
        throw "Credential-bearing template output found in $file."
    }
}

if ($Case) {
    $Subscription = 'test-sub'
    $SubscriptionId = $Subscription
    $ResourceGroup = 'test-rg'
    $AgentName = 'test-agent'
    $ExtrasFile = Join-Path $FixtureRoot 'extras.json'
    $extras = Get-Content -LiteralPath $ExtrasFile -Raw | ConvertFrom-Json
    $HttpTriggerUrl = if ($Case -eq 'no-trigger') { '' } else { 'https://agent.invalid/trigger' }
    $env:INPUT = $FixtureRoot

    function az {
        $global:LASTEXITCODE = 0
        switch -Wildcard ($args -join ' ') {
            '*listCallbackUrl*' {
                Write-Host 'UNEXPECTED-CALLBACK-REQUEST'
                'https://callback.invalid/?sig=offline-secret'
                $global:LASTEXITCODE = 1
                return
            }
            'resource list *' {
                if ($Case -eq 'lookup-failure') { $global:LASTEXITCODE = 7; return }
                if ($Case -eq 'existing') { 'test-agent-webhook-bridge' }
                return
            }
            'group show *' { 'eastus2'; return }
            'deployment group create *' {
                if ($Case -eq 'cli-failure') { $global:LASTEXITCODE = 7 }
                $state = if ($Case -eq 'state-failure') { 'Failed' } else { 'Succeeded' }
                $name = switch ($Case) { 'missing-name' { '' } 'blank-name' { '   ' } default { 'fixture-bridge' } }
                @{ properties = @{ provisioningState = $state; outputs = @{ logicAppName = @{ value = $name } } } } |
                    ConvertTo-Json -Depth 10 -Compress
                return
            }
            default { throw "Unexpected az command: $args" }
        }
    }

    $path = Join-Path $templates 'bicep\Apply-Extras.ps1'
    if ($Case -eq 'instructions') { $path = Join-Path $templates 'bin\ps\Deploy-Agent.ps1' }
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw "Script failed to parse: $path" }
    if ($Case -eq 'instructions') {
        $Scenario = 'dynatrace-mcp'
        $portalUrl = 'https://agent.invalid/portal'
        function Write-Header { param($Text) Write-Host $Text }
        $block = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.SwitchStatementAst] -and
            $node.Condition.Extent.Text -eq '$Scenario'
        }, $true)
    } else {
        $block = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.IfStatementAst] -and
            $node.Clauses[0].Item1.Extent.Text -eq '$HttpTriggerUrl'
        }, $true)
    }
    if (-not $block) { throw "Webhook section not found: $path" }
    # Run actual script sections with Azure mocked, without deploying resources.
    $section = Join-Path $FixtureRoot 'section.ps1'
    Set-Content -LiteralPath $section -Value $block.Extent.Text
    & $section
    exit 0
}

$temporary = Join-Path ([IO.Path]::GetTempPath()) "webhook-credentials-$([guid]::NewGuid())"
New-Item -ItemType Directory -Path $temporary | Out-Null
$shell = (Get-Process -Id $PID).Path
try {
    foreach ($caseName in @('existing', 'new', 'lookup-failure', 'cli-failure', 'state-failure', 'missing-name', 'blank-name', 'disabled', 'no-trigger', 'instructions')) {
        $enabled = $caseName -ne 'disabled'
        @{ enableWebhookBridge = $enabled } | ConvertTo-Json | Set-Content (Join-Path $temporary 'extras.json')
        @{ toggles = @{ enableWebhookBridge = $enabled } } | ConvertTo-Json | Set-Content (Join-Path $temporary 'agent.json')
        $output = (& $shell -NoProfile -File $PSCommandPath -Case $caseName -FixtureRoot $temporary 2>&1 | Out-String)
        $result = $LASTEXITCODE
        if ($output -match 'offline-secret|UNEXPECTED-CALLBACK-REQUEST') {
            throw "$caseName retrieved or printed a callback credential."
        }
        if ($caseName -in @('lookup-failure', 'cli-failure', 'state-failure', 'missing-name', 'blank-name')) {
            if ($result -eq 0 -or $output -match 'Webhook bridge deployed|listCallbackUrl') {
                throw "$caseName did not report failure: $output"
            }
        } elseif ($caseName -in @('disabled', 'no-trigger')) {
            if ($result -ne 0 -or $output -match 'listCallbackUrl') {
                throw "$caseName displayed bridge instructions: $output"
            }
        } else {
            $name = if ($caseName -eq 'new') { 'fixture-bridge' } else { 'test-agent-webhook-bridge' }
            $expected = "/subscriptions/test-sub/resourceGroups/test-rg/providers/Microsoft.Logic/workflows/$name/triggers/incoming_webhook/listCallbackUrl?api-version=2019-05-01"
            if ($result -ne 0 -or -not $output.Contains($expected) -or -not $output.Contains('--query value -o tsv')) {
                throw "$caseName missing protected retrieval instructions: $output"
            }
        }
        Write-Host "PASS: PowerShell webhook credentials: $caseName"
    }
} finally {
    Remove-Item -LiteralPath $temporary -Recurse -Force
}
