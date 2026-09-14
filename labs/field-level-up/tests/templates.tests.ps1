#requires -Version 7.0
<#
Offline compiled-template regression tests; no Pester required.
Requires an already-installed Azure CLI and Bicep compiler. Only the native
`az bicep build --stdout --no-restore` command is allowed. Version checks and
telemetry are disabled; this script never installs/restores dependencies.
Portability tests execute the real Part 3 script with fail-closed command mocks.
They verify parameter serialization, NOT ARM expression evaluation or deployment.
#>
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$labRoot = Split-Path $PSScriptRoot -Parent
$templates = @{}
$passed = 0
$failures = [System.Collections.Generic.List[string]]::new()
$expectedTemplates = @(
    'main.bicep', 'fault.bicep', 'agent-setup/main.bicep',
    'modules/workload.bicep', 'modules/database-identity.bicep',
    'modules/sre-agent-configuration.bicep', 'use-cases/main.bicep'
)
$savedEnvironment = @{}
foreach ($name in @('AZURE_BICEP_CHECK_VERSION', 'AZURE_CORE_COLLECT_TELEMETRY', 'AZURE_BICEP_USE_BINARY_FROM_PATH', 'PATH')) {
    $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}
$savedExitCode = Get-Variable LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue

function Assert-True([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw $Message }
}

function Assert-Equal($Actual, $Expected, [string] $Message) {
    Assert-True (($Actual | ConvertTo-Json -Depth 50 -Compress) -ceq
        ($Expected | ConvertTo-Json -Depth 50 -Compress)) $Message
}

function Invoke-Test([string] $TestName, [scriptblock] $Body) {
    try {
        & $Body | Out-Null
        $script:passed++
        Write-Host "PASS $TestName"
    }
    catch {
        $failures.Add("${TestName}: $($_.Exception.Message)")
        Write-Host "FAIL ${TestName}: $($_.Exception.Message)"
    }
}

function Get-TemplateResources($Template, [string] $ParentType = '') {
    Assert-True ($Template -is [System.Collections.IDictionary]) 'Expected a compiled template/resource object'
    Assert-True ($Template.Contains('resources')) 'Missing resources collection'
    $collection = $Template.resources
    if ($collection -is [System.Collections.IDictionary]) {
        $resources = @($collection.Values)
    }
    else {
        Assert-True ($collection -is [array]) 'Resources must be an array or symbolic-name object'
        $resources = $collection
    }
    foreach ($resource in $resources) {
        Assert-True (-not [string]::IsNullOrWhiteSpace($resource.type)) 'Resource type is missing'
        $type = $resource.type
        if ($ParentType -and $type -notmatch '^Microsoft\.') { $type = "$ParentType/$type" }
        if ($resource.Contains('existing')) {
            Assert-True ($resource.existing -is [bool]) 'existing must be a Boolean'
        }
        $normalized = $resource.Clone()
        $normalized.type = $type
        $normalized
        if ($resource.Contains('resources')) { Get-TemplateResources $resource $type }
        if ($type -eq 'Microsoft.Resources/deployments' -and $resource.existing -ne $true) {
            Assert-True (-not $resource.properties.Contains('templateLink')) 'External templates cannot be checked offline'
            Get-TemplateResources $resource.properties.template
        }
    }
}

function Get-CreatedResources($Template) {
    Get-TemplateResources $Template | Where-Object { $_.existing -ne $true }
}

function Get-OneResource($Template, [string] $Type) {
    $matches = @(Get-CreatedResources $Template | Where-Object type -eq $Type)
    Assert-True ($matches.Count -eq 1) "Expected exactly one created $Type; found $($matches.Count)"
    return $matches[0]
}

function Assert-AllowedTypes($Template, [string[]] $Allowed) {
    foreach ($resource in @(Get-CreatedResources $Template)) {
        Assert-True ($resource.type -in $Allowed) "Unexpected created resource: $($resource.type) $($resource.name)"
    }
}

# Deliberately not an ARM evaluator: accept only the observed single-variable
# payload wrapper and literal/text-variable references, rejecting other shapes.
function Get-Payload($Template, [string] $Type) {
    $resource = Get-OneResource $Template $Type
    $match = [regex]::Match($resource.properties.value, "^\[base64\(string\(variables\('([^']+)'\)\)\)\]$")
    Assert-True $match.Success "Unsupported payload expression for $Type"
    $payload = $Template.variables[$match.Groups[1].Value]
    Assert-True ($payload -is [System.Collections.IDictionary]) "Missing object payload for $Type"
    return $payload
}

function Get-SkillText($Template, $Value) {
    if ($Value -is [string] -and $Value.StartsWith('[')) {
        $match = [regex]::Match($Value, "^\[variables\('([^']+)'\)\]$")
        Assert-True $match.Success 'Unsupported skill content expression'
        $Value = $Template.variables[$match.Groups[1].Value]
    }
    Assert-True ($Value -is [string] -and $Value.StartsWith('---')) 'Expected literal skill Markdown'
    return $Value
}

function Get-ArgumentValue([object[]] $Arguments, [string] $Name) {
    $index = [array]::IndexOf($Arguments, $Name)
    Assert-True ($index -ge 0 -and $index + 1 -lt $Arguments.Count) "Missing mock argument: $Name"
    return $Arguments[$index + 1]
}

# These mocks never forward any command to native executables or HTTP clients.
function az {
    Assert-True ($null -ne $bindingMock) 'Unexpected az invocation outside portability test'
    Assert-Equal @($args[0..2]) @('deployment', 'group', 'create') 'Only a mocked deployment boundary is allowed'
    $bindingMock.Calls++
    Assert-True ((Get-ArgumentValue $args '--subscription') -eq $bindingMock.Values.AZURE_SUBSCRIPTION_ID) 'Wrong subscription binding'
    Assert-True ((Get-ArgumentValue $args '--resource-group') -ceq $bindingMock.Values.AZURE_RESOURCE_GROUP) 'Wrong resource-group binding'
    Assert-True ((Get-ArgumentValue $args '--template-file') -eq (Join-Path $labRoot 'use-cases/main.bicep')) 'Wrong template binding'
    Assert-True ((Get-ArgumentValue $args '--mode') -ceq 'Incremental') 'Unexpected deployment mode'
    $parameterArgument = Get-ArgumentValue $args '--parameters'
    Assert-True ($parameterArgument.StartsWith('@')) 'Expected a serialized parameter file'
    $bindingMock.File = $parameterArgument.Substring(1)
    $bindingMock.Document = Get-Content -LiteralPath $bindingMock.File -Raw | ConvertFrom-Json -AsHashtable
    $global:LASTEXITCODE = 0
    return '{"properties":{"provisioningState":"Succeeded","outputs":{}}}'
}

function azd {
    Assert-True ($null -ne $bindingMock) 'Unexpected azd invocation'
    Assert-True ($args.Count -eq 5 -and $args[0] -eq '-C' -and $args[1] -eq $labRoot -and
        $args[2] -eq 'env' -and $args[3] -eq 'get-value') 'Unexpected azd command'
    Assert-True ($bindingMock.Values.ContainsKey($args[4])) "Unexpected environment key: $($args[4])"
    $global:LASTEXITCODE = 0
    return $bindingMock.Values[$args[4]]
}

function Invoke-WebRequest { throw 'HTTP is forbidden in offline template tests' }
function Invoke-RestMethod { throw 'HTTP is forbidden in offline template tests' }

try {
    $env:AZURE_BICEP_CHECK_VERSION = 'false'
    $env:AZURE_CORE_COLLECT_TELEMETRY = 'false'
    $nativeAz = Get-Command az -CommandType Application -ErrorAction Stop | Select-Object -First 1
    # Force the CLI to use an existing executable, never its auto-install path.
    $compiler = Get-Command bicep -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($compiler) {
        $compilerPath = $compiler.Source
    }
    else {
        $configDirectory = if ($env:AZURE_CONFIG_DIR) { $env:AZURE_CONFIG_DIR } else { Join-Path $HOME '.azure' }
        $binaryName = if ($IsWindows) { 'bicep.exe' } else { 'bicep' }
        $compilerPath = Join-Path $configDirectory "bin/$binaryName"
    }
    Assert-True (Test-Path -LiteralPath $compilerPath -PathType Leaf) 'Bicep must already be installed; offline tests will not download it'
    $env:PATH = "$(Split-Path $compilerPath -Parent)$([IO.Path]::PathSeparator)$env:PATH"
    $env:AZURE_BICEP_USE_BINARY_FROM_PATH = 'true'
    Invoke-Test 'exactly seven Bicep files' {
        $actual = @(Get-ChildItem $labRoot -Recurse -Filter '*.bicep' -File | ForEach-Object {
            [IO.Path]::GetRelativePath($labRoot, $_.FullName).Replace('\', '/')
        } | Sort-Object)
        Assert-Equal $actual @($expectedTemplates | Sort-Object) 'Bicep inventory changed'
    }
    foreach ($relative in $expectedTemplates) {
        Invoke-Test "compile $relative (stdout, no restore)" {
            $json = & $nativeAz.Source bicep build --file (Join-Path $labRoot $relative) --stdout --no-restore
            Assert-True ($LASTEXITCODE -eq 0) "Bicep compilation failed: $relative"
            $template = ($json -join "`n") | ConvertFrom-Json -AsHashtable
            Assert-True ($template.metadata._generator.name -eq 'bicep') 'Expected Bicep-generated JSON'
            $templates[$relative] = $template
            Write-Host "  compiler=$($template.metadata._generator.version); hash=$($template.metadata._generator.templateHash)"
        }
    }
    Assert-True ($templates.Count -eq 7) 'Cannot run structural checks without all seven compiled templates'
    $part1 = $templates['main.bicep']
    $part2 = $templates['agent-setup/main.bicep']
    $part3 = $templates['use-cases/main.bicep']
    $configuration = $templates['modules/sre-agent-configuration.bicep']

    foreach ($symbolic in @($false, $true)) {
        Invoke-Test "resource walker handles mixed nested shapes (symbolic=$symbolic)" {
            $parent = @{ type = 'Microsoft.App/agents'; existing = $true; resources = @(
                @{ type = 'hooks'; existing = $false }
            ) }
            $nested = @{ type = 'Microsoft.Resources/deployments'; properties = @{
                template = @{ resources = @{ agent = $parent } }
            } }
            $fixture = @{ resources = @($nested) }
            if ($symbolic) { $fixture.resources = @{ nested = $nested } }
            $all = @(Get-TemplateResources $fixture)
            Assert-True ($all.Count -eq 3) 'Nested resources were skipped'
            Assert-Equal @(Get-CreatedResources $fixture | ForEach-Object type) @(
                'Microsoft.Resources/deployments', 'Microsoft.App/agents/hooks'
            ) 'Existing parent or nested child normalized incorrectly'
        }
    }
    Invoke-Test 'resource walker rejects linked templates' {
        $caught = $false
        try {
            Get-TemplateResources @{ resources = @(@{ type = 'Microsoft.Resources/deployments'; properties = @{
                templateLink = @{ uri = 'https://example.invalid/template.json' }
            } }) } | Out-Null
        }
        catch { $caught = $_.Exception.Message -eq 'External templates cannot be checked offline' }
        Assert-True $caught 'Linked templates must not silently bypass recursive inspection'
    }
    Invoke-Test 'Part 1 recursively contains workload but no agent or alerts' {
        $resources = @(Get-TemplateResources $part1)
        Assert-True ($resources.Count -gt 2) 'Workload module was not traversed'
        foreach ($resource in $resources) {
            Assert-True ($resource.type -notmatch '^Microsoft.App/agents(?:/|$)|(?i:alert|scheduledQueryRules|actionGroups|smartDetector)') "Part 1 contains $($resource.type)"
        }
        $null = Get-OneResource $part1 'Microsoft.Web/sites'
        $null = Get-OneResource $part1 'Microsoft.DBforPostgreSQL/flexibleServers/administrators'
    }
    Invoke-Test 'Part 2 only creates agent, identity, roles, telemetry and base configuration' {
        Assert-AllowedTypes $part2 @(
            'Microsoft.Resources/deployments', 'Microsoft.ManagedIdentity/userAssignedIdentities',
            'Microsoft.Authorization/roleAssignments', 'Microsoft.OperationalInsights/workspaces',
            'Microsoft.Insights/components', 'Microsoft.App/agents', 'Microsoft.App/agents/connectors',
            'Microsoft.App/agents/commonPrompts', 'Microsoft.App/agents/hooks',
            'Microsoft.App/agents/repositories'
        )
        $agent = Get-OneResource $part2 'Microsoft.App/agents'
        Assert-True ($agent.properties.actionConfiguration.mode -ceq 'Review') 'Base agent must remain in Review mode'
        $insights = Get-OneResource $part2 'Microsoft.Insights/components'
        Assert-True ($insights.name.Contains('-agent-appi')) 'Agent telemetry must be separate from workload telemetry'
        Assert-True ($agent.properties.logConfiguration.applicationInsightsConfiguration.appId.Contains('-agent-appi')) 'Agent must use its own telemetry'
    }
    Invoke-Test 'Part 2 attaches the public lab source repository' {
        $repository = Get-Payload $part2 'Microsoft.App/agents/repositories'
        Assert-True ($repository.url -ceq 'https://github.com/microsoft/sre-agent') 'Unexpected source repository URL'
        Assert-True ($repository.type -ceq 'GitHub') 'Source repository must use GitHub code access'
        Assert-True ($repository.branch -ceq 'main') 'Source repository must use the published branch'
        Assert-True (-not $repository.Contains('pat')) 'Public source repository must not embed credentials'
    }
    Invoke-Test 'Part 3 recursively creates no roles, governance, parent agent or workload' {
        Assert-AllowedTypes $part3 @(
            'Microsoft.Resources/deployments', 'Microsoft.Insights/scheduledQueryRules',
            'Microsoft.App/agents/skills', 'Microsoft.App/agents/subagents',
            'Microsoft.App/agents/incidentFilters', 'Microsoft.App/agents/scheduledTasks'
        )
        foreach ($type in @('skills', 'subagents', 'incidentFilters', 'scheduledTasks')) {
            $null = Get-OneResource $part3 "Microsoft.App/agents/$type"
        }
        $parents = @(Get-TemplateResources $part3 | Where-Object type -eq 'Microsoft.App/agents')
        foreach ($parent in $parents) {
            Assert-True ($parent.existing -eq $true -and $parent.name -ceq "[parameters('sreAgentName')]") 'Parent must only reference the supplied agent'
        }
    }
    Invoke-Test 'fault toggles exactly one narrow NSG rule' {
        $fault = $templates['fault.bicep']
        Assert-True (@(Get-CreatedResources $fault).Count -eq 1) 'Fault must not create parent NSG or other resources'
        $rule = Get-OneResource $fault 'Microsoft.Network/networkSecurityGroups/securityRules'
        Assert-True (-not $rule.Contains('copy') -and -not $rule.Contains('condition')) 'Fault must always update exactly one rule'
        Assert-True ($rule.name -ceq "[format('{0}/{1}', parameters('networkSecurityGroupName'), 'PostgreSqlFaultInjection')]") 'Fault rule target changed'
        Assert-Equal $rule.properties.access "[if(parameters('injectDatabaseFault'), 'Deny', 'Allow')]" 'Fault must toggle Deny/Allow'
        foreach ($entry in @{ protocol = 'Tcp'; destinationPortRange = '5432'; sourcePortRange = '*';
            sourceAddressPrefix = '10.42.0.0/23'; destinationAddressPrefix = '10.42.2.0/24'; direction = 'Outbound'; priority = 100 }.GetEnumerator()) {
            Assert-Equal $rule.properties[$entry.Key] $entry.Value "Fault $($entry.Key) changed"
        }
    }
    Invoke-Test 'checkout enables deployment build and Oryx' {
        $app = Get-OneResource $part1 'Microsoft.Web/sites'
        foreach ($name in @('SCM_DO_BUILD_DURING_DEPLOYMENT', 'ENABLE_ORYX_BUILD')) {
            $settings = @($app.properties.siteConfig.appSettings | Where-Object name -eq $name)
            Assert-True ($settings.Count -eq 1 -and $settings[0].value -ceq 'true') "$name must occur once with string true"
        }
    }
    Invoke-Test 'PostgreSQL is Entra-only without administrator password' {
        $server = Get-OneResource $part1 'Microsoft.DBforPostgreSQL/flexibleServers'
        Assert-True ($server.properties.authConfig.activeDirectoryAuth -ceq 'Enabled') 'Entra authentication must be enabled'
        Assert-True ($server.properties.authConfig.passwordAuth -ceq 'Disabled') 'Password authentication must be disabled'
        Assert-True (-not $server.properties.Contains('administratorLoginPassword')) 'Unexpected database password'
    }
    Invoke-Test 'response plan accepts exactly Sev1 and Sev2' {
        $plan = Get-Payload $configuration 'Microsoft.App/agents/incidentFilters'
        Assert-Equal $plan.priorities @('Sev1', 'Sev2') 'Unexpected response priorities'
        Assert-Equal $plan.agentMode 'autonomous' 'Incident response must run without interactive approvals'
        Assert-Equal $part3.parameters.alertSeverity.allowedValues @(1, 2) 'Alert severity must allow only 1 and 2'
        Assert-Equal $part3.parameters.alertSeverity.defaultValue 2 'Default alert severity must be 2'
        $alert = Get-OneResource $part3 'Microsoft.Insights/scheduledQueryRules'
        Assert-Equal $alert.properties.severity "[parameters('alertSeverity')]" 'Severity input is disconnected'
    }
    Invoke-Test 'scheduled task payload is paused and read-only' {
        $task = Get-Payload $configuration 'Microsoft.App/agents/scheduledTasks'
        Assert-Equal $task.status 'Paused' 'Scheduled task must start Paused'
        Assert-Equal $task.agentMode 'readonly' 'Scheduled task must remain read-only'
    }
    Invoke-Test 'alert and response plan are disabled by default and share opt-in' {
        foreach ($template in @($part3, $configuration)) {
            Assert-True ($template.parameters.enableIncidents.type -ceq 'bool' -and
                $template.parameters.enableIncidents.defaultValue -is [bool] -and
                $template.parameters.enableIncidents.defaultValue -eq $false) 'enableIncidents must default to Boolean false'
        }
        $alert = Get-OneResource $part3 'Microsoft.Insights/scheduledQueryRules'
        $plan = Get-Payload $configuration 'Microsoft.App/agents/incidentFilters'
        Assert-Equal $alert.properties.enabled "[parameters('enableIncidents')]" 'Alert opt-in is disconnected'
        Assert-Equal $plan.isEnabled "[parameters('enableIncidents')]" 'Response plan opt-in is disconnected'
    }
    Invoke-Test 'Part 3 forwards binding parameters into the actual nested template' {
        $module = Get-OneResource $part3 'Microsoft.Resources/deployments'
        Assert-Equal $module.properties.template $configuration 'Embedded configuration differs from standalone compilation'
        foreach ($name in @('sreAgentName', 'checkoutAppId', 'postgresServerId', 'applicationInsightsId',
            'applicationInsightsAppId', 'githubRepositoryUrl', 'emailRecipients', 'emailConnectorName', 'enableIncidents')) {
            Assert-Equal $module.properties.parameters[$name].value "[parameters('$name')]" "Module does not forward $name"
        }
        Assert-Equal $module.properties.parameters.incidentAlertTitle.value "[variables('checkoutAlertTitle')]" 'Alert title is disconnected'
        Assert-Equal $part3.variables.checkoutAlertTitle "[format('{0}-checkout-failures', parameters('namePrefix'))]" 'Alert title must be environment-specific'
    }
    Invoke-Test 'environment bindings are parameterized and consumed by commander' {
        foreach ($name in @('sreAgentName', 'checkoutAppId', 'postgresServerId', 'applicationInsightsId',
            'applicationInsightsAppId', 'githubRepositoryUrl', 'emailRecipients', 'emailConnectorName', 'incidentAlertTitle')) {
            Assert-Equal $configuration.variables.environmentBindings[$name] "[parameters('$name')]" "Hardcoded or missing binding: $name"
        }
        $commanders = @($configuration.variables.subagents | Where-Object name -eq "[variables('incidentCommanderName')]")
        Assert-True ($commanders.Count -eq 1 -and $commanders[0].spec.instructions.Contains("string(variables('environmentBindings'))")) 'Commander does not consume bindings'
        $commander = $commanders[0].spec
        foreach ($tool in @('RunAzCliReadCommands', 'Task', 'CreateGithubIssue', 'SendOutlookEmail')) {
            Assert-True ($commander.tools -contains $tool) "Commander is missing required tool $tool"
        }
        foreach ($tool in @('RunAzCliWriteCommands', 'RunInTerminal')) {
            Assert-True ($commander.tools -notcontains $tool) "Commander exposes mutation tool $tool"
        }
        Assert-Equal @($commander.allowedSkills | Sort-Object) @('azure-monitor-rca', 'email-incident-followup', 'github-issue-followup') 'Commander skill scope changed'
    }
    Invoke-Test 'application investigator can inspect attached source read-only' {
        $investigators = @($configuration.variables.subagents | Where-Object name -eq "[variables('applicationInvestigatorName')]")
        Assert-True ($investigators.Count -eq 1) 'Expected one application investigator'
        $investigator = $investigators[0].spec
        foreach ($tool in @('ReadFile', 'ListDir', 'FileSearch', 'GrepSearch')) {
            Assert-True ($investigator.tools -contains $tool) "Application investigator is missing source tool $tool"
        }
        foreach ($tool in @('CreateFile', 'ReplaceStringInFile', 'RunInTerminal')) {
            Assert-True ($investigator.tools -notcontains $tool) "Application investigator exposes mutation tool $tool"
        }
        Assert-True ($investigator.instructions.Contains('attached source repository')) 'Application investigator lacks source-analysis guidance'
        Assert-True ($investigator.instructions.Contains('Report missing source access')) 'Application investigator must not assume source access'
    }
    $pluginRoot = Join-Path $labRoot 'use-cases/plugin'
    $expectedSkills = @('azure-monitor-rca', 'email-incident-followup', 'github-issue-followup')
    Invoke-Test 'plugin manifest parses and discovers exactly three generic skill files' {
        $plugin = Get-Content (Join-Path $pluginRoot '.plugin/plugin.json') -Raw | ConvertFrom-Json -AsHashtable
        Assert-Equal $plugin.name 'azure-monitor-incident-response' 'Unexpected plugin name'
        Assert-True ($plugin.version -match '^\d+\.\d+\.\d+$') 'Missing plugin version'
        Assert-Equal $plugin.skills @('./skills') 'Unexpected plugin skill discovery roots'
        $files = @(Get-ChildItem (Join-Path $pluginRoot 'skills') -Recurse -Filter 'SKILL.md' -File)
        Assert-Equal @($files | ForEach-Object { $_.Directory.Name } | Sort-Object) $expectedSkills 'Skill file inventory changed'
        Assert-Equal @($configuration.variables.skills.name | Sort-Object) $expectedSkills 'Compiled skill inventory differs from plugin'
    }
    foreach ($name in $expectedSkills) {
        Invoke-Test "generic skill $name has no fixed Azure GUID, recipient or repository and matches compiled text" {
            $text = Get-Content (Join-Path $pluginRoot "skills/$name/SKILL.md") -Raw
            Assert-True ($text -match "(?s)^---\r?\nname: $([regex]::Escape($name))\r?\ndescription: [^\r\n]+\r?\n---") 'Missing or mismatched skill front matter'
            Assert-True ($text -notmatch '(?i)\b[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\b') 'Skill contains a fixed GUID'
            Assert-True ($text -notmatch '(?i)[a-z0-9.!#$%&''*+/=?^_`{|}~-]+@[a-z0-9-]+(?:\.[a-z0-9-]+)+') 'Skill contains a fixed email recipient'
            Assert-True ($text -notmatch '(?i)(?:https?://|git@)?(?:www\.)?github\.com[/:][a-z0-9_.-]+/[a-z0-9_.-]+|/subscriptions/[^\s<>]+') 'Skill contains a fixed repository or Azure resource scope'
            $skills = @($configuration.variables.skills | Where-Object name -eq $name)
            Assert-True ($skills.Count -eq 1) 'Expected exactly one matching compiled skill'
            $compiledText = Get-SkillText $configuration $skills[0].skillContent
            Assert-Equal $compiledText.Replace("`r`n", "`n") $text.Replace("`r`n", "`n") 'Compiled skill content differs from the plugin file'
        }
    }

    foreach ($environment in @(
        @{ Name = 'alpha'; Subscription = '11111111-1111-1111-1111-111111111111'; Location = 'eastus2'; AppId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'; Recipients = @('alpha@example.test') },
        @{ Name = 'bravo'; Subscription = '22222222-2222-2222-2222-222222222222'; Location = 'westus3'; AppId = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'; Recipients = @('bravo@example.test', 'oncall@example.test') }
    )) {
        Invoke-Test "binding portability $($environment.Name) (mock serialization, not runtime expansion)" {
            $prefix = $environment.Name
            $scope = "/subscriptions/$($environment.Subscription)/resourceGroups/rg-$prefix"
            $script:bindingMock = @{
                Calls = 0; File = $null; Document = $null
                Values = @{
                    AZURE_SUBSCRIPTION_ID = $environment.Subscription; AZURE_RESOURCE_GROUP = "rg-$prefix"
                    SRE_AGENT_NAME = "$prefix-agent"; SRE_AGENT_RESOURCE_ID = "$scope/providers/Microsoft.App/agents/$prefix-agent"
                    CHECKOUT_APP_ID = "$scope/providers/Microsoft.Web/sites/$prefix-checkout"
                    POSTGRES_SERVER_ID = "$scope/providers/Microsoft.DBforPostgreSQL/flexibleServers/$prefix-db"
                    APPLICATION_INSIGHTS_ID = "$scope/providers/Microsoft.Insights/components/$prefix-appi"
                    APPLICATION_INSIGHTS_APP_ID = $environment.AppId; LAB_NAME_PREFIX = $prefix; AZURE_LOCATION = $environment.Location
                }
            }
            try {
                & (Join-Path $labRoot 'scripts/deploy-use-cases.ps1') -GitHubRepositoryUrl "https://github.com/$prefix/incident-followups" `
                    -EmailRecipients $environment.Recipients -EmailConnectorName "$prefix-email" 6>$null | Out-Null
                Assert-True ($bindingMock.Calls -eq 1) 'Expected exactly one mocked deployment'
                Assert-True (-not (Test-Path -LiteralPath $bindingMock.File)) 'Helper did not remove the temporary parameter file'
                $expected = @{
                    sreAgentName = "$prefix-agent"; checkoutAppId = $bindingMock.Values.CHECKOUT_APP_ID
                    postgresServerId = $bindingMock.Values.POSTGRES_SERVER_ID; applicationInsightsId = $bindingMock.Values.APPLICATION_INSIGHTS_ID
                    applicationInsightsAppId = $environment.AppId; githubRepositoryUrl = "https://github.com/$prefix/incident-followups"
                    emailRecipients = $environment.Recipients; emailConnectorName = "$prefix-email"
                    namePrefix = $prefix; location = $environment.Location; enableIncidents = $false; alertSeverity = 2
                }
                $parameters = $bindingMock.Document.parameters
                Assert-Equal @($parameters.Keys | Sort-Object) @($expected.Keys | Sort-Object) 'Unexpected serialized parameter set'
                foreach ($name in $expected.Keys) {
                    Assert-Equal $parameters[$name].value $expected[$name] "Synthetic $prefix binding changed: $name"
                    Assert-True ($part3.parameters.Contains($name)) "Serialized parameter is not declared: $name"
                }
                Assert-True ($parameters.emailRecipients.value -is [array]) 'Recipients must remain an array even for one recipient'
                Assert-True ($parameters.enableIncidents.value -is [bool]) 'Opt-in must remain a Boolean'
            }
            finally {
                if ($bindingMock.File -and (Test-Path -LiteralPath $bindingMock.File)) { Remove-Item -LiteralPath $bindingMock.File -Force }
                $script:bindingMock = $null
            }
        }
    }
}
finally {
    foreach ($name in $savedEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name], 'Process')
    }
    if ($savedExitCode) { $global:LASTEXITCODE = $savedExitCode.Value }
    else { Remove-Variable LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue }
    Write-Host "RESULT: $passed passed; $($failures.Count) failed."
    Write-Host 'Scope: compiled JSON and mocked parameter binding only; no ARM runtime expansion, deployment, authentication, plugin loading, or connector/incident execution verified.'
}
if ($failures.Count -gt 0) { throw ($failures -join "`n") }