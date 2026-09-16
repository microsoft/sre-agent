$ErrorActionPreference = 'Stop'

$TemplatesDirectory = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$RepositoryDirectory = (Resolve-Path (Join-Path $TemplatesDirectory '..')).Path
$RecipeDirectory = Join-Path $RepositoryDirectory 'labs/onboardinglab/agent-recipe'
$TemporaryDirectory = Join-Path ([System.IO.Path]::GetTempPath()) "connector-v2-$([guid]::NewGuid())"
$OutputPrefix = Join-Path $TemporaryDirectory 'onboarding'
$ExtrasFile = "$OutputPrefix.extras.json"

New-Item -ItemType Directory -Path $TemporaryDirectory | Out-Null
try {
    & (Join-Path $TemplatesDirectory 'bicep/Assemble-Agent.ps1') `
        -ConfigDir $RecipeDirectory -Output $OutputPrefix | Out-Null

    $extras = Get-Content $ExtrasFile -Raw | ConvertFrom-Json
    if (@($extras.connectorV2).Count -ne 1 -or
        $extras.connectorV2[0].metadata.name -ne 'outlook' -or
        $extras.connectorV2[0].spec.apiName -ne 'office365' -or
        $extras.connectorV2[0].spec.connectionName -ne 'office365') {
        throw 'PowerShell assembly did not emit the expected Outlook ConnectorV2 definition.'
    }
    @{ connectorV2 = @($extras.connectorV2); knowledgeItems = @($extras.knowledgeItems) } |
        ConvertTo-Json -Depth 20 |
        Set-Content (Join-Path $TemporaryDirectory 'connector.extras.json')
    $ConnectorExtrasFile = Join-Path $TemporaryDirectory 'connector.extras.json'

    $global:ConnectorV2TestCalls = [System.Collections.Generic.List[string]]::new()
    $global:ConnectorV2TestBodies = @{}
    $global:KnowledgeTestCalls = [System.Collections.Generic.List[string]]::new()

    function global:az {
        if ($args[0] -eq 'rest') {
            $global:LASTEXITCODE = 0
            return '{"properties":{"agentEndpoint":"https://agent.test"},"identity":{"userAssignedIdentities":{}}}'
        }
        if ($args[0] -eq 'account' -and $args[1] -eq 'get-access-token') {
            $global:LASTEXITCODE = 0
            return 'test-token'
        }
        throw "Unexpected az call: $args"
    }

    function global:Mock-InvokeRestMethod {
        param(
            [string]$Uri,
            [string]$Method,
            [hashtable]$Headers,
            [object]$Body,
            [string]$ContentType,
            [int]$TimeoutSec
        )
        $global:ConnectorV2TestCalls.Add($Uri)
        if ($null -ne $Body) { $global:ConnectorV2TestBodies[$Uri] = "$Body" }
        if ($Uri -eq 'https://agent.test/api/v2/connectorV2/connections/office365') {
            return [pscustomobject]@{
                properties = [pscustomobject]@{ overallStatus = 'Connected' }
            }
        }
        return [pscustomobject]@{}
    }
    Set-Alias -Name Invoke-RestMethod -Value Mock-InvokeRestMethod -Scope Global

    function global:curl {
        $url = @($args | Where-Object { "$_" -like 'http*' } | Select-Object -First 1)
        $global:KnowledgeTestCalls.Add("$url")
        Write-Output '{}'
        Write-Output '200'
    }

    & (Join-Path $TemplatesDirectory 'bicep/Apply-Extras.ps1') `
        -Subscription test-subscription `
        -ResourceGroup test-resource-group `
        -AgentName test-agent `
        -ExtrasFile $ConnectorExtrasFile | Out-Null

    $expectedCalls = @(
        'https://agent.test/api/v2/connectorV2/connections/office365'
        'https://agent.test/api/v2/connectorV2/connections/office365/accessPolicies/office365-policy'
        'https://agent.test/api/v2/connectorV2/mcpservers/office365'
    )
    if (($global:ConnectorV2TestCalls -join "`n") -ne ($expectedCalls -join "`n")) {
        throw "Unexpected ConnectorV2 call sequence:`n$($global:ConnectorV2TestCalls -join "`n")"
    }

    $expectedKnowledgeCalls = @(
        'https://agent.test/api/v2/extendedAgent/connectors/onboardinglab-architecture-md'
        'https://agent.test/api/v2/extendedAgent/connectors/onboardinglab-incident-r-2bcbfae'
    )
    if (($global:KnowledgeTestCalls -join "`n") -ne ($expectedKnowledgeCalls -join "`n")) {
        throw "Unexpected Knowledge Source calls:`n$($global:KnowledgeTestCalls -join "`n")"
    }

    $mcpBody = $global:ConnectorV2TestBodies[$expectedCalls[2]] | ConvertFrom-Json
    $binding = @($mcpBody.properties.connectors)
    if ($binding.Count -ne 1 -or $binding[0].name -ne 'office365' -or $binding[0].connectionName -ne 'office365') {
        throw 'PowerShell did not bind the Office 365 connection to the MCP server configuration.'
    }

    Write-Host 'PASS: PowerShell deploys valid Knowledge Sources and the complete Outlook ConnectorV2 binding'
} finally {
    Remove-Item Function:\global:az -ErrorAction SilentlyContinue
    Remove-Item Alias:\global:Invoke-RestMethod -ErrorAction SilentlyContinue
    Remove-Item Function:\global:Mock-InvokeRestMethod -ErrorAction SilentlyContinue
    Remove-Item Function:\global:curl -ErrorAction SilentlyContinue
    Remove-Variable ConnectorV2TestCalls -Scope Global -ErrorAction SilentlyContinue
    Remove-Variable ConnectorV2TestBodies -Scope Global -ErrorAction SilentlyContinue
    Remove-Variable KnowledgeTestCalls -Scope Global -ErrorAction SilentlyContinue
    Remove-Item $TemporaryDirectory -Recurse -Force -ErrorAction SilentlyContinue
}