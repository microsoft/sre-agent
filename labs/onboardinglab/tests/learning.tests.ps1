#requires -Version 7.0
# Run: Invoke-Pester .\labs\onboardinglab\tests\learning.tests.ps1
BeforeAll {
    . (Join-Path $PSScriptRoot '..\scripts\learning.ps1')
    function az { throw 'Tests must mock every Azure CLI call.' }
    $script:agentId = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/lab-rg/providers/Microsoft.App/agents/lab-agent'
    $script:appId = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/lab-rg/providers/Microsoft.Insights/components/lab-ai'
    $script:appGuid = '22222222-2222-2222-2222-222222222222'
    function New-TestOptions {
        return @{
            Action = 'Skill'; AgentResourceId = $script:agentId; Name = 'onboarding-learned-checkout'
            MarkdownPath = (Join-Path $TestDrive 'lesson.md'); Description = 'Use checkout and PostgreSQL evidence.'
        }
    }
    function New-TestResponse($Status, $Body, $ETag = '"v1"') {
        return @{ StatusCode = $Status; Content = $(if ($null -ne $Body) { ConvertTo-Json -InputObject $Body -Depth 60 -Compress } else { '' }); Headers = @{ ETag = @($ETag) } }
    }
    function Copy-TestObject($Object) {
        return ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $Object -Depth 60) -AsHashtable
    }
}

Describe 'Onboarding learner persistence and request contracts' {
    BeforeEach {
        Set-Content -LiteralPath (Join-Path $TestDrive 'lesson.md') -Value "# Checkout evidence`nRequire fresh PostgreSQL success." -NoNewline
        $script:context = @{ AgentId = $script:agentId; Endpoint = 'https://lab-agent.region.azuresre.ai'; Token = 'never-print-this-test-token' }
        $script:objects = @{}
        $script:requests = [Collections.Generic.List[object]]::new()
        Mock New-LearningContext { return $script:context }
        Mock Write-Host {}
        Mock Invoke-WebRequest {
            param($Uri, $Method, $Headers, $Body, $MaximumRedirection, $TimeoutSec, $ConnectionTimeoutSeconds, $SkipHttpErrorCheck)
            $path = ([uri] $Uri).AbsolutePath
            $data = if ($null -ne $Body) { [Text.Encoding]::UTF8.GetString($Body) | ConvertFrom-Json -AsHashtable } else { $null }
            $script:requests.Add(@{ Path = $path; Method = $Method; Headers = $Headers; Body = $data
                Redirects = $MaximumRedirection; Timeout = $(if ($ConnectionTimeoutSeconds) { $ConnectionTimeoutSeconds } else { $TimeoutSec }); SkipHttpErrorCheck = $SkipHttpErrorCheck })
            if ($Method -eq 'GET') {
                if ($script:objects.Contains($path)) { return New-TestResponse 200 $script:objects[$path] }
                return New-TestResponse 404 $null
            }
            $script:objects[$path] = Copy-TestObject $data
            return New-TestResponse 200 $data
        }
    }

    It 'previews the exact tool-free skill envelope without any write' {
        $plan = Invoke-OnboardingLearning (New-TestOptions)
        $operation = $plan.Operations[0]
        $operation.Path | Should -BeExactly '/api/v2/extendedAgent/skills/onboarding-learned-checkout'
        $plan.Endpoint | Should -BeExactly 'https://lab-agent.region.azuresre.ai'
        $operation.Precondition.Count | Should -Be 0
        $operation.Body.type | Should -BeExactly 'Skill'
        @($operation.Body.properties.Keys | Sort-Object) | Should -Be @('additionalFiles', 'description', 'skillContent', 'tools')
        $operation.Body.properties.tools.Count | Should -Be 0
        $operation.Body.properties.additionalFiles.Count | Should -Be 0
        $operation.Body.properties.skillContent | Should -BeExactly (Get-Content (New-TestOptions).MarkdownPath -Raw)
        @($script:requests | Where-Object Method -ne GET).Count | Should -Be 0
        Should -Invoke Write-Host -ParameterFilter { $Object -match 'Plan SHA256:' } -Times 1
        Should -Invoke Write-Host -ParameterFilter { $Object -match 'never-print-this-test-token' } -Times 0
    }

    It 'requires explicit approval and exclusive access before cloud discovery' {
        $options = New-TestOptions
        $options.Apply = $true
        { Invoke-OnboardingLearning $options } | Should -Throw '*Apply requires*'
        Should -Invoke New-LearningContext -Times 0
        $options.ApprovePlan = 'a' * 64
        { Invoke-OnboardingLearning $options } | Should -Throw '*ExclusiveAccess*'
    }

    It 'rejects a mismatched approval without writing' {
        $options = New-TestOptions
        $options.Apply = $true; $options.ApprovePlan = 'a' * 64; $options.ExclusiveAccess = $true
        { Invoke-OnboardingLearning $options } | Should -Throw '*approval hash*'
        @($script:requests | Where-Object Method -eq PUT).Count | Should -Be 0
    }

    It 'performs one approved create and read-back and preserves unrelated objects' {
        $unrelated = @{ name = 'other'; type = 'Skill'; tags = @('keep'); properties = @{ tools = @('OtherTool'); skillContent = 'unchanged' } }
        $script:objects['/api/v2/extendedAgent/skills/other'] = Copy-TestObject $unrelated
        $options = New-TestOptions
        $plan = Invoke-OnboardingLearning $options
        $options.Apply = $true; $options.ApprovePlan = Get-LearningHash $plan; $options.ExclusiveAccess = $true
        Invoke-OnboardingLearning $options
        $puts = @($script:requests | Where-Object Method -eq PUT)
        $puts.Count | Should -Be 1
        $puts[0].Headers.ContainsKey('If-None-Match') | Should -BeFalse
        $puts[0].Body.properties.tools | Should -HaveCount 0
        $puts[0].Redirects | Should -Be 0
        $puts[0].Timeout | Should -Be 30
        (Get-LearningHash $script:objects['/api/v2/extendedAgent/skills/other']) | Should -BeExactly (Get-LearningHash $unrelated)
        $script:requests[-1].Method.ToString().ToUpperInvariant() | Should -BeExactly 'GET'
    }

    It 'rejects existing objects even when their content matches' {
        $plan = Invoke-OnboardingLearning (New-TestOptions)
        $script:objects[$plan.Operations[0].Path] = $plan.Operations[0].Body
        { Invoke-OnboardingLearning (New-TestOptions) } | Should -Throw '*already exists*'
        @($script:requests | Where-Object Method -eq PUT).Count | Should -Be 0
    }

    It 'creates only the isolated handler and disabled schedule, then enables and disables within the approved window' {
        $script:clock = [datetimeoffset]'2026-09-17T21:00:00Z'
        Mock Get-LearningUtcNow { return $script:clock }
        Mock Get-LearningTelemetry { return $script:appGuid }
        Mock Start-Sleep { $script:clock = $script:clock.AddMinutes(5) }
        $options = @{
            Action = 'Schedule'; AgentResourceId = $script:agentId; Name = 'onboarding-health-checkout'
            AppInsightsResourceId = $script:appId; StartUtc = '2026-09-17T21:00:00Z'; EndUtc = '2026-09-17T21:10:00Z'
        }
        $plan = Invoke-OnboardingLearning $options
        @($script:requests | Where-Object Method -eq PUT).Count | Should -Be 0
        $plan.Operations.Count | Should -Be 2
        $options.Apply = $true; $options.ApprovePlan = Get-LearningHash $plan; $options.ExclusiveAccess = $true
        Invoke-OnboardingLearning $options
        $taskPath = '/api/v2/extendedAgent/scheduledtasks/onboarding-health-checkout'
        $handlerPath = '/api/v2/extendedAgent/agents/onboarding-health-checkout-reader'
        $script:objects[$taskPath].properties.status | Should -BeExactly 'Paused'
        $script:objects[$handlerPath].properties.tools | Should -Be @('QueryAppInsightsUsingAppId')
        @($script:requests | Where-Object Method -eq PUT).Count | Should -Be 2
        $toggle = @{ Action = 'Enable'; AgentResourceId = $script:agentId; Name = 'onboarding-health-checkout' }
        $enablePlan = Invoke-OnboardingLearning $toggle
        @($script:requests | Where-Object Method -eq PUT).Count | Should -Be 2
        $toggle.Apply = $true; $toggle.ApprovePlan = Get-LearningHash $enablePlan; $toggle.ExclusiveAccess = $true
        Invoke-OnboardingLearning $toggle
        $script:objects[$taskPath].properties.status | Should -BeExactly 'Paused'
        $writes = @($script:requests | Where-Object Method -eq PUT)
        $writes.Count | Should -Be 4
        $writes[2].Body.properties.status | Should -BeExactly 'Active'
        $writes[3].Body.properties.status | Should -BeExactly 'Paused'
        $writes[2].Headers.ContainsKey('If-Match') | Should -BeFalse
        $writes[3].Headers.ContainsKey('If-Match') | Should -BeFalse
        Should -Invoke Start-Sleep -Times 2
    }

    It 'disables a verified task when the foreground timer is interrupted' {
        $script:clock = [datetimeoffset]'2026-09-17T21:00:00Z'
        Mock Get-LearningUtcNow { return $script:clock }
        Mock Get-LearningTelemetry { return $script:appGuid }
        Mock Start-Sleep { throw 'simulated interrupt' }
        $bodies = New-LearningScheduleBodies 'onboarding-health-checkout' $script:appId $script:appGuid '2026-09-17T21:00:00Z' '2026-09-17T21:10:00Z'
        $taskPath = '/api/v2/extendedAgent/scheduledtasks/onboarding-health-checkout'
        $script:objects[$taskPath] = Copy-TestObject $bodies.Task
        $script:objects['/api/v2/extendedAgent/agents/onboarding-health-checkout-reader'] = Copy-TestObject $bodies.Handler
        $options = @{ Action = 'Enable'; AgentResourceId = $script:agentId; Name = 'onboarding-health-checkout' }
        $plan = Invoke-OnboardingLearning $options
        $options.Apply = $true; $options.ApprovePlan = Get-LearningHash $plan; $options.ExclusiveAccess = $true
        { Invoke-OnboardingLearning $options } | Should -Throw '*simulated interrupt*'
        $script:objects[$taskPath].properties.status | Should -BeExactly 'Paused'
        @($script:requests | Where-Object Method -eq PUT).Count | Should -Be 2
    }

    It 'detects a concurrent create immediately before PUT' {
        $plan = Invoke-OnboardingLearning (New-TestOptions)
        $script:objects[$plan.Operations[0].Path] = @{ name = 'concurrent writer' }
        { Invoke-LearningOperation $script:context $plan.Operations[0] } | Should -Throw '*Concurrent create*'
        @($script:requests | Where-Object Method -eq PUT).Count | Should -Be 0
    }

    It 'rejects frontmatter and names outside the owned namespace' {
        $options = New-TestOptions
        Set-Content $options.MarkdownPath "---`ntools: [RunAzCliWriteCommands]`n---`nText"
        { Invoke-OnboardingLearning $options } | Should -Throw '*without YAML frontmatter*'
        $options.Name = 'sre-agent-self-configure'
        { Invoke-OnboardingLearning $options } | Should -Throw '*Name must start*'
        $options.Name = 'onboarding-learned-../../bad'
        { Invoke-OnboardingLearning $options } | Should -Throw '*Name must start*'
    }

    It 'recognizes the live skillMdContent response alias but rejects conflicting or missing fields' {
        $body = (Invoke-OnboardingLearning (New-TestOptions)).Operations[0].Body
        $actual = Copy-TestObject $body
        $actual.properties.skillMdContent = $actual.properties.skillContent
        $actual.properties.Remove('skillContent')
        { Assert-LearningReadback $actual $body } | Should -Not -Throw
        $actual.properties.skillContent = 'different'
        { Assert-LearningReadback $actual $body } | Should -Throw '*contradictory*'
        $actual.properties.Remove('skillContent')
        $actual.properties.Remove('tools')
        { Assert-LearningReadback $actual $body } | Should -Throw '*missing properties.tools*'
    }

    It 'normalizes service empty lists but rejects a write-capable read-back' {
        $body = (Invoke-OnboardingLearning (New-TestOptions)).Operations[0].Body
        $actual = Copy-TestObject $body
        $actual.properties.tools = $null
        { Assert-LearningReadback $actual $body } | Should -Not -Throw
        $actual.properties.tools = @('RunAzCliWriteCommands')
        { Assert-LearningReadback $actual $body } | Should -Throw '*properties.tools*'
    }

    It 'surfaces non-2xx <Status> with no retry or response-body disclosure' -ForEach @(
        @{ Status = 301 }, @{ Status = 400 }, @{ Status = 401 }, @{ Status = 403 },
        @{ Status = 409 }, @{ Status = 412 }, @{ Status = 429 }, @{ Status = 500 }
    ) {
        Mock Invoke-WebRequest { New-TestResponse $Status @{ error = 'never-print-this-test-token' } }
        { Invoke-LearningRequest $script:context PUT '/api/v2/extendedAgent/skills/onboarding-learned-a' @{ name = 'a' } } |
            Should -Throw "*HTTP $Status*"
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly
    }

    It 'redacts transport errors and never retries ambiguous writes' {
        Mock Invoke-WebRequest { throw 'Authorization: Bearer never-print-this-test-token' }
        try { Invoke-LearningRequest $script:context PUT '/api/v2/extendedAgent/skills/onboarding-learned-a' @{} }
        catch {
            $_.Exception.Message | Should -Match 'Outcome may be unknown'
            $_.Exception.Message | Should -Not -Match 'never-print'
        }
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly
    }

    It 'rejects malformed JSON and routes outside the allowlist' {
        Mock Invoke-WebRequest { @{ StatusCode = 200; Content = 'not-json'; Headers = @{} } }
        { Invoke-LearningRequest $script:context GET '/api/v2/extendedAgent/skills/onboarding-learned-a' } | Should -Throw '*Invalid JSON*'
        { Invoke-LearningRequest $script:context GET '/api/v2/extendedAgent/scheduledtasks/name/runs' } | Should -Throw '*outside*'
    }
}

Describe 'Bounded schedule contract' {
    BeforeEach {
        $script:context = @{ AgentId = $script:agentId; Endpoint = 'https://lab.region.azuresre.ai'; Token = 'test-token' }
        $start = [datetimeoffset]::UtcNow.AddMinutes(-1).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        $end = [datetimeoffset]::UtcNow.AddMinutes(10).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        $script:bodies = New-LearningScheduleBodies 'onboarding-health-checkout' $script:appId $script:appGuid $start $end
        Mock Get-LearningTelemetry { return $script:appGuid }
        Mock Write-Host {}
        Mock Invoke-LearningRequest {
            param($Context, $Method, $Path)
            if ($Path.EndsWith('-reader')) { return @{ Data = Copy-TestObject $script:bodies.Handler; ETag = @('"handler-v1"') } }
            return @{ Data = Copy-TestObject $script:bodies.Task; ETag = @('"task-v1"') }
        }
    }

    It 'uses the live schedule schema with paused state, end time and one execution' {
        $script:bodies.Task.type | Should -BeExactly 'ScheduledTask'
        @($script:bodies.Task.properties.Keys | Sort-Object) | Should -Be @('agent', 'agentMode', 'agentPrompt', 'cronExpression', 'description', 'endTime', 'maxExecutions', 'notificationChannel', 'startTime', 'status')
        $script:bodies.Task.properties.status | Should -BeExactly 'Paused'
        $script:bodies.Task.properties.maxExecutions | Should -Be 1
        $script:bodies.Task.properties.endTime | Should -Not -BeNullOrEmpty
        $script:bodies.Task.properties.cronExpression | Should -BeExactly '*/5 * * * *'
        $script:bodies.Task.properties.agent | Should -BeExactly $script:bodies.Handler.name
        $script:bodies.Handler.properties.tools | Should -Be @('QueryAppInsightsUsingAppId')
        $script:bodies.Handler.properties.enableSkills | Should -BeFalse
        $script:bodies.Handler.properties.allowedSkills | Should -HaveCount 0
        $script:bodies.Handler.properties.handoffs | Should -HaveCount 0
        $script:bodies.Task.properties.agentPrompt | Should -Match 'execution window closed'
        $script:bodies.Handler.properties.instructions | Should -Match ([regex]::Escape($script:appId))
    }

    It 'rejects broad, empty, non-UTC, or reversed windows' {
        { Get-LearningWindow '2026-09-17T21:00:00Z' '2026-09-17T22:00:00Z' } | Should -Throw '*5-30 minutes*'
        { Get-LearningWindow '2026-09-17T21:00:00Z' '2026-09-17T21:00:00Z' } | Should -Throw '*5-30 minutes*'
        { Get-LearningWindow '2026-09-17T21:00:00Z' '2026-09-17T20:55:00Z' } | Should -Throw '*5-30 minutes*'
        { Get-LearningWindow '2026-09-17T21:00:00-07:00' '2026-09-17T21:10:00Z' } | Should -Throw '*exact UTC*'
    }

    It 'previews enable without changing state or pretending ETags are supported' {
        $operation = New-LearningToggleOperation $script:context 'onboarding-health-checkout' $true
        $operation.Body.properties.status | Should -BeExactly 'Active'
        $operation.Precondition.Count | Should -Be 0
        $script:bodies.Task.properties.status | Should -BeExactly 'Paused'
        Should -Invoke Invoke-LearningRequest -ParameterFilter { $Method -eq 'PUT' } -Times 0
    }

    It 'accepts service-supplied non-capability defaults on the handler' {
        $script:bodies.Handler.properties.outputType = 'Text'
        { New-LearningToggleOperation $script:context 'onboarding-health-checkout' $true } | Should -Not -Throw
    }

    It 'refuses an enabled task, a modified handler, or a modified task' {
        $script:bodies.Task.properties.status = 'Active'
        { New-LearningToggleOperation $script:context 'onboarding-health-checkout' $true } | Should -Throw '*already has*'
        $script:bodies.Task.properties.status = 'Paused'
        $script:bodies.Handler.properties.tools += 'RunAzCliWriteCommands'
        { New-LearningToggleOperation $script:context 'onboarding-health-checkout' $true } | Should -Throw '*tools*'
        $script:bodies.Handler.properties.tools = @('QueryAppInsightsUsingAppId')
        $script:bodies.Handler.properties.mcpTools = @('SendOutlookEmail')
        { New-LearningToggleOperation $script:context 'onboarding-health-checkout' $true } | Should -Throw '*properties.mcpTools*'
        $script:bodies.Handler.properties.mcpTools = @()
        $script:bodies.Task.properties.agent = 'alert-investigator'
        { New-LearningToggleOperation $script:context 'onboarding-health-checkout' $true } | Should -Throw '*outside the local learning contract*'
    }

    It 'preserves unrelated properties on explicit disable' {
        $script:bodies.Task.properties.status = 'Active'
        $script:bodies.Task.properties.serverOption = @{ retain = 'yes' }
        $operation = New-LearningToggleOperation $script:context 'onboarding-health-checkout' $false
        $operation.Body.properties.status | Should -BeExactly 'Paused'
        $operation.Body.properties.serverOption.retain | Should -BeExactly 'yes'
        $operation.Body.tags | Should -Be $script:bodies.Task.tags
    }

    It 'rejects concurrent state or ETag changes' {
        $operation = New-LearningToggleOperation $script:context 'onboarding-health-checkout' $true
        $script:bodies.Task.properties.description = 'changed by another operator'
        { Invoke-LearningOperation $script:context $operation } | Should -Throw '*Concurrent modification*'
        Should -Invoke Invoke-LearningRequest -ParameterFilter { $Method -eq 'PUT' } -Times 0
    }

    It 'contains visible healthy, unhealthy and insufficient evidence contracts without remediation' {
        $content = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\agent-recipe\config\skills\onboarding-health-check.md') -Raw
        foreach ($text in @('HEALTHY', 'UNHEALTHY', 'INSUFFICIENT EVIDENCE', 'UTC', 'POST /checkout', 'PostgreSQL', 'operation_Id', 'no silent remediation', 'portal')) {
            $content | Should -Match ([regex]::Escape($text))
        }
        $yaml = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\agent-recipe\config\skills\onboarding-health-check.yaml') -Raw
        $yaml | Should -Match 'QueryAppInsightsUsingAppId'
        $yaml | Should -Not -Match 'RunAzCliWriteCommands|SendOutlookEmail|CreateGithubIssue'
    }
}

Describe 'Trusted ARM origin and telemetry discovery' {
    BeforeEach {
        $script:endpoint = 'https://lab.region.azuresre.ai/'
        Mock Get-LearningArmJson {
            param($ResourceId)
            if ($ResourceId.EndsWith('/DataConnectors')) {
                return @{ value = @(@{ properties = @{ dataConnectorType = 'AppInsights'; provisioningState = 'Succeeded'; dataSource = $script:appId } }) }
            }
            if ($ResourceId -eq $script:appId) { return @{ id = $script:appId; tags = @{ workload = 'onboardinglab' }; properties = @{ AppId = $script:appGuid } } }
            return @{ id = $script:agentId; properties = @{ agentEndpoint = $script:endpoint } }
        }
        Mock az { $global:LASTEXITCODE = 0; return 'test-token' }
    }

    It 'resolves only the exact ARM endpoint and uses the existing data-plane token audience' {
        $context = New-LearningContext $script:agentId
        $context.Endpoint | Should -BeExactly 'https://lab.region.azuresre.ai'
        $context.Token | Should -BeExactly 'test-token'
        Should -Invoke az -ParameterFilter { ($args -join ' ') -match 'get-access-token --resource https://azuresre.dev' } -Times 1
        (Get-LearningTelemetry $context $script:appId) | Should -BeExactly $script:appGuid
    }

    It 'rejects unsafe endpoint <Endpoint> before requesting a token' -ForEach @(
        @{ Endpoint = 'http://lab.azuresre.ai' }, @{ Endpoint = 'https://lab.azuresre.ai.evil.test' },
        @{ Endpoint = 'https://evil.test' }, @{ Endpoint = 'https://user@lab.azuresre.ai' },
        @{ Endpoint = 'https://lab.azuresre.ai:444' }, @{ Endpoint = 'https://lab.azuresre.ai/path' },
        @{ Endpoint = 'https://lab.azuresre.ai/?next=evil' }, @{ Endpoint = 'https://lab.azuresre.ai/#fragment' },
        @{ Endpoint = 'https://127.0.0.1' }
    ) {
        $script:endpoint = $Endpoint
        { New-LearningContext $script:agentId } | Should -Throw '*trusted HTTPS*'
        Should -Invoke az -Times 0
    }

    It 'rejects mismatched ARM identity and unhealthy connectors' {
        Mock Get-LearningArmJson { return @{ id = "$script:agentId-other"; properties = @{ agentEndpoint = $script:endpoint } } }
        { New-LearningContext $script:agentId } | Should -Throw '*different agent ID*'
        Mock Get-LearningArmJson {
            param($ResourceId)
            if ($ResourceId.EndsWith('/DataConnectors')) { return @{ value = @() } }
            return @{ id = $script:appId; tags = @{ workload = 'onboardinglab' }; properties = @{ AppId = $script:appGuid } }
        }
        { Get-LearningTelemetry @{ AgentId = $script:agentId } $script:appId } | Should -Throw '*one healthy*'
    }
}
