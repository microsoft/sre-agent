#requires -Version 7.0
<#
Offline regression tests. Run from the lab root with pwsh -NoProfile -File ./tests/deployment-scripts.tests.ps1
All external command boundaries are replaced by fail-closed PowerShell functions; no Pester or Azure login is needed.
#>
$ErrorActionPreference = 'Stop'
$labRoot = Split-Path $PSScriptRoot -Parent
$permissionScript = Join-Path $labRoot 'agent-setup/apply-permissions.ps1'
$agentDeploymentScript = Join-Path $labRoot 'scripts/deploy-agent.ps1'
$deploymentScript = Join-Path $labRoot 'scripts/deploy-use-cases.ps1'
$faultScript = Join-Path $labRoot 'scripts/fault.ps1'
. (Join-Path $labRoot 'scripts/internal/LabEnvironment.ps1')

$subscription = '11111111-1111-1111-1111-111111111111'
$resourceId = "/subscriptions/$subscription/resourceGroups/lab-rg/providers/Microsoft.App/agents/lab-agent"
$origin = 'https://lab-agent.example.test'
$expectedPolicy = @{
    permissions = @{
        allow = @(
            'GetAzCliHelp', 'RunAzCliReadCommands', 'ReadFile', 'ListDir', 'FileSearch', 'GrepSearch',
            'Task', 'read_skill_file', 'ManageTodoList', 'system-mcp-monitor/*', 'FetchGithubIssue',
            'FetchGithubIssues', 'CreateGithubIssue', 'ListOutlookEmails', 'SendOutlookEmail'
        )
        ask = @()
        deny = @(
            'RunAzCliWriteCommands', 'RunKubectlWriteCommand', 'RunInTerminal', 'Terminal', 'CreateFile',
            'CreateDirectory', 'SaveFileToBlob', 'ReplaceStringInFile', 'MultiReplaceStringInFile'
        )
    }
}
$legacyPolicy = @{
    permissions = @{
        allow = @('GetAzCliHelp', 'ReadFile', 'GrepSearch', 'FetchGithubIssues')
        ask = @('*')
        deny = @()
    }
}
$passed = 0
$failures = [System.Collections.Generic.List[string]]::new()
$savedExitCode = Get-Variable LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue

function Assert-True([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw $Message }
}

function Assert-Throws([scriptblock] $Action, [string] $Pattern) {
    $caught = $null
    try { & $Action | Out-Null }
    catch { $caught = $_ }
    Assert-True ($null -ne $caught) "Expected an error matching: $Pattern"
    Assert-True ($caught.Exception.Message -match $Pattern) "Unexpected error: $($caught.Exception.Message)"
}

function Reset-Mocks {
    $script:mock = @{
        Agent = @{ id = $resourceId; properties = @{ agentEndpoint = $origin; actionConfiguration = @{ mode = 'Review' } } }
        Feature = '{"enabled":true}'
        FeatureStatus = 200
        Settings = @{ permissions = @{ allow = @(); ask = @(); deny = @() } }
        ETagHeaders = @{}
        PutStatus = 200
        AzCalls = [System.Collections.Generic.List[object]]::new()
        AzdCalls = [System.Collections.Generic.List[object]]::new()
        HttpCalls = [System.Collections.Generic.List[object]]::new()
        HeaderReferences = [System.Collections.Generic.List[object]]::new()
        ParameterFiles = [System.Collections.Generic.List[string]]::new()
        DeploymentExitCode = 0
        DeploymentResponse = '{"properties":{"provisioningState":"Succeeded","outputs":{"result":{"value":"mock-output"}}}}'
        AzdExitCode = 0
        Values = @{
            AZURE_SUBSCRIPTION_ID = $subscription
            AZURE_RESOURCE_GROUP = 'lab-rg'
            SRE_AGENT_NAME = 'lab-agent'
            SRE_AGENT_RESOURCE_ID = $resourceId
            CHECKOUT_APP_ID = '/mock/checkout'
            POSTGRES_SERVER_ID = '/mock/postgres'
            APPLICATION_INSIGHTS_ID = '/mock/insights'
            APPLICATION_INSIGHTS_APP_ID = 'mock-app-id'
            LAB_NAME_PREFIX = 'lab'
            AZURE_LOCATION = 'eastus2'
        }
    }
}

function Get-ArgumentValue([object[]] $Arguments, [string] $Name) {
    $index = [array]::IndexOf($Arguments, $Name)
    Assert-True ($index -ge 0 -and $index + 1 -lt $Arguments.Count) "Missing command argument: $Name"
    return $Arguments[$index + 1]
}

# Basic functions intentionally capture native-style flags in $args, without PowerShell parameter coercion.
function az {
    $mock.AzCalls.Add(@($args))
    $global:LASTEXITCODE = 0
    if ($args[0] -eq 'rest') {
        Assert-True ((Get-ArgumentValue $args '--url') -eq "https://management.azure.com${resourceId}?api-version=2026-01-01") 'Unexpected ARM URL'
        Assert-True ((Get-ArgumentValue $args '--method') -eq 'get') 'ARM must only be read'
        return ($mock.Agent | ConvertTo-Json -Depth 10 -Compress)
    }
    if (($args[0..2] -join ' ') -eq 'account get-access-token --subscription') {
        Assert-True ((Get-ArgumentValue $args '--resource') -eq 'https://azuresre.dev') 'Unexpected token audience'
        return 'offline-test-token'
    }
    if (($args[0..2] -join ' ') -eq 'deployment group create') {
        $parameterArgument = Get-ArgumentValue $args '--parameters'
        Assert-True ($parameterArgument.StartsWith('@')) 'Parameters must use a file, not shell interpolation'
        $file = $parameterArgument.Substring(1)
        $mock.ParameterFiles.Add($file)
        Assert-True (Test-Path -LiteralPath $file) 'Parameter file must exist during deployment'
        $mock.DeploymentDocument = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json -AsHashtable
        $global:LASTEXITCODE = $mock.DeploymentExitCode
        return $mock.DeploymentResponse
    }
    throw "Unexpected az invocation: $args"
}

function azd {
    $mock.AzdCalls.Add(@($args))
    Assert-True ($args.Count -eq 5 -and $args[0] -eq '-C' -and $args[2] -eq 'env' -and $args[3] -eq 'get-value') 'Unexpected azd invocation'
    Assert-True ($args[1] -eq $labRoot) 'azd must be scoped to the lab directory'
    $global:LASTEXITCODE = $mock.AzdExitCode
    return $mock.Values[$args[4]]
}

function Invoke-WebRequest {
    [CmdletBinding()]
    param($Uri, $Method, $Headers, $MaximumRedirection, $MaximumRetryCount, $ContentType, $Body)

    Assert-True ($MaximumRedirection -eq 0 -and $MaximumRetryCount -eq 0) 'HTTP redirects and retries must be disabled'
    Assert-True ($Headers.Authorization -eq 'Bearer offline-test-token') 'Expected mock bearer token'
    $mock.HeaderReferences.Add($Headers)
    $mock.HttpCalls.Add(@{ Uri = [string]$Uri; Method = [string]$Method; Headers = $Headers.Clone(); Body = $Body })
    if ($Uri -eq "$origin/api/v1/Feature/status/enableV2AgentLoop" -and $Method -eq 'Get') {
        return @{ StatusCode = $mock.FeatureStatus; Content = $mock.Feature }
    }
    Assert-True ($Uri -eq "$origin/api/v2/agent/settings/global") 'Only the V2 settings endpoint is permitted'
    if ($Method -eq 'Get') {
        return @{ StatusCode = 200; Content = ($mock.Settings | ConvertTo-Json -Depth 10 -Compress); Headers = $mock.ETagHeaders }
    }
    if ($Method -eq 'Put') {
        Assert-True ($ContentType -eq 'application/json') 'Expected JSON PUT'
        if ($mock.PutStatus -eq 412) {
            $exception = [System.Exception]::new('Mock precondition failure')
            $exception | Add-Member -NotePropertyName Response -NotePropertyValue ([pscustomobject]@{ StatusCode = 412 })
            throw $exception
        }
        return @{ StatusCode = $mock.PutStatus }
    }
    throw "Unexpected HTTP method: $Method"
}

function Invoke-Permissions([switch] $CheckOnly) {
    & $permissionScript -SubscriptionId $subscription -ResourceId $resourceId -CheckOnly:$CheckOnly
}

function Assert-NoPut {
    Assert-True (@($mock.HttpCalls | Where-Object Method -eq 'Put').Count -eq 0) 'Unexpected permission PUT'
}

function Assert-V2First {
    Assert-True ($mock.HttpCalls.Count -ge 2) 'Expected feature check followed by settings GET'
    Assert-True ($mock.HttpCalls[0].Uri -eq "$origin/api/v1/Feature/status/enableV2AgentLoop") 'V2 must be checked first'
    Assert-True ($mock.HttpCalls[1].Uri -eq "$origin/api/v2/agent/settings/global" -and $mock.HttpCalls[1].Method -eq 'Get') 'Expected V2 settings GET second'
}

function New-UseCaseArguments {
    return @{
        GitHubRepositoryUrl = 'https://github.com/example/lab-repo'
        EmailRecipients = @('first@example.test', 'second@example.test')
        EmailConnectorName = 'existing-email'
    }
}

function Invoke-Test([string] $Name, [scriptblock] $Body) {
    Reset-Mocks
    try {
        & $Body | Out-Null
        foreach ($file in $mock.ParameterFiles) {
            Assert-True (-not (Test-Path -LiteralPath $file)) 'Temporary deployment parameter file was not deleted'
        }
        foreach ($headers in $mock.HeaderReferences) {
            Assert-True ($headers.Count -eq 0) 'Authorization headers were not cleared'
        }
        $script:passed++
        Write-Host "PASS $Name"
    }
    catch {
        $failures.Add("${Name}: $($_.Exception.Message)")
        Write-Host "FAIL ${Name}: $($_.Exception.Message)"
    }
    finally {
        # Clean up even when a regression leaves a file behind (the assertion above still fails).
        foreach ($file in $mock.ParameterFiles) {
            if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force }
        }
    }
}

try {
    Invoke-Test 'fault injection closes only resolved instances of the exact lab alert rule' {
        $source = Get-Content -LiteralPath $faultScript -Raw
        Assert-True ($source -match [regex]::Escape('alertRule -ieq $alertRuleId')) 'Fault helper must scope prior alerts to the exact rule'
        Assert-True ($source -match [regex]::Escape("monitorCondition -ine 'Resolved'")) 'Fault helper must reject an active prior alert'
        Assert-True ($source -match 'changestate\?api-version=2019-03-01&newState=Closed') 'Fault helper must close resolved prior instances'
    }

    Invoke-Test 'signed-in user lookup is tenant-scoped without unsupported subscription argument' {
        $source = Get-Content -LiteralPath $agentDeploymentScript -Raw
        $commands = @($source -split "`r?`n" | Where-Object { $_ -match 'az ad signed-in-user show' })
        Assert-True ($commands.Count -eq 1) 'Expected exactly one signed-in-user lookup'
        Assert-True ($commands[0] -notmatch '--subscription') 'az ad signed-in-user show does not support --subscription'
    }

    Invoke-Test 'install bounded autonomous policy with reads and follow-ups allowed and mutations denied' {
        Invoke-Permissions
        Assert-V2First
        Assert-True ($mock.HttpCalls.Count -eq 3) 'Expected exactly one PUT'
        $put = $mock.HttpCalls[2]
        Assert-True ($put.Method -eq 'Put' -and $put.Headers['If-Match'] -eq '*') 'Absent ETag on empty policy must use wildcard'
        $installed = ($put.Body | ConvertFrom-Json -AsHashtable).permissions
        Assert-True ($installed.allow.Count -eq $expectedPolicy.permissions.allow.Count) 'Unexpected allow count'
        Assert-True (($installed.allow -join ',') -ceq ($expectedPolicy.permissions.allow -join ',')) 'Unexpected allow policy'
        Assert-True ($installed.allow -contains 'RunAzCliReadCommands') 'Azure reads must run unattended'
        Assert-True ($installed.allow -contains 'CreateGithubIssue' -and $installed.allow -contains 'SendOutlookEmail') 'Configured follow-up writes must be allowed'
        Assert-True ($installed.ask.Count -eq 0) 'The incident path must not pause for approval'
        Assert-True ($installed.deny -contains 'RunAzCliWriteCommands' -and $installed.deny -contains 'RunInTerminal') 'Mutation tools must be denied'
    }
    Invoke-Test 'migrate exact legacy lab policy with strong ETag' {
        $mock.Settings = $legacyPolicy
        $mock.ETagHeaders = @{ ETag = @('"legacy-revision"') }
        Invoke-Permissions
        Assert-True ($mock.HttpCalls.Count -eq 3) 'Expected one migration PUT'
        Assert-True ($mock.HttpCalls[2].Headers['If-Match'] -ceq '"legacy-revision"') 'Legacy migration must use the strong ETag'
        $installed = $mock.HttpCalls[2].Body | ConvertFrom-Json -AsHashtable
        foreach ($kind in @('allow', 'ask', 'deny')) {
            $actualSet = [System.Collections.Generic.HashSet[string]]::new([string[]]$installed.permissions[$kind], [System.StringComparer]::OrdinalIgnoreCase)
            Assert-True ($actualSet.SetEquals([string[]]$expectedPolicy.permissions[$kind])) "Migration installed the wrong $kind policy"
        }
    }
    Invoke-Test 'legacy lab policy without ETag fails closed' {
        $mock.Settings = $legacyPolicy
        Assert-Throws { Invoke-Permissions } 'legacy lab policy.*no ETag'
        Assert-NoPut
    }

    foreach ($checkOnly in @($false, $true)) {
        Invoke-Test "equal policy succeeds without PUT (CheckOnly=$checkOnly)" {
            $mock.Settings = $expectedPolicy
            Invoke-Permissions -CheckOnly:$checkOnly
            Assert-V2First
            Assert-NoPut
        }
    }
    Invoke-Test 'equal policy comparison is case and order insensitive' {
        $mock.Settings.permissions = @{
            allow = @($expectedPolicy.permissions.allow | ForEach-Object { $_.ToUpperInvariant() } | Sort-Object -Descending)
            ask = @()
            deny = @($expectedPolicy.permissions.deny | ForEach-Object { $_.ToLowerInvariant() } | Sort-Object -Descending)
        }
        Invoke-Permissions
        Assert-V2First
        Assert-NoPut
    }

    # Exercise each otherwise-successful path: installation, equal policy, and equal CheckOnly.
    foreach ($feature in @('{"enabled":false}', '{"enabled":"true"}', '{"enabled":1}', '{"enabled":null}', '{}', 'not-json')) {
        foreach ($path in @('install', 'equal', 'check-only')) {
            Invoke-Test "reject V2 $feature before $path" {
                $mock.Feature = $feature
                if ($path -ne 'install') { $mock.Settings = $expectedPolicy }
                Assert-Throws { Invoke-Permissions -CheckOnly:($path -eq 'check-only') } 'V2'
                Assert-NoPut
                Assert-True ($mock.HttpCalls.Count -eq 1) 'Must stop before reading settings when V2 is not Boolean true'
            }
        }
    }
    Invoke-Test 'non-200 V2 response fails even with Boolean true' {
        $mock.FeatureStatus = 503
        Assert-Throws { Invoke-Permissions } 'V2'
        Assert-NoPut
    }
    Invoke-Test 'empty CheckOnly fails without PUT' {
        Assert-Throws { Invoke-Permissions -CheckOnly } 'permissions are empty'
        Assert-V2First
        Assert-NoPut
    }
    foreach ($checkOnly in @($false, $true)) {
        Invoke-Test "differing nonempty policy fails (CheckOnly=$checkOnly)" {
            $mock.Settings.permissions.allow = @('RunAzCliReadCommands')
            Assert-Throws { Invoke-Permissions -CheckOnly:$checkOnly } 'nonempty global permissions differ'
            Assert-NoPut
        }
    }
    Invoke-Test 'strong ETag is forwarded exactly' {
        $mock.ETagHeaders = @{ ETag = @('"revision-42"') }
        Invoke-Permissions
        Assert-True ($mock.HttpCalls[2].Headers['If-Match'] -ceq '"revision-42"') 'ETag changed'
    }
    foreach ($etag in @('W/"revision-42"', '', 'unquoted')) {
        Invoke-Test "reject present invalid ETag [$etag]" {
            $mock.ETagHeaders = @{ ETag = @($etag) }
            Assert-Throws { Invoke-Permissions } 'invalid strong ETag'
            Assert-NoPut
        }
    }
    Invoke-Test '412 makes exactly one PUT and never retries' {
        $mock.PutStatus = 412
        Assert-Throws { Invoke-Permissions } 'HTTP 412.*No retry'
        Assert-True ($mock.HttpCalls.Count -eq 3) 'Unexpected retry after conflict'
        Assert-True (@($mock.HttpCalls | Where-Object Method -eq 'Put').Count -eq 1) 'Expected one PUT attempt'
    }
    foreach ($suffix in @('?x=1', '#fragment', '/extra', '%2Fextra')) {
        Invoke-Test "reject invalid resource ID suffix $suffix before az" {
            Assert-Throws { & $permissionScript -SubscriptionId $subscription -ResourceId "$resourceId$suffix" } 'ResourceId must'
            Assert-True ($mock.AzCalls.Count -eq 0 -and $mock.HttpCalls.Count -eq 0) 'Invalid resource ID reached external commands'
        }
    }
    Invoke-Test 'reject resource from another subscription before az' {
        Assert-Throws { & $permissionScript -SubscriptionId '22222222-2222-2222-2222-222222222222' -ResourceId $resourceId } 'ResourceId must'
        Assert-True ($mock.AzCalls.Count -eq 0) 'Subscription mismatch reached az'
    }
    foreach ($endpoint in @('http://agent.example.test', 'https://agent.example.test/path', 'https://agent.example.test?x=1', 'https://agent.example.test:8443', 'https://user@agent.example.test', 'https://127.0.0.1')) {
        Invoke-Test "reject ARM endpoint $endpoint before token acquisition" {
            $mock.Agent.properties.agentEndpoint = $endpoint
            Assert-Throws { Invoke-Permissions } 'HTTPS agent origin'
            Assert-True ($mock.AzCalls.Count -eq 1 -and $mock.HttpCalls.Count -eq 0) 'Invalid endpoint reached authenticated calls'
        }
    }
    foreach ($mode in @('Autonomous', 'review', '')) {
        Invoke-Test "reject ARM mode [$mode]" {
            $mock.Agent.properties.actionConfiguration.mode = $mode
            Assert-Throws { Invoke-Permissions } 'mode must be Review'
            Assert-True ($mock.AzCalls.Count -eq 1 -and $mock.HttpCalls.Count -eq 0) 'Invalid mode reached authenticated calls'
        }
    }
    Invoke-Test 'reject mismatched ARM response identity' {
        $mock.Agent.id = "$resourceId-other"
        Assert-Throws { Invoke-Permissions } 'ARM agent identity must match'
        Assert-True ($mock.HttpCalls.Count -eq 0) 'Mismatched identity reached HTTP'
    }

    foreach ($url in @('https://example.test/owner/repo', 'https://github.com/owner/repo?x=1', 'https://github.com/owner/%72epo', 'https://github.com:8443/owner/repo')) {
        Invoke-Test "reject repository URL $url before azd" {
            $arguments = New-UseCaseArguments
            $arguments.GitHubRepositoryUrl = $url
            Assert-Throws { & $deploymentScript @arguments } 'Supply https://github.com'
            Assert-True ($mock.AzdCalls.Count -eq 0 -and $mock.AzCalls.Count -eq 0) 'Invalid URL reached azd or az'
        }
    }
    Invoke-Test 'EnableIncidents requires ConfirmConnectionsReady before azd' {
        $arguments = New-UseCaseArguments
        Assert-Throws { & $deploymentScript @arguments -EnableIncidents } 'ConfirmConnectionsReady'
        Assert-True ($mock.AzdCalls.Count -eq 0 -and $mock.AzCalls.Count -eq 0) 'Unconfirmed activation reached azd or az'
    }
    foreach ($recipient in @('not-an-address', 'Display Name <person@example.test>', ' person@example.test ', "person@example.test`r`nBcc:other@example.test")) {
        Invoke-Test "reject invalid supplied recipient [$($recipient.Replace("`r", '\r').Replace("`n", '\n'))]" {
            $arguments = New-UseCaseArguments
            $arguments.EmailRecipients = @('valid@example.test', $recipient)
            Assert-Throws { & $deploymentScript @arguments } 'email'
            Assert-True ($mock.AzdCalls.Count -eq 0 -and $mock.AzCalls.Count -eq 0) 'Invalid recipient reached azd or az'
        }
    }
    foreach ($enabled in @($false, $true)) {
        Invoke-Test "mock use-case deployment preserves arrays and Boolean (enabled=$enabled), cleans file" {
            $arguments = New-UseCaseArguments
            $mock.Settings = $expectedPolicy
            & $deploymentScript @arguments -EnableIncidents:$enabled -ConfirmConnectionsReady:$enabled
            $parameters = $mock.DeploymentDocument.parameters
            Assert-True ($parameters.emailRecipients.value -is [array] -and $parameters.emailRecipients.value.Count -eq 2) 'Recipients must remain an array'
            Assert-True (($parameters.emailRecipients.value -join ',') -ceq ($arguments.EmailRecipients -join ',')) 'Recipients changed'
            Assert-True ($parameters.enableIncidents.value -is [bool] -and $parameters.enableIncidents.value -eq $enabled) 'Boolean was coerced or changed'
            Assert-True ($parameters.alertSeverity.value -eq 2 -and $parameters.githubRepositoryUrl.value -ceq $arguments.GitHubRepositoryUrl) 'Parameters changed'
            Assert-True ($mock.ParameterFiles.Count -eq 1) 'Expected one deployment'
            Assert-NoPut
            if ($enabled) { Assert-V2First }
            else { Assert-True ($mock.HttpCalls.Count -eq 0) 'Disabled incidents should not check permissions' }
            $call = $mock.AzCalls[$mock.AzCalls.Count - 1]
            Assert-True ((Get-ArgumentValue $call '--mode') -eq 'Incremental') 'Deployment must be incremental'
            Assert-True ((Get-ArgumentValue $call '--subscription') -eq $subscription -and (Get-ArgumentValue $call '--resource-group') -eq 'lab-rg') 'Wrong deployment scope'
        }
    }
    Invoke-Test 'activation with empty policy cannot install permissions or deploy' {
        $arguments = New-UseCaseArguments
        Assert-Throws { & $deploymentScript @arguments -EnableIncidents -ConfirmConnectionsReady } 'permissions are empty'
        Assert-NoPut
        Assert-True ($mock.ParameterFiles.Count -eq 0) 'Failed activation still deployed'
    }

    Invoke-Test 'Get-LabValue trims multiline output' {
        $mock.Values.TEST_VALUE = @('  first', 'second  ')
        Assert-True ((Get-LabValue 'TEST_VALUE') -ceq "first`nsecond") 'Unexpected trimming or joining'
    }
    foreach ($exitCode in @(0, 1)) {
        Invoke-Test "missing or failed azd value is optional only when requested (exit=$exitCode)" {
            $mock.AzdExitCode = $exitCode
            $mock.Values.TEST_VALUE = '   '
            if ($exitCode -ne 0) { $mock.Values.TEST_VALUE = 'untrusted output' }
            Assert-Throws { Get-LabValue 'TEST_VALUE' } 'Missing azd value'
            Assert-True ($null -eq (Get-LabValue 'TEST_VALUE' -Optional)) 'Optional missing value must be null'
        }
    }
    foreach ($outcome in @('success', 'cli-error', 'malformed-json', 'failed-state')) {
        Invoke-Test "Invoke-LabDeployment $outcome preserves types and cleans temporary file" {
            switch ($outcome) {
                'cli-error' { $mock.DeploymentExitCode = 1 }
                'malformed-json' { $mock.DeploymentResponse = 'not-json' }
                'failed-state' { $mock.DeploymentResponse = '{"properties":{"provisioningState":"Failed"}}' }
            }
            $deploy = {
                Invoke-LabDeployment -SubscriptionId $subscription -ResourceGroup 'lab-rg' -Name 'offline-test' `
                    -TemplateFile (Join-Path $labRoot 'use-cases/main.bicep') `
                    -Parameters @{ recipients = @('only@example.test'); enabled = $false; empty = @() }
            }
            if ($outcome -eq 'success') {
                $outputs = & $deploy
                Assert-True ($outputs.result.value -eq 'mock-output') 'Deployment outputs not returned'
            }
            else { Assert-Throws $deploy 'failed|invalid deployment response|did not report success' }
            Assert-True ($mock.ParameterFiles.Count -eq 1 -and $mock.AzCalls.Count -eq 1) 'Expected exactly one deployment attempt'
            $parameters = $mock.DeploymentDocument.parameters
            Assert-True ($parameters.recipients.value -is [array] -and $parameters.recipients.value.Count -eq 1) 'Singleton array was flattened'
            Assert-True ($parameters.empty.value -is [array] -and $parameters.empty.value.Count -eq 0) 'Empty array was lost'
            Assert-True ($parameters.enabled.value -is [bool] -and -not $parameters.enabled.value) 'False Boolean was lost'
        }
    }
    Invoke-Test 'missing template fails before az' {
        Assert-Throws {
            Invoke-LabDeployment -SubscriptionId $subscription -ResourceGroup 'lab-rg' -Name 'offline-test' `
                -TemplateFile (Join-Path $PSScriptRoot 'does-not-exist.bicep') -Parameters @{}
        } 'template is missing'
        Assert-True ($mock.AzCalls.Count -eq 0 -and $mock.ParameterFiles.Count -eq 0) 'Missing template reached deployment'
    }
}
finally {
    if ($null -ne $savedExitCode) { $global:LASTEXITCODE = $savedExitCode.Value }
    else { Remove-Variable LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue }
}

Write-Host "`nResults: $passed passed, $($failures.Count) failed."
if ($failures.Count -gt 0) { throw ($failures -join "`n") }