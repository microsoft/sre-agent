#!/usr/bin/env bash
# export-agent.sh — Extract full SRE Agent configuration into deploy-ready files.
#
# Reads every ARM child resource + data-plane config and emits:
#   <output-prefix>.parameters.json  — Bicep-deployable (agent core + connectors/tools/skills/etc.)
#   <output-prefix>.extras.json      — Data-plane config (hooks/repos/prompts/knowledge/plugins/etc.)
#
# These files slot directly into deploy.sh + apply-extras.sh for cloning.
#
# Usage:
#   ./export-agent.sh --subscription <sub> --resource-group <rg> --agent-name <name> [--output <prefix>]
#   ./export-agent.sh -s <sub> -g <rg> -n <name> [-o <prefix>]
#
# Prerequisites:
#   - az CLI logged in with access to the agent's subscription
#   - jq installed
#   - Agent must be provisioned and reachable
#
# Integrates with future `sre agent export` CLI command — same flags, same output format.

set -euo pipefail

# ─────────────────────────── Argument parsing ───────────────────────────
usage() {
  cat <<EOF
Usage: $0 --subscription <sub> --resource-group <rg> --agent-name <name> [options]

Required:
  -s, --subscription     Subscription ID
  -g, --resource-group   Resource group containing the agent
  -n, --agent-name       Agent name

Options:
  -o, --output           Output directory (default: <agent-name>-export)
  --set key=value        Override identity fields (agentName, resourceGroup, location)
                         Use for cloning: --set agentName=my-clone --set location=uksouth
  --include-repo-instructions  Export repo instruction files (large, off by default)
  --no-knowledge         Skip knowledge documents
  --no-memories          Skip synthesized knowledge and workspace memories
  --no-download          Skip downloading file content (metadata only)
  --include-all          Enable all --include-* flags
  --include-knowledge-items  Export knowledge items (KnowledgeText/File/WebPage)
  --include-repo-instructions  Export repo instruction files
  --include-memories     Export synthesized knowledge and workspace memories
  --include-all          Enable all --include-* flags
  --download-files       Download actual file content (not just metadata)
  --dry-run              Show what would be exported, don't write files
  -h, --help             Show this help
EOF
  exit "${1:-0}"
}

SUB="" RG="" AGENT="" OUTPUT="" DRY_RUN=false
INCLUDE_KNOWLEDGE=true INCLUDE_KNOWLEDGE_ITEMS=true
INCLUDE_REPO_INSTRUCTIONS=false INCLUDE_MEMORIES=true
DOWNLOAD_FILES=true
declare -a SET_OVERRIDES=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -s|--subscription)     SUB="$2"; shift 2 ;;
    -g|--resource-group)   RG="$2"; shift 2 ;;
    -n|--agent-name)       AGENT="$2"; shift 2 ;;
    -o|--output)           OUTPUT="$2"; shift 2 ;;
    --set)                 SET_OVERRIDES+=("$2"); shift 2 ;;
    --include-knowledge)   INCLUDE_KNOWLEDGE=true; shift ;;
    --include-knowledge-items) INCLUDE_KNOWLEDGE_ITEMS=true; shift ;;
    --include-repo-instructions) INCLUDE_REPO_INSTRUCTIONS=true; shift ;;
    --include-memories)    INCLUDE_MEMORIES=true; shift ;;
    --include-all)         INCLUDE_KNOWLEDGE=true; INCLUDE_KNOWLEDGE_ITEMS=true
                           INCLUDE_REPO_INSTRUCTIONS=true; INCLUDE_MEMORIES=true; shift ;;
    --no-knowledge)        INCLUDE_KNOWLEDGE=false; INCLUDE_KNOWLEDGE_ITEMS=false; shift ;;
    --no-memories)         INCLUDE_MEMORIES=false; shift ;;
    --no-download)         DOWNLOAD_FILES=false; shift ;;
    --download-files)      DOWNLOAD_FILES=true; shift ;;
    --dry-run)             DRY_RUN=true; shift ;;
    -h|--help)             usage 0 ;;
    *)                     echo "Unknown option: $1" >&2; usage 1 ;;
  esac
done

[[ -n "$SUB" ]]   || { echo "Error: --subscription is required" >&2; usage 1; }
[[ -n "$RG" ]]    || { echo "Error: --resource-group is required" >&2; usage 1; }
[[ -n "$AGENT" ]] || { echo "Error: --agent-name is required" >&2; usage 1; }
[[ -n "$OUTPUT" ]] || OUTPUT="${AGENT}-export"

command -v jq >/dev/null || { echo "Error: jq is required" >&2; exit 1; }
command -v az >/dev/null || { echo "Error: az CLI is required" >&2; exit 1; }

API_VERSION="2025-05-01-preview"
ARM_BASE="https://management.azure.com/subscriptions/${SUB}/resourceGroups/${RG}/providers/Microsoft.App/agents/${AGENT}"

# ─────────────────────────── Helpers ───────────────────────────

_log()  { echo "  $*"; }
_info() { echo "── $* ──"; }
_warn() { echo "  WARN: $*" >&2; }
_fail() { echo "  ERROR: $*" >&2; exit 1; }

# JSON → YAML conversion (for human-editable config files)
json2yaml() {
  python3 -c "
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
"
}

# Write a JSON value as a YAML file
write_yaml() {
  local dest="$1" json="$2"
  echo "$json" | json2yaml > "$dest"
}

# ARM GET with error handling
arm_get() {
  local url="$1"
  az rest -m GET --url "${url}?api-version=${API_VERSION}" -o json 2>/dev/null || echo "null"
}

# ARM LIST child resources (returns .value array or empty array)
arm_list() {
  local child_type="$1"
  local url="${ARM_BASE}/${child_type}?api-version=${API_VERSION}"
  local result
  result=$(az rest -m GET --url "$url" -o json 2>/dev/null || echo '{"value":[]}')
  echo "$result" | jq -c '.value // []'
}

# Data-plane GET with bearer token
_dp_token_cache=""
_dp_token() {
  if [[ -z "$_dp_token_cache" ]]; then
    _dp_token_cache=$(az account get-access-token --resource https://azuresre.dev --query accessToken -o tsv 2>/dev/null) \
      || _fail "Could not get data-plane token (audience https://azuresre.dev)"
  fi
  echo "$_dp_token_cache"
}

dp_get() {
  local path="$1"
  local token
  token=$(_dp_token)
  curl -sS -f --max-time 10 -H "Authorization: Bearer ${token}" "${AGENT_ENDPOINT}${path}" 2>/dev/null || echo "null"
}

# Download a file from data-plane to local path
dp_download() {
  local path="$1" dest="$2"
  local token
  token=$(_dp_token)
  mkdir -p "$(dirname "$dest")"
  curl -sS -f -H "Authorization: Bearer ${token}" \
    -o "$dest" "${AGENT_ENDPOINT}${path}" 2>/dev/null
}

# Download a tar.gz from data-plane and extract to local dir
dp_download_tarball() {
  local path="$1" dest_dir="$2" label="$3"
  local token tmpfile
  token=$(_dp_token)
  tmpfile=$(mktemp -t export.XXXXXX.tar.gz)
  if curl -sS -f -H "Authorization: Bearer ${token}" \
    -o "$tmpfile" "${AGENT_ENDPOINT}${path}" 2>/dev/null; then
    mkdir -p "$dest_dir"
    tar -xzf "$tmpfile" -C "$dest_dir" 2>/dev/null || true
    local count
    count=$(find "$dest_dir" -type f | wc -l | tr -d ' ')
    _log "  Downloaded ${label}: ${count} file(s) → ${dest_dir}"
  else
    _log "  WARN: Could not download ${label}"
  fi
  rm -f "$tmpfile"
}

# Decode base64 opaque ARM sub-resources → spec JSON
# Output shape: { metadata: { name }, spec: { ...decoded... } }
decode_opaque() {
  local raw="$1"
  echo "$raw" | jq -c '[.[] | {
    metadata: { name: (.name | split("/") | last) },
    spec: (
      (.properties.value // "") |
      if . == "" then {} else (. | @base64d | fromjson) end
    )
  }]'
}

# Decode skills — special shape to match Bicep input format.
# Stored base64: { name, description, tools, skillContent, additionalFiles }
# Bicep input:   { metadata: { name, description, spec: { tools } }, skillContent, additionalFiles }
decode_skills() {
  local raw="$1"
  echo "$raw" | jq -c '[.[] | {
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

# Sanitize secrets — replace known secret patterns with EDIT_ME placeholders
sanitize() {
  local json="$1"
  echo "$json" | jq '
    walk(
      if type == "string" then
        # GitHub PATs
        (if test("^ghp_[A-Za-z0-9_]+$") then "EDIT_ME_GITHUB_PAT"
        # Bearer tokens
        elif test("^Bearer ") then "EDIT_ME_BEARER_TOKEN"
        # Generic long base64-ish secrets (>40 chars, no spaces, no slashes from resource IDs)
        elif (test("^[A-Za-z0-9+/=]{40,}$") and (test("^/subscriptions/") | not)) then "EDIT_ME_SECRET"
        # BearerToken= in connection strings
        elif test("BearerToken=[^;]+") then gsub("BearerToken=[^;]+"; "BearerToken=EDIT_ME_TOKEN")
        # accessToken fields
        elif test("accessToken") then "EDIT_ME_ACCESS_TOKEN"
        else . end)
      else . end
    )'
}

# ─────────────────────── Phase 1: ARM — agent core ───────────────────────
_info "Connecting to agent ${AGENT} in ${RG}"

AGENT_JSON=$(arm_get "$ARM_BASE")
[[ "$AGENT_JSON" != "null" ]] || _fail "Agent ${AGENT} not found in ${RG} (subscription: ${SUB})"

AGENT_ENDPOINT=$(echo "$AGENT_JSON" | jq -r '.properties.agentEndpoint // empty')
[[ -n "$AGENT_ENDPOINT" ]] || _fail "Agent has no endpoint — may still be provisioning"

LOCATION=$(echo "$AGENT_JSON" | jq -r '.location // "eastus2"')
ACCESS_LEVEL=$(echo "$AGENT_JSON" | jq -r '.properties.actionConfiguration.accessLevel // .properties.accessLevel // "Low"')
ACTION_MODE=$(echo "$AGENT_JSON" | jq -r '.properties.actionConfiguration.mode // .properties.actionMode // "Review"')
UPGRADE_CHANNEL=$(echo "$AGENT_JSON" | jq -r '.properties.upgradeChannel // "Preview"')
DEFAULT_MODEL_PROVIDER=$(echo "$AGENT_JSON" | jq -r '.properties.defaultModelProvider // "Anthropic"')
AGENT_UAMI=$(echo "$AGENT_JSON" | jq -r '.identity.userAssignedIdentities // {} | keys[0] // ""')

_log "Location:       ${LOCATION}"
_log "Access level:   ${ACCESS_LEVEL}"
_log "Action mode:    ${ACTION_MODE}"
_log "Endpoint:       ${AGENT_ENDPOINT}"
[[ -n "$AGENT_UAMI" ]] && _log "UAMI:           ${AGENT_UAMI##*/}"

# Extract target resource groups from knowledgeGraphConfiguration.managedResources
# These are full ARM RG IDs: /subscriptions/.../resourceGroups/<name>
# Fall back to role assignment scopes if managedResources is empty
TARGET_RGS=$(echo "$AGENT_JSON" | jq -c '
  ([
    .properties.knowledgeGraphConfiguration.managedResources // [] | .[] |
    capture("/resourceGroups/(?<rg>[^/]+)") | .rg
  ] | unique) as $from_managed |
  if ($from_managed | length) > 0 then $from_managed
  else [
    .properties.managedResources // [] |
    .[] | select(.type == "Microsoft.Authorization/roleAssignments") |
    .scope // "" | capture("/resourceGroups/(?<rg>[^/]+)") | .rg
  ] | unique end
')

_log "Target RGs:     $(echo "$TARGET_RGS" | jq -r 'join(", ") // "<none>"')"

echo

# ─────────────────── Phase 2: ARM — child resources ───────────────────────

_info "Exporting ARM child resources"

# Connectors (typed — not opaque)
_log "Reading connectors..."
RAW_CONNECTORS=$(arm_list "connectors")
CONNECTOR_COUNT=$(echo "$RAW_CONNECTORS" | jq 'length')
_log "  Found ${CONNECTOR_COUNT} connector(s) from ARM"

# Also read connectors from data-plane (has full extendedProperties including secrets)
DP_CONNECTORS=$(dp_get "/api/v2/extendedAgent/connectors" | jq -c '.value // []' 2>/dev/null || echo '[]')
DP_COUNT=$(echo "$DP_CONNECTORS" | jq 'length')
_log "  Found ${DP_COUNT} connector(s) from data-plane"

# Normalize connectors — prefer data-plane for ALL connectors (ARM redacts secrets and nulls resource IDs)
CONNECTORS=$(echo "$RAW_CONNECTORS" | jq -c --argjson dp "$DP_CONNECTORS" '[.[] | 
  . as $arm |
  ($arm.name | split("/") | last) as $cname |
  ($arm.properties.dataConnectorType) as $ctype |
  # Try data-plane first (has full properties), fall back to ARM
  ([$dp[] | select(.name == $cname)] | first) as $dpconn |
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
]')
# Sanitize any embedded secrets in connector datasource strings
CONNECTORS=$(sanitize "$CONNECTORS")

# Tools (opaque — base64-encoded)
_log "Reading tools..."
RAW_TOOLS=$(arm_list "tools")
TOOL_COUNT=$(echo "$RAW_TOOLS" | jq 'length')
_log "  Found ${TOOL_COUNT} tool(s)"
TOOLS=$(decode_opaque "$RAW_TOOLS")

# Skills (opaque — special shape: Bicep encodes {name,description,tools,skillContent,additionalFiles})
_log "Reading skills..."
RAW_SKILLS=$(arm_list "skills")
SKILL_COUNT=$(echo "$RAW_SKILLS" | jq 'length')
_log "  Found ${SKILL_COUNT} skill(s)"
SKILLS=$(decode_skills "$RAW_SKILLS")

# Scheduled Tasks (opaque)
_log "Reading scheduled tasks..."
RAW_TASKS=$(arm_list "scheduledTasks")
TASK_COUNT=$(echo "$RAW_TASKS" | jq 'length')
_log "  Found ${TASK_COUNT} scheduled task(s)"
SCHEDULED_TASKS=$(decode_opaque "$RAW_TASKS")

# Incident Filters (opaque)
_log "Reading incident filters..."
RAW_FILTERS=$(arm_list "incidentFilters")
FILTER_COUNT=$(echo "$RAW_FILTERS" | jq 'length')
_log "  Found ${FILTER_COUNT} incident filter(s)"
INCIDENT_FILTERS=$(decode_opaque "$RAW_FILTERS")

# Incident Handlers — data-plane (customInstructions lives here, not on the filter)
_log "Reading incident handlers (data-plane)..."
DP_HANDLERS=$(dp_get "/api/v1/incidentPlayground/handlers" 2>/dev/null || echo '[]')
DP_HANDLER_COUNT=$(echo "$DP_HANDLERS" | jq 'length' 2>/dev/null || echo 0)
_log "  Found ${DP_HANDLER_COUNT} incident handler(s)"
# Merge customInstructions from handler into the matching filter's spec
if [[ "$DP_HANDLER_COUNT" -gt 0 ]]; then
  INCIDENT_FILTERS=$(echo "$INCIDENT_FILTERS" | jq -c --argjson handlers "$DP_HANDLERS" '
    [.[] | . as $f |
      ($handlers | map(select(.incidentFilterId == $f.metadata.name)) | first // null) as $h |
      if $h and ($h.customInstructions // "") != "" then
        .spec.customInstructions = $h.customInstructions
      else . end
    ]')
  _log "  Merged customInstructions into filters"
fi

# Subagents (opaque)
_log "Reading subagents..."
RAW_SUBAGENTS=$(arm_list "subagents")
SUBAGENT_COUNT=$(echo "$RAW_SUBAGENTS" | jq 'length')
_log "  Found ${SUBAGENT_COUNT} subagent(s)"
SUBAGENTS=$(decode_opaque "$RAW_SUBAGENTS")

# Hooks (opaque — try ARM first; public Bicep deploys these via ARM now)
_log "Reading hooks (ARM)..."
RAW_HOOKS_ARM=$(arm_list "hooks" 2>/dev/null || echo "[]")
HOOKS_ARM_COUNT=$(echo "$RAW_HOOKS_ARM" | jq 'length')
if [[ "$HOOKS_ARM_COUNT" -gt 0 ]]; then
  HOOKS_ARM=$(decode_opaque "$RAW_HOOKS_ARM")
  _log "  Found ${HOOKS_ARM_COUNT} hook(s) via ARM"
else
  HOOKS_ARM="[]"
  _log "  None via ARM (will try data-plane)"
fi

# Common Prompts (opaque — try ARM first)
_log "Reading common prompts (ARM)..."
RAW_PROMPTS_ARM=$(arm_list "commonPrompts" 2>/dev/null || echo "[]")
PROMPTS_ARM_COUNT=$(echo "$RAW_PROMPTS_ARM" | jq 'length')
if [[ "$PROMPTS_ARM_COUNT" -gt 0 ]]; then
  PROMPTS_ARM=$(decode_opaque "$RAW_PROMPTS_ARM")
  _log "  Found ${PROMPTS_ARM_COUNT} common prompt(s) via ARM"
else
  PROMPTS_ARM="[]"
  _log "  None via ARM (will try data-plane)"
fi

# Plugin Configs (opaque — try ARM first)
_log "Reading plugin configs (ARM)..."
RAW_PLUGINS_ARM=$(arm_list "pluginConfigs" 2>/dev/null || echo "[]")
PLUGINS_ARM_COUNT=$(echo "$RAW_PLUGINS_ARM" | jq 'length')
if [[ "$PLUGINS_ARM_COUNT" -gt 0 ]]; then
  PLUGINS_ARM=$(decode_opaque "$RAW_PLUGINS_ARM")
  _log "  Found ${PLUGINS_ARM_COUNT} plugin config(s) via ARM"
else
  PLUGINS_ARM="[]"
  _log "  None via ARM (will try data-plane)"
fi

echo

# ────────────────── Phase 3: Data plane — extended config ──────────────────

_info "Exporting data-plane configuration"

# Hooks (data-plane — merge with ARM results)
_log "Reading hooks (data-plane)..."
RAW_HOOKS_DP=$(dp_get "/api/v2/extendedAgent/hooks")
if [[ "$RAW_HOOKS_DP" != "null" ]]; then
  HOOKS_DP=$(echo "$RAW_HOOKS_DP" | jq -c '[(.value // . // [])[] | {
    name: .name,
    type: (.type // ""),
    tags: (.tags // []),
    properties: (.properties // {})
  }]' 2>/dev/null || echo "[]")
else
  HOOKS_DP="[]"
fi
# Merge: use ARM if available (Bicep-compatible shape), otherwise data-plane (extras shape)
if [[ "$HOOKS_ARM_COUNT" -gt 0 ]]; then
  HOOKS_FOR_PARAMS="$HOOKS_ARM"
  HOOKS_FOR_EXTRAS="[]"
  HOOK_COUNT="$HOOKS_ARM_COUNT"
else
  HOOKS_FOR_PARAMS="[]"
  HOOKS_FOR_EXTRAS="$HOOKS_DP"
  HOOK_COUNT=$(echo "$HOOKS_DP" | jq 'length')
fi
_log "  Found ${HOOK_COUNT} hook(s) total"

# Common Prompts (data-plane — merge with ARM results)
_log "Reading common prompts (data-plane)..."
RAW_PROMPTS_DP=$(dp_get "/api/v2/extendedAgent/commonprompts")
if [[ "$RAW_PROMPTS_DP" != "null" ]]; then
  PROMPTS_DP=$(echo "$RAW_PROMPTS_DP" | jq -c '[(.value // . // [])[] | {
    name: .name,
    type: (.type // ""),
    tags: (.tags // []),
    properties: (.properties // {})
  }]' 2>/dev/null || echo "[]")
else
  PROMPTS_DP="[]"
fi
if [[ "$PROMPTS_ARM_COUNT" -gt 0 ]]; then
  PROMPTS_FOR_PARAMS="$PROMPTS_ARM"
  PROMPTS_FOR_EXTRAS="[]"
  PROMPT_COUNT="$PROMPTS_ARM_COUNT"
else
  PROMPTS_FOR_PARAMS="[]"
  PROMPTS_FOR_EXTRAS="$PROMPTS_DP"
  PROMPT_COUNT=$(echo "$PROMPTS_DP" | jq 'length')
fi
_log "  Found ${PROMPT_COUNT} common prompt(s) total"

# Plugin Configs (data-plane — merge with ARM results)
_log "Reading plugin configs (data-plane)..."
RAW_PLUGINS_DP=$(dp_get "/api/v2/extendedAgent/plugins")
if [[ "$RAW_PLUGINS_DP" != "null" ]]; then
  PLUGINS_DP=$(echo "$RAW_PLUGINS_DP" | jq -c '[(.value // . // [])[] | {
    name: .name,
    type: (.type // "plugin"),
    tags: (.tags // []),
    properties: (.properties // {})
  }]' 2>/dev/null || echo "[]")
else
  PLUGINS_DP="[]"
fi
if [[ "$PLUGINS_ARM_COUNT" -gt 0 ]]; then
  PLUGINS_FOR_PARAMS="$PLUGINS_ARM"
  PLUGINS_FOR_EXTRAS="[]"
  PLUGIN_COUNT="$PLUGINS_ARM_COUNT"
else
  PLUGINS_FOR_PARAMS="[]"
  PLUGINS_FOR_EXTRAS="$PLUGINS_DP"
  PLUGIN_COUNT=$(echo "$PLUGINS_DP" | jq 'length')
fi
_log "  Found ${PLUGIN_COUNT} plugin config(s) total"

# Repos
_log "Reading repos..."
RAW_REPOS=$(dp_get "/api/v2/repos/")
if [[ "$RAW_REPOS" != "null" ]]; then
  REPOS=$(echo "$RAW_REPOS" | jq -c '[(.value // . // [])[] | {
    name: .name,
    spec: {
      url: (.properties.url // ""),
      type: ((.properties.type // "GitHub") | ascii_downcase),
      branch: (.properties.branch // "main")
    }
  }]' 2>/dev/null || echo "[]")
else
  REPOS="[]"
fi
REPO_COUNT=$(echo "$REPOS" | jq 'length')
_log "  Found ${REPO_COUNT} repo(s)"

# Incident Platforms — read from ARM agent properties (incidentManagementConfiguration)
# The platform type is set via ARM PATCH, not the data-plane indexing API.
_log "Reading incident platforms..."
INCIDENT_PLATFORMS="[]"
IM_TYPE=$(echo "$AGENT_JSON" | jq -r '.properties.incidentManagementConfiguration.type // "None"' 2>/dev/null)
if [[ "$IM_TYPE" != "None" && "$IM_TYPE" != "null" && -n "$IM_TYPE" ]]; then
  INCIDENT_PLATFORMS=$(jq -nc --arg t "$IM_TYPE" '[{name: ($t | ascii_downcase), spec: {platformType: $t}}]')
fi
# Also check data-plane indexing configs for additional settings
for platform_type in azmonitor pagerduty servicenow; do
  result=$(dp_get "/api/v2/incidents/indexing/${platform_type}/configuration" 2>/dev/null)
  if [[ "$result" != "null" && -n "$result" ]]; then
    entry=$(echo "$result" | jq -c --arg t "$platform_type" '{name: $t, spec: (.spec // .properties // .)}' 2>/dev/null || echo "")
    if [[ -n "$entry" && "$entry" != "null" ]]; then
      INCIDENT_PLATFORMS=$(echo "$INCIDENT_PLATFORMS" | jq -c --argjson e "$entry" '. + [$e]')
    fi
  fi
done
INCIDENT_PLATFORM_COUNT=$(echo "$INCIDENT_PLATFORMS" | jq 'length')
_log "  Found ${INCIDENT_PLATFORM_COUNT} incident platform(s)"

# Plugin Marketplaces + Installations
_log "Reading plugin marketplaces..."
RAW_MARKETPLACES=$(dp_get "/api/v2/plugins/marketplaces")
if [[ "$RAW_MARKETPLACES" != "null" ]]; then
  PLUGIN_MARKETPLACES=$(echo "$RAW_MARKETPLACES" | jq -c '[(.value // . // [])[] | {
    name: (.metadata.name // .name),
    spec: (.spec // .properties // {})
  }]' 2>/dev/null || echo "[]")
else
  PLUGIN_MARKETPLACES="[]"
fi
_log "  Found $(echo "$PLUGIN_MARKETPLACES" | jq 'length') marketplace(s)"

_log "Reading plugin installations..."
RAW_INSTALLATIONS=$(dp_get "/api/v2/plugins/installations")
if [[ "$RAW_INSTALLATIONS" != "null" ]]; then
  PLUGIN_INSTALLATIONS=$(echo "$RAW_INSTALLATIONS" | jq -c '[(.value // . // [])[] | {
    name: (.metadata.name // .name),
    spec: (.spec // .properties // {})
  }]' 2>/dev/null || echo "[]")
else
  PLUGIN_INSTALLATIONS="[]"
fi
_log "  Found $(echo "$PLUGIN_INSTALLATIONS" | jq 'length') installation(s)"

# HTTP Triggers (data-plane — /api/v1/httpTriggers)
_log "Reading HTTP triggers..."
RAW_HTTP_TRIGGERS=$(dp_get "/api/v1/httpTriggers")
HTTP_TRIGGER_TYPE=$(echo "$RAW_HTTP_TRIGGERS" | jq -r 'type' 2>/dev/null)
if [[ "$HTTP_TRIGGER_TYPE" == "array" ]]; then
  HTTP_TRIGGERS=$(echo "$RAW_HTTP_TRIGGERS" | jq -c '[.[] | {
    name: (.name // ""),
    spec: {
      description: (.description // ""),
      prompt: (.agentPrompt // .prompt // ""),
      handlingAgent: (.agent // .handlingAgent // ""),
      agentMode: (.agentMode // "Review")
    }
  }]' 2>/dev/null || echo "[]")
elif [[ "$HTTP_TRIGGER_TYPE" == "object" ]]; then
  HTTP_TRIGGERS=$(echo "$RAW_HTTP_TRIGGERS" | jq -c '[(.value // [])[] | {
    name: (.name // ""),
    spec: {
      description: (.description // ""),
      prompt: (.agentPrompt // .prompt // ""),
      handlingAgent: (.agent // .handlingAgent // ""),
      agentMode: (.agentMode // "Review")
    }
  }]' 2>/dev/null || echo "[]")
else
  HTTP_TRIGGERS="[]"
fi
HTTP_TRIGGER_COUNT=$(echo "$HTTP_TRIGGERS" | jq 'length')
_log "  Found ${HTTP_TRIGGER_COUNT} HTTP trigger(s)"

# Webhook bridge detection (check if Logic App exists)
_log "Checking for webhook bridge (Logic App)..."
BRIDGE_EXISTS=false
BRIDGE_JSON=$(az resource show \
  --ids "/subscriptions/${SUB}/resourceGroups/${RG}/providers/Microsoft.Logic/workflows/${AGENT}-webhook-bridge" \
  -o json 2>/dev/null || echo "null")
if [[ "$BRIDGE_JSON" != "null" ]]; then
  BRIDGE_EXISTS=true
  _log "  Found webhook bridge: ${AGENT}-webhook-bridge"
else
  _log "  No webhook bridge found"
fi

# Knowledge (metadata only by default — can be large)
# Two sources: (1) AgentMemory uploads, (2) Knowledge items via connectors API
KNOWLEDGE="[]"
KNOWLEDGE_ITEMS="[]"
FILES_DIR="${OUTPUT}-files"

# ── 1. AgentMemory uploaded documents ──
if [[ "$INCLUDE_KNOWLEDGE" == "true" ]]; then
  _log "Reading AgentMemory documents..."
  RAW_KNOWLEDGE=$(dp_get "/api/v1/AgentMemory/files")
  if [[ "$RAW_KNOWLEDGE" != "null" ]]; then
    KNOWLEDGE=$(echo "$RAW_KNOWLEDGE" | jq -c '[(.files // .value // . // [])[] | {
      filename: (.filename // .name // ""),
      mimeType: (.mimeType // .contentType // "application/octet-stream"),
      fileSize: (.fileSize // .size // 0),
      indexStatus: (if .isIndexed == true then "indexed" elif .isIndexed == false then "pending" else (.indexStatus // "unknown") end),
      triggerIndexing: true
    }]' 2>/dev/null || echo "[]")
  fi
  KNOWLEDGE_COUNT=$(echo "$KNOWLEDGE" | jq 'length')
  _log "  Found ${KNOWLEDGE_COUNT} uploaded document(s)"

  # Download actual files if requested
  # NOTE: The AgentMemory API has no file download endpoint — uploaded files are
  # chunked into Azure AI Search and the original blob is not retrievable.
  # We search local config directories and recipes for the source files.
  if [[ "$DOWNLOAD_FILES" == "true" && "$KNOWLEDGE_COUNT" -gt 0 ]]; then
    DOCS_DIR="${OUTPUT}/data/knowledge"
    mkdir -p "$DOCS_DIR"
    _log "  Locating knowledge source files..."
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
    found=0 missing=0
    for i in $(seq 0 $((KNOWLEDGE_COUNT - 1))); do
      fname=$(echo "$KNOWLEDGE" | jq -r --argjson i "$i" '.[$i].filename')
      copied=false
      # Search: source config data/, all recipe data/ dirs, current dir
      while IFS= read -r candidate; do
        if [[ -f "$candidate" ]]; then
          cp "$candidate" "${DOCS_DIR}/${fname}"
          _log "    ✓ ${fname} (from ${candidate})"
          copied=true
          found=$((found + 1))
          break
        fi
      done < <(find "${REPO_ROOT}/recipes" -name "$fname" -type f 2>/dev/null; \
               find "${REPO_ROOT}" -maxdepth 3 -name "$fname" -path "*/data/*" -type f 2>/dev/null)
      if [[ "$copied" == "false" ]]; then
        _log "    ✗ ${fname} (no download API — place in <config>/data/knowledge/ before deploy)"
        missing=$((missing + 1))
      fi
    done
    if [[ "$missing" -gt 0 ]]; then
      _log "  ⚠ ${missing} file(s) not found locally. Place them in ${OUTPUT}/data/knowledge/ before deploy."
    fi
    # Update knowledge entries with localPath for files that exist
    KNOWLEDGE=$(echo "$KNOWLEDGE" | jq -c --arg dir "$DOCS_DIR" '[
      .[] | . + {localPath: ($dir + "/" + .filename)}
    ]')
  fi
else
  _log "Skipping AgentMemory documents (use --include-knowledge to include)"
fi

# ── 2. Knowledge items (KnowledgeText/File/WebPage/Repository via connectors API) ──
if [[ "$INCLUDE_KNOWLEDGE_ITEMS" == "true" ]]; then
  _log "Reading knowledge items from connectors API..."
  RAW_KNOWLEDGE_ITEMS=$(dp_get "/api/v2/extendedAgent/connectors")
  if [[ "$RAW_KNOWLEDGE_ITEMS" != "null" ]]; then
    KNOWLEDGE_ITEMS=$(echo "$RAW_KNOWLEDGE_ITEMS" | jq -c '[
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
    ]' 2>/dev/null || echo "[]")
  fi
  KI_COUNT=$(echo "$KNOWLEDGE_ITEMS" | jq 'length')
  _log "  Found ${KI_COUNT} knowledge item(s)"

  # Download knowledge item content if requested
  if [[ "$DOWNLOAD_FILES" == "true" && "$KI_COUNT" -gt 0 ]]; then
    _log "  Downloading knowledge item content..."
    KI_DIR="${FILES_DIR}/knowledge-items"
    mkdir -p "$KI_DIR"
    for i in $(seq 0 $((KI_COUNT - 1))); do
      kiname=$(echo "$KNOWLEDGE_ITEMS" | jq -r --argjson i "$i" '.[$i].name')
      kitype=$(echo "$KNOWLEDGE_ITEMS" | jq -r --argjson i "$i" '.[$i].type')
      # Determine file extension based on type
      case "$kitype" in
        KnowledgeText)     ext=".md" ;;
        KnowledgeWebPage)  ext=".html" ;;
        KnowledgeFile)     ext="" ;;
        *)                 ext=".json" ;;
      esac
      dp_download "/api/v2/extendedAgent/connectors/$(printf %s "$kiname" | jq -sRr @uri)/content" \
        "${KI_DIR}/${kiname}${ext}" 2>/dev/null && \
        _log "    ✓ ${kiname} (${kitype})" || \
        _log "    ✗ ${kiname} (could not download content)"
    done
    # Update entries with localPath
    KNOWLEDGE_ITEMS=$(echo "$KNOWLEDGE_ITEMS" | jq -c --arg dir "$KI_DIR" '[
      .[] | . + {
        localPath: ($dir + "/" + .name + (
          if .type == "KnowledgeText" then ".md"
          elif .type == "KnowledgeWebPage" then ".html"
          elif .type == "KnowledgeFile" then ""
          else ".json" end
        ))
      }
    ]')
  fi
else
  _log "Skipping knowledge items (use --include-knowledge-items to include)"
fi

# ── 3. Synthesized knowledge (workspace memories — learned patterns, preferences, etc.) ──
SYNTHESIZED_KNOWLEDGE="[]"
if [[ "$INCLUDE_MEMORIES" == "true" ]]; then
  _log "Reading synthesized knowledge..."
  RAW_SYNTH=$(dp_get "/api/v1/WorkspaceMemory/list?type=synthesized-knowledge")
  if [[ "$RAW_SYNTH" != "null" ]]; then
    SYNTHESIZED_KNOWLEDGE=$(echo "$RAW_SYNTH" | jq -c '[
      (.files // .value // . // [])[] | {
        path: (.path // ""),
        size: (.size // 0),
        lastModified: (.lastModified // "")
      }
    ]' 2>/dev/null || echo "[]")
  fi
  SYNTH_COUNT=$(echo "$SYNTHESIZED_KNOWLEDGE" | jq 'length')
  _log "  Found ${SYNTH_COUNT} synthesized knowledge file(s)"

  # Download synthesized knowledge tar.gz — contains ALL memory files
  if [[ "$DOWNLOAD_FILES" == "true" ]]; then
    SYNTH_DIR="${FILES_DIR}/synthesized-knowledge"
    dp_download_tarball "/api/v1/WorkspaceMemory/synthesized-knowledge" "$SYNTH_DIR" "synthesized-knowledge"
  fi

  # Also list all workspace memory entries for inventory
  _log "Reading workspace memory inventory..."
  RAW_WS_MEM=$(dp_get "/api/v1/WorkspaceMemory/list")
  if [[ "$RAW_WS_MEM" != "null" ]]; then
    WS_MEM_COUNT=$(echo "$RAW_WS_MEM" | jq '(.files // .value // . // []) | length' 2>/dev/null || echo "0")
    _log "  Found ${WS_MEM_COUNT} total workspace memory file(s)"
  fi
else
  _log "Skipping synthesized knowledge/memories (use --include-memories to include)"
fi

# Repo Instructions (requires per-repo fetch)
REPO_INSTRUCTIONS="[]"
if [[ "$INCLUDE_REPO_INSTRUCTIONS" == "true" && "$REPO_COUNT" -gt 0 ]]; then
  _log "Reading repo instructions..."
  for i in $(seq 0 $((REPO_COUNT - 1))); do
    rname=$(echo "$REPOS" | jq -r --argjson i "$i" '.[$i].name')
    # Download tar.gz if --download-files is set
    if [[ "$DOWNLOAD_FILES" == "true" ]]; then
      RI_DIR="${FILES_DIR}/repo-instructions/${rname}"
      dp_download_tarball "/api/v1/WorkspaceMemory/repo-instructions?repo=$(printf %s "$rname" | jq -sRr @uri)" \
        "$RI_DIR" "repo-instructions/${rname}"
      # Build files array from downloaded content
      if [[ -d "$RI_DIR" ]]; then
        entry=$(find "$RI_DIR" -type f | while read -r f; do
          relpath="${f#${RI_DIR}/}"
          jq -n --arg p "$relpath" --arg c "$(cat "$f")" '{path: $p, content: $c}'
        done | jq -sc --arg r "$rname" '{repo: $r, files: .}')
        REPO_INSTRUCTIONS=$(echo "$REPO_INSTRUCTIONS" | jq -c --argjson e "$entry" '. + [$e]')
      fi
    else
      # Metadata only — try to list files
      result=$(dp_get "/api/v1/WorkspaceMemory/list?type=repo-instructions&repo=$(printf %s "$rname" | jq -sRr @uri)")
      if [[ "$result" != "null" ]]; then
        files=$(echo "$result" | jq -c '[(.value // . // [])[] | {path: .path, size: .size}]' 2>/dev/null || echo "[]")
        file_count=$(echo "$files" | jq 'length')
        if [[ "$file_count" -gt 0 ]]; then
          entry=$(jq -n -c --arg r "$rname" --argjson f "$files" '{repo: $r, files: $f, _note: "Content not downloaded — use --download-files to include"}')
          REPO_INSTRUCTIONS=$(echo "$REPO_INSTRUCTIONS" | jq -c --argjson e "$entry" '. + [$e]')
        fi
      fi
    fi
  done
  _log "  Found $(echo "$REPO_INSTRUCTIONS" | jq 'length') repo instruction set(s)"
else
  _log "Skipping repo instructions (use --include-repo-instructions to include)"
fi

echo

# ────────────────────── Phase 4: Dry-run summary ──────────────────────

_info "Export summary"

echo "  Agent:              ${AGENT}"
echo "  Location:           ${LOCATION}"
echo "  Access level:       ${ACCESS_LEVEL}"
echo "  Action mode:        ${ACTION_MODE}"
echo "  Target RGs:         $(echo "$TARGET_RGS" | jq -r 'join(", ") // "<none>"')"
echo
echo "  Connectors:         ${CONNECTOR_COUNT}"
for i in $(seq 0 $((CONNECTOR_COUNT - 1))); do
  cname=$(echo "$CONNECTORS" | jq -r --argjson i "$i" '.[$i].name')
  ctype=$(echo "$CONNECTORS" | jq -r --argjson i "$i" '.[$i].properties.dataConnectorType')
  echo "    - ${cname} (${ctype})"
done
echo "  Skills:             ${SKILL_COUNT}"
echo "$SKILLS" | jq -r '.[].metadata.name' 2>/dev/null | while read -r n; do echo "    - $n"; done
echo "  Subagents:          ${SUBAGENT_COUNT}"
echo "$SUBAGENTS" | jq -r '.[].metadata.name' 2>/dev/null | while read -r n; do echo "    - $n"; done
echo "  Hooks:              ${HOOK_COUNT}"
echo "$HOOKS_FOR_EXTRAS" | jq -r '.[].name' 2>/dev/null | while read -r n; do echo "    - $n"; done
echo "  Common prompts:     ${PROMPT_COUNT}"
echo "$PROMPTS_FOR_EXTRAS" | jq -r '.[].name' 2>/dev/null | while read -r n; do echo "    - $n"; done
echo "  HTTP triggers:      ${HTTP_TRIGGER_COUNT}"
echo "$HTTP_TRIGGERS" | jq -r '.[].name' 2>/dev/null | while read -r n; do echo "    - $n"; done
echo "  Repos:              ${REPO_COUNT}"
echo "$REPOS" | jq -r '.[].name' 2>/dev/null | while read -r n; do echo "    - $n"; done
echo "  Webhook bridge:     $([[ "$BRIDGE_EXISTS" == true ]] && echo "yes" || echo "no")"
echo "  Incident platforms: ${INCIDENT_PLATFORM_COUNT}"
echo "  Scheduled tasks:    ${TASK_COUNT}"
echo "  Incident filters:   ${FILTER_COUNT}"

if [[ "$DRY_RUN" == "true" ]]; then
  echo
  echo "Dry run — no files written."
  exit 0
fi

echo

# ────────────────────── Phase 5: Write structured output ──────────────────────
#
# Layout:
#   <output>/
#     agent.json                  ← Agent identity + settings
#     connectors.json             ← Connector toggles + entries (secrets → env var refs)
#     connectors.secrets.env      ← Secret values (.gitignore this)
#     .gitignore                  ← Ignores secrets file
#     config/                     ← Agent capabilities
#       skills/<name>.yaml + <name>.md
#       subagents/<name>.yaml + <name>.instructions.md
#       tools/<name>.yaml
#       hooks/<name>.yaml
#       common-prompts/<name>.yaml or .md
#       plugin-configs/<name>.yaml
#       repos/<name>.yaml
#       plugins/marketplaces/<name>.yaml
#       plugins/installations/<name>.yaml
#     automations/                ← Inbound triggers + scheduled work
#       scheduled-tasks/<name>.yaml
#       incident-filters/<name>.yaml
#       http-triggers/<name>.yaml
#       incident-platforms/<name>.yaml
#     data/                       ← Only with --include-* / --download-files
#       knowledge/
#       knowledge-items/
#       synthesized-knowledge/
#       repo-instructions/

EXPORT_DIR="${OUTPUT}"
mkdir -p "${EXPORT_DIR}/config"

# ── Helper: write array items as individual YAML files ──
write_config_items() {
  local dir="$1" items_json="$2" name_path="$3" base="${4:-config}"
  local count
  count=$(echo "$items_json" | jq 'length')
  [[ "$count" -gt 0 ]] || return 0
  mkdir -p "${EXPORT_DIR}/${base}/${dir}"
  for i in $(seq 0 $((count - 1))); do
    local name
    name=$(echo "$items_json" | jq -r --argjson i "$i" ".[$i]${name_path}")
    echo "$items_json" | jq --argjson i "$i" '.[$i]' | json2yaml > "${EXPORT_DIR}/${base}/${dir}/${name}.yaml"
  done
  _log "  ${dir}: ${count} file(s)"
}

# ═══════ 1. agent.json — generic metadata (easy to edit for cloning) ═══════

_info "Writing agent.json"

# Toggle inference
ENABLE_AI=false; AI_RESOURCE_ID=""; AI_APP_ID=""
ENABLE_LAW=false; LAW_RESOURCE_ID=""
ENABLE_AZMON=false; AZMON_LOOKBACK=7

for i in $(seq 0 $((CONNECTOR_COUNT - 1))); do
  ctype=$(echo "$CONNECTORS" | jq -r --argjson i "$i" '.[$i].properties.dataConnectorType')
  case "$ctype" in
    AppInsights)
      ENABLE_AI=true
      AI_RESOURCE_ID=$(echo "$CONNECTORS" | jq -r --argjson i "$i" '.[$i].properties.dataSource // .[$i].properties.extendedProperties.armResourceId // ""')
      AI_APP_ID=$(echo "$CONNECTORS" | jq -r --argjson i "$i" '.[$i].properties.extendedProperties.appId // ""')
      ;;
    LogAnalytics)
      ENABLE_LAW=true
      LAW_RESOURCE_ID=$(echo "$CONNECTORS" | jq -r --argjson i "$i" '.[$i].properties.dataSource // .[$i].properties.extendedProperties.armResourceId // ""')
      ;;
    AzureMonitor)
      ENABLE_AZMON=true
      AZMON_LOOKBACK=$(echo "$CONNECTORS" | jq -r --argjson i "$i" '.[$i].properties.extendedProperties.lookbackDays // 7')
      ;;
  esac
done

jq -n \
  --arg agent "$AGENT" \
  --arg rg "$RG" \
  --arg sub "$SUB" \
  --arg loc "$LOCATION" \
  --arg access "$ACCESS_LEVEL" \
  --arg action "$ACTION_MODE" \
  --argjson targetRgs "$TARGET_RGS" \
  --argjson enableBridge "$BRIDGE_EXISTS" \
  '{
    "_description": "SRE Agent configuration — edit these values to clone to a new environment.",
    "_exported_at": (now | todate),

    "identity": {
      "agentName":            $agent,
      "resourceGroup":        $rg,
      "subscription":         $sub,
      "location":             $loc,
      "targetResourceGroups": $targetRgs
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
      "enableWebhookBridge":         $enableBridge,
      "webhookBridgeTriggerUrl":     ""
    }
  }' > "${EXPORT_DIR}/agent.json"

# Apply --set overrides to agent.json (for cloning)
if [[ ${#SET_OVERRIDES[@]} -gt 0 ]]; then
  _log "Applying --set overrides:"
  for override in "${SET_OVERRIDES[@]}"; do
    key="${override%%=*}"
    val="${override#*=}"
    case "$key" in
      agentName)
        jq --arg v "$val" '.identity.agentName = $v' "${EXPORT_DIR}/agent.json" > /tmp/_agent_set.json && mv /tmp/_agent_set.json "${EXPORT_DIR}/agent.json"
        _log "  agentName → $val"
        ;;
      resourceGroup)
        jq --arg v "$val" '.identity.resourceGroup = $v' "${EXPORT_DIR}/agent.json" > /tmp/_agent_set.json && mv /tmp/_agent_set.json "${EXPORT_DIR}/agent.json"
        _log "  resourceGroup → $val"
        ;;
      location)
        jq --arg v "$val" '.identity.location = $v' "${EXPORT_DIR}/agent.json" > /tmp/_agent_set.json && mv /tmp/_agent_set.json "${EXPORT_DIR}/agent.json"
        _log "  location → $val"
        ;;
      targetRGs)
        jq --arg v "$val" '.identity.targetResourceGroups = $v' "${EXPORT_DIR}/agent.json" > /tmp/_agent_set.json && mv /tmp/_agent_set.json "${EXPORT_DIR}/agent.json"
        _log "  targetRGs → $val"
        ;;
      accessLevel)
        jq --arg v "$val" '.access.accessLevel = $v' "${EXPORT_DIR}/agent.json" > /tmp/_agent_set.json && mv /tmp/_agent_set.json "${EXPORT_DIR}/agent.json"
        _log "  accessLevel → $val"
        ;;
      actionMode)
        jq --arg v "$val" '.access.actionMode = $v' "${EXPORT_DIR}/agent.json" > /tmp/_agent_set.json && mv /tmp/_agent_set.json "${EXPORT_DIR}/agent.json"
        _log "  actionMode → $val"
        ;;
      pagerdutyApiKey|servicenowApiKey|connectionKey)
        # Inject connectionKey into incident platform YAML
        for pf in "${EXPORT_DIR}/automations/incident-platforms"/*.yaml; do
          [[ -f "$pf" ]] || continue
          python3 -c "
import yaml, sys
with open('$pf') as f: d = yaml.safe_load(f)
d.setdefault('spec',{})['connectionKey'] = '$val'
with open('$pf','w') as f: yaml.dump(d, f, default_flow_style=False, sort_keys=False)
" 2>/dev/null
        done
        _log "  connectionKey → (set in incident-platforms/*.yaml)"
        ;;
      *)
        _warn "Unknown --set key: $key (ignored)"
        ;;
    esac
  done
fi

_log "Wrote agent.json"

# ═══════ 2. connectors.json + connectors.secrets.env ═══════

_info "Writing connectors.json"

# Separate secrets from connector config.
# Replace secret values with ${ENV_VAR} references, write actual values to .env file.
SECRETS_ENV="${EXPORT_DIR}/connectors.secrets.env"
echo "# SRE Agent connector secrets — DO NOT commit this file." > "$SECRETS_ENV"
echo "# Generated $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$SECRETS_ENV"
echo "" >> "$SECRETS_ENV"

# Process connectors: extract secrets, replace with env refs
CONNECTORS_CLEAN="$CONNECTORS"
for i in $(seq 0 $((CONNECTOR_COUNT - 1))); do
  cname=$(echo "$CONNECTORS" | jq -r --argjson i "$i" '.[$i].name')
  ctype=$(echo "$CONNECTORS" | jq -r --argjson i "$i" '.[$i].properties.dataConnectorType')
  dsrc=$(echo "$CONNECTORS" | jq -r --argjson i "$i" '.[$i].properties.dataSource // ""')

  # Env var name: uppercase, underscores
  ENV_PREFIX=$(echo "${cname}" | tr '[:lower:]-' '[:upper:]_')

  # Extract bearer tokens from connection strings
  if [[ "$dsrc" == *BearerToken=* ]]; then
    token=$(echo "$dsrc" | grep -oP 'BearerToken=\K[^;]+' 2>/dev/null || echo "")
    if [[ -n "$token" ]]; then
      echo "${ENV_PREFIX}_BEARER_TOKEN=${token}" >> "$SECRETS_ENV"
      # Replace token with env var reference in connector
      CONNECTORS_CLEAN=$(echo "$CONNECTORS_CLEAN" | jq --argjson i "$i" --arg ref "\${${ENV_PREFIX}_BEARER_TOKEN}" \
        '.[$i].properties.dataSource = (.[$i].properties.dataSource | gsub("BearerToken=[^;]+"; "BearerToken=" + $ref))')
    fi
  fi

  # Extract bearer tokens from extendedProperties
  bt=$(echo "$CONNECTORS" | jq -r --argjson i "$i" '.[$i].properties.extendedProperties.bearerToken // empty')
  if [[ -n "$bt" ]]; then
    echo "${ENV_PREFIX}_BEARER_TOKEN=${bt}" >> "$SECRETS_ENV"
    CONNECTORS_CLEAN=$(echo "$CONNECTORS_CLEAN" | jq --argjson i "$i" --arg ref "\${${ENV_PREFIX}_BEARER_TOKEN}" \
      '.[$i].properties.extendedProperties.bearerToken = $ref')
  fi
done

# Sanitize anything remaining
CONNECTORS_CLEAN=$(sanitize "$CONNECTORS_CLEAN")

# ── Write connectors.json ──
# Toggle-managed types (AppInsights, LogAnalytics, AzureMonitor) go into toggles.
# All other connectors (MCP, Kusto, etc.) go into the connectors array.
TOGGLE_TYPES="AppInsights|LogAnalytics|AzureMonitor"
CONNECTORS_ARRAY=$(echo "$CONNECTORS_CLEAN" | jq -c --arg tt "$TOGGLE_TYPES" '[.[] | select(.properties.dataConnectorType | test("^(\($tt))$") | not)]')

echo "$CONNECTORS_ARRAY" | jq --argjson enableAI "$ENABLE_AI" --arg aiResId "$AI_RESOURCE_ID" --arg aiAppId "$AI_APP_ID" \
  --argjson enableLAW "$ENABLE_LAW" --arg lawResId "$LAW_RESOURCE_ID" \
  --argjson enableAzMon "$ENABLE_AZMON" --argjson azMonLookback "$AZMON_LOOKBACK" \
  '{
    "toggles": {
      "enableAppInsightsConnector": $enableAI,
      "appInsightsResourceId": $aiResId,
      "appInsightsAppId": $aiAppId,
      "enableLogAnalyticsConnector": $enableLAW,
      "lawResourceId": $lawResId,
      "enableAzureMonitorConnector": $enableAzMon,
      "azureMonitorLookbackDays": $azMonLookback
    },
    "connectors": .
  }' > "${EXPORT_DIR}/connectors.json"
CONN_COUNT=$(echo "$CONNECTORS_ARRAY" | jq 'length')
_log "Wrote connectors.json (${CONN_COUNT} connector(s) + toggles)"

_log "Wrote connectors.secrets.env (secrets extracted — DO NOT commit)"

# ── Export admin settings (cross-tenant admin users) ──
ADMIN_USERS=$(echo "$AGENT_JSON" | jq -c '.properties.adminUsers // []' 2>/dev/null || echo "[]")

if [[ $(echo "$ADMIN_USERS" | jq 'length') -gt 0 ]]; then
  jq -n \
    --argjson adminUsers "$ADMIN_USERS" \
    '{
      "_description": "Cross-tenant admin users for portal access.",
      "adminUsers": $adminUsers
    }' > "${EXPORT_DIR}/admin-settings.json"
  _log "Wrote admin-settings.json ($(echo "$ADMIN_USERS" | jq 'length') admin user(s))"
fi

# .gitignore
cat > "${EXPORT_DIR}/.gitignore" << 'GITIGNORE'
# Secrets — never commit
connectors.secrets.env
*.secrets.env

# Downloaded data (can be large)
data/
GITIGNORE
_log "Wrote .gitignore"

# ═══════ expected-config.json — verification spec ═══════

_log "Generating expected-config.json"

# Build connector list from toggle-managed + array connectors
EXPECTED_CONNECTORS="[]"
if [[ "$ENABLE_LAW" == "true" ]]; then
  EXPECTED_CONNECTORS=$(echo "$EXPECTED_CONNECTORS" | jq '. + [{"name":"log-analytics","type":"LogAnalytics"}]')
fi
if [[ "$ENABLE_AI" == "true" ]]; then
  EXPECTED_CONNECTORS=$(echo "$EXPECTED_CONNECTORS" | jq '. + [{"name":"app-insights","type":"AppInsights"}]')
fi
if [[ "$ENABLE_AZMON" == "true" ]]; then
  EXPECTED_CONNECTORS=$(echo "$EXPECTED_CONNECTORS" | jq '. + [{"name":"azure-monitor","type":"AzureMonitor"}]')
fi
# Array connectors (MCP, Kusto, etc.) — skip null/empty entries
for i in $(seq 0 $(($(echo "$CONNECTORS_ARRAY" | jq 'length') - 1))); do
  cname=$(echo "$CONNECTORS_ARRAY" | jq -r --argjson i "$i" '.[$i].name')
  ctype=$(echo "$CONNECTORS_ARRAY" | jq -r --argjson i "$i" '.[$i].properties.dataConnectorType')
  [[ "$cname" == "null" || -z "$cname" ]] && continue
  EXPECTED_CONNECTORS=$(echo "$EXPECTED_CONNECTORS" | jq --arg n "$cname" --arg t "$ctype" '. + [{"name":$n,"type":$t}]')
done

# Incident platform
INC_PLATFORM=$(echo "$INCIDENT_PLATFORMS" | jq -r '.[0].spec.platformType // "None"' 2>/dev/null || echo "None")

# Response plans from incident filters
EXPECTED_PLANS=$(echo "$INCIDENT_FILTERS" | jq -c '[.[] | {name: (.metadata.name // .name), handlingAgent: (.spec.handlingAgent // .handlingAgent // "")}]' 2>/dev/null || echo "[]")

jq -n \
  --arg scenario "exported" \
  --arg accessLevel "$ACCESS_LEVEL" \
  --arg actionMode "$ACTION_MODE" \
  --arg upgradeChannel "${UPGRADE_CHANNEL:-Preview}" \
  --arg modelProvider "${DEFAULT_MODEL_PROVIDER:-Anthropic}" \
  --arg incidentPlatform "$INC_PLATFORM" \
  --argjson connectors "$EXPECTED_CONNECTORS" \
  --argjson skills "$(echo "$SKILLS" | jq '[.[].metadata.name]')" \
  --argjson subagents "$(echo "$SUBAGENTS" | jq '[.[].metadata.name]')" \
  --argjson hooks "$(echo "$HOOKS_FOR_EXTRAS" "$HOOKS_FOR_PARAMS" | jq -sc 'add // [] | [.[] | .name // .metadata.name] | unique')" \
  --argjson prompts "$(echo "$PROMPTS_FOR_EXTRAS" "$PROMPTS_FOR_PARAMS" | jq -sc 'add // [] | [.[] | .name // .metadata.name] | unique')" \
  --argjson tasks "$(echo "$SCHEDULED_TASKS" | jq '[.[] | .metadata.name // .name]' 2>/dev/null || echo '[]')" \
  --argjson plans "$EXPECTED_PLANS" \
  --argjson repos "$(echo "$REPOS" | jq '[.[].name]' 2>/dev/null || echo '[]')" \
  '{
    "_scenario": $scenario,
    "agent": {
      "accessLevel": $accessLevel,
      "actionMode": $actionMode,
      "upgradeChannel": $upgradeChannel,
      "defaultModelProvider": $modelProvider,
      "incidentPlatform": $incidentPlatform
    },
    "connectors": $connectors,
    "skills": $skills,
    "subagents": $subagents,
    "hooks": $hooks,
    "commonPrompts": $prompts,
    "scheduledTasks": $tasks,
    "responsePlans": $plans,
    "repos": $repos
  }' > "${EXPORT_DIR}/expected-config.json"

_log "Wrote expected-config.json"

# ═══════ 3. config/ — all builder config as YAML files ═══════
_info "Writing config/ files (YAML)"

# Helper: resolve target dir — all items go to config/
resolve_config_dir() {
  local json="$1"
  echo "${EXPORT_DIR}/config"
}

# Skills — YAML metadata + separate .md for skillContent
SKILL_COUNT_EXP=0; SKILL_SKIP=0
if [[ $(echo "$SKILLS" | jq 'length') -gt 0 ]]; then
  SKILL_COUNT_INT=$(echo "$SKILLS" | jq 'length')
  for i in $(seq 0 $((SKILL_COUNT_INT - 1))); do
    sname=$(echo "$SKILLS" | jq -r --argjson i "$i" '.[$i].metadata.name')
    skill_json=$(echo "$SKILLS" | jq --argjson i "$i" '.[$i]')

    BASE=$(resolve_config_dir "$skill_json")
    if [[ -z "$BASE" ]]; then SKILL_SKIP=$((SKILL_SKIP + 1)); continue; fi
    SKILL_COUNT_EXP=$((SKILL_COUNT_EXP + 1))
    mkdir -p "${BASE}/skills"

    # Write skillContent to .md
    scontent=$(echo "$SKILLS" | jq -r --argjson i "$i" '.[$i].skillContent // ""')
    [[ -n "$scontent" ]] && printf '%s' "$scontent" > "${BASE}/skills/${sname}.md"
    # Write additionalFiles
    af_count=$(echo "$SKILLS" | jq --argjson i "$i" '.[$i].additionalFiles // [] | length')
    if [[ "$af_count" -gt 0 ]]; then
      mkdir -p "${BASE}/skills/${sname}"
      for j in $(seq 0 $((af_count - 1))); do
        afname=$(echo "$SKILLS" | jq -r --argjson i "$i" --argjson j "$j" '.[$i].additionalFiles[$j].name // .[$i].additionalFiles[$j].path // "file-\($j)"')
        afcontent=$(echo "$SKILLS" | jq -r --argjson i "$i" --argjson j "$j" '.[$i].additionalFiles[$j].content // ""')
        printf '%s' "$afcontent" > "${BASE}/skills/${sname}/${afname}"
      done
    fi
    # Write YAML with file reference for skillContent
    echo "$SKILLS" | jq --argjson i "$i" '.[$i] |
      .skillContent = ("skills/" + .metadata.name + ".md") |
      if (.additionalFiles | length) > 0 then
        .additionalFiles = [.additionalFiles[] | .content = (.metadata.name + "/" + (.name // .path // "file"))]
      else . end' | json2yaml > "${BASE}/skills/${sname}.yaml"
  done
  _log "  skills: ${SKILL_COUNT_EXP} file(s)"
fi

# Subagents — YAML metadata + separate .md for instructions
SA_COUNT_EXP=0; SA_SKIP=0
if [[ $(echo "$SUBAGENTS" | jq 'length') -gt 0 ]]; then
  SUBAGENT_COUNT_INT=$(echo "$SUBAGENTS" | jq 'length')
  for i in $(seq 0 $((SUBAGENT_COUNT_INT - 1))); do
    saname=$(echo "$SUBAGENTS" | jq -r --argjson i "$i" '.[$i].metadata.name')
    sa_json=$(echo "$SUBAGENTS" | jq --argjson i "$i" '.[$i]')

    BASE=$(resolve_config_dir "$sa_json")
    if [[ -z "$BASE" ]]; then SA_SKIP=$((SA_SKIP + 1)); continue; fi
    SA_COUNT_EXP=$((SA_COUNT_EXP + 1))
    mkdir -p "${BASE}/subagents"

    instructions=$(echo "$SUBAGENTS" | jq -r --argjson i "$i" '.[$i].spec.instructions // ""')
    [[ -n "$instructions" ]] && printf '%s' "$instructions" > "${BASE}/subagents/${saname}.instructions.md"
    handoff=$(echo "$SUBAGENTS" | jq -r --argjson i "$i" '.[$i].spec.handoffDescription // ""')
    [[ ${#handoff} -gt 200 ]] && printf '%s' "$handoff" > "${BASE}/subagents/${saname}.handoff.md"
    echo "$SUBAGENTS" | jq --argjson i "$i" '.[$i] |
      if (.spec.instructions // "" | length) > 0 then
        .spec.instructions = ("subagents/" + .metadata.name + ".instructions.md")
      else . end |
      if (.spec.handoffDescription // "" | length) > 200 then
        .spec.handoffDescription = (.metadata.name + ".handoff.md")
      else . end' | json2yaml > "${BASE}/subagents/${saname}.yaml"
  done
  _log "  subagents: ${SA_COUNT_EXP} file(s)"
fi

# Tools — YAML
T_COUNT_EXP=0; T_SKIP=0
if [[ $(echo "$TOOLS" | jq 'length') -gt 0 ]]; then
  for i in $(seq 0 $(($(echo "$TOOLS" | jq 'length') - 1))); do
    tname=$(echo "$TOOLS" | jq -r --argjson i "$i" '.[$i].metadata.name')
    tool_json=$(echo "$TOOLS" | jq --argjson i "$i" '.[$i]')
    BASE=$(resolve_config_dir "$tool_json")
    if [[ -z "$BASE" ]]; then T_SKIP=$((T_SKIP + 1)); continue; fi
    T_COUNT_EXP=$((T_COUNT_EXP + 1))
    mkdir -p "${BASE}/tools"
    write_yaml "${BASE}/tools/${tname}.yaml" "$tool_json"
  done
  _log "  tools: ${T_COUNT_EXP} file(s)"
fi

# Hooks (from ARM or data-plane) → YAML
ALL_HOOKS=$(echo "$HOOKS_FOR_PARAMS" "$HOOKS_FOR_EXTRAS" | jq -sc 'add // []')
if [[ $(echo "$ALL_HOOKS" | jq 'length') -gt 0 ]]; then
  mkdir -p "${EXPORT_DIR}/config/hooks"
  for i in $(seq 0 $(($(echo "$ALL_HOOKS" | jq 'length') - 1))); do
    hname=$(echo "$ALL_HOOKS" | jq -r --argjson i "$i" '.[$i].metadata.name // .[$i].name')
    echo "$ALL_HOOKS" | jq --argjson i "$i" '.[$i]' | json2yaml > "${EXPORT_DIR}/config/hooks/${hname}.yaml"
  done
  _log "  hooks: $(echo "$ALL_HOOKS" | jq 'length') hook(s)"
fi

# Common prompts — YAML + .md for prompt content
ALL_PROMPTS=$(echo "$PROMPTS_FOR_PARAMS" "$PROMPTS_FOR_EXTRAS" | jq -sc 'add // []')
if [[ $(echo "$ALL_PROMPTS" | jq 'length') -gt 0 ]]; then
  mkdir -p "${EXPORT_DIR}/config/common-prompts"
  for i in $(seq 0 $(($(echo "$ALL_PROMPTS" | jq 'length') - 1))); do
    pname=$(echo "$ALL_PROMPTS" | jq -r --argjson i "$i" '.[$i].metadata.name // .[$i].name')
    prompt_text=$(echo "$ALL_PROMPTS" | jq -r --argjson i "$i" '.[$i].spec.prompt // .[$i].properties.content // .[$i].properties.prompt // ""')
    [[ -n "$prompt_text" ]] && printf '%s' "$prompt_text" > "${EXPORT_DIR}/config/common-prompts/${pname}.md"
    echo "$ALL_PROMPTS" | jq --argjson i "$i" '.[$i]' | json2yaml > "${EXPORT_DIR}/config/common-prompts/${pname}.yaml"
  done
  _log "  common-prompts: $(echo "$ALL_PROMPTS" | jq 'length') prompt(s)"
fi

# Scheduled tasks → YAML (automations/)
write_config_items "scheduled-tasks" "$SCHEDULED_TASKS" ".metadata.name" "automations"

# Incident filters → YAML (automations/)
write_config_items "incident-filters" "$INCIDENT_FILTERS" ".metadata.name" "automations"

# HTTP triggers → YAML (automations/)
if [[ $(echo "$HTTP_TRIGGERS" | jq 'length') -gt 0 ]]; then
  mkdir -p "${EXPORT_DIR}/automations/http-triggers"
  for i in $(seq 0 $(($(echo "$HTTP_TRIGGERS" | jq 'length') - 1))); do
    tname=$(echo "$HTTP_TRIGGERS" | jq -r --argjson i "$i" '.[$i].name')
    echo "$HTTP_TRIGGERS" | jq --argjson i "$i" '.[$i]' | json2yaml > "${EXPORT_DIR}/automations/http-triggers/${tname}.yaml"
  done
  _log "  http-triggers: $(echo "$HTTP_TRIGGERS" | jq 'length') trigger(s)"
fi

# Plugin configs → YAML
ALL_PLUGINS=$(echo "$PLUGINS_FOR_PARAMS" "$PLUGINS_FOR_EXTRAS" | jq -sc 'add // []')
write_config_items "plugin-configs" "$ALL_PLUGINS" ".metadata.name // .name"

# Incident platforms → YAML (automations/)
if [[ $(echo "$INCIDENT_PLATFORMS" | jq 'length') -gt 0 ]]; then
  mkdir -p "${EXPORT_DIR}/automations/incident-platforms"
  for i in $(seq 0 $(($(echo "$INCIDENT_PLATFORMS" | jq 'length') - 1))); do
    ipname=$(echo "$INCIDENT_PLATFORMS" | jq -r --argjson i "$i" '.[$i].name')
    echo "$INCIDENT_PLATFORMS" | jq --argjson i "$i" '.[$i]' | json2yaml > "${EXPORT_DIR}/automations/incident-platforms/${ipname}.yaml"
    # Check if this platform needs a connectionKey (PagerDuty, ServiceNow)
    ptype=$(echo "$INCIDENT_PLATFORMS" | jq -r --argjson i "$i" '.[$i].spec.platformType // .[$i].spec.incidentPlatform // ""')
    case "$ptype" in
      PagerDuty|ServiceNow)
        has_key=$(python3 -c "import yaml; d=yaml.safe_load(open('${EXPORT_DIR}/automations/incident-platforms/${ipname}.yaml')); print('yes' if d.get('spec',{}).get('connectionKey') else 'no')" 2>/dev/null || echo "no")
        if [[ "$has_key" != "yes" ]]; then
          # Add connectionKey as env var reference so assemble-agent.sh substitutes it
          env_var="$(echo "${ptype}" | tr '[:lower:]' '[:upper:]')_API_KEY"
          python3 -c "
import yaml
f='${EXPORT_DIR}/automations/incident-platforms/${ipname}.yaml'
with open(f) as fh: d = yaml.safe_load(fh)
d.setdefault('spec',{})['connectionKey'] = '\${${env_var}}'
with open(f,'w') as fh: yaml.dump(d, fh, default_flow_style=False, sort_keys=False)
" 2>/dev/null
          # Add env var to secrets file (uncommented so source picks it up)
          echo "" >> "${EXPORT_DIR}/connectors.secrets.env"
          echo "# ${ptype} API key — required for incident platform" >> "${EXPORT_DIR}/connectors.secrets.env"
          echo "${env_var}=" >> "${EXPORT_DIR}/connectors.secrets.env"
          _warn "${ptype} connectionKey is redacted by API."
          _warn "  Set ${env_var} in ${EXPORT_DIR}/connectors.secrets.env before deploy."
        fi
        ;;
    esac
  done
  _log "  incident-platforms: $(echo "$INCIDENT_PLATFORMS" | jq 'length') platform(s)"
fi

# Repos → YAML
if [[ $(echo "$REPOS" | jq 'length') -gt 0 ]]; then
  mkdir -p "${EXPORT_DIR}/config/repos"
  for i in $(seq 0 $(($(echo "$REPOS" | jq 'length') - 1))); do
    rname=$(echo "$REPOS" | jq -r --argjson i "$i" '.[$i].name')
    echo "$REPOS" | jq --argjson i "$i" '.[$i]' | json2yaml > "${EXPORT_DIR}/config/repos/${rname}.yaml"
  done
  _log "  repos: $(echo "$REPOS" | jq 'length') repo(s)"
fi

# Plugin marketplaces + installations → YAML
if [[ $(echo "$PLUGIN_MARKETPLACES" | jq 'length') -gt 0 ]]; then
  mkdir -p "${EXPORT_DIR}/config/plugins/marketplaces"
  for i in $(seq 0 $(($(echo "$PLUGIN_MARKETPLACES" | jq 'length') - 1))); do
    mname=$(echo "$PLUGIN_MARKETPLACES" | jq -r --argjson i "$i" '.[$i].name')
    echo "$PLUGIN_MARKETPLACES" | jq --argjson i "$i" '.[$i]' | json2yaml > "${EXPORT_DIR}/config/plugins/marketplaces/${mname}.yaml"
  done
fi
if [[ $(echo "$PLUGIN_INSTALLATIONS" | jq 'length') -gt 0 ]]; then
  mkdir -p "${EXPORT_DIR}/config/plugins/installations"
  for i in $(seq 0 $(($(echo "$PLUGIN_INSTALLATIONS" | jq 'length') - 1))); do
    iname=$(echo "$PLUGIN_INSTALLATIONS" | jq -r --argjson i "$i" '.[$i].name')
    echo "$PLUGIN_INSTALLATIONS" | jq --argjson i "$i" '.[$i]' | json2yaml > "${EXPORT_DIR}/config/plugins/installations/${iname}.yaml"
  done
fi

# ═══════ 4. data/ — knowledge, memories, repo instructions ═══════

_info "Writing data/ files"

DATA_DIR="${EXPORT_DIR}/data"

# Ensure data directories exist so users know where to place files
mkdir -p "${DATA_DIR}/knowledge"
mkdir -p "${DATA_DIR}/synthesized-knowledge"
touch "${DATA_DIR}/knowledge/.gitkeep"
touch "${DATA_DIR}/synthesized-knowledge/.gitkeep"

if [[ $(echo "$KNOWLEDGE" | jq 'length') -gt 0 ]]; then
  mkdir -p "${DATA_DIR}"
  echo "$KNOWLEDGE" | jq '.' > "${DATA_DIR}/knowledge.json"
  _log "  knowledge.json: $(echo "$KNOWLEDGE" | jq 'length') document(s)"
fi

if [[ $(echo "$KNOWLEDGE_ITEMS" | jq 'length') -gt 0 ]]; then
  mkdir -p "${DATA_DIR}"
  echo "$KNOWLEDGE_ITEMS" | jq '.' > "${DATA_DIR}/knowledge-items.json"
  _log "  knowledge-items.json: $(echo "$KNOWLEDGE_ITEMS" | jq 'length') item(s)"
fi

if [[ $(echo "$SYNTHESIZED_KNOWLEDGE" | jq 'length') -gt 0 ]]; then
  mkdir -p "${DATA_DIR}"
  echo "$SYNTHESIZED_KNOWLEDGE" | jq '.' > "${DATA_DIR}/synthesized-knowledge.json"
  _log "  synthesized-knowledge.json: $(echo "$SYNTHESIZED_KNOWLEDGE" | jq 'length') file(s)"
fi

if [[ $(echo "$REPO_INSTRUCTIONS" | jq 'length') -gt 0 ]]; then
  mkdir -p "${DATA_DIR}"
  echo "$REPO_INSTRUCTIONS" | jq '.' > "${DATA_DIR}/repo-instructions.json"
  _log "  repo-instructions.json: $(echo "$REPO_INSTRUCTIONS" | jq 'length') set(s)"
fi

# Move downloaded files into data/ if they were downloaded
if [[ "$DOWNLOAD_FILES" == "true" && -d "$FILES_DIR" ]]; then
  for subdir in knowledge knowledge-items synthesized-knowledge repo-instructions; do
    if [[ -d "${FILES_DIR}/${subdir}" ]]; then
      mkdir -p "${DATA_DIR}/${subdir}"
      cp -r "${FILES_DIR}/${subdir}/." "${DATA_DIR}/${subdir}/" 2>/dev/null || true
    fi
  done
  # Clean up temp files dir if it was separate
  [[ "$FILES_DIR" != "$DATA_DIR" && "$FILES_DIR" != "${EXPORT_DIR}/data" ]] && rm -rf "$FILES_DIR" 2>/dev/null || true
fi

echo

# ═══════ Final summary ═══════

_info "Export complete"
echo
echo "  ${EXPORT_DIR}/"
echo "    agent.json               ← Agent identity + settings"
echo "    connectors.json          ← Connector toggles + entries (secrets → env var refs)"
echo "    connectors.secrets.env   ← Actual secrets (gitignored)"
echo "    config/"
for d in skills subagents tools hooks common-prompts plugin-configs repos; do
  [[ -d "${EXPORT_DIR}/config/${d}" ]] && printf '      %-24s ← %s file(s)\n' "${d}/" "$(find "${EXPORT_DIR}/config/${d}" -maxdepth 1 -name '*.yaml' | wc -l | tr -d ' ')"
done
if [[ -d "${EXPORT_DIR}/automations" ]]; then
  echo "    automations/"
  for d in scheduled-tasks incident-filters http-triggers incident-platforms; do
    [[ -d "${EXPORT_DIR}/automations/${d}" ]] && printf '      %-24s ← %s file(s)\n' "${d}/" "$(find "${EXPORT_DIR}/automations/${d}" -maxdepth 1 -name '*.yaml' | wc -l | tr -d ' ')"
  done
fi
[[ -d "${DATA_DIR}" ]] && echo "    data/                    ← Knowledge, memories, repo instructions"
[[ -f "${EXPORT_DIR}/admin-settings.json" ]] && echo "    admin-settings.json      ← Cross-tenant admin users"
echo
echo "Next steps:"
echo "  1. Review agent.json — change identity.agentName, identity.resourceGroup, identity.location"
echo "  2. Update connectors.json — change resource IDs for target environment"
echo "  3. Fill connectors.secrets.env with real tokens for the target"
echo "  4. Edit config/ YAML files — skills, subagents, tools, hooks as needed"
echo "  Deploy with:"
echo "    ./clone-agent.sh --source ${EXPORT_DIR} --agent-name <new-name> --resource-group <rg>"
echo
