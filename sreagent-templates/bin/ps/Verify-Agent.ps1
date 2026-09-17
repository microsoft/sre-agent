<#
.SYNOPSIS
    Verify an SRE Agent deployment is complete.

.DESCRIPTION
    Queries ARM + data-plane APIs and prints a pass/fail table.
    If -Expected is given, compares counts against the config directory's
    expected-config.json.

.PARAMETER Subscription
    Azure subscription ID.

.PARAMETER ResourceGroup
    Resource group containing the agent.

.PARAMETER AgentName
    Agent resource name.

.PARAMETER Expected
    Path to the config directory containing expected-config.json.

.EXAMPLE
    .\Verify-Agent.ps1 -Subscription <sub> -ResourceGroup <rg> -AgentName <name>
    .\Verify-Agent.ps1 -s <sub> -g <rg> -n <name> -Expected /tmp/my-agent-export
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [Alias('s', 'SubscriptionId')]
    [string]$Subscription,

    [Parameter(Mandatory)]
    [Alias('g')]
    [string]$ResourceGroup,

    [Parameter(Mandatory)]
    [Alias('n')]
    [string]$AgentName,

    [Alias('e')]
    [string]$Expected
)

Set-StrictMode -Version Latest

# PS 7.3+ changed how native-command arguments are passed; use Legacy to avoid
# broken arg splitting when args contain '=' (e.g. jq --argjson, terraform -out=).
if ($PSVersionTable.PSVersion.Major -ge 7 -and $PSVersionTable.PSVersion.Minor -ge 3) {
    $PSNativeCommandArgumentPassing = 'Legacy'
}
$ErrorActionPreference = 'Stop'

# ── Load safe jq wrapper (avoids PS 7.3+ argument mangling) ──
. (Join-Path $PSScriptRoot 'Invoke-Jq.ps1')

# ─────────────────────────── Prerequisites ───────────────────────────

$PrereqScript = Join-Path $PSScriptRoot 'Check-Prerequisites.ps1'
if (Test-Path $PrereqScript) {
    . $PrereqScript
    if (-not (Test-Prerequisites -IncludeCurl)) { exit 1 }
} else {
    foreach ($cmd in @('jq', 'az', 'curl')) {
        if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
            Write-Host "Error: $cmd is required but not found." -ForegroundColor Red
            exit 1
        }
    }
}

# ─────────────────────────── Expected config ───────────────────────────

$ExpectedConfig = $null
if ($Expected -and (Test-Path (Join-Path $Expected 'expected-config.json'))) {
    $ExpectedConfig = Get-Content (Join-Path $Expected 'expected-config.json') -Raw
}

function Get-Exp {
    param([string]$JqPath, [string]$Fallback = '-')
    if ($ExpectedConfig) {
        $val = $ExpectedConfig | Invoke-Jq -Raw -Filter "$JqPath // empty"
        if ($val -and $val -ne 'null') { return $val }
    }
    return $Fallback
}

function Get-ExpList {
    param([string]$JqPath)
    if ($ExpectedConfig) {
        return ($ExpectedConfig | Invoke-Jq -Raw -Filter "$JqPath // [] | sort | join(`",`")")
    }
    return ''
}

$AllowAdditionalResources = $false
if ($ExpectedConfig) {
    $AllowAdditionalResources = ($ExpectedConfig | Invoke-Jq -Raw -Filter '.allowAdditionalResources // false') -eq 'true'
}

# ─────────────────────────── ARM + Data-plane setup ───────────────────────────

$API_VERSION = '2025-05-01-preview'
$ARM_BASE    = "https://management.azure.com/subscriptions/${Subscription}/resourceGroups/${ResourceGroup}/providers/Microsoft.App/agents/${AgentName}"

$AgentJson = (az rest -m GET --url "${ARM_BASE}?api-version=${API_VERSION}" -o json 2>$null) -join "`n"
if ($LASTEXITCODE -ne 0 -or -not $AgentJson) {
    Write-Host "FAIL: Could not read agent ${AgentName} from ARM (Azure CLI exit $LASTEXITCODE)" -ForegroundColor Red
    exit 1
}
try {
    $null = ConvertFrom-Json -InputObject $AgentJson -ErrorAction Stop
} catch {
    Write-Host "FAIL: ARM returned invalid JSON for ${AgentName}" -ForegroundColor Red
    exit 1
}

$Endpoint = $AgentJson | Invoke-Jq -Raw -Filter '.properties.agentEndpoint // empty'
if (-not $Endpoint -or $Endpoint -eq 'null') {
    Write-Host "FAIL: Could not resolve agent endpoint for ${AgentName} in ${ResourceGroup}" -ForegroundColor Red
    exit 1
}

$Token = az account get-access-token --resource https://azuresre.dev --query accessToken -o tsv 2>$null
if ($LASTEXITCODE -ne 0 -or -not $Token) {
    Write-Host "FAIL: Could not get data-plane token" -ForegroundColor Red
    exit 1
}

function Invoke-Dp {
    param([string]$Path, [switch]$Collection)
    $script:UnavailableData = $false
    try {
        $response = Invoke-WebRequest -Uri "${Endpoint}${Path}" -Headers @{ Authorization = "Bearer $Token" } `
            -TimeoutSec 30 -SkipHttpErrorCheck
        if ($response.StatusCode -lt 200 -or $response.StatusCode -ge 300) {
            throw "HTTP $($response.StatusCode)"
        }
        return (Convert-ApiResponse -Json $response.Content -Collection:$Collection)
    } catch {
        Add-RequestFailure "GET $Path" $_.Exception.Message
        if ($Collection) { return '{"value":[]}' }
        return '{}'
    }
}

function Invoke-Arm {
    param([string]$Path)
    $script:UnavailableData = $false
    try {
        $result = (az rest -m GET --url "${ARM_BASE}${Path}?api-version=${API_VERSION}" -o json 2>$null) -join "`n"
        if ($LASTEXITCODE -ne 0) { throw "Azure CLI exited $LASTEXITCODE" }
        return (Convert-ApiResponse -Json $result -Collection)
    } catch {
        Add-RequestFailure "ARM GET $Path" $_.Exception.Message
        return '{"value":[]}'
    }
}

function Convert-ApiResponse {
    param([string]$Json, [switch]$Collection)
    if ([string]::IsNullOrWhiteSpace($Json)) { throw 'Empty API response' }
    $parsed = ConvertFrom-Json -InputObject $Json -NoEnumerate
    if ($null -eq $parsed) { throw 'Null API response' }
    if ($parsed.PSObject.Properties['error']) { throw 'API returned an error object' }
    if ($Collection) {
        if ($parsed -is [array]) {
            return (ConvertTo-Json -InputObject @{ value = $parsed } -Depth 100 -Compress)
        }
        if (-not $parsed.PSObject.Properties['value'] -or $parsed.value -isnot [array]) {
            throw 'Expected an array or an object containing a value array'
        }
    } elseif ($parsed -isnot [PSCustomObject]) {
        throw 'Expected a JSON object'
    }
    return $Json
}

# ─────────────────────────── Results tracking ───────────────────────────

$Pass = 0
$Fail = 0
$Results = [System.Collections.Generic.List[PSCustomObject]]::new()
$UnavailableData = $false

function Add-RequestFailure {
    param([string]$Name, [string]$Detail)
    $script:UnavailableData = $true
    $script:Results.Add([PSCustomObject]@{
        Name = $Name
        Actual = $Detail
        Expected = 'Successful response'
        Result = 'FAIL'
    })
    $script:Fail++
}

function Add-Check {
    param(
        [string]$Name,
        [string]$Actual,
        [string]$ExpectedVal,
        [ValidateSet('Exact', 'Minimum', 'Subset')]
        [string]$Mode = 'Exact'
    )
    $script:Results.Add([PSCustomObject]@{
        Name     = $Name
        Actual   = $Actual
        Expected = $ExpectedVal
        Result   = ''
    })
    $last = $script:Results[$script:Results.Count - 1]
    if ($script:UnavailableData) {
        $last.Actual = 'unavailable'
        $last.Result = 'FAIL'
        $script:Fail++
    }
    elseif ($ExpectedVal -eq '-') {
        $last.Expected = [char]0x2014   # em dash
        $last.Result   = [char]0x2705   # ✅
        $script:Pass++
    }
    elseif ($Mode -eq 'Minimum' -and [int]$Actual -ge [int]$ExpectedVal) {
        $last.Expected = "$([char]0x2265)$ExpectedVal"
        $last.Result = "$([char]0x2705) PASS"
        $script:Pass++
    }
    elseif ($Mode -eq 'Subset') {
        $actualItems = @($Actual -split ',' | Where-Object { $_ })
        $expectedItems = @($ExpectedVal -split ',' | Where-Object { $_ })
        $missing = @($expectedItems | Where-Object { $_ -notin $actualItems })
        if ($missing.Count -eq 0) {
            $last.Expected = "includes $ExpectedVal"
            $last.Result = "$([char]0x2705) PASS"
            $script:Pass++
        } else {
            $last.Expected = "missing $($missing -join ',')"
            $last.Result = "$([char]0x274C) FAIL"
            $script:Fail++
        }
    }
    elseif ($Actual -eq $ExpectedVal) {
        $last.Result = "$([char]0x2705) PASS"
        $script:Pass++
    }
    else {
        $last.Result = "$([char]0x274C) FAIL"
        $script:Fail++
    }
}

$CollectionCountMode = if ($AllowAdditionalResources) { 'Minimum' } else { 'Exact' }
$CollectionNameMode = if ($AllowAdditionalResources) { 'Subset' } else { 'Exact' }

function Add-InfoRow {
    param([string]$Name, [string]$Actual)
    $script:Results.Add([PSCustomObject]@{
        Name     = $Name
        Actual   = $(if ($script:UnavailableData) { 'unavailable' } else { $Actual })
        Expected = [char]0x2014
        Result   = ''
    })
}

# ─────────────────────────── Banner ───────────────────────────

Write-Host ''
Write-Host (([string][char]0x2550) * 55) -ForegroundColor Cyan
Write-Host "  SRE Agent Verification: ${AgentName}" -ForegroundColor Cyan
Write-Host "  Endpoint: ${Endpoint}" -ForegroundColor Cyan
Write-Host (([string][char]0x2550) * 55) -ForegroundColor Cyan
Write-Host ''

# ─────────────────────────── Agent properties ───────────────────────────

$Props = $AgentJson | Invoke-Jq -Compact -Filter '{
  accessLevel: .properties.actionConfiguration.accessLevel,
  mode: .properties.actionConfiguration.mode,
  upgradeChannel: .properties.upgradeChannel,
  modelProvider: .properties.defaultModel.provider,
  incidentPlatform: (.properties.incidentManagementConfiguration.type // "None")
}'

Add-Check 'Agent exists'       'yes'                                             'yes'
Add-Check 'Access level'       ($Props | Invoke-Jq -Raw -Filter '.accessLevel')       (Get-Exp '.agent.accessLevel')
Add-Check 'Action mode'        ($Props | Invoke-Jq -Raw -Filter '.mode')            (Get-Exp '.agent.actionMode')
Add-Check 'Upgrade channel'    ($Props | Invoke-Jq -Raw -Filter '.upgradeChannel')  (Get-Exp '.agent.upgradeChannel')
Add-Check 'Model provider'     ($Props | Invoke-Jq -Raw -Filter '.modelProvider')   (Get-Exp '.agent.defaultModelProvider')
Add-Check 'Incident platform'  ($Props | Invoke-Jq -Raw -Filter '.incidentPlatform') (Get-Exp '.agent.incidentPlatform')

# ─────────────────────────── Connectors (ARM) ───────────────────────────

$Connectors   = Invoke-Arm '/DataConnectors'
$ConnCt       = $Connectors | Invoke-Jq -Filter '[.value[] | select((.properties.dataConnectorType // "") | startswith("Knowledge") | not)] | length'
$ConnHealthy  = $Connectors | Invoke-Jq -Filter '[.value[] | select(((.properties.dataConnectorType // "") | startswith("Knowledge") | not) and .properties.provisioningState == "Succeeded")] | length'
$ConnNames    = ($Connectors | Invoke-Jq -Raw -Filter '.value[] | select((.properties.dataConnectorType // "") | startswith("Knowledge") | not) | .name' | Sort-Object) -join ','
$ExpConnCt    = Get-Exp '.connectors | length'
$ExpConnNames = Get-ExpList '[.connectors[].name]'

Add-Check 'Connectors (total)'   $ConnCt      $ExpConnCt $CollectionCountMode
Add-Check 'Connectors (healthy)' $ConnHealthy  $ConnCt
if ($ExpConnNames) {
    Add-Check 'Connector names' $ConnNames $ExpConnNames $CollectionNameMode
} else {
    Add-InfoRow 'Connector names' $ConnNames
}

# ─────────────────────────── Knowledge Sources ───────────────────────────

$AllDpConnectors = Invoke-Dp '/api/v2/extendedAgent/connectors' -Collection
$KnowledgeCt = $AllDpConnectors | Invoke-Jq -Filter '[((.value // .)[]?) | select((.properties.dataConnectorType // "") | startswith("Knowledge"))] | length'
$KnowledgeNames = ($AllDpConnectors | Invoke-Jq -Raw -Filter '(.value // .)[]? | select((.properties.dataConnectorType // "") | startswith("Knowledge")) | .name' | Sort-Object) -join ','
$ExpKnowledgeCt = Get-Exp '.knowledgeSources | length'
$ExpKnowledgeNames = Get-ExpList '.knowledgeSources'
Add-Check 'Knowledge Sources' $KnowledgeCt $ExpKnowledgeCt $CollectionCountMode
if ($ExpKnowledgeNames) {
    Add-Check 'Knowledge Source names' $KnowledgeNames $ExpKnowledgeNames $CollectionNameMode
}

# ─────────────────────────── Managed connectors (ConnectorV2) ───────────────────────────

$ManagedConnectors   = Invoke-Dp '/api/v2/connectorV2/mcpservers' -Collection
$ManagedConnCt       = $ManagedConnectors | Invoke-Jq -Filter '.value // [] | length'
$ManagedConnNames    = ($ManagedConnectors | Invoke-Jq -Raw -Filter '.value[]?.name' | Sort-Object) -join ','
$ExpManagedConnCt    = Get-Exp '.managedConnectors | length'
$ExpManagedConnNames = Get-ExpList '.managedConnectors'

Add-Check 'Managed connectors' $ManagedConnCt $ExpManagedConnCt $CollectionCountMode
if ($ExpManagedConnNames) {
    Add-Check 'Managed connector names' $ManagedConnNames $ExpManagedConnNames $CollectionNameMode
} else {
    Add-InfoRow 'Managed connector names' $ManagedConnNames
}

# ─────────────────────────── Skills ───────────────────────────

$Skills   = Invoke-Dp '/api/v1/extendedAgent/skills' -Collection
$SkillCt  = $Skills | Invoke-Jq -Filter 'if type == "array" then length elif .value then (.value | length) else 0 end'
if (-not $SkillCt) { $SkillCt = '0' }
$SkillNames   = ($Skills | Invoke-Jq -Raw -Filter '(if type == "array" then . elif .value then .value else [] end)[].name' | Sort-Object) -join ','
$ExpSkillCt   = Get-Exp '.skills | length'
$ExpSkillNames = Get-ExpList '.skills'

Add-Check 'Skills' $SkillCt $ExpSkillCt $CollectionCountMode
if ($ExpSkillNames) {
    Add-Check 'Skill names' $SkillNames $ExpSkillNames $CollectionNameMode
} else {
    Add-InfoRow 'Skill names' $SkillNames
}
if ($ExpectedConfig) {
    $expectedObject = $ExpectedConfig | ConvertFrom-Json
    if ($expectedObject.PSObject.Properties['skillDetails']) {
        foreach ($expectedSkill in $expectedObject.skillDetails) {
            $skillDetail = Invoke-Dp "/api/v2/extendedAgent/skills/$([uri]::EscapeDataString($expectedSkill.name))"
            $actualTools = $skillDetail | Invoke-Jq -Raw -Filter '.properties.tools // [] | sort | join(",")'
            $expectedTools = @($expectedSkill.tools | Sort-Object) -join ','
            Add-Check "Skill tools ($($expectedSkill.name))" $actualTools $expectedTools
            if ($expectedSkill.requireDescription) {
                $description = $skillDetail | Invoke-Jq -Raw -Filter '.properties.description // empty'
                Add-Check "Skill description ($($expectedSkill.name))" $(if ($description) { 'present' } else { 'missing' }) 'present'
            }
            if ($expectedSkill.requireContent) {
                $content = $skillDetail | Invoke-Jq -Raw -Filter '.properties.skillContent // empty'
                Add-Check "Skill content ($($expectedSkill.name))" $(if ($content) { 'present' } else { 'missing' }) 'present'
            }
        }
    }
    if ($expectedObject.PSObject.Properties['toolPermissions']) {
        $globalSettings = Invoke-Dp '/api/v2/agent/settings/global'
        foreach ($category in @('allow', 'ask', 'deny')) {
            $actualPermissions = $globalSettings | Invoke-Jq -Raw -Filter ".permissions.$category // [] | sort | join(`",`")"
            $expectedPermissions = $ExpectedConfig | Invoke-Jq -Raw -Filter ".toolPermissions.$category // [] | sort | join(`",`")"
            Add-Check "Tool policy ($category)" $actualPermissions $expectedPermissions
        }
    }
}

# ─────────────────────────── Subagents ───────────────────────────

$Subagents = Invoke-Dp '/api/v2/extendedAgent/agents' -Collection
$SaCt      = $Subagents | Invoke-Jq -Filter '.value | length'
if (-not $SaCt) { $SaCt = '0' }
$SaNames    = ($Subagents | Invoke-Jq -Raw -Filter '.value[].name' | Sort-Object) -join ','
$ExpSaCt    = Get-Exp '.subagents | length'
$ExpSaNames = Get-ExpList '.subagents'

Add-Check 'Subagents' $SaCt $ExpSaCt $CollectionCountMode
if ($ExpSaNames) {
    Add-Check 'Subagent names' $SaNames $ExpSaNames $CollectionNameMode
} else {
    Add-InfoRow 'Subagent names' $SaNames
}

# ─────────────────────────── Hooks ───────────────────────────

$Hooks   = Invoke-Dp '/api/v2/extendedAgent/hooks' -Collection
$HookCt  = $Hooks | Invoke-Jq -Filter '.value // . | if type == "array" then length else 0 end'
if (-not $HookCt) { $HookCt = '0' }
$HookNames    = ($Hooks | Invoke-Jq -Raw -Filter '(.value // .)[].name' | Sort-Object) -join ','
$ExpHookCt    = Get-Exp '.hooks | length'
$ExpHookNames = Get-ExpList '.hooks'

Add-Check 'Hooks' $HookCt $ExpHookCt $CollectionCountMode
if ($ExpHookNames) {
    Add-Check 'Hook names' $HookNames $ExpHookNames $CollectionNameMode
} else {
    Add-InfoRow 'Hook names' $HookNames
}

# ─────────────────────────── Common Prompts ───────────────────────────

$Prompts   = Invoke-Dp '/api/v2/extendedAgent/commonprompts' -Collection
$PromptCt  = $Prompts | Invoke-Jq -Filter '.value // . | if type == "array" then length else 0 end'
if (-not $PromptCt) { $PromptCt = '0' }
$PromptNames    = ($Prompts | Invoke-Jq -Raw -Filter '(.value // .)[].name' | Sort-Object) -join ','
$ExpPromptCt    = Get-Exp '.commonPrompts | length'
$ExpPromptNames = Get-ExpList '.commonPrompts'

Add-Check 'Common Prompts' $PromptCt $ExpPromptCt $CollectionCountMode
if ($ExpPromptNames) {
    Add-Check 'Prompt names' $PromptNames $ExpPromptNames $CollectionNameMode
} else {
    Add-InfoRow 'Prompt names' $PromptNames
}

# ─────────────────────────── Scheduled Tasks ───────────────────────────

$Tasks      = Invoke-Dp '/api/v2/extendedAgent/scheduledtasks' -Collection
$TaskCt     = $Tasks | Invoke-Jq -Filter '(.value // .) | if type == "array" then length else 0 end'
if (-not $TaskCt) { $TaskCt = '0' }
$TaskUnique = $Tasks | Invoke-Jq -Filter '[(.value // .)[].name] | unique | length'
if (-not $TaskUnique) { $TaskUnique = '0' }
$TaskNames    = $Tasks | Invoke-Jq -Raw -Filter '[(.value // .)[].name] | unique | sort | join(",")'
$ExpTaskCt    = Get-Exp '.scheduledTasks | length'
$ExpTaskNames = Get-ExpList '.scheduledTasks'

Add-Check 'Scheduled Tasks (unique)' $TaskUnique $ExpTaskCt $CollectionCountMode
if ($ExpTaskNames) {
    Add-Check 'Task names' $TaskNames $ExpTaskNames $CollectionNameMode
}
if ($TaskCt -ne $TaskUnique) {
    Add-InfoRow "  Warning: Duplicates" "${TaskCt} total, ${TaskUnique} unique"
}

# ─────────────────────────── Response Plans (Incident Filters) ───────────────────────────

$Filters   = Invoke-Dp '/api/v2/extendedAgent/incidentFilters' -Collection
$FilterCt  = $Filters | Invoke-Jq -Filter '(.value // .) | if type == "array" then length else 0 end'
if (-not $FilterCt) { $FilterCt = '0' }
$FilterNames    = ($Filters | Invoke-Jq -Raw -Filter '[(.value // .)[].name] | sort | join(",")' )
$ExpFilterCt    = Get-Exp '.responsePlans | length'
$ExpFilterNames = Get-ExpList '[.responsePlans[].name]'

Add-Check 'Response Plans' $FilterCt $ExpFilterCt $CollectionCountMode
if ($ExpFilterNames) {
    Add-Check 'Filter names' $FilterNames $ExpFilterNames $CollectionNameMode
} else {
    Add-InfoRow 'Filter names' $FilterNames
}

# ─────────────────────────── GitHub ───────────────────────────

$GhStatus     = Invoke-Dp '/api/v2/github/domains'
$GhConfigured = $GhStatus | Invoke-Jq -Raw -Filter 'if ((.values // []) | length) > 0 then true else false end'
Add-Check 'GitHub OAuth' $GhConfigured '-'

# ─────────────────────────── Repos ───────────────────────────

$Repos   = Invoke-Dp '/api/v2/repos' -Collection
$RepoCt  = $Repos | Invoke-Jq -Filter '.value // . | if type == "array" then length else 0 end'
if (-not $RepoCt) { $RepoCt = '0' }
$RepoNames    = ($Repos | Invoke-Jq -Raw -Filter '(.value // .)[].name' | Sort-Object) -join ','
$ExpRepoCt    = Get-Exp '.repos | length'
$ExpRepoNames = Get-ExpList '.repos'

Add-Check 'Repos' $RepoCt $ExpRepoCt $CollectionCountMode
if ($ExpRepoNames) {
    Add-Check 'Repo names' $RepoNames $ExpRepoNames $CollectionNameMode
} else {
    Add-InfoRow 'Repo names' $RepoNames
}
if ($ExpectedConfig -and $expectedObject.PSObject.Properties['repoBranches']) {
    foreach ($expectedRepo in $expectedObject.repoBranches.PSObject.Properties) {
        $repoName = $expectedRepo.Name
        $repo = ($Repos | ConvertFrom-Json).value | Where-Object name -eq $repoName | Select-Object -First 1
        $actualBranch = if ($repo -and $repo.PSObject.Properties['properties'] -and $repo.properties -and $repo.properties.PSObject.Properties['branch']) {
            $repo.properties.branch
        } else { '' }
        Add-Check "Repo branch ($repoName)" $actualBranch $expectedRepo.Value
    }
}

# ─────────────────────────── Print results table ───────────────────────────

Write-Host ''
$fmt = '  {0,-25} {1,-10} {2,-10} {3}'
Write-Host ($fmt -f 'Check', 'Actual', 'Expected', 'Result')
Write-Host ($fmt -f (([string][char]0x2500) * 25), (([string][char]0x2500) * 10), (([string][char]0x2500) * 10), (([string][char]0x2500) * 6))

foreach ($r in $Results) {
    $color = if ($r.Result -match 'FAIL') { 'Red' } elseif ($r.Result -match 'PASS') { 'Green' } else { 'Gray' }
    Write-Host ($fmt -f $r.Name, $r.Actual, $r.Expected, $r.Result) -ForegroundColor $color
}

# ─────────────────────────── Summary ───────────────────────────

Write-Host ''
Write-Host (([string][char]0x2550) * 55) -ForegroundColor Cyan
Write-Host "  Results: ${Pass} passed, ${Fail} failed" -ForegroundColor $(if ($Fail -gt 0) { 'Red' } else { 'Green' })
Write-Host "  Portal:  https://sre.azure.com/agents/subscriptions/${Subscription}/resourceGroups/${ResourceGroup}/providers/Microsoft.App/agents/${AgentName}" -ForegroundColor Cyan
Write-Host (([string][char]0x2550) * 55) -ForegroundColor Cyan
Write-Host ''

if ($Fail -gt 0) { exit 1 }
exit 0
