#Requires -Version 7.4
# Shared by setup-sre-agent.ps1 and its offline contract tests. No network on import.

function Wait-ZavaDataPlane {
    param(
        [object]$Client,
        [string]$Endpoint,
        [ValidateRange(1, 3600)][int]$TimeoutSeconds = 900,
        [ValidateRange(0, 60)][int]$PollSeconds = 5
    )
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $lastStatus = 'no response'
    $reportedStatus = ''
    while ($clock.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        $response = $null
        $remaining = $TimeoutSeconds - $clock.Elapsed.TotalSeconds
        if ($remaining -le 0) { break }
        $cancellation = [Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds([Math]::Min(30, $remaining)))
        try {
            $response = $Client.GetAsync("$($Endpoint.TrimEnd('/'))/api/v2/extendedAgent/skills", $cancellation.Token).GetAwaiter().GetResult()
            $status = [int]$response.StatusCode
            $lastStatus = "HTTP $status"
            if ($status -eq 200) {
                $text = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                $parsed = ConvertFrom-Json -InputObject $text -NoEnumerate -ErrorAction Stop
                if ($parsed -isnot [array] -and
                    (-not $parsed -or -not $parsed.PSObject.Properties['value'] -or $parsed.value -isnot [array])) {
                    throw 'Agent readiness returned HTTP 200 without a resource collection.'
                }
                Write-Host '  [ok] Agent configuration API is ready' -ForegroundColor Green
                return
            }
            if ($status -notin @(404, 408, 429, 500, 502, 503, 504)) {
                throw "Agent readiness failed with HTTP $status. Check the endpoint and configuring identity; no connectors or configuration were written."
            }
        } catch [Threading.Tasks.TaskCanceledException] {
            $lastStatus = 'request timed out'
        } catch [Net.Http.HttpRequestException] {
            # Do not turn certificate/authentication errors into startup retries.
            if ($_.Exception.HttpRequestError -notin @(
                [Net.Http.HttpRequestError]::NameResolutionError,
                [Net.Http.HttpRequestError]::ConnectionError,
                [Net.Http.HttpRequestError]::ResponseEnded
            )) { throw }
            $lastStatus = "connection unavailable ($($_.Exception.HttpRequestError))"
        } finally {
            if ($response) { $response.Dispose() }
            $cancellation.Dispose()
        }
        if ($lastStatus -ne $reportedStatus) {
            Write-Host "  [wait] Agent configuration API: $lastStatus" -ForegroundColor Yellow
            $reportedStatus = $lastStatus
        }
        $remaining = $TimeoutSeconds - $clock.Elapsed.TotalSeconds
        if ($remaining -gt 0 -and $PollSeconds -gt 0) {
            Start-Sleep -Milliseconds ([int](1000 * [Math]::Min($PollSeconds, $remaining)))
        }
    }
    throw "Agent configuration API was not ready within $TimeoutSeconds seconds (last result: $lastStatus). No connectors or configuration were written. Check agent provisioning and rerun setup; use -ReadinessTimeoutSeconds to allow a longer startup window."
}

function Assert-ZavaRenderedText {
    param([string]$Text, [string]$Label)
    if ([string]::IsNullOrWhiteSpace($Text) -or $Text -match '@@|<embed\b|<placeholder\b') {
        throw "$Label is empty or contains an unresolved configuration placeholder."
    }
}

function Read-ZavaConfigText {
    param([string]$Root, [string]$RelativePath, [string]$ResourceGroup, [string]$SharedContext = '')
    $rootPath = [IO.Path]::GetFullPath($Root) + [IO.Path]::DirectorySeparatorChar
    $path = [IO.Path]::GetFullPath((Join-Path $Root $RelativePath))
    if (-not $path.StartsWith($rootPath, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Configuration reference must stay within sre-config: $RelativePath"
    }
    $text = [IO.File]::ReadAllText($path).Replace('@@RG@@', $ResourceGroup)
    if ($text.Contains('@@SHARED@@')) {
        if (-not $SharedContext) { throw "Shared context is not permitted in $RelativePath." }
        $text = $text.Replace('@@SHARED@@', $SharedContext)
    }
    Assert-ZavaRenderedText $text $RelativePath
    return $text.Replace("`r", '').Trim()
}

function Read-ZavaToolSource {
    param(
        [string]$Root,
        [string]$RelativePath,
        [string]$ResourceGroup,
        [hashtable]$PostgresConfiguration
    )
    $text = [IO.File]::ReadAllText((Join-Path $Root $RelativePath)).Replace('@@RG@@', $ResourceGroup)
    foreach ($name in $PostgresConfiguration.Keys) {
        $text = $text.Replace("@@$name@@", [string]$PostgresConfiguration[$name])
    }
    Assert-ZavaRenderedText $text $RelativePath
    return $text.Replace("`r", '').Trim()
}

function Assert-ZavaStringArray {
    param([object]$Value, [string]$Label, [switch]$Nonempty)
    if ($Value -isnot [array] -or ($Nonempty -and $Value.Count -eq 0)) {
        throw "$Label must be an explicit JSON array$(if ($Nonempty) { ' with at least one entry' })."
    }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($entry in $Value) {
        if ($entry -isnot [string] -or [string]::IsNullOrWhiteSpace($entry) -or
            $entry -cne $entry.Trim() -or -not $seen.Add($entry)) {
            throw "$Label contains a blank, non-string, whitespace-padded, or duplicate entry."
        }
    }
}

function Get-ZavaConfiguration {
    param(
        [string]$ConfigRoot,
        [string]$ResourceGroup,
        [ValidateSet('SkillOwned', 'ExplicitAgent')][string]$EvidenceToolMode = 'SkillOwned',
        [hashtable]$PostgresConfiguration = @{}
    )
    Assert-ZavaRenderedText $ResourceGroup 'ResourceGroup'
    $config = Get-Content -Raw (Join-Path $ConfigRoot 'agent-config.json') | ConvertFrom-Json -AsHashtable
    foreach ($key in @('DB_HOST', 'DB_NAME', 'SRE_AGENT_CLIENT_ID', 'SRE_AGENT_PRINCIPAL_NAME')) {
        if (-not $PostgresConfiguration.ContainsKey($key) -or [string]::IsNullOrWhiteSpace([string]$PostgresConfiguration[$key])) {
            throw "PostgreSQL configuration is missing $key."
        }
        Assert-ZavaRenderedText ([string]$PostgresConfiguration[$key]) $key
    }
    $shared = Read-ZavaConfigText $ConfigRoot 'skills\shared-context.md' $ResourceGroup
    $skills = @{}
    $tools = @{}
    $resources = [Collections.Generic.List[object]]::new()
    foreach ($kind in @('tools', 'skills', 'agents', 'incidentFilters')) {
        $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        if ($config[$kind] -isnot [array]) { throw "Manifest $kind must be an array." }
        foreach ($entry in $config[$kind]) {
            $namePattern = if ($kind -eq 'tools') { '^[A-Za-z][A-Za-z0-9_-]*$' } else { '^[a-z0-9][a-z0-9-]*$' }
            if ($entry.name -cnotmatch $namePattern -or -not $names.Add($entry.name)) {
                throw "Invalid or duplicate $kind name: $($entry.name)"
            }
            $type = switch ($kind) { tools { 'ExtendedAgentTool' } skills { 'Skill' } agents { 'ExtendedAgent' } incidentFilters { 'IncidentFilter' } }
            switch ($kind) {
                tools {
                    if ($entry.type -cne 'PythonFunctionTool') { throw "Unsupported tool type: $($entry.type)" }
                    if ($entry.description -isnot [string]) { throw "$($entry.name).description must be a string." }
                    Assert-ZavaRenderedText $entry.description "$($entry.name).description"
                    $source = Read-ZavaToolSource $ConfigRoot $entry.sourceFile $ResourceGroup $PostgresConfiguration
                    $operationDescription = [string]$entry.properties.parameters[0].description
                    $properties = [ordered]@{
                        type = 'PythonFunctionTool'
                        functionCode = $source
                        timeoutSeconds = 120
                        dependencies = @('azure-identity', 'pg8000')
                        connector = $null
                        description = $entry.description
                        parameters = @([ordered]@{
                            name = 'operation'
                            type = 'string'
                            description = $operationDescription
                            required = $true
                            mapTo = ''
                            target = 'direct'
                            value = $null
                            validation = $null
                            isDictionaryTarget = $false
                        })
                        attributes = $null
                        toolMode = 'Auto'
                    }
                    $tools[$entry.name] = $properties
                }
                skills {
                    if ($entry.description -isnot [string]) { throw "$($entry.name).description must be a string." }
                    Assert-ZavaRenderedText $entry.description "$($entry.name).description"
                    Assert-ZavaStringArray $entry.tools "$($entry.name).tools"
                    $context = if ($entry.name -like 'zava-*-evidence') { '' } else { $shared }
                    $properties = [ordered]@{
                        description = $entry.description
                        tools = @($entry.tools)
                        skillContent = Read-ZavaConfigText $ConfigRoot $entry.skillContentFile $ResourceGroup $context
                        additionalFiles = @()
                        sourcePluginInstallation = $null
                    }
                    $skills[$entry.name] = $properties
                }
                agents {
                    $properties = Read-ZavaConfigText $ConfigRoot $entry.propertiesFile $ResourceGroup | ConvertFrom-Json -AsHashtable
                    $supported = @('instructions', 'handoffDescription', 'tools', 'mcpTools', 'commonTools', 'allowedSkills', 'allowParallelToolCalls')
                    foreach ($key in $properties.Keys) {
                        if ($key -cnotin $supported) { throw "Unsupported lab agent property $($entry.name).$key" }
                    }
                    foreach ($key in @('instructions', 'handoffDescription')) {
                        if ($properties[$key] -isnot [string]) { throw "$($entry.name).$key must be a string." }
                        Assert-ZavaRenderedText $properties[$key] "$($entry.name).$key"
                    }
                    foreach ($key in @('tools', 'mcpTools', 'commonTools', 'allowedSkills')) {
                        Assert-ZavaStringArray $properties[$key] "$($entry.name).$key" -Nonempty:($key -in @('tools', 'allowedSkills'))
                    }
                    if ($properties.allowParallelToolCalls -isnot [bool]) {
                        throw "$($entry.name).allowParallelToolCalls must be a boolean."
                    }
                    if ($properties.tools.Count -ne 1 -or $properties.tools[0] -cne 'ReadFile' -or
                        $properties.mcpTools.Count -ne 0 -or $properties.commonTools.Count -ne 0) {
                        throw "$($entry.name) must retain the explicit ReadFile base with no authored MCP/common tools."
                    }
                    foreach ($skillName in $properties.allowedSkills) {
                        if ($skillName -cne 'self_manual' -and -not $skills.ContainsKey($skillName)) {
                            throw "Unknown selected skill: $skillName"
                        }
                    }
                    if ($EvidenceToolMode -eq 'ExplicitAgent') {
                        $properties.mcpTools = @($properties.allowedSkills |
                            Where-Object { $skills.ContainsKey($_) } |
                            ForEach-Object { $skills[$_].tools } | Sort-Object -Unique)
                    }
                    $properties.hooks = @{
                        PreToolUse = @(@{
                            type = 'command'
                            matcher = '(?s:.*)'
                            timeout = 30
                            failMode = 'block'
                            script = Read-ZavaConfigText $ConfigRoot $entry.preToolUseScriptFile $ResourceGroup
                        })
                    }
                }
                incidentFilters { $properties = $entry.properties }
            }
            $body = if ($kind -eq 'tools') {
                [ordered]@{
                    name = $entry.name
                    type = $properties.type
                    description = $properties.description
                    functionCode = $properties.functionCode
                    timeoutSeconds = $properties.timeoutSeconds
                    dependencies = $properties.dependencies
                    parameters = $properties.parameters
                }
            } else {
                @{ name = $entry.name; type = $type; tags = @(); properties = $properties }
            }
            Assert-ZavaRenderedText ($body | ConvertTo-Json -Depth 30) "$kind/$($entry.name)"
            $resources.Add([pscustomobject]@{
                Kind = $kind
                Name = $entry.name
                Path = if ($kind -eq 'tools') {
                    '/api/v1/extendedAgent/apply'
                } else {
                    "/api/v2/extendedAgent/$kind/$([uri]::EscapeDataString($entry.name))"
                }
                Body = $body
            })
        }
    }
    return [pscustomobject]@{
        EvidenceToolMode = $EvidenceToolMode
        Resources = $resources.ToArray()
        Tools = $tools
        CustomInstructions = Read-ZavaConfigText $ConfigRoot 'custom-instructions.md' $ResourceGroup
    }
}

function ConvertTo-ZavaComparable {
    param([AllowNull()][object]$Value, [string]$Key = '')
    if ($null -eq $Value) { return $null }
    if ($Value -is [string]) {
        # Normalize prose/scripts, never tool identities or the security matcher.
        $text = if ($Key -in @('', 'instructions', 'handoffDescription', 'description', 'skillContent', 'script')) {
            $Value.Replace("`r", '').Trim()
        } else { $Value }
        if ($Key -in @('type', 'failMode')) { $text = $text.ToLowerInvariant() }
        return $text
    }
    if ($Value -is [Collections.IDictionary] -or $Value -is [pscustomobject]) {
        $result = [ordered]@{}
        $keys = if ($Value -is [Collections.IDictionary]) { @($Value.Keys) } else { @($Value.PSObject.Properties.Name) }
        foreach ($name in ($keys | Sort-Object -CaseSensitive)) {
            $child = $Value.$name
            # Hook readback can include unset optional API fields.
            if ($null -ne $child) { $result[$name] = ConvertTo-ZavaComparable $child $name }
        }
        return $result
    }
    if ($Value -is [array]) {
        $items = @($Value | ForEach-Object { ConvertTo-ZavaComparable $_ $Key })
        if ($Key -in @('tools', 'mcpTools', 'commonTools', 'allowedSkills')) {
            $items = @($items | Sort-Object -CaseSensitive)
        }
        return ,$items
    }
    return $Value
}

function Compare-ExpectedProperties {
    param([object]$Expected, [object]$Actual, [string]$Path, [Collections.Generic.List[string]]$Differences)
    $keys = if ($Expected -is [Collections.IDictionary]) { @($Expected.Keys) } else { @($Expected.PSObject.Properties.Name) }
    foreach ($key in $keys) {
        $present = if ($Actual -is [Collections.IDictionary]) { $Actual.Contains($key) } else { $null -ne $Actual -and $null -ne $Actual.PSObject.Properties[$key] }
        if (-not $present) {
            $Differences.Add("$Path.$key is missing")
            continue
        }
        $left = ConvertTo-Json -InputObject (ConvertTo-ZavaComparable $Expected.$key $key) -Depth 30 -Compress
        $right = ConvertTo-Json -InputObject (ConvertTo-ZavaComparable $Actual.$key $key) -Depth 30 -Compress
        if ($left -cne $right) { $Differences.Add("$Path.$key differs") }
    }
}

function Get-ZavaComparisonValue {
    param([string]$Kind, [AllowNull()][object]$Body)
    if ($null -eq $Body) { return $null }
    if ($Kind -eq 'tools') { return $Body }
    return $Body.properties
}

function Get-ZavaCollectionPath {
    param([string]$Kind)
    if ($Kind -eq 'tools') { return '/api/v1/extendedAgent/tools?page=1&limit=200' }
    return "/api/v2/extendedAgent/$Kind"
}

function Get-ZavaWriteBody {
    param([string]$Kind, [object]$Body)
    if ($Kind -eq 'tools') {
        $parameters = @($Body.parameters | ForEach-Object {
            [ordered]@{
                name = $_.name
                type = $_.type
                required = $_.required
                description = $_.description
                target = 'direct'
            }
        })
        $tool = [ordered]@{
            name = $Body.name
            type = $Body.type
            description = $Body.description
            function_code = $Body.functionCode
            timeout_seconds = $Body.timeoutSeconds
            dependencies = $Body.dependencies
            parameters = $parameters
        }
        return [ordered]@{
            api_version = 'azuresre.ai/v1'
            kind = 'ToolList'
            spec = [ordered]@{ tools = @($tool) }
        }
    }
    return $Body
}

function New-ZavaSyncPlan {
    param([object]$Configuration, [hashtable]$Collections, [AllowEmptyString()][string]$CurrentInstructions)
    $items = [Collections.Generic.List[object]]::new()
    foreach ($resource in $Configuration.Resources) {
        $matches = @($Collections[$resource.Kind] | Where-Object { $_.name -eq $resource.Name })
        if ($matches.Count -gt 1) { throw "Duplicate remote resource: $($resource.Kind)/$($resource.Name)" }
        $previous = if ($matches.Count) { $matches[0] } else { $null }
        if ($previous -and $previous.name -cne $resource.Name) {
            throw "Remote name collides with different casing: $($previous.name). Review it before applying $($resource.Name)."
        }
        $differences = [Collections.Generic.List[string]]::new()
        if ($previous) {
            Compare-ExpectedProperties (Get-ZavaComparisonValue $resource.Kind $resource.Body) (Get-ZavaComparisonValue $resource.Kind $previous) "$($resource.Kind)/$($resource.Name)" $differences
        }
        $items.Add([pscustomobject]@{
            Resource = $resource
            Previous = $previous
            Action = if (-not $previous) { 'create' } elseif ($differences.Count) { 'update' } else { 'skip' }
            Differences = $differences.ToArray()
        })
    }
    $ciChanged = (ConvertTo-ZavaComparable $CurrentInstructions) -cne (ConvertTo-ZavaComparable $Configuration.CustomInstructions)
    return [pscustomobject]@{
        Items = $items.ToArray()
        PreviousInstructions = $CurrentInstructions
        InstructionsChanged = $ciChanged
        InstructionsDrift = $ciChanged -and -not [string]::IsNullOrWhiteSpace($CurrentInstructions)
    }
}

function Assert-ZavaUpdateApproved {
    param([object]$Plan, [switch]$UpdateExisting)
    $drift = @($Plan.Items | Where-Object Action -eq 'update' | ForEach-Object { $_.Differences })
    if ($Plan.InstructionsDrift) { $drift += 'customInstructions.instructions differs' }
    if ($drift.Count) {
        Write-Host ("Managed configuration differences:`n  " + ($drift -join "`n  ")) -ForegroundColor Yellow
        if (-not $UpdateExisting) {
            throw 'Existing managed configuration differs. Review it, then explicitly rerun with -UpdateExisting to snapshot and replace the intended fields. Nothing has been written.'
        }
    }
}

function Save-ZavaSnapshot {
    param([object]$Plan, [string]$Directory, [string]$AgentArmId)
    if (-not $Directory) {
        $Directory = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'sre-agent\snapshots'
    }
    $fullPath = [IO.Path]::GetFullPath($Directory)
    $ancestor = $fullPath
    while ($ancestor) {
        if (Test-Path (Join-Path $ancestor '.git')) { throw 'SnapshotDirectory must be outside a Git checkout; snapshots may contain private configuration.' }
        $ancestor = [IO.Path]::GetDirectoryName($ancestor)
    }
    $null = New-Item -ItemType Directory -Path $fullPath -Force
    $path = Join-Path $fullPath ("zava-{0}-{1}.json" -f (Get-Date -AsUTC -Format 'yyyyMMddTHHmmssZ'), [guid]::NewGuid().ToString('N'))
    $snapshot = @{
        agentArmId = $AgentArmId
        capturedAt = (Get-Date -AsUTC).ToString('o')
        resources = @($Plan.Items | ForEach-Object { @{ path = $_.Resource.Path; previous = $_.Previous; action = $_.Action } })
        customInstructions = @{ instructions = $Plan.PreviousInstructions }
    }
    $snapshot | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $path -Encoding utf8
    Write-Host "  Rollback snapshot (private; do not commit): $path" -ForegroundColor Yellow
    return $path
}

function Assert-ZavaResourcesConverged {
    param([object[]]$Resources, [int]$MaxAttempts = 6, [int]$DelaySeconds = 5)
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $differences = [Collections.Generic.List[string]]::new()
        foreach ($group in ($Resources | Group-Object Kind)) {
            $remote = @(Get-DataPlaneCollection -Path (Get-ZavaCollectionPath $group.Name))
            foreach ($resource in $group.Group) {
                $actual = @($remote | Where-Object { $_.name -ceq $resource.Name })
                if ($actual.Count -ne 1) { $differences.Add("$($resource.Kind)/$($resource.Name) is missing or duplicated"); continue }
                Compare-ExpectedProperties (Get-ZavaComparisonValue $resource.Kind $resource.Body) (Get-ZavaComparisonValue $resource.Kind $actual[0]) "$($resource.Kind)/$($resource.Name)" $differences
            }
        }
        if ($differences.Count -eq 0) { return }
        if ($attempt -lt $MaxAttempts) { Start-Sleep -Seconds $DelaySeconds }
    }
    throw "Configuration readback did not converge: $($differences -join '; ')"
}

function Sync-ZavaResources {
    param([object]$Plan, [string]$Kind)
    $items = @($Plan.Items | Where-Object { $_.Resource.Kind -eq $Kind })
    foreach ($item in $items) {
        $resource = $item.Resource
        if ($item.Action -eq 'skip') {
            Write-Host "  [skip] $Kind/$($resource.Name) unchanged" -ForegroundColor DarkGray
            continue
        }
        # Recheck for concurrent edits before changing the resource.
        $current = @(Get-DataPlaneCollection -Path (Get-ZavaCollectionPath $Kind) | Where-Object { $_.name -eq $resource.Name })
        $before = ConvertTo-Json -InputObject (ConvertTo-ZavaComparable (Get-ZavaComparisonValue $Kind $item.Previous)) -Depth 50 -Compress
        $now = ConvertTo-Json -InputObject (ConvertTo-ZavaComparable (Get-ZavaComparisonValue $Kind $(if ($current.Count -eq 1) { $current[0] } else { $null }))) -Depth 50 -Compress
        if ($current.Count -gt 1 -or $before -cne $now) {
            throw "$Kind/$($resource.Name) changed after preflight. Rerun to review the new drift."
        }
        $body = [ordered]@{}
        foreach ($key in $resource.Body.Keys) { $body[$key] = $resource.Body[$key] }
        if ($item.Previous -and $null -ne $item.Previous.tags) { $body.tags = $item.Previous.tags }
        $attempts = if ($Kind -eq 'incidentFilters') { 4 } else { 1 }
        # Agent PUT replaces omitted settings; PATCH preserves operator-owned fields.
        $method = if ($Kind -eq 'agents' -and $item.Action -eq 'update') { 'Patch' } else { 'Put' }
        $writeBody = Get-ZavaWriteBody $Kind $body
        $contentType = if ($Kind -eq 'tools') { 'application/x-yaml' } else { 'application/json' }
        if (-not (Invoke-DataPlaneWrite -Path $resource.Path -Body $writeBody -Label "$Kind/$($resource.Name)" -MaxAttempts $attempts -Method $method -ContentType $contentType)) {
            throw "Failed to synchronize $Kind/$($resource.Name)."
        }
    }
    Assert-ZavaResourcesConverged -Resources @($items | ForEach-Object { $_.Resource })
}
