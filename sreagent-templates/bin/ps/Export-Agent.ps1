<#
.SYNOPSIS
    Export full SRE Agent configuration into deploy-ready files.

.DESCRIPTION
    Reads every ARM child resource + data-plane config and emits a structured
    directory of JSON, YAML, and markdown files that slot into Deploy-Agent.ps1
    / Apply-Extras.ps1 for cloning.

    Layout:
      <output>/
        agent.json               — Agent identity + settings
        connectors.json          — Connector toggles + entries (secrets → env var refs)
        connectors.secrets.env   — Actual secrets (.gitignored)
        expected-config.json     — Verification spec
        .gitignore
        config/                  — Skills, subagents, tools, hooks, prompts, repos
        automations/             — Scheduled tasks, incident filters, HTTP triggers, platforms
        data/                    — Knowledge, memories, repo instructions

.PARAMETER Subscription
    Azure subscription ID.

.PARAMETER ResourceGroup
    Resource group containing the agent.

.PARAMETER AgentName
    Agent resource name.

.PARAMETER Output
    Output directory (default: <AgentName>-export).

.PARAMETER Set
    Override identity fields for cloning. Accepts:
      -Set @{ agentName='my-clone'; location='uksouth' }
    Or an array of 'key=value' strings:
      -Set 'agentName=my-clone','location=uksouth'

.PARAMETER IncludeRepoInstructions
    Export repo instruction files (large, off by default).

.PARAMETER IncludeAll
    Enable all --include-* flags.

.PARAMETER NoKnowledge
    Skip knowledge documents.

.PARAMETER NoMemories
    Skip synthesized knowledge and workspace memories.

.PARAMETER NoDownload
    Skip downloading file content (metadata only).

.PARAMETER DryRun
    Show what would be exported, don't write files.

.EXAMPLE
    .\Export-Agent.ps1 -Subscription <sub> -ResourceGroup <rg> -AgentName <name>
    .\Export-Agent.ps1 -s <sub> -g <rg> -n <name> -Output /tmp/clone -Set @{agentName='clone1';location='uksouth'}
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

    [Alias('o')]
    [string]$Output,

    [object]$Set,

    [switch]$IncludeRepoInstructions,
    [switch]$IncludeAll,
    [switch]$NoKnowledge,
    [switch]$NoMemories,
    [switch]$NoDownload,
    [switch]$DownloadFiles,
    [switch]$DryRun
)

Set-StrictMode -Version Latest

# PS 7.3+ changed how native-command arguments are passed; use Legacy to avoid
# broken arg splitting when args contain '=' (e.g. jq --argjson, terraform -out=).
if ($PSVersionTable.PSVersion.Major -ge 7 -and $PSVersionTable.PSVersion.Minor -ge 3) {
    $PSNativeCommandArgumentPassing = 'Legacy'
}
$ErrorActionPreference = 'Stop'

# ─────────────────────────── Defaults ───────────────────────────

if (-not $Output)       { $Output = "${AgentName}-export" }

$INCLUDE_KNOWLEDGE       = -not $NoKnowledge
$INCLUDE_KNOWLEDGE_ITEMS = -not $NoKnowledge
$INCLUDE_REPO_INSTRUCTIONS = [bool]$IncludeRepoInstructions
$INCLUDE_MEMORIES        = -not $NoMemories
$DOWNLOAD_FILES          = -not $NoDownload

if ($IncludeAll) {
    $INCLUDE_KNOWLEDGE       = $true
    $INCLUDE_KNOWLEDGE_ITEMS = $true
    $INCLUDE_REPO_INSTRUCTIONS = $true
    $INCLUDE_MEMORIES        = $true
}

# Normalise -Set into a hashtable
$SetOverrides = @{}
if ($null -ne $Set) {
    if ($Set -is [hashtable]) {
        $SetOverrides = $Set
    } elseif ($Set -is [System.Collections.IDictionary]) {
        foreach ($k in $Set.Keys) { $SetOverrides[$k] = $Set[$k] }
    } elseif ($Set -is [array] -or $Set -is [string]) {
        $items = @($Set)
        foreach ($item in $items) {
            $eqIdx = $item.IndexOf('=')
            if ($eqIdx -gt 0) {
                $SetOverrides[$item.Substring(0, $eqIdx)] = $item.Substring($eqIdx + 1)
            }
        }
    }
}

$API_VERSION = '2025-05-01-preview'
$ARM_BASE    = "https://management.azure.com/subscriptions/${Subscription}/resourceGroups/${ResourceGroup}/providers/Microsoft.App/agents/${AgentName}"

# ─────────────────────────── Prerequisites ───────────────────────────

$PrereqScript = Join-Path $PSScriptRoot 'Check-Prerequisites.ps1'
if (Test-Path $PrereqScript) {
    . $PrereqScript
    if (-not (Test-Prerequisites -IncludePython -IncludeCurl)) { exit 1 }
} else {
    foreach ($cmd in @('jq', 'az', 'python3', 'curl')) {
        if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
            Write-Host "Error: $cmd is required but not found." -ForegroundColor Red
            exit 1
        }
    }
}
. (Join-Path $PSScriptRoot 'Invoke-Jq.ps1')

# ─────────────────────────── Helpers ───────────────────────────

function _log  { param([string]$Msg) Write-Host "  $Msg" }
function _info { param([string]$Msg) Write-Host "── $Msg ──" -ForegroundColor Cyan }
function _warn { param([string]$Msg) Write-Host "  WARN: $Msg" -ForegroundColor Yellow }
function _fail { param([string]$Msg) Write-Host "  ERROR: $Msg" -ForegroundColor Red; exit 1 }

# ── JSON → YAML via python3 ──
function ConvertTo-Yaml {
    param([Parameter(ValueFromPipeline)][string]$Json)
    begin   { $inputLines = [System.Collections.Generic.List[string]]::new() }
    process { if ($Json) { $inputLines.Add($Json) } }
    end {
        $fullJson = $inputLines -join "`n"
        $result = $fullJson | python3 -c @"
import sys, json, yaml

def strip_nulls(obj):
    if isinstance(obj, dict):
        return {k: strip_nulls(v) for k, v in obj.items() if v is not None}
    elif isinstance(obj, list):
        return [strip_nulls(i) for i in obj if i is not None]
    return obj

data = json.load(sys.stdin)
data = strip_nulls(data)
yaml.dump(data, sys.stdout, default_flow_style=False, sort_keys=False, allow_unicode=True)
"@
        if ($LASTEXITCODE -ne 0 -or -not $result) {
            throw "python3 YAML conversion failed (exit code: $LASTEXITCODE)"
        }
        # PS captures native-command stdout as string[] (one per line).
        # Join with newlines so Set-Content -NoNewline writes proper YAML.
        return ($result -join "`n")
    }
}

function Write-Yaml {
    param([string]$Dest, [string]$Json)
    $Json | ConvertTo-Yaml | Set-Content -Path $Dest -NoNewline -Encoding utf8
}

# ── ARM GET ──
function Invoke-ArmGet {
    param([string]$Url)
    try {
        $result = (az rest -m GET --url "${Url}?api-version=${API_VERSION}" -o json 2>$null) -join "`n"
        if ($LASTEXITCODE -ne 0 -or -not $result) { return 'null' }
        return $result
    } catch {
        return 'null'
    }
}

# ── ARM LIST child resources → .value array ──
function Invoke-ArmList {
    param([string]$ChildType)
    $url = "${ARM_BASE}/${ChildType}?api-version=${API_VERSION}"
    try {
        $result = (az rest -m GET --url $url -o json 2>$null) -join "`n"
        if ($LASTEXITCODE -ne 0 -or -not $result) { return '[]' }
        return ($result | Invoke-Jq -Compact -Filter '.value // []')
    } catch {
        return '[]'
    }
}

# ── Data-plane token (cached) ──
$script:DpTokenCache = ''
function Get-DpToken {
    if (-not $script:DpTokenCache) {
        try {
            $script:DpTokenCache = az account get-access-token --resource 'https://azuresre.dev' --query accessToken -o tsv 2>$null
            if ($LASTEXITCODE -ne 0 -or -not $script:DpTokenCache) {
                _fail 'Could not get data-plane token (audience https://azuresre.dev)'
            }
        } catch {
            _fail 'Could not get data-plane token (audience https://azuresre.dev)'
        }
    }
    return $script:DpTokenCache
}

# ── Data-plane GET ──
function Invoke-DpGet {
    param([string]$Path)
    $token = Get-DpToken
    try {
        $result = (curl -sS -f --max-time 10 -H "Authorization: Bearer $token" "${AGENT_ENDPOINT}${Path}" 2>$null) -join "`n"
        if ($LASTEXITCODE -ne 0 -or -not $result) { return 'null' }
        return $result
    } catch {
        return 'null'
    }
}

# ── Data-plane download file ──
function Invoke-DpDownload {
    param([string]$Path, [string]$Dest)
    $token = Get-DpToken
    $dir = Split-Path -Parent $Dest
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    curl -sS -f -H "Authorization: Bearer $token" -o $Dest "${AGENT_ENDPOINT}${Path}" 2>$null
    return ($LASTEXITCODE -eq 0)
}

# ── Data-plane download tarball ──
function Invoke-DpDownloadTarball {
    param([string]$Path, [string]$DestDir, [string]$Label)
    $token = Get-DpToken
    $tmpfile = [System.IO.Path]::GetTempFileName() + '.tar.gz'
    $ok = $false
    try {
        curl -sS -f -H "Authorization: Bearer $token" -o $tmpfile "${AGENT_ENDPOINT}${Path}" 2>$null
        if ($LASTEXITCODE -eq 0) {
            if (-not (Test-Path $DestDir)) { New-Item -ItemType Directory -Path $DestDir -Force | Out-Null }
            tar -xzf $tmpfile -C $DestDir 2>$null
            $count = (Get-ChildItem -Path $DestDir -File -Recurse -ErrorAction SilentlyContinue | Measure-Object).Count
            _log "  Downloaded ${Label}: ${count} file(s) → ${DestDir}"
            $ok = $true
        } else {
            _log "  WARN: Could not download ${Label}"
        }
    } catch {
        _log "  WARN: Could not download ${Label}"
    } finally {
        Remove-Item $tmpfile -Force -ErrorAction SilentlyContinue
    }
    return $ok
}

# ── Decode base64 opaque ARM sub-resources ──
function ConvertFrom-OpaqueArm {
    param([string]$Raw)
    $Raw | Invoke-Jq -Compact -Filter '[.[] | {
        metadata: { name: (.name | split("/") | last) },
        spec: (
            (.properties.value // "") |
            if . == "" then {} else (. | @base64d | fromjson) end
        )
    }]'
}

# ── Decode skills (special shape) ──
function ConvertFrom-SkillsArm {
    param([string]$Raw)
    $Raw | Invoke-Jq -Compact -Filter '[.[] | {
        metadata: {
            name: (.name | split("/") | last),
            description: (
                (.properties.value // "") |
                if . == "" then "" else (. | @base64d | fromjson | .description // "") end
            ),
            spec: {
                tools: (
                    (.properties.value // "") |
                    if . == "" then [] else (. | @base64d | fromjson | .tools // []) end
                )
            }
        },
        skillContent: (
            (.properties.value // "") |
            if . == "" then "" else (. | @base64d | fromjson | .skillContent // "") end
        ),
        additionalFiles: (
            (.properties.value // "") |
            if . == "" then [] else (. | @base64d | fromjson | .additionalFiles // []) end
        )
    }]'
}

# ── Sanitize secrets ──
function Invoke-Sanitize {
    param([string]$Json)
    $Json | Invoke-Jq -Filter '
        walk(
            if type == "string" then
                (if test("^ghp_[A-Za-z0-9_]+$") then "EDIT_ME_GITHUB_PAT"
                elif test("^Bearer ") then "EDIT_ME_BEARER_TOKEN"
                elif (test("^[A-Za-z0-9+/=]{40,}$") and (test("^/subscriptions/") | not)) then "EDIT_ME_SECRET"
                elif test("BearerToken=[^;]+") then gsub("BearerToken=[^;]+"; "BearerToken=EDIT_ME_TOKEN")
                elif test("accessToken") then "EDIT_ME_ACCESS_TOKEN"
                else . end)
            else . end
        )'
}

# ── Write array items as individual YAML files ──
function Write-ConfigItems {
    param(
        [string]$Dir,
        [string]$ItemsJson,
        [string]$NamePath,
        [string]$Base = 'config'
    )
    $count = ($ItemsJson | jq 'length') -as [int]
    if ($count -le 0) { return }
    $targetDir = Join-Path $EXPORT_DIR "$Base/$Dir"
    if (-not (Test-Path $targetDir)) { New-Item -ItemType Directory -Path $targetDir -Force | Out-Null }
    for ($i = 0; $i -lt $count; $i++) {
        $name = $ItemsJson | jq -r --argjson i $i ".[$i]${NamePath}"
        $itemJson = $ItemsJson | jq --argjson i $i '.[$i]'
        Write-Yaml -Dest (Join-Path $targetDir "${name}.yaml") -Json $itemJson
    }
    _log "  ${Dir}: ${count} file(s)"
}

# ═══════════════════════════════════════════════════════════════════
# Phase 1: ARM — agent core
# ═══════════════════════════════════════════════════════════════════

_info "Connecting to agent ${AgentName} in ${ResourceGroup}"

$AGENT_JSON = Invoke-ArmGet $ARM_BASE
if ($AGENT_JSON -eq 'null') {
    _fail "Agent ${AgentName} not found in ${ResourceGroup} (subscription: ${Subscription})"
}

$AGENT_ENDPOINT = $AGENT_JSON | Invoke-Jq -Raw -Filter '.properties.agentEndpoint // empty'
if (-not $AGENT_ENDPOINT) {
    _fail 'Agent has no endpoint — may still be provisioning'
}

$LOCATION      = ($AGENT_JSON | Invoke-Jq -Raw -Filter '.location // "eastus2"')
$ACCESS_LEVEL  = ($AGENT_JSON | Invoke-Jq -Raw -Filter '.properties.actionConfiguration.accessLevel // .properties.accessLevel // "Low"')
$ACTION_MODE   = ($AGENT_JSON | Invoke-Jq -Raw -Filter '.properties.actionConfiguration.mode // .properties.actionMode // "Review"')
$UPGRADE_CHANNEL = ($AGENT_JSON | Invoke-Jq -Raw -Filter '.properties.upgradeChannel // "Preview"')
$DEFAULT_MODEL_PROVIDER = ($AGENT_JSON | Invoke-Jq -Raw -Filter '.properties.defaultModelProvider // "Anthropic"')
$AGENT_UAMI    = ($AGENT_JSON | Invoke-Jq -Raw -Filter '.identity.userAssignedIdentities // {} | keys[0] // ""')

_log "Location:       ${LOCATION}"
_log "Access level:   ${ACCESS_LEVEL}"
_log "Action mode:    ${ACTION_MODE}"
_log "Endpoint:       ${AGENT_ENDPOINT}"
if ($AGENT_UAMI) { _log "UAMI:           $($AGENT_UAMI.Split('/')[-1])" }

# Extract target resource groups
$TARGET_RGS = $AGENT_JSON | Invoke-Jq -Compact -Filter '
    ([
        .properties.knowledgeGraphConfiguration.managedResources // [] | .[] |
        capture("/resourceGroups/(?<rg>[^/]+)") | .rg
    ] | unique) as $from_managed |
    if ($from_managed | length) > 0 then $from_managed
    else [
        .properties.managedResources // [] |
        .[] | select(.type == "Microsoft.Authorization/roleAssignments") |
        .scope // "" | capture("/resourceGroups/(?<rg>[^/]+)") | .rg
    ] | unique end'

_log "Target RGs:     $($TARGET_RGS | Invoke-Jq -Raw -Filter 'join(", ") // "<none>"')"
Write-Host ''

# ═══════════════════════════════════════════════════════════════════
# Phase 2: ARM — child resources
# ═══════════════════════════════════════════════════════════════════

_info 'Exporting ARM child resources'

# ── Connectors ──
_log 'Reading connectors...'
$RAW_CONNECTORS = Invoke-ArmList 'connectors'
$CONNECTOR_COUNT = ($RAW_CONNECTORS | jq 'length') -as [int]
_log "  Found ${CONNECTOR_COUNT} connector(s) from ARM"

$DP_CONNECTORS = Invoke-DpGet '/api/v2/extendedAgent/connectors' | Invoke-Jq -Compact -Filter '.value // []'
if (-not $DP_CONNECTORS -or $DP_CONNECTORS -eq 'null') { $DP_CONNECTORS = '[]' }
$DP_COUNT = ($DP_CONNECTORS | jq 'length') -as [int]
_log "  Found ${DP_COUNT} connector(s) from data-plane"

# Prefer data-plane connectors (ARM redacts secrets)
$dpTmpFile = [System.IO.Path]::GetTempFileName()
$DP_CONNECTORS | Set-Content -Path $dpTmpFile -Encoding utf8 -NoNewline
$CONNECTORS = $RAW_CONNECTORS | Invoke-Jq -Compact -Filter '[.[] |
    . as $arm |
    ($arm.name | split("/") | last) as $cname |
    ($arm.properties.dataConnectorType) as $ctype |
    ([$dp[0][] | select(.name == $cname)] | first) as $dpconn |
    if $dpconn then {
        name: $cname,
        properties: {
            dataConnectorType: ($dpconn.properties.dataConnectorType // $ctype),
            dataSource: ($dpconn.properties.dataSource // $arm.properties.dataSource // ""),
            extendedProperties: ($dpconn.properties.extendedProperties // $arm.properties.extendedProperties // {}),
            identity: ($dpconn.properties.identity // $arm.properties.identity // "system")
        }
    } else {
        name: $cname,
        properties: {
            dataConnectorType: $ctype,
            dataSource: ($arm.properties.dataSource // ""),
            extendedProperties: ($arm.properties.extendedProperties // {}),
            identity: ($arm.properties.identity // "system")
        }
    } end
]' -ExtraArgs @('--slurpfile', 'dp', $dpTmpFile)
Remove-Item $dpTmpFile -Force -ErrorAction SilentlyContinue
$CONNECTORS = Invoke-Sanitize $CONNECTORS

# ── Tools (opaque) ──
_log 'Reading tools...'
$RAW_TOOLS = Invoke-ArmList 'tools'
$TOOL_COUNT = ($RAW_TOOLS | jq 'length') -as [int]
_log "  Found ${TOOL_COUNT} tool(s)"
$TOOLS = ConvertFrom-OpaqueArm $RAW_TOOLS

# ── Skills (opaque, special shape) ──
_log 'Reading skills...'
$RAW_SKILLS = Invoke-ArmList 'skills'
$SKILL_COUNT = ($RAW_SKILLS | jq 'length') -as [int]
_log "  Found ${SKILL_COUNT} skill(s)"
$SKILLS = ConvertFrom-SkillsArm $RAW_SKILLS

# ── Scheduled Tasks (opaque) ──
_log 'Reading scheduled tasks...'
$RAW_TASKS = Invoke-ArmList 'scheduledTasks'
$TASK_COUNT = ($RAW_TASKS | jq 'length') -as [int]
_log "  Found ${TASK_COUNT} scheduled task(s)"
$SCHEDULED_TASKS = ConvertFrom-OpaqueArm $RAW_TASKS

# ── Incident Filters (opaque) ──
_log 'Reading incident filters...'
$RAW_FILTERS = Invoke-ArmList 'incidentFilters'
$FILTER_COUNT = ($RAW_FILTERS | jq 'length') -as [int]
_log "  Found ${FILTER_COUNT} incident filter(s)"
$INCIDENT_FILTERS = ConvertFrom-OpaqueArm $RAW_FILTERS

# ── Incident Handlers (data-plane) — merge customInstructions ──
_log 'Reading incident handlers (data-plane)...'
$DP_HANDLERS = Invoke-DpGet '/api/v1/incidentPlayground/handlers'
if ($DP_HANDLERS -eq 'null') { $DP_HANDLERS = '[]' }
$DP_HANDLER_COUNT = ($DP_HANDLERS | jq 'length' 2>$null) -as [int]
if (-not $DP_HANDLER_COUNT) { $DP_HANDLER_COUNT = 0 }
_log "  Found ${DP_HANDLER_COUNT} incident handler(s)"

if ($DP_HANDLER_COUNT -gt 0) {
    $handlersTmpFile = [System.IO.Path]::GetTempFileName()
    $DP_HANDLERS | Set-Content -Path $handlersTmpFile -Encoding utf8 -NoNewline
    $INCIDENT_FILTERS = $INCIDENT_FILTERS | Invoke-Jq -Compact -Filter '
        [.[] | . as $f |
            ($handlers[0] | map(select(.incidentFilterId == $f.metadata.name)) | first // null) as $h |
            if $h and ($h.customInstructions // "") != "" then
                .spec.customInstructions = $h.customInstructions
            else . end
        ]' -ExtraArgs @('--slurpfile', 'handlers', $handlersTmpFile)
    Remove-Item $handlersTmpFile -Force -ErrorAction SilentlyContinue
    _log '  Merged customInstructions into filters'
}

# ── Subagents (opaque) ──
_log 'Reading subagents...'
$RAW_SUBAGENTS = Invoke-ArmList 'subagents'
$SUBAGENT_COUNT = ($RAW_SUBAGENTS | jq 'length') -as [int]
_log "  Found ${SUBAGENT_COUNT} subagent(s)"
$SUBAGENTS = ConvertFrom-OpaqueArm $RAW_SUBAGENTS

# ── Hooks (ARM) ──
_log 'Reading hooks (ARM)...'
$RAW_HOOKS_ARM = Invoke-ArmList 'hooks'
$HOOKS_ARM_COUNT = ($RAW_HOOKS_ARM | jq 'length') -as [int]
if ($HOOKS_ARM_COUNT -gt 0) {
    $HOOKS_ARM = ConvertFrom-OpaqueArm $RAW_HOOKS_ARM
    _log "  Found ${HOOKS_ARM_COUNT} hook(s) via ARM"
} else {
    $HOOKS_ARM = '[]'
    _log '  None via ARM (will try data-plane)'
}

# ── Common Prompts (ARM) ──
_log 'Reading common prompts (ARM)...'
$RAW_PROMPTS_ARM = Invoke-ArmList 'commonPrompts'
$PROMPTS_ARM_COUNT = ($RAW_PROMPTS_ARM | jq 'length') -as [int]
if ($PROMPTS_ARM_COUNT -gt 0) {
    $PROMPTS_ARM = ConvertFrom-OpaqueArm $RAW_PROMPTS_ARM
    _log "  Found ${PROMPTS_ARM_COUNT} common prompt(s) via ARM"
} else {
    $PROMPTS_ARM = '[]'
    _log '  None via ARM (will try data-plane)'
}

# ── Plugin Configs (ARM) ──
_log 'Reading plugin configs (ARM)...'
$RAW_PLUGINS_ARM = Invoke-ArmList 'pluginConfigs'
$PLUGINS_ARM_COUNT = ($RAW_PLUGINS_ARM | jq 'length') -as [int]
if ($PLUGINS_ARM_COUNT -gt 0) {
    $PLUGINS_ARM = ConvertFrom-OpaqueArm $RAW_PLUGINS_ARM
    _log "  Found ${PLUGINS_ARM_COUNT} plugin config(s) via ARM"
} else {
    $PLUGINS_ARM = '[]'
    _log '  None via ARM (will try data-plane)'
}

Write-Host ''

# ═══════════════════════════════════════════════════════════════════
# Phase 3: Data plane — extended config
# ═══════════════════════════════════════════════════════════════════

_info 'Exporting data-plane configuration'

# ── Hooks (data-plane) ──
_log 'Reading hooks (data-plane)...'
$RAW_HOOKS_DP = Invoke-DpGet '/api/v2/extendedAgent/hooks'
if ($RAW_HOOKS_DP -ne 'null') {
    $HOOKS_DP = $RAW_HOOKS_DP | Invoke-Jq -Compact -Filter '[(.value // . // [])[] | {
        name: .name,
        type: (.type // ""),
        tags: (.tags // []),
        properties: (.properties // {})
    }]'
    if (-not $HOOKS_DP) { $HOOKS_DP = '[]' }
} else {
    $HOOKS_DP = '[]'
}
if ($HOOKS_ARM_COUNT -gt 0) {
    $HOOKS_FOR_PARAMS = $HOOKS_ARM
    $HOOKS_FOR_EXTRAS = '[]'
    $HOOK_COUNT = $HOOKS_ARM_COUNT
} else {
    $HOOKS_FOR_PARAMS = '[]'
    $HOOKS_FOR_EXTRAS = $HOOKS_DP
    $HOOK_COUNT = ($HOOKS_DP | jq 'length') -as [int]
}
_log "  Found ${HOOK_COUNT} hook(s) total"

# ── Common Prompts (data-plane) ──
_log 'Reading common prompts (data-plane)...'
$RAW_PROMPTS_DP = Invoke-DpGet '/api/v2/extendedAgent/commonprompts'
if ($RAW_PROMPTS_DP -ne 'null') {
    $PROMPTS_DP = $RAW_PROMPTS_DP | Invoke-Jq -Compact -Filter '[(.value // . // [])[] | {
        name: .name,
        type: (.type // ""),
        tags: (.tags // []),
        properties: (.properties // {})
    }]'
    if (-not $PROMPTS_DP) { $PROMPTS_DP = '[]' }
} else {
    $PROMPTS_DP = '[]'
}
if ($PROMPTS_ARM_COUNT -gt 0) {
    $PROMPTS_FOR_PARAMS = $PROMPTS_ARM
    $PROMPTS_FOR_EXTRAS = '[]'
    $PROMPT_COUNT = $PROMPTS_ARM_COUNT
} else {
    $PROMPTS_FOR_PARAMS = '[]'
    $PROMPTS_FOR_EXTRAS = $PROMPTS_DP
    $PROMPT_COUNT = ($PROMPTS_DP | jq 'length') -as [int]
}
_log "  Found ${PROMPT_COUNT} common prompt(s) total"

# ── Plugin Configs (data-plane) ──
_log 'Reading plugin configs (data-plane)...'
$RAW_PLUGINS_DP = Invoke-DpGet '/api/v2/extendedAgent/plugins'
if ($RAW_PLUGINS_DP -ne 'null') {
    $PLUGINS_DP = $RAW_PLUGINS_DP | Invoke-Jq -Compact -Filter '[(.value // . // [])[] | {
        name: .name,
        type: (.type // "plugin"),
        tags: (.tags // []),
        properties: (.properties // {})
    }]'
    if (-not $PLUGINS_DP) { $PLUGINS_DP = '[]' }
} else {
    $PLUGINS_DP = '[]'
}
if ($PLUGINS_ARM_COUNT -gt 0) {
    $PLUGINS_FOR_PARAMS = $PLUGINS_ARM
    $PLUGINS_FOR_EXTRAS = '[]'
    $PLUGIN_COUNT = $PLUGINS_ARM_COUNT
} else {
    $PLUGINS_FOR_PARAMS = '[]'
    $PLUGINS_FOR_EXTRAS = $PLUGINS_DP
    $PLUGIN_COUNT = ($PLUGINS_DP | jq 'length') -as [int]
}
_log "  Found ${PLUGIN_COUNT} plugin config(s) total"

# ── Repos ──
_log 'Reading repos...'
$RAW_REPOS = Invoke-DpGet '/api/v2/repos/'
if ($RAW_REPOS -ne 'null') {
    $REPOS = $RAW_REPOS | Invoke-Jq -Compact -Filter '[(.value // . // [])[] | {
        name: .name,
        spec: {
            url: (.properties.url // ""),
            type: ((.properties.type // "GitHub") | ascii_downcase),
            branch: (.properties.branch // "main")
        }
    }]'
    if (-not $REPOS) { $REPOS = '[]' }
} else {
    $REPOS = '[]'
}
$REPO_COUNT = ($REPOS | jq 'length') -as [int]
_log "  Found ${REPO_COUNT} repo(s)"

# ── Incident Platforms ──
_log 'Reading incident platforms...'
$INCIDENT_PLATFORMS = '[]'
$IM_TYPE = $AGENT_JSON | Invoke-Jq -Raw -Filter '.properties.incidentManagementConfiguration.type // "None"'
if ($IM_TYPE -and $IM_TYPE -ne 'None' -and $IM_TYPE -ne 'null') {
    $INCIDENT_PLATFORMS = Invoke-Jq -Compact -Filter 'null | [{name: ($t | ascii_downcase), spec: {platformType: $t}}]' -ExtraArgs @('--arg', 't', $IM_TYPE)
}
foreach ($platformType in @('azmonitor', 'pagerduty', 'servicenow')) {
    $result = Invoke-DpGet "/api/v2/incidents/indexing/${platformType}/configuration" 2>$null
    if ($result -and $result -ne 'null') {
        $entry = $result | Invoke-Jq -Compact -Filter '{name: $t, spec: (.spec // .properties // .)}' -ExtraArgs @('--arg', 't', $platformType)
        if ($entry -and $entry -ne 'null') {
            $eTmpFile = [System.IO.Path]::GetTempFileName()
            $entry | Set-Content -Path $eTmpFile -Encoding utf8 -NoNewline
            $INCIDENT_PLATFORMS = $INCIDENT_PLATFORMS | Invoke-Jq -Compact -Filter '. + $e' -ExtraArgs @('--slurpfile', 'e', $eTmpFile)
            Remove-Item $eTmpFile -Force -ErrorAction SilentlyContinue
        }
    }
}
$INCIDENT_PLATFORM_COUNT = ($INCIDENT_PLATFORMS | jq 'length') -as [int]
_log "  Found ${INCIDENT_PLATFORM_COUNT} incident platform(s)"

# ── Plugin Marketplaces + Installations ──
_log 'Reading plugin marketplaces...'
$RAW_MARKETPLACES = Invoke-DpGet '/api/v2/plugins/marketplaces'
if ($RAW_MARKETPLACES -ne 'null') {
    $PLUGIN_MARKETPLACES = $RAW_MARKETPLACES | Invoke-Jq -Compact -Filter '[(.value // . // [])[] | {
        name: (.metadata.name // .name),
        spec: (.spec // .properties // {})
    }]'
    if (-not $PLUGIN_MARKETPLACES) { $PLUGIN_MARKETPLACES = '[]' }
} else {
    $PLUGIN_MARKETPLACES = '[]'
}
_log "  Found $($PLUGIN_MARKETPLACES | jq 'length') marketplace(s)"

_log 'Reading plugin installations...'
$RAW_INSTALLATIONS = Invoke-DpGet '/api/v2/plugins/installations'
if ($RAW_INSTALLATIONS -ne 'null') {
    $PLUGIN_INSTALLATIONS = $RAW_INSTALLATIONS | Invoke-Jq -Compact -Filter '[(.value // . // [])[] | {
        name: (.metadata.name // .name),
        spec: (.spec // .properties // {})
    }]'
    if (-not $PLUGIN_INSTALLATIONS) { $PLUGIN_INSTALLATIONS = '[]' }
} else {
    $PLUGIN_INSTALLATIONS = '[]'
}
_log "  Found $($PLUGIN_INSTALLATIONS | jq 'length') installation(s)"

# ── HTTP Triggers ──
_log 'Reading HTTP triggers...'
$RAW_HTTP_TRIGGERS = Invoke-DpGet '/api/v1/httpTriggers'
$HTTP_TRIGGER_TYPE = $RAW_HTTP_TRIGGERS | jq -r 'type' 2>$null
if ($HTTP_TRIGGER_TYPE -eq 'array') {
    $HTTP_TRIGGERS = $RAW_HTTP_TRIGGERS | Invoke-Jq -Compact -Filter '[.[] | {
        name: (.name // ""),
        spec: {
            description: (.description // ""),
            prompt: (.agentPrompt // .prompt // ""),
            handlingAgent: (.agent // .handlingAgent // ""),
            agentMode: (.agentMode // "Review")
        }
    }]'
} elseif ($HTTP_TRIGGER_TYPE -eq 'object') {
    $HTTP_TRIGGERS = $RAW_HTTP_TRIGGERS | Invoke-Jq -Compact -Filter '[(.value // [])[] | {
        name: (.name // ""),
        spec: {
            description: (.description // ""),
            prompt: (.agentPrompt // .prompt // ""),
            handlingAgent: (.agent // .handlingAgent // ""),
            agentMode: (.agentMode // "Review")
        }
    }]'
} else {
    $HTTP_TRIGGERS = '[]'
}
if (-not $HTTP_TRIGGERS) { $HTTP_TRIGGERS = '[]' }
$HTTP_TRIGGER_COUNT = ($HTTP_TRIGGERS | jq 'length') -as [int]
_log "  Found ${HTTP_TRIGGER_COUNT} HTTP trigger(s)"

# ── Webhook bridge detection ──
_log 'Checking for webhook bridge (Logic App)...'
$BRIDGE_EXISTS = $false
$bridgeId = "/subscriptions/${Subscription}/resourceGroups/${ResourceGroup}/providers/Microsoft.Logic/workflows/${AgentName}-webhook-bridge"
try {
    $BRIDGE_JSON = (az resource show --ids $bridgeId -o json 2>$null) -join "`n"
    if ($LASTEXITCODE -eq 0 -and $BRIDGE_JSON -and $BRIDGE_JSON -ne 'null') {
        $BRIDGE_EXISTS = $true
        _log "  Found webhook bridge: ${AgentName}-webhook-bridge"
    } else {
        _log '  No webhook bridge found'
    }
} catch {
    _log '  No webhook bridge found'
}

# ── Knowledge ──
$KNOWLEDGE = '[]'
$KNOWLEDGE_ITEMS = '[]'
$FILES_DIR = "${Output}-files"

# 1. AgentMemory uploaded documents
if ($INCLUDE_KNOWLEDGE) {
    _log 'Reading AgentMemory documents...'
    $RAW_KNOWLEDGE = Invoke-DpGet '/api/v1/AgentMemory/files'
    if ($RAW_KNOWLEDGE -ne 'null') {
        $KNOWLEDGE = $RAW_KNOWLEDGE | Invoke-Jq -Compact -Filter '[(.files // .value // . // [])[] | {
            filename: (.filename // .name // ""),
            mimeType: (.mimeType // .contentType // "application/octet-stream"),
            fileSize: (.fileSize // .size // 0),
            indexStatus: (if .isIndexed == true then "indexed" elif .isIndexed == false then "pending" else (.indexStatus // "unknown") end),
            triggerIndexing: true
        }]'
        if (-not $KNOWLEDGE) { $KNOWLEDGE = '[]' }
    }
    $KNOWLEDGE_COUNT = ($KNOWLEDGE | jq 'length') -as [int]
    _log "  Found ${KNOWLEDGE_COUNT} uploaded document(s)"

    if ($DOWNLOAD_FILES -and $KNOWLEDGE_COUNT -gt 0) {
        $DOCS_DIR = Join-Path $Output 'data/knowledge'
        if (-not (Test-Path $DOCS_DIR)) { New-Item -ItemType Directory -Path $DOCS_DIR -Force | Out-Null }
        _log '  Locating knowledge source files...'
        $ScriptDir2 = Split-Path -Parent $MyInvocation.MyCommand.Definition
        $RepoRoot = Split-Path -Parent (Split-Path -Parent $ScriptDir2)
        $found = 0; $missing = 0
        for ($i = 0; $i -lt $KNOWLEDGE_COUNT; $i++) {
            $fname = $KNOWLEDGE | jq -r --argjson i $i '.[$i].filename'
            $copied = $false
            # Search recipes and data dirs
            $candidates = @()
            $candidates += Get-ChildItem -Path (Join-Path $RepoRoot 'recipes') -Filter $fname -Recurse -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName
            $candidates += Get-ChildItem -Path $RepoRoot -Filter $fname -Depth 3 -File -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -like '*data*' } | Select-Object -ExpandProperty FullName
            foreach ($candidate in $candidates) {
                if (Test-Path $candidate) {
                    Copy-Item $candidate (Join-Path $DOCS_DIR $fname) -Force
                    _log "    + ${fname} (from ${candidate})"
                    $copied = $true; $found++
                    break
                }
            }
            if (-not $copied) {
                _log "    x ${fname} (no download API - place in <config>/data/knowledge/ before deploy)"
                $missing++
            }
        }
        if ($missing -gt 0) {
            _log "  WARNING: ${missing} file(s) not found locally. Place them in ${Output}/data/knowledge/ before deploy."
        }
        $KNOWLEDGE = $KNOWLEDGE | Invoke-Jq -Compact -Filter '[.[] | . + {localPath: ($dir + "/" + .filename)}]' -ExtraArgs @('--arg', 'dir', $DOCS_DIR)
    }
} else {
    _log 'Skipping AgentMemory documents (use -IncludeAll to include)'
}

# 2. Knowledge items (via connectors API)
if ($INCLUDE_KNOWLEDGE_ITEMS) {
    _log 'Reading knowledge items from connectors API...'
    $RAW_KNOWLEDGE_ITEMS = Invoke-DpGet '/api/v2/extendedAgent/connectors'
    if ($RAW_KNOWLEDGE_ITEMS -ne 'null') {
        $KNOWLEDGE_ITEMS = $RAW_KNOWLEDGE_ITEMS | Invoke-Jq -Compact -Filter '[
            (.value // . // [])[] |
            select(.properties.dataConnectorType // "" | test("^Knowledge")) |
            {
                name: .name,
                type: .properties.dataConnectorType,
                displayName: (.properties.displayName // .name),
                sourceUrl: (.properties.sourceUrl // ""),
                metadata: (.properties.metadata // {}),
                fileSize: (.properties.fileSize // 0)
            }
        ]'
        if (-not $KNOWLEDGE_ITEMS) { $KNOWLEDGE_ITEMS = '[]' }
    }
    $KI_COUNT = ($KNOWLEDGE_ITEMS | jq 'length') -as [int]
    _log "  Found ${KI_COUNT} knowledge item(s)"

    if ($DOWNLOAD_FILES -and $KI_COUNT -gt 0) {
        _log '  Downloading knowledge item content...'
        $KI_DIR = Join-Path $FILES_DIR 'knowledge-items'
        if (-not (Test-Path $KI_DIR)) { New-Item -ItemType Directory -Path $KI_DIR -Force | Out-Null }
        for ($i = 0; $i -lt $KI_COUNT; $i++) {
            $kiname = $KNOWLEDGE_ITEMS | jq -r --argjson i $i '.[$i].name'
            $kitype = $KNOWLEDGE_ITEMS | jq -r --argjson i $i '.[$i].type'
            $ext = switch ($kitype) {
                'KnowledgeText'    { '.md' }
                'KnowledgeWebPage' { '.html' }
                'KnowledgeFile'    { '' }
                default            { '.json' }
            }
            $encodedName = [System.Uri]::EscapeDataString($kiname)
            $ok = Invoke-DpDownload "/api/v2/extendedAgent/connectors/${encodedName}/content" (Join-Path $KI_DIR "${kiname}${ext}")
            if ($ok) {
                _log "    + ${kiname} (${kitype})"
            } else {
                _log "    x ${kiname} (could not download content)"
            }
        }
        $KNOWLEDGE_ITEMS = $KNOWLEDGE_ITEMS | Invoke-Jq -Compact -Filter '[
            .[] | . + {
                localPath: ($dir + "/" + .name + (
                    if .type == "KnowledgeText" then ".md"
                    elif .type == "KnowledgeWebPage" then ".html"
                    elif .type == "KnowledgeFile" then ""
                    else ".json" end
                ))
            }
        ]' -ExtraArgs @('--arg', 'dir', $KI_DIR)
    }
} else {
    _log 'Skipping knowledge items (use -IncludeAll to include)'
}

# 3. Synthesized knowledge
$SYNTHESIZED_KNOWLEDGE = '[]'
if ($INCLUDE_MEMORIES) {
    _log 'Reading synthesized knowledge...'
    $RAW_SYNTH = Invoke-DpGet '/api/v1/WorkspaceMemory/list?type=synthesized-knowledge'
    if ($RAW_SYNTH -ne 'null') {
        $SYNTHESIZED_KNOWLEDGE = $RAW_SYNTH | Invoke-Jq -Compact -Filter '[
            (.files // .value // . // [])[] | {
                path: (.path // ""),
                size: (.size // 0),
                lastModified: (.lastModified // "")
            }
        ]'
        if (-not $SYNTHESIZED_KNOWLEDGE) { $SYNTHESIZED_KNOWLEDGE = '[]' }
    }
    $SYNTH_COUNT = ($SYNTHESIZED_KNOWLEDGE | jq 'length') -as [int]
    _log "  Found ${SYNTH_COUNT} synthesized knowledge file(s)"

    if ($DOWNLOAD_FILES) {
        $SYNTH_DIR = Join-Path $FILES_DIR 'synthesized-knowledge'
        Invoke-DpDownloadTarball '/api/v1/WorkspaceMemory/synthesized-knowledge' $SYNTH_DIR 'synthesized-knowledge' | Out-Null
    }

    _log 'Reading workspace memory inventory...'
    $RAW_WS_MEM = Invoke-DpGet '/api/v1/WorkspaceMemory/list'
    if ($RAW_WS_MEM -ne 'null') {
        $WS_MEM_COUNT = ($RAW_WS_MEM | Invoke-Jq -Filter '(.files // .value // . // []) | length') -as [int]
        _log "  Found ${WS_MEM_COUNT} total workspace memory file(s)"
    }
} else {
    _log 'Skipping synthesized knowledge/memories (use -IncludeAll to include)'
}

# ── Repo Instructions ──
$REPO_INSTRUCTIONS = '[]'
if ($INCLUDE_REPO_INSTRUCTIONS -and $REPO_COUNT -gt 0) {
    _log 'Reading repo instructions...'
    for ($i = 0; $i -lt $REPO_COUNT; $i++) {
        $rname = $REPOS | jq -r --argjson i $i '.[$i].name'
        if ($DOWNLOAD_FILES) {
            $RI_DIR = Join-Path $FILES_DIR "repo-instructions/${rname}"
            $encodedRname = [System.Uri]::EscapeDataString($rname)
            Invoke-DpDownloadTarball "/api/v1/WorkspaceMemory/repo-instructions?repo=${encodedRname}" $RI_DIR "repo-instructions/${rname}" | Out-Null
            if (Test-Path $RI_DIR) {
                $filesArray = '[]'
                Get-ChildItem -Path $RI_DIR -File -Recurse | ForEach-Object {
                    $relpath = $_.FullName.Substring($RI_DIR.Length + 1)
                    $content = Get-Content $_.FullName -Raw -ErrorAction SilentlyContinue
                    $filesArray = $filesArray | Invoke-Jq -Compact -Filter '. + [{path: $p, content: $c}]' -ExtraArgs @('--arg', 'p', $relpath, '--arg', 'c', "$content")
                }
                $fTmpFile = [System.IO.Path]::GetTempFileName()
                $filesArray | Set-Content -Path $fTmpFile -Encoding utf8 -NoNewline
                $entry = Invoke-Jq -Compact -Filter 'null | {repo: $r, files: $f[0]}' -ExtraArgs @('--arg', 'r', $rname, '--slurpfile', 'f', $fTmpFile)
                Remove-Item $fTmpFile -Force -ErrorAction SilentlyContinue
                $eTmpFile = [System.IO.Path]::GetTempFileName()
                $entry | Set-Content -Path $eTmpFile -Encoding utf8 -NoNewline
                $REPO_INSTRUCTIONS = $REPO_INSTRUCTIONS | Invoke-Jq -Compact -Filter '. + $e' -ExtraArgs @('--slurpfile', 'e', $eTmpFile)
                Remove-Item $eTmpFile -Force -ErrorAction SilentlyContinue
            }
        } else {
            $encodedRname = [System.Uri]::EscapeDataString($rname)
            $result = Invoke-DpGet "/api/v1/WorkspaceMemory/list?type=repo-instructions&repo=${encodedRname}"
            if ($result -ne 'null') {
                $files = $result | Invoke-Jq -Compact -Filter '[(.value // . // [])[] | {path: .path, size: .size}]'
                if (-not $files) { $files = '[]' }
                $fileCount = ($files | jq 'length') -as [int]
                if ($fileCount -gt 0) {
                    $fTmpFile2 = [System.IO.Path]::GetTempFileName()
                    $files | Set-Content -Path $fTmpFile2 -Encoding utf8 -NoNewline
                    $entry = Invoke-Jq -Compact -Filter 'null | {repo: $r, files: $f[0], _note: "Content not downloaded \u2014 use -DownloadFiles to include"}' -ExtraArgs @('--arg', 'r', $rname, '--slurpfile', 'f', $fTmpFile2)
                    Remove-Item $fTmpFile2 -Force -ErrorAction SilentlyContinue
                    $eTmpFile2 = [System.IO.Path]::GetTempFileName()
                    $entry | Set-Content -Path $eTmpFile2 -Encoding utf8 -NoNewline
                    $REPO_INSTRUCTIONS = $REPO_INSTRUCTIONS | Invoke-Jq -Compact -Filter '. + $e' -ExtraArgs @('--slurpfile', 'e', $eTmpFile2)
                    Remove-Item $eTmpFile2 -Force -ErrorAction SilentlyContinue
                }
            }
        }
    }
    _log "  Found $($REPO_INSTRUCTIONS | jq 'length') repo instruction set(s)"
} else {
    _log 'Skipping repo instructions (use -IncludeRepoInstructions to include)'
}

Write-Host ''

# ═══════════════════════════════════════════════════════════════════
# Phase 4: Dry-run summary
# ═══════════════════════════════════════════════════════════════════

_info 'Export summary'

Write-Host "  Agent:              ${AgentName}"
Write-Host "  Location:           ${LOCATION}"
Write-Host "  Access level:       ${ACCESS_LEVEL}"
Write-Host "  Action mode:        ${ACTION_MODE}"
Write-Host "  Target RGs:         $($TARGET_RGS | Invoke-Jq -Raw -Filter 'join(", ") // "<none>"')"
Write-Host ''

Write-Host "  Connectors:         ${CONNECTOR_COUNT}"
for ($i = 0; $i -lt $CONNECTOR_COUNT; $i++) {
    $cname = $CONNECTORS | jq -r --argjson i $i '.[$i].name'
    $ctype = $CONNECTORS | jq -r --argjson i $i '.[$i].properties.dataConnectorType'
    Write-Host "    - ${cname} (${ctype})"
}
Write-Host "  Skills:             ${SKILL_COUNT}"
$SKILLS | jq -r '.[].metadata.name' 2>$null | ForEach-Object { Write-Host "    - $_" }
Write-Host "  Subagents:          ${SUBAGENT_COUNT}"
$SUBAGENTS | jq -r '.[].metadata.name' 2>$null | ForEach-Object { Write-Host "    - $_" }
Write-Host "  Hooks:              ${HOOK_COUNT}"
$HOOKS_FOR_EXTRAS | jq -r '.[].name' 2>$null | ForEach-Object { Write-Host "    - $_" }
Write-Host "  Common prompts:     ${PROMPT_COUNT}"
$PROMPTS_FOR_EXTRAS | jq -r '.[].name' 2>$null | ForEach-Object { Write-Host "    - $_" }
Write-Host "  HTTP triggers:      ${HTTP_TRIGGER_COUNT}"
$HTTP_TRIGGERS | jq -r '.[].name' 2>$null | ForEach-Object { Write-Host "    - $_" }
Write-Host "  Repos:              ${REPO_COUNT}"
$REPOS | jq -r '.[].name' 2>$null | ForEach-Object { Write-Host "    - $_" }
Write-Host "  Webhook bridge:     $(if ($BRIDGE_EXISTS) { 'yes' } else { 'no' })"
Write-Host "  Incident platforms: ${INCIDENT_PLATFORM_COUNT}"
Write-Host "  Scheduled tasks:    ${TASK_COUNT}"
Write-Host "  Incident filters:   ${FILTER_COUNT}"

if ($DryRun) {
    Write-Host ''
    Write-Host 'Dry run — no files written.'
    exit 0
}

Write-Host ''

# ═══════════════════════════════════════════════════════════════════
# Phase 5: Write structured output
# ═══════════════════════════════════════════════════════════════════

$EXPORT_DIR = $Output
if (-not (Test-Path (Join-Path $EXPORT_DIR 'config'))) {
    New-Item -ItemType Directory -Path (Join-Path $EXPORT_DIR 'config') -Force | Out-Null
}

# ═══════ 1. agent.json ═══════

_info 'Writing agent.json'

# Toggle inference from connectors
$ENABLE_AI = $false; $AI_RESOURCE_ID = ''; $AI_APP_ID = ''
$ENABLE_LAW = $false; $LAW_RESOURCE_ID = ''
$ENABLE_AZMON = $false; $AZMON_LOOKBACK = 7

for ($i = 0; $i -lt $CONNECTOR_COUNT; $i++) {
    $ctype = $CONNECTORS | jq -r --argjson i $i '.[$i].properties.dataConnectorType'
    switch ($ctype) {
        'AppInsights' {
            $ENABLE_AI = $true
            $AI_RESOURCE_ID = $CONNECTORS | Invoke-Jq -Raw -Filter '.[$i].properties.dataSource // .[$i].properties.extendedProperties.armResourceId // ""' -ExtraArgs @('--argjson', 'i', "$i")
            $AI_APP_ID = $CONNECTORS | Invoke-Jq -Raw -Filter '.[$i].properties.extendedProperties.appId // ""' -ExtraArgs @('--argjson', 'i', "$i")
        }
        'LogAnalytics' {
            $ENABLE_LAW = $true
            $LAW_RESOURCE_ID = $CONNECTORS | Invoke-Jq -Raw -Filter '.[$i].properties.dataSource // .[$i].properties.extendedProperties.armResourceId // ""' -ExtraArgs @('--argjson', 'i', "$i")
        }
        'AzureMonitor' {
            $ENABLE_AZMON = $true
            $AZMON_LOOKBACK = ($CONNECTORS | Invoke-Jq -Raw -Filter '.[$i].properties.extendedProperties.lookbackDays // 7' -ExtraArgs @('--argjson', 'i', "$i")) -as [int]
        }
    }
}

$bridgeBool = if ($BRIDGE_EXISTS) { 'true' } else { 'false' }
$trgTmpFile = [System.IO.Path]::GetTempFileName()
$TARGET_RGS | Set-Content -Path $trgTmpFile -Encoding utf8 -NoNewline
Invoke-Jq -Filter '{
        "_description": "SRE Agent configuration — edit these values to clone to a new environment.",
        "_exported_at": (now | todate),
        "identity": {
            "agentName":            $agent,
            "resourceGroup":        $rg,
            "subscription":         $sub,
            "location":             $loc,
            "targetResourceGroups": $targetRgs[0]
        },
        "access": {
            "accessLevel":  $access,
            "actionMode":   $action
        },
        "upgradeChannel": "Preview",
        "defaultModelProvider": "Anthropic",
        "monthlyAgentUnitLimit": 10000,
        "tags": {},
        "toggles": {
            "enableWebhookBridge":     ($enableBridge | test("true")),
            "webhookBridgeTriggerUrl": ""
        }
    }' -ExtraArgs @(
        '--arg', 'agent', $AgentName,
        '--arg', 'rg', $ResourceGroup,
        '--arg', 'sub', $Subscription,
        '--arg', 'loc', $LOCATION,
        '--arg', 'access', $ACCESS_LEVEL,
        '--arg', 'action', $ACTION_MODE,
        '--slurpfile', 'targetRgs', $trgTmpFile,
        '--arg', 'enableBridge', $bridgeBool
    ) | Set-Content -Path (Join-Path $EXPORT_DIR 'agent.json') -Encoding utf8
Remove-Item $trgTmpFile -Force -ErrorAction SilentlyContinue

# Apply --set overrides
if ($SetOverrides.Count -gt 0) {
    _log 'Applying --set overrides:'
    $agentJsonPath = Join-Path $EXPORT_DIR 'agent.json'
    foreach ($key in $SetOverrides.Keys) {
        $val = $SetOverrides[$key]
        $tmpFile = [System.IO.Path]::GetTempFileName()
        switch ($key) {
            'agentName' {
                Get-Content $agentJsonPath -Raw | Invoke-Jq -Filter '.identity.agentName = $v' -ExtraArgs @('--arg', 'v', $val) | Set-Content $tmpFile -Encoding utf8
                Move-Item $tmpFile $agentJsonPath -Force
                _log "  agentName -> $val"
            }
            'resourceGroup' {
                Get-Content $agentJsonPath -Raw | Invoke-Jq -Filter '.identity.resourceGroup = $v' -ExtraArgs @('--arg', 'v', $val) | Set-Content $tmpFile -Encoding utf8
                Move-Item $tmpFile $agentJsonPath -Force
                _log "  resourceGroup -> $val"
            }
            'location' {
                Get-Content $agentJsonPath -Raw | Invoke-Jq -Filter '.identity.location = $v' -ExtraArgs @('--arg', 'v', $val) | Set-Content $tmpFile -Encoding utf8
                Move-Item $tmpFile $agentJsonPath -Force
                _log "  location -> $val"
            }
            'targetRGs' {
                Get-Content $agentJsonPath -Raw | Invoke-Jq -Filter '.identity.targetResourceGroups = $v' -ExtraArgs @('--arg', 'v', $val) | Set-Content $tmpFile -Encoding utf8
                Move-Item $tmpFile $agentJsonPath -Force
                _log "  targetRGs -> $val"
            }
            'accessLevel' {
                Get-Content $agentJsonPath -Raw | Invoke-Jq -Filter '.access.accessLevel = $v' -ExtraArgs @('--arg', 'v', $val) | Set-Content $tmpFile -Encoding utf8
                Move-Item $tmpFile $agentJsonPath -Force
                _log "  accessLevel -> $val"
            }
            'actionMode' {
                Get-Content $agentJsonPath -Raw | Invoke-Jq -Filter '.access.actionMode = $v' -ExtraArgs @('--arg', 'v', $val) | Set-Content $tmpFile -Encoding utf8
                Move-Item $tmpFile $agentJsonPath -Force
                _log "  actionMode -> $val"
            }
            { $_ -in 'pagerdutyApiKey', 'servicenowApiKey', 'connectionKey' } {
                $platDir = Join-Path $EXPORT_DIR 'automations/incident-platforms'
                if (Test-Path $platDir) {
                    Get-ChildItem -Path $platDir -Filter '*.yaml' | ForEach-Object {
                        python3 -c @"
import yaml
with open('$($_.FullName)') as f: d = yaml.safe_load(f)
d.setdefault('spec',{})['connectionKey'] = '$val'
with open('$($_.FullName)','w') as f: yaml.dump(d, f, default_flow_style=False, sort_keys=False)
"@ 2>$null
                    }
                }
                _log "  connectionKey -> (set in incident-platforms/*.yaml)"
                Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue
            }
            default {
                _warn "Unknown --set key: $key (ignored)"
                Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue
            }
        }
    }
}
_log 'Wrote agent.json'

# ═══════ 2. connectors.json + connectors.secrets.env ═══════

_info 'Writing connectors.json'

$SECRETS_ENV = Join-Path $EXPORT_DIR 'connectors.secrets.env'
$secretLines = @(
    '# SRE Agent connector secrets — DO NOT commit this file.',
    "# Generated $(Get-Date -Format 'yyyy-MM-ddTHH:mm:ssZ' -AsUTC)",
    ''
)

$CONNECTORS_CLEAN = $CONNECTORS
for ($i = 0; $i -lt $CONNECTOR_COUNT; $i++) {
    $cname = $CONNECTORS | jq -r --argjson i $i '.[$i].name'
    $dsrc  = $CONNECTORS | Invoke-Jq -Raw -Filter '.[$i].properties.dataSource // ""' -ExtraArgs @('--argjson', 'i', "$i")
    $ENV_PREFIX = ($cname -replace '-', '_').ToUpper()

    # Extract bearer tokens from connection strings
    if ($dsrc -match 'BearerToken=([^;]+)') {
        $token = $Matches[1]
        $secretLines += "${ENV_PREFIX}_BEARER_TOKEN=${token}"
        $ref = "`${${ENV_PREFIX}_BEARER_TOKEN}"
        $CONNECTORS_CLEAN = $CONNECTORS_CLEAN | Invoke-Jq -Filter '.[$i].properties.dataSource = (.[$i].properties.dataSource | gsub("BearerToken=[^;]+"; "BearerToken=" + $ref))' -ExtraArgs @('--argjson', 'i', "$i", '--arg', 'ref', $ref)
    }

    # Extract bearer tokens from extendedProperties
    $bt = $CONNECTORS | Invoke-Jq -Raw -Filter '.[$i].properties.extendedProperties.bearerToken // empty' -ExtraArgs @('--argjson', 'i', "$i")
    if ($bt) {
        $secretLines += "${ENV_PREFIX}_BEARER_TOKEN=${bt}"
        $ref = "`${${ENV_PREFIX}_BEARER_TOKEN}"
        $CONNECTORS_CLEAN = $CONNECTORS_CLEAN | Invoke-Jq -Filter '.[$i].properties.extendedProperties.bearerToken = $ref' -ExtraArgs @('--argjson', 'i', "$i", '--arg', 'ref', $ref)
    }
}

$CONNECTORS_CLEAN = Invoke-Sanitize $CONNECTORS_CLEAN

# Separate toggle-managed connectors from array connectors
$TOGGLE_TYPES = 'AppInsights|LogAnalytics|AzureMonitor'
$CONNECTORS_ARRAY = $CONNECTORS_CLEAN | Invoke-Jq -Compact -Filter '[.[] | select(.properties.dataConnectorType | test("^(\($tt))$") | not)]' -ExtraArgs @('--arg', 'tt', $TOGGLE_TYPES)

$enableAIStr   = if ($ENABLE_AI)    { 'true' } else { 'false' }
$enableLAWStr  = if ($ENABLE_LAW)   { 'true' } else { 'false' }
$enableAzMonStr = if ($ENABLE_AZMON) { 'true' } else { 'false' }

$CONNECTORS_ARRAY | Invoke-Jq -Filter '{
        "toggles": {
            "enableAppInsightsConnector": ($enableAI | test("true")),
            "appInsightsResourceId": $aiResId,
            "appInsightsAppId": $aiAppId,
            "enableLogAnalyticsConnector": ($enableLAW | test("true")),
            "lawResourceId": $lawResId,
            "enableAzureMonitorConnector": ($enableAzMon | test("true")),
            "azureMonitorLookbackDays": ($azMonLookback | tonumber)
        },
        "connectors": .
    }' -ExtraArgs @('--arg', 'enableAI', $enableAIStr, '--arg', 'aiResId', $AI_RESOURCE_ID, '--arg', 'aiAppId', $AI_APP_ID, '--arg', 'enableLAW', $enableLAWStr, '--arg', 'lawResId', $LAW_RESOURCE_ID, '--arg', 'enableAzMon', $enableAzMonStr, '--arg', 'azMonLookback', "$AZMON_LOOKBACK") | Set-Content -Path (Join-Path $EXPORT_DIR 'connectors.json') -Encoding utf8

$CONN_COUNT = ($CONNECTORS_ARRAY | jq 'length') -as [int]
_log "Wrote connectors.json (${CONN_COUNT} connector(s) + toggles)"

$secretLines | Set-Content -Path $SECRETS_ENV -Encoding utf8
_log 'Wrote connectors.secrets.env (secrets extracted — DO NOT commit)'

# ── Admin settings ──
$ADMIN_USERS = $AGENT_JSON | Invoke-Jq -Compact -Filter '.properties.adminUsers // []'
if (-not $ADMIN_USERS) { $ADMIN_USERS = '[]' }
$adminCount = ($ADMIN_USERS | jq 'length') -as [int]
if ($adminCount -gt 0) {
    $adminTmpFile = [System.IO.Path]::GetTempFileName()
    $ADMIN_USERS | Set-Content -Path $adminTmpFile -Encoding utf8 -NoNewline
    Invoke-Jq -Filter 'null | {
        "_description": "Cross-tenant admin users for portal access.",
        "adminUsers": $adminUsers[0]
    }' -ExtraArgs @('--slurpfile', 'adminUsers', $adminTmpFile) | Set-Content -Path (Join-Path $EXPORT_DIR 'admin-settings.json') -Encoding utf8
    Remove-Item $adminTmpFile -Force -ErrorAction SilentlyContinue
    _log "Wrote admin-settings.json (${adminCount} admin user(s))"
}

# ── .gitignore ──
@'
# Secrets — never commit
connectors.secrets.env
*.secrets.env

# Downloaded data (can be large)
data/
'@ | Set-Content -Path (Join-Path $EXPORT_DIR '.gitignore') -Encoding utf8
_log 'Wrote .gitignore'

# ═══════ expected-config.json ═══════

_log 'Generating expected-config.json'

$EXPECTED_CONNECTORS = '[]'
if ($ENABLE_LAW)   { $EXPECTED_CONNECTORS = $EXPECTED_CONNECTORS | Invoke-Jq -Filter '. + [{"name":"log-analytics","type":"LogAnalytics"}]' }
if ($ENABLE_AI)    { $EXPECTED_CONNECTORS = $EXPECTED_CONNECTORS | Invoke-Jq -Filter '. + [{"name":"app-insights","type":"AppInsights"}]' }
if ($ENABLE_AZMON)  { $EXPECTED_CONNECTORS = $EXPECTED_CONNECTORS | Invoke-Jq -Filter '. + [{"name":"azure-monitor","type":"AzureMonitor"}]' }

$connArrayCount = ($CONNECTORS_ARRAY | jq 'length') -as [int]
for ($i = 0; $i -lt $connArrayCount; $i++) {
    $cname = $CONNECTORS_ARRAY | jq -r --argjson i $i '.[$i].name'
    $ctype = $CONNECTORS_ARRAY | jq -r --argjson i $i '.[$i].properties.dataConnectorType'
    if (-not $cname -or $cname -eq 'null') { continue }
    $EXPECTED_CONNECTORS = $EXPECTED_CONNECTORS | Invoke-Jq -Filter '. + [{"name":$n,"type":$t}]' -ExtraArgs @('--arg', 'n', $cname, '--arg', 't', $ctype)
}

$INC_PLATFORM = ($INCIDENT_PLATFORMS | Invoke-Jq -Raw -Filter '.[0].spec.platformType // "None"')
if (-not $INC_PLATFORM) { $INC_PLATFORM = 'None' }

$EXPECTED_PLANS = $INCIDENT_FILTERS | Invoke-Jq -Compact -Filter '[.[] | {name: (.metadata.name // .name), handlingAgent: (.spec.handlingAgent // .handlingAgent // "")}]'
if (-not $EXPECTED_PLANS) { $EXPECTED_PLANS = '[]' }

$skillNames   = $SKILLS | jq -c '[.[].metadata.name]' 2>$null
if (-not $skillNames) { $skillNames = '[]' }
$saNames      = $SUBAGENTS | jq -c '[.[].metadata.name]' 2>$null
if (-not $saNames) { $saNames = '[]' }
$hookNames    = @($HOOKS_FOR_EXTRAS, $HOOKS_FOR_PARAMS) -join "`n" | Invoke-Jq -Slurp -Compact -Filter 'add // [] | [.[] | .name // .metadata.name] | unique'
if (-not $hookNames) { $hookNames = '[]' }
$promptNames  = @($PROMPTS_FOR_EXTRAS, $PROMPTS_FOR_PARAMS) -join "`n" | Invoke-Jq -Slurp -Compact -Filter 'add // [] | [.[] | .name // .metadata.name] | unique'
if (-not $promptNames) { $promptNames = '[]' }
$taskNames    = $SCHEDULED_TASKS | Invoke-Jq -Compact -Filter '[.[] | .metadata.name // .name]'
if (-not $taskNames) { $taskNames = '[]' }
$repoNames    = $REPOS | jq -c '[.[].name]' 2>$null
if (-not $repoNames) { $repoNames = '[]' }

# Build expected-config via slurpfiles for all JSON arrays
$ecTmpDir = Join-Path ([System.IO.Path]::GetTempPath()) "export-ec-$(Get-Random)"
New-Item -ItemType Directory -Path $ecTmpDir -Force | Out-Null
$EXPECTED_CONNECTORS | Set-Content -Path (Join-Path $ecTmpDir 'conn.json') -Encoding utf8 -NoNewline
$skillNames | Set-Content -Path (Join-Path $ecTmpDir 'skills.json') -Encoding utf8 -NoNewline
$saNames | Set-Content -Path (Join-Path $ecTmpDir 'sa.json') -Encoding utf8 -NoNewline
$hookNames | Set-Content -Path (Join-Path $ecTmpDir 'hooks.json') -Encoding utf8 -NoNewline
$promptNames | Set-Content -Path (Join-Path $ecTmpDir 'prompts.json') -Encoding utf8 -NoNewline
$taskNames | Set-Content -Path (Join-Path $ecTmpDir 'tasks.json') -Encoding utf8 -NoNewline
$EXPECTED_PLANS | Set-Content -Path (Join-Path $ecTmpDir 'plans.json') -Encoding utf8 -NoNewline
$repoNames | Set-Content -Path (Join-Path $ecTmpDir 'repos.json') -Encoding utf8 -NoNewline

Invoke-Jq -Filter '{
        "_scenario": $scenario,
        "agent": {
            "accessLevel": $accessLevel,
            "actionMode": $actionMode,
            "upgradeChannel": $upgradeChannel,
            "defaultModelProvider": $modelProvider,
            "incidentPlatform": $incidentPlatform
        },
        "connectors": $connectors[0],
        "skills": $skills[0],
        "subagents": $subagents[0],
        "hooks": $hooks[0],
        "commonPrompts": $prompts[0],
        "scheduledTasks": $tasks[0],
        "responsePlans": $plans[0],
        "repos": $repos[0]
    }' -ExtraArgs @(
        '--arg', 'scenario', 'exported',
        '--arg', 'accessLevel', $ACCESS_LEVEL,
        '--arg', 'actionMode', $ACTION_MODE,
        '--arg', 'upgradeChannel', $UPGRADE_CHANNEL,
        '--arg', 'modelProvider', $DEFAULT_MODEL_PROVIDER,
        '--arg', 'incidentPlatform', $INC_PLATFORM,
        '--slurpfile', 'connectors', (Join-Path $ecTmpDir 'conn.json'),
        '--slurpfile', 'skills', (Join-Path $ecTmpDir 'skills.json'),
        '--slurpfile', 'subagents', (Join-Path $ecTmpDir 'sa.json'),
        '--slurpfile', 'hooks', (Join-Path $ecTmpDir 'hooks.json'),
        '--slurpfile', 'prompts', (Join-Path $ecTmpDir 'prompts.json'),
        '--slurpfile', 'tasks', (Join-Path $ecTmpDir 'tasks.json'),
        '--slurpfile', 'plans', (Join-Path $ecTmpDir 'plans.json'),
        '--slurpfile', 'repos', (Join-Path $ecTmpDir 'repos.json')
    ) | Set-Content -Path (Join-Path $EXPORT_DIR 'expected-config.json') -Encoding utf8
Remove-Item $ecTmpDir -Recurse -Force -ErrorAction SilentlyContinue

_log 'Wrote expected-config.json'

# ═══════ 3. config/ — YAML files ═══════

_info 'Writing config/ files (YAML)'

# ── Skills ──
$SKILL_COUNT_EXP = 0
$skillTotal = ($SKILLS | jq 'length') -as [int]
if ($skillTotal -gt 0) {
    for ($i = 0; $i -lt $skillTotal; $i++) {
        $sname = $SKILLS | jq -r --argjson i $i '.[$i].metadata.name'
        $skillDir = Join-Path $EXPORT_DIR 'config/skills'
        if (-not (Test-Path $skillDir)) { New-Item -ItemType Directory -Path $skillDir -Force | Out-Null }
        $SKILL_COUNT_EXP++

        # Write skillContent to .md
        $scontent = $SKILLS | Invoke-Jq -Raw -Filter '.[$i].skillContent // ""' -ExtraArgs @('--argjson', 'i', "$i")
        if ($scontent) {
            [System.IO.File]::WriteAllText((Join-Path $skillDir "${sname}.md"), $scontent)
        }

        # Write additionalFiles
        $afCount = ($SKILLS | Invoke-Jq -Filter '.[$i].additionalFiles // [] | length' -ExtraArgs @('--argjson', 'i', "$i")) -as [int]
        if ($afCount -gt 0) {
            $afDir = Join-Path $skillDir $sname
            if (-not (Test-Path $afDir)) { New-Item -ItemType Directory -Path $afDir -Force | Out-Null }
            for ($j = 0; $j -lt $afCount; $j++) {
                $afname = $SKILLS | Invoke-Jq -Raw -Filter '.[$i].additionalFiles[$j].name // .[$i].additionalFiles[$j].path // "file-\($j)"' -ExtraArgs @('--argjson', 'i', "$i", '--argjson', 'j', "$j")
                $afcontent = $SKILLS | Invoke-Jq -Raw -Filter '.[$i].additionalFiles[$j].content // ""' -ExtraArgs @('--argjson', 'i', "$i", '--argjson', 'j', "$j")
                [System.IO.File]::WriteAllText((Join-Path $afDir $afname), $afcontent)
            }
        }

        # Write YAML with file reference for skillContent
        $skillYaml = $SKILLS | Invoke-Jq -Filter '.[$i] |
            .skillContent = ("skills/" + .metadata.name + ".md") |
            if (.additionalFiles | length) > 0 then
                .additionalFiles = [.additionalFiles[] | .content = (.metadata.name + "/" + (.name // .path // "file"))]
            else . end' -ExtraArgs @('--argjson', 'i', "$i")
        $skillYaml | ConvertTo-Yaml | Set-Content -Path (Join-Path $skillDir "${sname}.yaml") -NoNewline -Encoding utf8
    }
    _log "  skills: ${SKILL_COUNT_EXP} file(s)"
}

# ── Subagents ──
$SA_COUNT_EXP = 0
$saTotal = ($SUBAGENTS | jq 'length') -as [int]
if ($saTotal -gt 0) {
    for ($i = 0; $i -lt $saTotal; $i++) {
        $saname = $SUBAGENTS | jq -r --argjson i $i '.[$i].metadata.name'
        $saDir = Join-Path $EXPORT_DIR 'config/subagents'
        if (-not (Test-Path $saDir)) { New-Item -ItemType Directory -Path $saDir -Force | Out-Null }
        $SA_COUNT_EXP++

        $instructions = $SUBAGENTS | Invoke-Jq -Raw -Filter '.[$i].spec.instructions // ""' -ExtraArgs @('--argjson', 'i', "$i")
        if ($instructions) {
            [System.IO.File]::WriteAllText((Join-Path $saDir "${saname}.instructions.md"), $instructions)
        }
        $handoff = $SUBAGENTS | Invoke-Jq -Raw -Filter '.[$i].spec.handoffDescription // ""' -ExtraArgs @('--argjson', 'i', "$i")
        if ($handoff -and $handoff.Length -gt 200) {
            [System.IO.File]::WriteAllText((Join-Path $saDir "${saname}.handoff.md"), $handoff)
        }

        $saYaml = $SUBAGENTS | Invoke-Jq -Filter '.[$i] |
            if (.spec.instructions // "" | length) > 0 then
                .spec.instructions = ("subagents/" + .metadata.name + ".instructions.md")
            else . end |
            if (.spec.handoffDescription // "" | length) > 200 then
                .spec.handoffDescription = (.metadata.name + ".handoff.md")
            else . end' -ExtraArgs @('--argjson', 'i', "$i")
        $saYaml | ConvertTo-Yaml | Set-Content -Path (Join-Path $saDir "${saname}.yaml") -NoNewline -Encoding utf8
    }
    _log "  subagents: ${SA_COUNT_EXP} file(s)"
}

# ── Tools ──
$T_COUNT_EXP = 0
$toolTotal = ($TOOLS | jq 'length') -as [int]
if ($toolTotal -gt 0) {
    for ($i = 0; $i -lt $toolTotal; $i++) {
        $tname = $TOOLS | jq -r --argjson i $i '.[$i].metadata.name'
        $toolDir = Join-Path $EXPORT_DIR 'config/tools'
        if (-not (Test-Path $toolDir)) { New-Item -ItemType Directory -Path $toolDir -Force | Out-Null }
        $T_COUNT_EXP++
        $toolJson = $TOOLS | jq --argjson i $i '.[$i]'
        Write-Yaml -Dest (Join-Path $toolDir "${tname}.yaml") -Json $toolJson
    }
    _log "  tools: ${T_COUNT_EXP} file(s)"
}

# ── Hooks ──
$ALL_HOOKS = @($HOOKS_FOR_PARAMS, $HOOKS_FOR_EXTRAS) -join "`n" | Invoke-Jq -Slurp -Compact -Filter 'add // []'
$allHookCount = ($ALL_HOOKS | jq 'length') -as [int]
if ($allHookCount -gt 0) {
    $hookDir = Join-Path $EXPORT_DIR 'config/hooks'
    if (-not (Test-Path $hookDir)) { New-Item -ItemType Directory -Path $hookDir -Force | Out-Null }
    for ($i = 0; $i -lt $allHookCount; $i++) {
        $hname = $ALL_HOOKS | Invoke-Jq -Raw -Filter '.[$i].metadata.name // .[$i].name' -ExtraArgs @('--argjson', 'i', "$i")
        $hookJson = $ALL_HOOKS | jq --argjson i $i '.[$i]'
        $hookJson | ConvertTo-Yaml | Set-Content -Path (Join-Path $hookDir "${hname}.yaml") -NoNewline -Encoding utf8
    }
    _log "  hooks: ${allHookCount} hook(s)"
}

# ── Common Prompts ──
$ALL_PROMPTS = @($PROMPTS_FOR_PARAMS, $PROMPTS_FOR_EXTRAS) -join "`n" | Invoke-Jq -Slurp -Compact -Filter 'add // []'
$allPromptCount = ($ALL_PROMPTS | jq 'length') -as [int]
if ($allPromptCount -gt 0) {
    $promptDir = Join-Path $EXPORT_DIR 'config/common-prompts'
    if (-not (Test-Path $promptDir)) { New-Item -ItemType Directory -Path $promptDir -Force | Out-Null }
    for ($i = 0; $i -lt $allPromptCount; $i++) {
        $pname = $ALL_PROMPTS | Invoke-Jq -Raw -Filter '.[$i].metadata.name // .[$i].name' -ExtraArgs @('--argjson', 'i', "$i")
        $promptText = $ALL_PROMPTS | Invoke-Jq -Raw -Filter '.[$i].spec.prompt // .[$i].properties.content // .[$i].properties.prompt // ""' -ExtraArgs @('--argjson', 'i', "$i")
        if ($promptText) {
            [System.IO.File]::WriteAllText((Join-Path $promptDir "${pname}.md"), $promptText)
        }
        $promptJson = $ALL_PROMPTS | jq --argjson i $i '.[$i]'
        $promptJson | ConvertTo-Yaml | Set-Content -Path (Join-Path $promptDir "${pname}.yaml") -NoNewline -Encoding utf8
    }
    _log "  common-prompts: ${allPromptCount} prompt(s)"
}

# ── Scheduled Tasks ──
Write-ConfigItems -Dir 'scheduled-tasks' -ItemsJson $SCHEDULED_TASKS -NamePath '.metadata.name' -Base 'automations'

# ── Incident Filters ──
Write-ConfigItems -Dir 'incident-filters' -ItemsJson $INCIDENT_FILTERS -NamePath '.metadata.name' -Base 'automations'

# ── HTTP Triggers ──
$httpCount = ($HTTP_TRIGGERS | jq 'length') -as [int]
if ($httpCount -gt 0) {
    $htDir = Join-Path $EXPORT_DIR 'automations/http-triggers'
    if (-not (Test-Path $htDir)) { New-Item -ItemType Directory -Path $htDir -Force | Out-Null }
    for ($i = 0; $i -lt $httpCount; $i++) {
        $tname = $HTTP_TRIGGERS | jq -r --argjson i $i '.[$i].name'
        $trigJson = $HTTP_TRIGGERS | jq --argjson i $i '.[$i]'
        $trigJson | ConvertTo-Yaml | Set-Content -Path (Join-Path $htDir "${tname}.yaml") -NoNewline -Encoding utf8
    }
    _log "  http-triggers: ${httpCount} trigger(s)"
}

# ── Plugin Configs ──
$ALL_PLUGINS = @($PLUGINS_FOR_PARAMS, $PLUGINS_FOR_EXTRAS) -join "`n" | Invoke-Jq -Slurp -Compact -Filter 'add // []'
Write-ConfigItems -Dir 'plugin-configs' -ItemsJson $ALL_PLUGINS -NamePath '.metadata.name // .name'

# ── Incident Platforms ──
$ipCount = ($INCIDENT_PLATFORMS | jq 'length') -as [int]
if ($ipCount -gt 0) {
    $ipDir = Join-Path $EXPORT_DIR 'automations/incident-platforms'
    if (-not (Test-Path $ipDir)) { New-Item -ItemType Directory -Path $ipDir -Force | Out-Null }
    for ($i = 0; $i -lt $ipCount; $i++) {
        $ipname = $INCIDENT_PLATFORMS | jq -r --argjson i $i '.[$i].name'
        $ipJson = $INCIDENT_PLATFORMS | jq --argjson i $i '.[$i]'
        $ipJson | ConvertTo-Yaml | Set-Content -Path (Join-Path $ipDir "${ipname}.yaml") -NoNewline -Encoding utf8

        # Check if platform needs connectionKey placeholder
        $ptype = $INCIDENT_PLATFORMS | Invoke-Jq -Raw -Filter '.[$i].spec.platformType // .[$i].spec.incidentPlatform // ""' -ExtraArgs @('--argjson', 'i', "$i")
        if ($ptype -in @('PagerDuty', 'ServiceNow')) {
            $yamlPath = Join-Path $ipDir "${ipname}.yaml"
            $hasKey = python3 -c @"
import yaml
d = yaml.safe_load(open('$yamlPath'))
print('yes' if d.get('spec',{}).get('connectionKey') else 'no')
"@ 2>$null
            if ($hasKey -ne 'yes') {
                $envVar = "$($ptype.ToUpper())_API_KEY"
                python3 -c @"
import yaml
f = '$yamlPath'
with open(f) as fh: d = yaml.safe_load(fh)
d.setdefault('spec',{})['connectionKey'] = '`${$envVar}'
with open(f,'w') as fh: yaml.dump(d, fh, default_flow_style=False, sort_keys=False)
"@ 2>$null
                $secretLines += @('', "# ${ptype} API key — required for incident platform", "${envVar}=")
                # Re-write secrets env with the new lines
                $secretLines | Set-Content -Path $SECRETS_ENV -Encoding utf8
                _warn "${ptype} connectionKey is redacted by API."
                _warn "  Set ${envVar} in ${EXPORT_DIR}/connectors.secrets.env before deploy."
            }
        }
    }
    _log "  incident-platforms: ${ipCount} platform(s)"
}

# ── Repos ──
$repoTotal = ($REPOS | jq 'length') -as [int]
if ($repoTotal -gt 0) {
    $repoDir = Join-Path $EXPORT_DIR 'config/repos'
    if (-not (Test-Path $repoDir)) { New-Item -ItemType Directory -Path $repoDir -Force | Out-Null }
    for ($i = 0; $i -lt $repoTotal; $i++) {
        $rname = $REPOS | jq -r --argjson i $i '.[$i].name'
        $repoJson = $REPOS | jq --argjson i $i '.[$i]'
        $repoJson | ConvertTo-Yaml | Set-Content -Path (Join-Path $repoDir "${rname}.yaml") -NoNewline -Encoding utf8
    }
    _log "  repos: ${repoTotal} repo(s)"
}

# ── Plugin Marketplaces + Installations ──
$mpCount = ($PLUGIN_MARKETPLACES | jq 'length') -as [int]
if ($mpCount -gt 0) {
    $mpDir = Join-Path $EXPORT_DIR 'config/plugins/marketplaces'
    if (-not (Test-Path $mpDir)) { New-Item -ItemType Directory -Path $mpDir -Force | Out-Null }
    for ($i = 0; $i -lt $mpCount; $i++) {
        $mname = $PLUGIN_MARKETPLACES | jq -r --argjson i $i '.[$i].name'
        $mpJson = $PLUGIN_MARKETPLACES | jq --argjson i $i '.[$i]'
        $mpJson | ConvertTo-Yaml | Set-Content -Path (Join-Path $mpDir "${mname}.yaml") -NoNewline -Encoding utf8
    }
}
$piCount = ($PLUGIN_INSTALLATIONS | jq 'length') -as [int]
if ($piCount -gt 0) {
    $piDir = Join-Path $EXPORT_DIR 'config/plugins/installations'
    if (-not (Test-Path $piDir)) { New-Item -ItemType Directory -Path $piDir -Force | Out-Null }
    for ($i = 0; $i -lt $piCount; $i++) {
        $iname = $PLUGIN_INSTALLATIONS | jq -r --argjson i $i '.[$i].name'
        $piJson = $PLUGIN_INSTALLATIONS | jq --argjson i $i '.[$i]'
        $piJson | ConvertTo-Yaml | Set-Content -Path (Join-Path $piDir "${iname}.yaml") -NoNewline -Encoding utf8
    }
}

# ═══════ 4. data/ — knowledge, memories, repo instructions ═══════

_info 'Writing data/ files'

$DATA_DIR = Join-Path $EXPORT_DIR 'data'
foreach ($subDir in @('knowledge', 'synthesized-knowledge')) {
    $p = Join-Path $DATA_DIR $subDir
    if (-not (Test-Path $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
    $gitkeep = Join-Path $p '.gitkeep'
    if (-not (Test-Path $gitkeep)) { '' | Set-Content $gitkeep }
}

$knowledgeCount = ($KNOWLEDGE | jq 'length') -as [int]
if ($knowledgeCount -gt 0) {
    $KNOWLEDGE | jq '.' | Set-Content -Path (Join-Path $DATA_DIR 'knowledge.json') -Encoding utf8
    _log "  knowledge.json: ${knowledgeCount} document(s)"
}

$kiTotal = ($KNOWLEDGE_ITEMS | jq 'length') -as [int]
if ($kiTotal -gt 0) {
    $KNOWLEDGE_ITEMS | jq '.' | Set-Content -Path (Join-Path $DATA_DIR 'knowledge-items.json') -Encoding utf8
    _log "  knowledge-items.json: ${kiTotal} item(s)"
}

$synthTotal = ($SYNTHESIZED_KNOWLEDGE | jq 'length') -as [int]
if ($synthTotal -gt 0) {
    $SYNTHESIZED_KNOWLEDGE | jq '.' | Set-Content -Path (Join-Path $DATA_DIR 'synthesized-knowledge.json') -Encoding utf8
    _log "  synthesized-knowledge.json: ${synthTotal} file(s)"
}

$riTotal = ($REPO_INSTRUCTIONS | jq 'length') -as [int]
if ($riTotal -gt 0) {
    $REPO_INSTRUCTIONS | jq '.' | Set-Content -Path (Join-Path $DATA_DIR 'repo-instructions.json') -Encoding utf8
    _log "  repo-instructions.json: ${riTotal} set(s)"
}

# Move downloaded files into data/
if ($DOWNLOAD_FILES -and (Test-Path $FILES_DIR)) {
    foreach ($subdir in @('knowledge', 'knowledge-items', 'synthesized-knowledge', 'repo-instructions')) {
        $srcDir = Join-Path $FILES_DIR $subdir
        if (Test-Path $srcDir) {
            $destDir = Join-Path $DATA_DIR $subdir
            if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
            Copy-Item -Path (Join-Path $srcDir '*') -Destination $destDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    if ($FILES_DIR -ne $DATA_DIR -and $FILES_DIR -ne (Join-Path $EXPORT_DIR 'data')) {
        Remove-Item $FILES_DIR -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ''

# ═══════ Final summary ═══════

_info 'Export complete'
Write-Host ''
Write-Host "  ${EXPORT_DIR}/"
Write-Host '    agent.json               <- Agent identity + settings'
Write-Host '    connectors.json          <- Connector toggles + entries (secrets -> env var refs)'
Write-Host '    connectors.secrets.env   <- Actual secrets (gitignored)'
Write-Host '    config/'
foreach ($d in @('skills', 'subagents', 'tools', 'hooks', 'common-prompts', 'plugin-configs', 'repos')) {
    $dPath = Join-Path $EXPORT_DIR "config/$d"
    if (Test-Path $dPath) {
        $yamlCount = (Get-ChildItem -Path $dPath -Filter '*.yaml' -File -ErrorAction SilentlyContinue | Measure-Object).Count
        Write-Host ("      {0,-24} <- {1} file(s)" -f "${d}/", $yamlCount)
    }
}
$autoDir = Join-Path $EXPORT_DIR 'automations'
if (Test-Path $autoDir) {
    Write-Host '    automations/'
    foreach ($d in @('scheduled-tasks', 'incident-filters', 'http-triggers', 'incident-platforms')) {
        $dPath = Join-Path $autoDir $d
        if (Test-Path $dPath) {
            $yamlCount = (Get-ChildItem -Path $dPath -Filter '*.yaml' -File -ErrorAction SilentlyContinue | Measure-Object).Count
            Write-Host ("      {0,-24} <- {1} file(s)" -f "${d}/", $yamlCount)
        }
    }
}
if (Test-Path $DATA_DIR) {
    Write-Host '    data/                    <- Knowledge, memories, repo instructions'
}
if (Test-Path (Join-Path $EXPORT_DIR 'admin-settings.json')) {
    Write-Host '    admin-settings.json      <- Cross-tenant admin users'
}
Write-Host ''
Write-Host 'Next steps:'
Write-Host '  1. Review agent.json - change identity.agentName, identity.resourceGroup, identity.location'
Write-Host '  2. Update connectors.json - change resource IDs for target environment'
Write-Host '  3. Fill connectors.secrets.env with real tokens for the target'
Write-Host '  4. Edit config/ YAML files - skills, subagents, tools, hooks as needed'
Write-Host '  Deploy with:'
Write-Host "    .\Deploy-Agent.ps1 -InputPath ${EXPORT_DIR}"
Write-Host ''
