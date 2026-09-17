#requires -Version 7.0
<#
.SYNOPSIS
Preview or explicitly apply a learner skill or bounded read-only schedule.
.DESCRIPTION
Every action previews by default. Review the target and body, then repeat with
-Apply -ApprovePlan <sha256>. No provisioning hook calls this script.
Skill and Schedule are create-only. Schedule creates a dedicated telemetry-only
handler and a disabled task. Enable stays in the foreground until the UTC window
ends and pauses the task in finally. The service task also has an explicit
endTime and maxExecutions=1. Keep the terminal open and verify final state.
The deployed extension API does not enforce conditional creates and returns no
ETag. Apply therefore requires -ExclusiveAccess: use an isolated learner agent
or a facilitator-controlled configuration window with no concurrent editors.
Read/compare/write is best-effort concurrency detection, not an atomic transaction.
Never retry an ambiguous write automatically. Reconcile its exact target first.
.EXAMPLE
.\learning.ps1 -Action Skill -AgentResourceId $agentId -Name onboarding-learned-checkout -MarkdownPath .\checkout.md -Description 'Checkout evidence learned in the lab'
.EXAMPLE
.\learning.ps1 -Action Schedule -AgentResourceId $agentId -Name onboarding-health-checkout -AppInsightsResourceId $appInsightsId -StartUtc '2026-09-17T21:00:00Z' -EndUtc '2026-09-17T21:15:00Z'
.EXAMPLE
.\learning.ps1 -Action Disable -AgentResourceId $agentId -Name onboarding-health-checkout
#>
[CmdletBinding()]
param(
    [ValidateSet('Skill', 'Schedule', 'Enable', 'Disable')][string] $Action,
    [string] $AgentResourceId,
    [string] $Name,
    [string] $MarkdownPath,
    [string] $Description,
    [string] $AppInsightsResourceId,
    [string] $StartUtc,
    [string] $EndUtc,
    [switch] $Apply,
    [string] $ApprovePlan,
    [switch] $ExclusiveAccess
)

function Get-LearningArmJson {
    param([string] $ResourceId, [string] $ApiVersion = '2025-05-01-preview')
    $raw = & az rest --method GET --url "https://management.azure.com$ResourceId`?api-version=$ApiVersion" --output json --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw 'ARM read failed. Check the signed-in account and exact resource ID.' }
    return ($raw -join "`n" | ConvertFrom-Json -AsHashtable -ErrorAction Stop)
}

function Assert-LearningResourceId {
    param([string] $Id, [string] $Provider)
    $pattern = '^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[A-Za-z0-9_.()-]+/providers/' +
        [regex]::Escape($Provider) + '/[A-Za-z0-9][A-Za-z0-9-]*$'
    # Restrict shell metacharacters even though the ID is only an ARM read argument.
    if ($Id -notmatch $pattern -or $Id.Contains('(') -or $Id.Contains(')')) {
        throw "Invalid or shell-unsafe resource ID for $Provider."
    }
    $subscription = ($Id -split '/')[2]
    if ($subscription -notmatch '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$') {
        throw 'Invalid subscription UUID.'
    }
}

function New-LearningContext {
    param([string] $Id)
    Assert-LearningResourceId $Id 'Microsoft.App/agents'
    $agent = Get-LearningArmJson $Id
    if ($agent.id -ine $Id) { throw 'ARM returned a different agent ID.' }
    $endpoint = [string] $agent.properties.agentEndpoint
    $uri = $null
    if (-not [uri]::TryCreate($endpoint, [UriKind]::Absolute, [ref] $uri) -or
        $uri.Scheme -cne 'https' -or $uri.Port -ne 443 -or $uri.UserInfo -or
        $uri.Query -or $uri.Fragment -or $uri.AbsolutePath -ne '/' -or
        $uri.Host -notmatch '^[a-zA-Z0-9-]+(?:\.[a-zA-Z0-9-]+)*\.azuresre\.ai$' -or
        $endpoint -match '[\\\s]') {
        throw 'ARM agentEndpoint must be a trusted HTTPS azuresre.ai origin with no path, credentials, query, or fragment.'
    }
    $token = (& az account get-access-token --resource https://azuresre.dev --query accessToken --output tsv --only-show-errors) -join ''
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($token)) {
        throw 'Unable to acquire the SRE Agent data-plane token.'
    }
    return @{ AgentId = $Id; Endpoint = $uri.GetLeftPart([UriPartial]::Authority); Token = $token.Trim() }
}

function Invoke-LearningRequest {
    param([hashtable] $Context, [string] $Method, [string] $Path, $Body, [hashtable] $Precondition = @{})
    if ($Path -cnotmatch '^/api/v2/extendedAgent/(skills|agents|scheduledtasks)/[a-z0-9-]+$') {
        throw 'Refusing a request outside the owned extension routes.'
    }
    $headers = @{ Authorization = "Bearer $($Context.Token)" }
    foreach ($key in $Precondition.Keys) { $headers[$key] = $Precondition[$key] }
    $request = @{
        Uri = $Context.Endpoint + $Path; Method = $Method; Headers = $headers
        MaximumRedirection = 0; TimeoutSec = 30; SkipHttpErrorCheck = $true
        ErrorAction = 'Stop'
    }
    if ($null -ne $Body) {
        $request.ContentType = 'application/json; charset=utf-8'
        $request.Body = [Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 60 -Compress))
    }
    try { $response = Invoke-WebRequest @request }
    catch {
        # Do not expose HTTP exception objects, which can contain request credentials.
        throw "Transport failure for $Method $Path. Outcome may be unknown; reconcile before retrying."
    }
    if ($Method -eq 'GET' -and $response.StatusCode -eq 404) { return $null }
    if ($response.StatusCode -lt 200 -or $response.StatusCode -ge 300) {
        throw "HTTP $($response.StatusCode) for $Method $Path. No retry performed; reconcile before another write."
    }
    $data = $null
    if ($response.Content) {
        try { $data = $response.Content | ConvertFrom-Json -AsHashtable -ErrorAction Stop }
        catch { throw "Invalid JSON for $Method $Path. Outcome may be unknown; reconcile before retrying." }
    }
    return @{ Data = $data; ETag = @($response.Headers['ETag']); Status = $response.StatusCode }
}

function Get-LearningHash {
    param($Value)
    # Sort object keys recursively; retain array ordering and scalar types.
    function ConvertTo-Canonical($Item) {
        if ($Item -is [System.Collections.IDictionary]) {
            $sorted = [ordered]@{}
            foreach ($key in @($Item.Keys | Sort-Object -CaseSensitive)) { $sorted[$key] = ConvertTo-Canonical $Item[$key] }
            return $sorted
        }
        if ($Item -is [array]) { return ,@($Item | ForEach-Object { ConvertTo-Canonical $_ }) }
        return $Item
    }
    $json = ConvertTo-Json -InputObject (ConvertTo-Canonical $Value) -Depth 70 -Compress
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($json)))).Replace('-', '').ToLowerInvariant()
    }
    finally { $sha.Dispose() }
}

function Assert-LearningReadback {
    param($Actual, $Expected)
    if ($Actual.name -cne $Expected.name -or $Actual.type -cne $Expected.type) { throw 'Read-back identity mismatch.' }
    foreach ($key in $Expected.properties.Keys) {
        if (-not $Actual.properties.Contains($key) -and
            -not ($Expected.type -eq 'Skill' -and $key -eq 'skillContent' -and $Actual.properties.Contains('skillMdContent'))) {
            throw "Read-back missing properties.$key."
        }
        $value = $Actual.properties[$key]
        if ($Expected.type -eq 'Skill' -and $key -eq 'skillContent' -and $Actual.properties.Contains('skillMdContent')) {
            $value = $Actual.properties.skillMdContent
            if ($Actual.properties.Contains('skillContent') -and $Actual.properties.skillContent -cne $value) {
                throw 'Read-back has contradictory skill content fields.'
            }
        }
        $expectedValue = $Expected.properties[$key]
        if ($expectedValue -is [array] -and $expectedValue.Count -eq 0 -and $null -eq $value) { continue }
        if ($key -in @('startTime', 'endTime') -and $value -and $expectedValue) {
            if ([datetimeoffset]::Parse("$value") -eq [datetimeoffset]::Parse("$expectedValue")) { continue }
        }
        if ((Get-LearningHash $value) -cne (Get-LearningHash $expectedValue)) {
            throw "Read-back mismatch in properties.$key."
        }
    }
    # This service drops extension tags; ownership is checked through exact
    # names, handler references and the known task description instead.
}

function Get-LearningWindow {
    param([string] $Start, [string] $End)
    foreach ($value in @($Start, $End)) {
        if ($value -cnotmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$') { throw 'Use an exact UTC timestamp: yyyy-MM-ddTHH:mm:ssZ.' }
    }
    $begin = [datetimeoffset]::ParseExact($Start, "yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal)
    $finish = [datetimeoffset]::ParseExact($End, "yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal)
    if (($finish - $begin).TotalMinutes -lt 5 -or ($finish - $begin).TotalMinutes -gt 30) {
        throw 'The execution window must be 5-30 minutes.'
    }
    return @{ Start = $begin; End = $finish }
}

function Get-LearningUtcNow {
    return [datetimeoffset]::UtcNow
}

function Get-LearningTelemetry {
    param([hashtable] $Context, [string] $ResourceId)
    Assert-LearningResourceId $ResourceId 'Microsoft.Insights/components'
    if (($ResourceId -split '/')[2] -ine ($Context.AgentId -split '/')[2]) { throw 'Telemetry must be in the agent subscription.' }
    if (($ResourceId -split '/')[4] -ine ($Context.AgentId -split '/')[4]) { throw 'Telemetry must be in this lab agent resource group.' }
    $resource = Get-LearningArmJson $ResourceId '2020-02-02'
    if ($resource.id -ine $ResourceId -or $resource.tags.workload -cne 'onboardinglab' -or
        $resource.properties.AppId -notmatch '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$') {
        throw 'Expected the exact onboardinglab-tagged Application Insights workload resource with an AppId.'
    }
    $connectors = Get-LearningArmJson "$($Context.AgentId)/DataConnectors"
    $healthy = @($connectors.value | Where-Object {
        $_.properties.dataConnectorType -eq 'AppInsights' -and
        $_.properties.provisioningState -in @('Succeeded', 'Running')
    })
    if ($healthy.Count -ne 1) { throw 'Expected one healthy AppInsights connector for the exact workload resource.' }
    if ($healthy[0].properties.dataSource) {
        if ($healthy[0].properties.dataSource -ine $ResourceId) { throw 'AppInsights connector points at a different workload resource.' }
    }
    else {
        Write-Warning 'ARM redacts the connector target. The task uses the explicit approved workload AppId; verify its actual query result before relying on the check.'
    }
    return [string] $resource.properties.AppId
}

function New-LearningScheduleBodies {
    param([string] $TaskName, [string] $ResourceId, [string] $AppId, [string] $Start, [string] $End)
    $null = Get-LearningWindow $Start $End
    $content = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\agent-recipe\config\skills\onboarding-health-check.md') -Raw
    $handlerName = "$TaskName-reader"
    $scope = "Execution window: [$Start, $End) UTC. Workload Application Insights resource: $ResourceId. AppId: $AppId."
    $handler = @{
        name = $handlerName; type = 'ExtendedAgent'; tags = @()
        properties = @{
            instructions = "$scope`n$content"; handoffDescription = 'Bounded read-only onboarding checkout health report.'
            handoffs = @(); tools = @('QueryAppInsightsUsingAppId')
            mcpTools = @(); connectors = @(); agentsAsTools = @(); commonTools = @()
            temperature = 0.2; enableSkills = $false; addSystemSkills = $false; allowedSkills = @()
        }
    }
    $task = @{
        name = $TaskName; type = 'ScheduledTask'
        tags = @()
        properties = @{
            description = 'Onboarding lab health check v1: operator-owned, one execution, read-only.'
            cronExpression = '*/5 * * * *'
            startTime = $Start; endTime = $End; maxExecutions = 1; notificationChannel = $null
            agentPrompt = "$scope Use only $handlerName. Outside this window return INSUFFICIENT EVIDENCE: execution window closed without any tools. Inside the window report HEALTHY, UNHEALTHY, or INSUFFICIENT EVIDENCE with checkout and PostgreSQL evidence. No writes, notifications, delegation, or remediation."
            agent = $handlerName; agentMode = 'Autonomous'; status = 'Paused'
        }
    }
    return @{ Handler = $handler; Task = $task }
}

function New-LearningCreateOperation {
    param($Context, [string] $Kind, $Body)
    $path = "/api/v2/extendedAgent/$Kind/$($Body.name)"
    if ($null -ne (Invoke-LearningRequest $Context GET $path)) {
        throw "Object already exists at $path. Create-only operation refused; choose a new namespaced name."
    }
    return @{ Path = $path; Body = $Body; Precondition = @{}; Before = $null }
}

function New-LearningToggleOperation {
    param($Context, [string] $TaskName, [bool] $Enabled)
    $path = "/api/v2/extendedAgent/scheduledtasks/$TaskName"
    $current = Invoke-LearningRequest $Context GET $path
    if ($null -eq $current) { throw 'Scheduled task does not exist.' }
    $body = $current.Data
    if ($body.name -cne $TaskName -or $body.type -cne 'ScheduledTask' -or
        $body.properties.description -cne 'Onboarding lab health check v1: operator-owned, one execution, read-only.' -or
        $body.properties.agent -cne "$TaskName-reader" -or $body.properties.status -notin @('Active', 'Paused', 'Completed')) {
        throw 'Refusing a schedule outside the local learning contract.'
    }
    $targetStatus = if ($Enabled) { 'Active' } else { 'Paused' }
    if ($body.properties.status -eq $targetStatus) { throw 'The task already has the requested state. No write is necessary.' }
    if ($Enabled) {
        $scopePattern = '^Execution window: \[([^,]+), ([^)]+)\) UTC\. Workload Application Insights resource: (\S+)\. AppId: ([0-9a-fA-F-]+)\.'
        if ($body.properties.agentPrompt -notmatch $scopePattern) { throw 'Missing or invalid execution scope.' }
        $fields = @{ 'utc-start' = $Matches[1]; 'utc-end' = $Matches[2]; 'app-insights' = $Matches[3]; 'app-id' = $Matches[4] }
        $window = Get-LearningWindow $fields['utc-start'] $fields['utc-end']
        $now = Get-LearningUtcNow
        if ($now -lt $window.Start -or $now -ge $window.End.AddMinutes(-1)) {
            throw 'Enable only inside the execution window with at least one minute remaining.'
        }
        $appId = Get-LearningTelemetry $Context $fields['app-insights']
        if ($appId -cne $fields['app-id']) { throw 'Telemetry AppId changed; create a new reviewed task.' }
        $expected = New-LearningScheduleBodies $TaskName $fields['app-insights'] $appId $fields['utc-start'] $fields['utc-end']
        Assert-LearningReadback $body $expected.Task
        $handler = Invoke-LearningRequest $Context GET "/api/v2/extendedAgent/agents/$TaskName-reader"
        if ($null -eq $handler) { throw 'Read-only handler is missing.' }
        Assert-LearningReadback $handler.Data $expected.Handler
        # Service-supplied defaults are permitted; all capability-bearing fields
        # above must match the explicit read-only configuration.
    }
    $before = Get-LearningHash $body
    $copy = $body | ConvertTo-Json -Depth 60 | ConvertFrom-Json -AsHashtable
    $copy.properties.status = $targetStatus
    return @{ Path = $path; Body = $copy; Precondition = @{}; Before = $before
        End = $(if ($Enabled) { $window.End.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'") } else { $null }) }
}

function Invoke-LearningOperation {
    param($Context, $Operation)
    $current = Invoke-LearningRequest $Context GET $Operation.Path
    if ($null -eq $Operation.Before) {
        if ($null -ne $current) { throw 'Concurrent create detected; refusing to overwrite.' }
    } elseif ($null -eq $current -or (Get-LearningHash $current.Data) -cne $Operation.Before) {
        throw 'Concurrent modification detected; reread and approve a new plan.'
    }
    $null = Invoke-LearningRequest $Context PUT $Operation.Path $Operation.Body $Operation.Precondition
    $verified = Invoke-LearningRequest $Context GET $Operation.Path
    if ($null -eq $verified) { throw 'Read-back is missing after PUT. Outcome unknown; reconcile before retrying.' }
    Assert-LearningReadback $verified.Data $Operation.Body
    Write-Host "Verified: $($Context.Endpoint)$($Operation.Path)"
}

function Invoke-OnboardingLearning {
    param([hashtable] $Options)
    $ErrorActionPreference = 'Stop'
    $action = $Options.Action
    if ($action -notin @('Skill', 'Schedule', 'Enable', 'Disable')) { throw 'Specify -Action Skill, Schedule, Enable, or Disable.' }
    $name = [string] $Options.Name
    $prefix = if ($action -eq 'Skill') { 'onboarding-learned-' } else { 'onboarding-health-' }
    if ($name -cnotmatch ('^' + $prefix + '[a-z0-9][a-z0-9-]{0,30}$')) {
        throw "Name must start with $prefix and have a 1-31 character lowercase alphanumeric/hyphen suffix."
    }
    if ($Options.Apply -and (-not $Options.ExclusiveAccess -or $Options.ApprovePlan -cnotmatch '^[a-f0-9]{64}$')) {
        throw 'Apply requires -ApprovePlan <reviewed sha256> and -ExclusiveAccess to an isolated agent or facilitator-controlled configuration window.'
    }
    $context = New-LearningContext $Options.AgentResourceId
    try {
        $operations = @()
        switch ($action) {
            'Skill' {
                if ([string]::IsNullOrWhiteSpace($Options.Description) -or $Options.Description.Length -gt 300) { throw 'Description must contain 1-300 characters.' }
                $file = Get-Item -LiteralPath $Options.MarkdownPath
                if ($file.PSIsContainer -or $file.Extension -ine '.md' -or $file.Length -gt 65536) { throw 'Use one local .md file of at most 64 KiB.' }
                $content = [IO.File]::ReadAllText($file.FullName, [Text.UTF8Encoding]::new($false, $true))
                if ([string]::IsNullOrWhiteSpace($content) -or $content -match '^\s*---(\r?\n|$)') { throw 'Use nonempty Markdown without YAML frontmatter; attached tools are always empty.' }
                $body = @{ name = $name; type = 'Skill'; tags = @()
                    properties = @{ description = $Options.Description; tools = @(); skillContent = $content; additionalFiles = @() } }
                $operations = @(New-LearningCreateOperation $context skills $body)
            }
            'Schedule' {
                $window = Get-LearningWindow $Options.StartUtc $Options.EndUtc
                if ($window.End -le (Get-LearningUtcNow)) { throw 'Schedule execution window has already ended.' }
                $appId = Get-LearningTelemetry $context $Options.AppInsightsResourceId
                $bodies = New-LearningScheduleBodies $name $Options.AppInsightsResourceId $appId $Options.StartUtc $Options.EndUtc
                $operations = @(
                    New-LearningCreateOperation $context agents $bodies.Handler
                    New-LearningCreateOperation $context scheduledtasks $bodies.Task
                )
            }
            default { $operations = @(New-LearningToggleOperation $context $name ($action -eq 'Enable')) }
        }
        $plan = @{ AgentResourceId = $context.AgentId; Endpoint = $context.Endpoint; Action = $action; Operations = $operations }
        $hash = Get-LearningHash $plan
        Write-Host ($plan | ConvertTo-Json -Depth 60)
        Write-Host "Plan SHA256: $hash"
        if (-not $Options.Apply) { return $plan }
        if ($Options.ApprovePlan -cne $hash) { throw 'Plan changed or approval hash is wrong. Review this plan before applying.' }
        if ($action -eq 'Enable') {
            Write-Host 'Keep this terminal open. Enable also approves pause at the UTC deadline. The task is bounded to one execution and a server endTime; verify the final state.'
            $attempted = $false
            try {
                $attempted = $true
                Invoke-LearningOperation $context $operations[0]
                $end = [datetimeoffset]::Parse($operations[0].End, [Globalization.CultureInfo]::InvariantCulture)
                while ((Get-LearningUtcNow) -lt $end) { Start-Sleep -Seconds 1 }
            } finally {
                if ($attempted) {
                    $state = Invoke-LearningRequest $context GET $operations[0].Path
                    if ($null -eq $state) { throw 'Unable to reconcile enabled task. Inspect the exact task in the portal immediately.' }
                    if ($state.Data.properties.status -eq 'Active') {
                        $expected = $operations[0].Body
                        Assert-LearningReadback $state.Data $expected
                        $disable = New-LearningToggleOperation $context $name $false
                        Invoke-LearningOperation $context $disable
                    } elseif ($state.Data.properties.status -notin @('Paused', 'Completed')) { throw 'Unknown task state after enable; inspect it in the portal.' }
                }
            }
        } else {
            foreach ($operation in $operations) { Invoke-LearningOperation $context $operation }
        }
        Write-Host 'Local apply/read-back completed. Inspect actual execution history in the portal; this does not prove a successful scheduled run.'
    } finally { $context.Token = $null }
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-OnboardingLearning $PSBoundParameters
}
