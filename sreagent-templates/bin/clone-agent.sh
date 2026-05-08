#!/usr/bin/env bash
# clone-agent.sh — Clone an SRE Agent to another environment.
#
# All-in-one: exports config from a live agent (or reads an exported directory),
# validates everything (7 checks including experience quality), and deploys.
#
# Accepts:
#   (a) Live agent coordinates → runs export-agent.sh + assemble + deploy
#   (b) Export directory (from export-agent.sh) → runs assemble + deploy
#   (c) Legacy parameters.json + extras.json → validates + deploys
#
# Usage:
#   # Clone from a live agent (export + assemble + validate + deploy)
#   ./clone-agent.sh --from-agent <name> --from-rg <rg> --from-sub <sub> \
#     --agent-name <new-name> --resource-group <new-rg> --location <region>
#
#   # Clone from an exported directory
#   ./clone-agent.sh --source my-agent-export/ --agent-name <new-name> --resource-group <new-rg>
#
#   # Dry run — validate only, no deployment
#   ./clone-agent.sh --source my-agent-export/ --agent-name <new> --resource-group <rg> --validate-only

set -euo pipefail

# ─────────────────────────── Argument parsing ───────────────────────────
usage() {
  cat <<EOF
Usage: $0 --source <dir-or-file> --agent-name <name> --resource-group <rg> [options]

Required:
  --source              Export directory (with agent.json) OR legacy parameters.json file
                        OR use --from-agent/--from-rg/--from-sub to export from a live agent
  --agent-name          New agent name for the clone
  --resource-group      Resource group for the cloned agent

Live agent source (alternative to --source):
  --from-agent          Source agent name to clone from
  --from-rg             Source agent resource group
  --from-sub            Source agent subscription ID

Optional:
  --extras              Extras file (only needed with legacy .parameters.json source)
  --secrets             Secrets env file (only with directory source; default: <dir>/connectors.secrets.env)
  --location            Target region (default: inherit from source)
  --target-resource-groups  Comma-separated RGs the clone should monitor
  --subscription        Target subscription (default: current az account)
  --access-level        Override access level (High/Low)
  --action-mode         Override action mode (Review/Automatic)
  --override            key=value override (repeatable). e.g.:
                          --override connectors.0.properties.dataSource=/subscriptions/.../new-ai
  --validate-only       Run all validation checks without deploying
  --skip-extras         Deploy Bicep only, skip data-plane config
  -h, --help            Show this help
EOF
  exit "${1:-0}"
}

SOURCE="" EXTRAS="" SECRETS="" NEW_AGENT="" NEW_RG="" NEW_LOC="" NEW_TARGET_RGS=""
NEW_SUB="" NEW_ACCESS="" NEW_ACTION="" VALIDATE_ONLY=false SKIP_EXTRAS=false
FROM_AGENT="" FROM_RG="" FROM_SUB=""
declare -a OVERRIDES=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source)                  SOURCE="$2"; shift 2 ;;
    --from-agent)              FROM_AGENT="$2"; shift 2 ;;
    --from-rg)                 FROM_RG="$2"; shift 2 ;;
    --from-sub)                FROM_SUB="$2"; shift 2 ;;
    --extras)                  EXTRAS="$2"; shift 2 ;;
    --secrets)                 SECRETS="$2"; shift 2 ;;
    --agent-name)              NEW_AGENT="$2"; shift 2 ;;
    --resource-group)          NEW_RG="$2"; shift 2 ;;
    --location)                NEW_LOC="$2"; shift 2 ;;
    --target-resource-groups)  NEW_TARGET_RGS="$2"; shift 2 ;;
    --subscription)            NEW_SUB="$2"; shift 2 ;;
    --access-level)            NEW_ACCESS="$2"; shift 2 ;;
    --action-mode)             NEW_ACTION="$2"; shift 2 ;;
    --override)                OVERRIDES+=("$2"); shift 2 ;;
    --validate-only)           VALIDATE_ONLY=true; shift ;;
    --skip-extras)             SKIP_EXTRAS=true; shift ;;
    -h|--help)                 usage 0 ;;
    *)                         echo "Unknown option: $1" >&2; usage 1 ;;
  esac
done

[[ -n "$SOURCE" || -n "$FROM_AGENT" ]] || { echo "Error: --source or --from-agent is required" >&2; usage 1; }
[[ -n "$NEW_AGENT" ]] || { echo "Error: --agent-name is required" >&2; usage 1; }
[[ -n "$NEW_RG" ]]    || { echo "Error: --resource-group is required" >&2; usage 1; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IS_DIR_SOURCE=false

# ── If --from-agent, export from live agent first ──
if [[ -n "$FROM_AGENT" ]]; then
  [[ -n "$FROM_RG" ]] || { echo "Error: --from-rg required with --from-agent" >&2; exit 1; }
  [[ -n "$FROM_SUB" ]] || FROM_SUB=$(az account show --query id -o tsv 2>/dev/null)
  [[ -n "$FROM_SUB" ]] || { echo "Error: --from-sub required (or az login first)" >&2; exit 1; }

  EXPORT_DIR=$(mktemp -d "${FROM_AGENT}-clone-export.XXXXXX")
  echo "── Exporting from live agent: ${FROM_AGENT} ──"
  bash "${SCRIPT_DIR}/export-agent.sh" \
    --subscription "$FROM_SUB" \
    --resource-group "$FROM_RG" \
    --agent-name "$FROM_AGENT" \
    --output "$EXPORT_DIR/${FROM_AGENT}" \
    --include-all
  SOURCE="${EXPORT_DIR}/${FROM_AGENT}"
  trap 'rm -rf "$EXPORT_DIR"' EXIT
  echo
fi

# Detect source type: directory (new layout) vs file (legacy)
if [[ -d "$SOURCE" ]]; then
  IS_DIR_SOURCE=true
  [[ -f "${SOURCE}/agent.json" ]] || { echo "Error: ${SOURCE}/agent.json not found" >&2; exit 1; }

  # Apply overrides to agent.json before assembling
  AGENT_JSON_TMP=$(mktemp)
  cp "${SOURCE}/agent.json" "$AGENT_JSON_TMP"

  # Override identity fields from CLI args
  jq --arg name "$NEW_AGENT" --arg rg "$NEW_RG" \
    '.identity.agentName = $name | .identity.resourceGroup = $rg' \
    "$AGENT_JSON_TMP" > "${AGENT_JSON_TMP}.tmp" && mv "${AGENT_JSON_TMP}.tmp" "$AGENT_JSON_TMP"

  [[ -n "$NEW_LOC" ]] && jq --arg v "$NEW_LOC" '.identity.location = $v' "$AGENT_JSON_TMP" > "${AGENT_JSON_TMP}.tmp" && mv "${AGENT_JSON_TMP}.tmp" "$AGENT_JSON_TMP"
  [[ -n "$NEW_ACCESS" ]] && jq --arg v "$NEW_ACCESS" '.access.accessLevel = $v' "$AGENT_JSON_TMP" > "${AGENT_JSON_TMP}.tmp" && mv "${AGENT_JSON_TMP}.tmp" "$AGENT_JSON_TMP"
  [[ -n "$NEW_ACTION" ]] && jq --arg v "$NEW_ACTION" '.access.actionMode = $v' "$AGENT_JSON_TMP" > "${AGENT_JSON_TMP}.tmp" && mv "${AGENT_JSON_TMP}.tmp" "$AGENT_JSON_TMP"
  [[ -n "$NEW_SUB" ]] && jq --arg v "$NEW_SUB" '.identity.subscription = $v' "$AGENT_JSON_TMP" > "${AGENT_JSON_TMP}.tmp" && mv "${AGENT_JSON_TMP}.tmp" "$AGENT_JSON_TMP"

  if [[ -n "$NEW_TARGET_RGS" ]]; then
    IFS=',' read -ra TGT_ARRAY <<< "$NEW_TARGET_RGS"
    TGT_JSON=$(printf '%s\n' "${TGT_ARRAY[@]}" | jq -R . | jq -sc .)
    jq --argjson v "$TGT_JSON" '.identity.targetResourceGroups = $v' "$AGENT_JSON_TMP" > "${AGENT_JSON_TMP}.tmp" && mv "${AGENT_JSON_TMP}.tmp" "$AGENT_JSON_TMP"
  fi

  # Write modified agent.json temporarily for assembly
  CLONE_SOURCE_DIR=$(mktemp -d)
  cp -r "${SOURCE}/." "$CLONE_SOURCE_DIR/"
  cp "$AGENT_JSON_TMP" "${CLONE_SOURCE_DIR}/agent.json"
  rm -f "$AGENT_JSON_TMP"

  # Run assemble to produce parameters.json + extras.json
  echo "── Assembling from directory layout ──"
  ASSEMBLE_ARGS=("$CLONE_SOURCE_DIR" --output "${CLONE_SOURCE_DIR}/assembled")
  [[ -n "$SECRETS" ]] && ASSEMBLE_ARGS+=(--secrets "$SECRETS")
  bash "${SCRIPT_DIR}/../bicep/assemble-agent.sh" "${ASSEMBLE_ARGS[@]}"

  SOURCE="${CLONE_SOURCE_DIR}/assembled.parameters.json"
  [[ -z "$EXTRAS" ]] && EXTRAS="${CLONE_SOURCE_DIR}/assembled.extras.json"
  trap 'rm -rf "$CLONE_SOURCE_DIR"' EXIT
else
  [[ -f "$SOURCE" ]] || { echo "Error: source not found: $SOURCE" >&2; exit 1; }
  [[ -z "$EXTRAS" || -f "$EXTRAS" ]] || { echo "Error: extras file not found: $EXTRAS" >&2; exit 1; }
fi

command -v jq >/dev/null || { echo "Error: jq is required" >&2; exit 1; }
command -v az >/dev/null || { echo "Error: az CLI is required" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ERRORS=0
WARNINGS=0

_log()  { echo "  $*"; }
_info() { echo "── $* ──"; }
_ok()   { echo "  ✓ $*"; }
_warn() { echo "  ⚠ $*"; WARNINGS=$((WARNINGS + 1)); }
_err()  { echo "  ✗ $*" >&2; ERRORS=$((ERRORS + 1)); }

# ─────────────────── Step 1: Read source configuration ───────────────────

_info "Step 1/6: Reading source configuration"

SRC_AGENT=$(jq -r '.parameters.agentName.value' "$SOURCE")
SRC_RG=$(jq -r '.parameters.agentResourceGroupName.value' "$SOURCE")
SRC_LOC=$(jq -r '.parameters.location.value // "eastus2"' "$SOURCE")
SRC_ACCESS=$(jq -r '.parameters.accessLevel.value // "Low"' "$SOURCE")
SRC_ACTION=$(jq -r '.parameters.actionMode.value // "Review"' "$SOURCE")

_log "Source agent:    ${SRC_AGENT} (${SRC_RG}, ${SRC_LOC})"
_log "Clone target:    ${NEW_AGENT} (${NEW_RG}, ${NEW_LOC:-$SRC_LOC})"

# Resolve defaults
[[ -n "$NEW_LOC" ]]    || NEW_LOC="$SRC_LOC"
[[ -n "$NEW_ACCESS" ]] || NEW_ACCESS="$SRC_ACCESS"
[[ -n "$NEW_ACTION" ]] || NEW_ACTION="$SRC_ACTION"
[[ -n "$NEW_SUB" ]]    || NEW_SUB=$(az account show --query id -o tsv 2>/dev/null)

echo

# ─────────────────── Step 2: Validate target environment ───────────────────

_info "Step 2/6: Validating target environment"

# 2a. Agent name format
if [[ "$NEW_AGENT" =~ ^[a-z][a-z0-9-]{1,61}[a-z0-9]$ ]]; then
  _ok "Agent name '${NEW_AGENT}' is valid"
else
  _err "Agent name '${NEW_AGENT}' invalid — must be lowercase alphanumeric + hyphens, 3-63 chars"
fi

# 2b. Region is supported
ALLOWED_REGIONS=("swedencentral" "uksouth" "eastus2" "australiaeast")
if printf '%s\n' "${ALLOWED_REGIONS[@]}" | grep -qx "$NEW_LOC"; then
  _ok "Region '${NEW_LOC}' is supported"
else
  _err "Region '${NEW_LOC}' not supported. Allowed: ${ALLOWED_REGIONS[*]}"
fi

# 2c. Subscription is accessible
if az account show -s "$NEW_SUB" -o none 2>/dev/null; then
  _ok "Subscription ${NEW_SUB} is accessible"
else
  _err "Cannot access subscription ${NEW_SUB} — check az login"
fi

# 2d. Check if agent already exists in target
API_VERSION="2025-05-01-preview"
EXISTING=$(az rest -m GET \
  --url "https://management.azure.com/subscriptions/${NEW_SUB}/resourceGroups/${NEW_RG}/providers/Microsoft.App/agents/${NEW_AGENT}?api-version=${API_VERSION}" \
  -o json 2>/dev/null || echo "null")
if [[ "$EXISTING" != "null" && -n "$EXISTING" ]]; then
  _warn "Agent '${NEW_AGENT}' already exists in ${NEW_RG} — deployment will UPDATE it"
else
  _ok "Agent '${NEW_AGENT}' does not yet exist in ${NEW_RG}"
fi

# 2e. Target resource groups exist
if [[ -n "$NEW_TARGET_RGS" ]]; then
  IFS=',' read -ra TGT_ARRAY <<< "$NEW_TARGET_RGS"
  for trg in "${TGT_ARRAY[@]}"; do
    trg=$(echo "$trg" | xargs) # trim
    if [[ "$(az group exists -n "$trg" --subscription "$NEW_SUB" 2>/dev/null)" == "true" ]]; then
      _ok "Target RG '${trg}' exists"
    else
      _err "Target RG '${trg}' does not exist in subscription ${NEW_SUB}"
    fi
  done
  TARGET_RGS_JSON=$(printf '%s\n' "${TGT_ARRAY[@]}" | jq -R . | jq -sc .)
else
  # Inherit from source
  TARGET_RGS_JSON=$(jq -c '.parameters.targetResourceGroups.value // []' "$SOURCE")
  _warn "No --target-resource-groups specified — inheriting from source: $(echo "$TARGET_RGS_JSON" | jq -r 'join(", ")')"
  _warn "  Make sure these RGs exist in the target subscription!"
fi

# 2f. Access level / action mode valid
if [[ "$NEW_ACCESS" == "High" || "$NEW_ACCESS" == "Low" ]]; then
  _ok "Access level: ${NEW_ACCESS}"
else
  _err "Invalid access level '${NEW_ACCESS}' — must be High or Low"
fi
if [[ "$NEW_ACTION" == "Review" || "$NEW_ACTION" == "Automatic" ]]; then
  _ok "Action mode: ${NEW_ACTION}"
else
  _err "Invalid action mode '${NEW_ACTION}' — must be Review or Automatic"
fi

echo

# ─────────────────── Step 3: Validate exported config ───────────────────

_info "Step 3/6: Validating exported configuration"

# 3a. Check for EDIT_ME placeholders that haven't been filled
EDIT_ME_COUNT=$(jq '[.. | strings | select(test("EDIT_ME"))] | length' "$SOURCE" 2>/dev/null || echo 0)
if [[ "$EDIT_ME_COUNT" -gt 0 ]]; then
  _warn "${EDIT_ME_COUNT} EDIT_ME placeholder(s) found in parameters — review before deploying:"
  jq -r '[paths(type == "string" and test("EDIT_ME"))] | .[] | "    " + (map(tostring) | join("."))' "$SOURCE" 2>/dev/null || true
fi

if [[ -n "$EXTRAS" ]]; then
  EDIT_ME_EXTRAS=$(jq '[.. | strings | select(test("EDIT_ME"))] | length' "$EXTRAS" 2>/dev/null || echo 0)
  if [[ "$EDIT_ME_EXTRAS" -gt 0 ]]; then
    _warn "${EDIT_ME_EXTRAS} EDIT_ME placeholder(s) found in extras — review before deploying"
  fi
fi

# 3b. Connectors reference valid resource IDs
CONNECTOR_COUNT=$(jq '.parameters.connectors.value // [] | length' "$SOURCE")
for i in $(seq 0 $((CONNECTOR_COUNT - 1))); do
  cname=$(jq -r --argjson i "$i" '.parameters.connectors.value[$i].name' "$SOURCE")
  ctype=$(jq -r --argjson i "$i" '.parameters.connectors.value[$i].properties.dataConnectorType' "$SOURCE")
  dsrc=$(jq -r --argjson i "$i" '.parameters.connectors.value[$i].properties.dataSource // ""' "$SOURCE")

  # Validate AppInsights / LogAnalytics resource IDs exist
  if [[ "$ctype" == "AppInsights" || "$ctype" == "LogAnalytics" ]]; then
    if [[ "$dsrc" == /subscriptions/* ]]; then
      if az resource show --ids "$dsrc" -o none 2>/dev/null; then
        _ok "Connector '${cname}' (${ctype}): resource exists"
      else
        _warn "Connector '${cname}' (${ctype}): resource ${dsrc} not found — update dataSource for target environment"
      fi
    elif [[ "$dsrc" == *EDIT_ME* ]]; then
      _warn "Connector '${cname}' (${ctype}): dataSource has EDIT_ME placeholder"
    else
      _ok "Connector '${cname}' (${ctype}): ${dsrc}"
    fi
  else
    _ok "Connector '${cname}' (${ctype})"
  fi
done

# 3c. Skills reference valid tools
SKILL_COUNT=$(jq '.parameters.skills.value // [] | length' "$SOURCE")
if [[ "$SKILL_COUNT" -gt 0 ]]; then
  _ok "${SKILL_COUNT} skill(s) found"
fi

# 3d. Subagents reference valid handoffs
SUBAGENT_COUNT=$(jq '.parameters.subagents.value // [] | length' "$SOURCE")
if [[ "$SUBAGENT_COUNT" -gt 0 ]]; then
  _ok "${SUBAGENT_COUNT} subagent(s) found"
  SUBAGENT_NAMES=$(jq -r '.parameters.subagents.value[].metadata.name' "$SOURCE" | sort)
  for i in $(seq 0 $((SUBAGENT_COUNT - 1))); do
    sname=$(jq -r --argjson i "$i" '.parameters.subagents.value[$i].metadata.name' "$SOURCE")
    handoffs=$(jq -r --argjson i "$i" '.parameters.subagents.value[$i].spec.handoffs // [] | .[]' "$SOURCE" 2>/dev/null)
    for h in $handoffs; do
      if echo "$SUBAGENT_NAMES" | grep -qx "$h"; then
        _ok "Subagent '${sname}' handoff to '${h}' is valid"
      else
        _warn "Subagent '${sname}' handoff to '${h}' — target subagent not found in export"
      fi
    done
  done
fi

# 3e. Hooks, common prompts, plugin configs in parameters
PARAM_HOOK_COUNT=$(jq '.parameters.hooks.value // [] | length' "$SOURCE")
PARAM_PROMPT_COUNT=$(jq '.parameters.commonPrompts.value // [] | length' "$SOURCE")
PARAM_PLUGIN_COUNT=$(jq '.parameters.pluginConfigs.value // [] | length' "$SOURCE")
[[ "$PARAM_HOOK_COUNT" -gt 0 ]] && _ok "${PARAM_HOOK_COUNT} hook(s) in parameters (ARM-deployable)"
[[ "$PARAM_PROMPT_COUNT" -gt 0 ]] && _ok "${PARAM_PROMPT_COUNT} common prompt(s) in parameters (ARM-deployable)"
[[ "$PARAM_PLUGIN_COUNT" -gt 0 ]] && _ok "${PARAM_PLUGIN_COUNT} plugin config(s) in parameters (ARM-deployable)"

# 3f. Skills have correct shape (metadata.name + skillContent)
SKILL_COUNT=$(jq '.parameters.skills.value // [] | length' "$SOURCE")
if [[ "$SKILL_COUNT" -gt 0 ]]; then
  # Determine files directory for _file: references
  SOURCE_BASE="${SOURCE%.parameters.json}"
  CLONE_FILES_DIR="${SOURCE_BASE}-files"
  [[ -d "$CLONE_FILES_DIR" ]] || CLONE_FILES_DIR="$(dirname "$SOURCE")"

  for i in $(seq 0 $((SKILL_COUNT - 1))); do
    skname=$(jq -r --argjson i "$i" '.parameters.skills.value[$i].metadata.name // "unnamed"' "$SOURCE")
    sk_content=$(jq -r --argjson i "$i" '.parameters.skills.value[$i].skillContent // ""' "$SOURCE")
    has_tools=$(jq --argjson i "$i" '.parameters.skills.value[$i].metadata.spec.tools // [] | length > 0' "$SOURCE")

    # Check if content is a file reference
    if [[ "$sk_content" == _file:* ]]; then
      fpath="${CLONE_FILES_DIR}/${sk_content#_file:}"
      if [[ -f "$fpath" ]]; then
        _ok "Skill '${skname}': file ref → ${sk_content#_file:} ($(wc -c < "$fpath" | tr -d ' ') bytes)"
      else
        _err "Skill '${skname}': file ref → ${sk_content#_file:} NOT FOUND (expected at ${fpath})"
      fi
    elif [[ -n "$sk_content" ]]; then
      _ok "Skill '${skname}': has inline skillContent"
    else
      _warn "Skill '${skname}': missing skillContent"
    fi
    if [[ "$has_tools" == "true" ]]; then
      _ok "Skill '${skname}': has tool bindings"
    else
      _warn "Skill '${skname}': no tools bound"
    fi
  done
fi

# 3g. Subagents — check _file: references for instructions
SUBAGENT_COUNT_VAL=$(jq '.parameters.subagents.value // [] | length' "$SOURCE")
if [[ "$SUBAGENT_COUNT_VAL" -gt 0 ]]; then
  for i in $(seq 0 $((SUBAGENT_COUNT_VAL - 1))); do
    saname=$(jq -r --argjson i "$i" '.parameters.subagents.value[$i].metadata.name' "$SOURCE")
    sa_instr=$(jq -r --argjson i "$i" '.parameters.subagents.value[$i].spec.instructions // ""' "$SOURCE")
    if [[ "$sa_instr" == _file:* ]]; then
      fpath="${CLONE_FILES_DIR}/${sa_instr#_file:}"
      if [[ -f "$fpath" ]]; then
        _ok "Subagent '${saname}': instructions → ${sa_instr#_file:} ($(wc -c < "$fpath" | tr -d ' ') bytes)"
      else
        _err "Subagent '${saname}': instructions file NOT FOUND → ${fpath}"
      fi
    elif [[ -n "$sa_instr" ]]; then
      _ok "Subagent '${saname}': has inline instructions"
    else
      _warn "Subagent '${saname}': missing instructions"
    fi
  done
fi

echo

# ─────────────────── Step 4/7: Experience quality checks ───────────────────

_info "Step 4/7: Agent experience quality checks"
echo "  These checks ensure the agent will have a good user experience."
echo

# 4a. Must have at least 1 connector (otherwise agent can't observe anything)
TOTAL_CONNECTORS=$((CONNECTOR_COUNT + $(jq '.parameters.enableAppInsightsConnector.value // false | if . then 1 else 0 end' "$SOURCE" 2>/dev/null || echo 0) + $(jq '.parameters.enableLogAnalyticsConnector.value // false | if . then 1 else 0 end' "$SOURCE" 2>/dev/null || echo 0) + $(jq '.parameters.enableAzureMonitorConnector.value // false | if . then 1 else 0 end' "$SOURCE" 2>/dev/null || echo 0)))
if [[ "$TOTAL_CONNECTORS" -ge 2 ]]; then
  _ok "Connectors: ${TOTAL_CONNECTORS} configured (good — agent has observability data)"
elif [[ "$TOTAL_CONNECTORS" -eq 1 ]]; then
  _warn "Only 1 connector configured — consider adding a second (e.g., AppInsights + LogAnalytics) for better investigation quality"
else
  _err "No connectors configured — agent will have no observability data to work with"
fi

# 4b. Region — all 4 supported regions are equal
SUPPORTED_REGIONS=("eastus2" "swedencentral" "uksouth" "australiaeast")
if printf '%s\n' "${SUPPORTED_REGIONS[@]}" | grep -qx "$NEW_LOC"; then
  _ok "Region '${NEW_LOC}' is supported"
else
  _err "Region '${NEW_LOC}' not supported. Must be: eastus2, swedencentral, uksouth, or australiaeast"
fi

# 4d. Skills — at least one skill recommended
SKILL_CT=$(jq '.parameters.skills.value // [] | length' "$SOURCE" 2>/dev/null || echo 0)
if [[ "$SKILL_CT" -gt 0 ]]; then
  _ok "${SKILL_CT} skill(s) configured — agent has investigation playbooks"
else
  _warn "No skills configured — skills provide structured investigation playbooks. Consider adding at least one"
fi

# 4e. Access level + action mode coherence
if [[ "$NEW_ACCESS" == "High" && "$NEW_ACTION" == "Automatic" ]]; then
  _warn "accessLevel=High + actionMode=Automatic — agent can take actions WITHOUT human approval. Make sure this is intentional"
fi

# 4f. Feature flags — check if source agent had workspace tools + v2 loop enabled
if [[ "$IS_DIR_SOURCE" == "true" ]]; then
  # Read from agent.json featureFlags section
  WS_TOOLS=$(jq -r '.featureFlags.enableWorkspaceTools // "unknown"' "${CLONE_SOURCE_DIR}/agent.json" 2>/dev/null || echo "unknown")
  V2_LOOP=$(jq -r '.featureFlags.enableV2AgentLoop // "unknown"' "${CLONE_SOURCE_DIR}/agent.json" 2>/dev/null || echo "unknown")
  TASK_V2=$(jq -r '.featureFlags.enableTaskToolsV2 // "unknown"' "${CLONE_SOURCE_DIR}/agent.json" 2>/dev/null || echo "unknown")
else
  WS_TOOLS="unknown"; V2_LOOP="unknown"; TASK_V2="unknown"
fi

if [[ "$WS_TOOLS" == "true" ]]; then
  _ok "EnableWorkspaceTools: enabled (recommended for best experience)"
elif [[ "$WS_TOOLS" == "false" ]]; then
  _warn "EnableWorkspaceTools: OFF — workspace tools provide file ops, terminal, and project-aware investigations. Enable via portal Features page after deploy"
else
  _warn "EnableWorkspaceTools: could not determine — verify in portal Features page after deploy"
fi

if [[ "$V2_LOOP" == "true" ]]; then
  _ok "EnableV2AgentLoop: enabled (checkpoint-based resilience)"
elif [[ "$V2_LOOP" == "false" ]]; then
  _warn "EnableV2AgentLoop: OFF — the V2 agent loop provides better resilience and hook support. Enable via portal Features page after deploy"
fi

# 4g. Connector auth — flag each connector that needs credentials re-supplied
_log "Checking connector auth requirements..."
for i in $(seq 0 $((CONNECTOR_COUNT - 1))); do
  cname=$(jq -r --argjson i "$i" '.parameters.connectors.value[$i].name' "$SOURCE")
  ctype=$(jq -r --argjson i "$i" '.parameters.connectors.value[$i].properties.dataConnectorType' "$SOURCE")
  dsrc=$(jq -r --argjson i "$i" '.parameters.connectors.value[$i].properties.dataSource // ""' "$SOURCE")
  ident=$(jq -r --argjson i "$i" '.parameters.connectors.value[$i].properties.identity // "system"' "$SOURCE")

  case "$ctype" in
    AppInsights|LogAnalytics|AzureMonitor|MonitorClient)
      # Managed Identity — no user action needed if MI has RBAC on the resource
      _ok "Connector '${cname}' (${ctype}): uses Managed Identity — ensure MI has Reader on target resource"
      ;;
    Kusto|KustoUser|KustoDataIndexer|KustoClient|AzureMcpKusto)
      _ok "Connector '${cname}' (${ctype}): uses Managed Identity — ensure MI has Viewer on ADX cluster"
      ;;
    Mcp|DynatraceMcp|DatadogMcp|NewRelicMcp|SplunkMcp|ElasticsearchMcp|HawkeyeMcp)
      # MCP connectors typically need bearer tokens
      if [[ "$dsrc" == *EDIT_ME* || "$dsrc" == *'${' ]]; then
        _warn "Connector '${cname}' (${ctype}): needs BEARER TOKEN — fill in connectors.secrets.env or supply via portal"
      else
        _ok "Connector '${cname}' (${ctype}): MCP endpoint configured"
      fi
      ;;
    GitHubOAuth)
      _warn "Connector '${cname}' (${ctype}): needs GITHUB OAUTH sign-in — do this in portal after deploy, or set GITHUB_PAT env var"
      ;;
    AzureDevOpsOAuth|AzureDevOpsMcp)
      _warn "Connector '${cname}' (${ctype}): needs ADO AUTH — set ADO_PAT, ADO_USE_AAD=1, or ADO_USE_MI=1 before running apply-extras.sh"
      ;;
    Teams)
      _warn "Connector '${cname}' (${ctype}): needs PORTAL SETUP — configure Teams connector via portal API Connections blade"
      ;;
    Outlook)
      _warn "Connector '${cname}' (${ctype}): needs PORTAL SETUP — configure Outlook connector via portal API Connections blade"
      ;;
    IcM)
      _warn "Connector '${cname}' (${ctype}): needs CERT or MI auth — 1P only. See roles.yaml for setup options"
      ;;
    PagerDuty)
      _warn "Connector '${cname}' (${ctype}): needs PAGERDUTY API KEY — configure via portal Incident Platforms page"
      ;;
    ServiceNow)
      _warn "Connector '${cname}' (${ctype}): needs SERVICENOW CREDENTIALS — configure via portal Incident Platforms page"
      ;;
    Dgrep|GenevaMetrics|Ev2Mcp|S360Mcp)
      _ok "Connector '${cname}' (${ctype}): 1P connector — uses MI or Key Vault (grant UAMI access after deploy)"
      ;;
    *)
      _warn "Connector '${cname}' (${ctype}): unknown type — verify auth manually in portal"
      ;;
  esac
done

# 4h. LLM model — check it's a known model name

echo

# ─────────────────── Step 5/7: Validate extras (data-plane) ───────────────────

_info "Step 5/7: Validating extras configuration"

if [[ -n "$EXTRAS" ]]; then
  # Repos
  REPO_COUNT=$(jq '.repos // [] | length' "$EXTRAS")
  for i in $(seq 0 $((REPO_COUNT - 1))); do
    rname=$(jq -r --argjson i "$i" '.repos[$i].name' "$EXTRAS")
    rurl=$(jq -r --argjson i "$i" '.repos[$i].spec.url // ""' "$EXTRAS")
    rtype=$(jq -r --argjson i "$i" '.repos[$i].spec.type // "github"' "$EXTRAS")
    if [[ -z "$rurl" || "$rurl" == *EDIT_ME* ]]; then
      _warn "Repo '${rname}': URL needs to be set"
    else
      _ok "Repo '${rname}': ${rurl} (${rtype})"
    fi
  done

  # Hooks
  HOOK_COUNT=$(jq '(.hooks // []) | length' "$EXTRAS")
  _ok "${HOOK_COUNT} hook(s)"

  # Common prompts
  PROMPT_COUNT=$(jq '(.commonPrompts // []) | length' "$EXTRAS")
  _ok "${PROMPT_COUNT} common prompt(s)"

  # Incident platforms
  PLATFORM_COUNT=$(jq '(.incidentPlatforms // []) | length' "$EXTRAS")
  _ok "${PLATFORM_COUNT} incident platform(s)"

  # HTTP triggers
  TRIGGER_COUNT=$(jq '(.httpTriggers // []) | length' "$EXTRAS")
  if [[ "$TRIGGER_COUNT" -gt 0 ]]; then
    _ok "${TRIGGER_COUNT} HTTP trigger(s)"
    # Check if webhook bridge is needed
    HAS_BRIDGE=$(jq '.enableWebhookBridge // false' "$EXTRAS" 2>/dev/null || echo "false")
    if [[ "$HAS_BRIDGE" == "true" ]]; then
      _warn "Source had a webhook bridge — will be re-created if enableWebhookBridge=true in parameters"
    fi
  fi

  # MCP connectors (data-plane overlay needed for bearer tokens)
  MCP_COUNT=$(jq '(.connectors // []) | length' "$EXTRAS")
  if [[ "$MCP_COUNT" -gt 0 ]]; then
    _warn "${MCP_COUNT} MCP connector(s) need data-plane overlay (ARM strips bearer tokens)"
  fi

  # Knowledge & memories
  KNOWLEDGE_COUNT=$(jq '(.knowledge // []) | length' "$EXTRAS")
  KI_COUNT=$(jq '(.knowledgeItems // []) | length' "$EXTRAS")
  SYNTH_COUNT=$(jq '(.synthesizedKnowledge // []) | length' "$EXTRAS")
  RI_COUNT=$(jq '(.repoInstructions // []) | length' "$EXTRAS")
  if [[ "$KNOWLEDGE_COUNT" -gt 0 ]]; then
    _ok "${KNOWLEDGE_COUNT} knowledge document(s)"
    # Check if localPath references exist
    MISSING_FILES=$(jq '[.knowledge // [] | .[] | select(.localPath != null) | select(.localPath != "") | .localPath] | map(select(. as $p | $p | test("EDIT_ME") | not))' "$EXTRAS" 2>/dev/null || echo "[]")
    for lp in $(echo "$MISSING_FILES" | jq -r '.[]' 2>/dev/null); do
      if [[ ! -f "$lp" ]]; then
        _warn "Knowledge file not found: ${lp} — re-upload via portal or update localPath"
      fi
    done
  fi
  [[ "$KI_COUNT" -gt 0 ]] && _ok "${KI_COUNT} knowledge item(s) (KnowledgeText/File/WebPage)"
  [[ "$SYNTH_COUNT" -gt 0 ]] && _ok "${SYNTH_COUNT} synthesized knowledge file(s)"
  [[ "$RI_COUNT" -gt 0 ]] && _ok "${RI_COUNT} repo instruction set(s)"

  if [[ "$KNOWLEDGE_COUNT" -gt 0 || "$KI_COUNT" -gt 0 || "$SYNTH_COUNT" -gt 0 ]]; then
    _warn "Knowledge/memory items require re-upload after clone — not auto-deployed by Bicep"
  fi

  # Auth reminders
  HAS_GITHUB_REPOS=$(jq '[.repos // [] | .[].spec.type // "github" | select(. == "github")] | length > 0' "$EXTRAS")
  HAS_ADO_REPOS=$(jq '[.repos // [] | .[].spec.type // "" | select(test("ado|azuredevops"; "i"))] | length > 0' "$EXTRAS")
  if [[ "$HAS_GITHUB_REPOS" == "true" ]]; then
    _warn "GitHub repos detected — you'll need to sign in via OAuth or set GITHUB_PAT"
  fi
  if [[ "$HAS_ADO_REPOS" == "true" ]]; then
    _warn "ADO repos detected — set ADO_ORG + ADO_PAT (or ADO_USE_AAD=1 / ADO_USE_MI=1)"
  fi
else
  _log "No extras file provided — data-plane config will not be deployed"
fi

echo

# ─────────────────── Step 6/7: Validation summary ───────────────────

_info "Step 6/7: Validation summary"

echo
echo "  Errors:   ${ERRORS}"
echo "  Warnings: ${WARNINGS}"
echo

if [[ "$ERRORS" -gt 0 ]]; then
  echo "  ✗ Validation FAILED — fix ${ERRORS} error(s) before deploying"
  echo
  exit 1
fi

if [[ "$WARNINGS" -gt 0 ]]; then
  echo "  ⚠ Validation passed with ${WARNINGS} warning(s) — review before proceeding"
else
  echo "  ✓ All validation checks passed"
fi

if [[ "$VALIDATE_ONLY" == "true" ]]; then
  echo
  echo "  Validate-only mode — no deployment."
  exit 0
fi

echo
read -rp "  Proceed with deployment? [y/N] " confirm
[[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

echo

# ─────────────────── Step 7/7: Build clone parameters + deploy ───────────────────

_info "Step 7/7: Deploying clone"

# Build the clone parameters by substituting target values
CLONE_PARAMS=$(mktemp "${NEW_AGENT}-clone.XXXXXX.parameters.json")
trap 'rm -f "$CLONE_PARAMS"' EXIT

jq \
  --arg agent "$NEW_AGENT" \
  --arg rg "$NEW_RG" \
  --arg loc "$NEW_LOC" \
  --arg access "$NEW_ACCESS" \
  --arg action "$NEW_ACTION" \
  --argjson targetRgs "$TARGET_RGS_JSON" \
  '.parameters.agentName.value = $agent |
   .parameters.agentResourceGroupName.value = $rg |
   .parameters.location.value = $loc |
   .parameters.accessLevel.value = $access |
   .parameters.actionMode.value = $action |
   .parameters.targetResourceGroups.value = $targetRgs |
   del(._exported_from)' \
  "$SOURCE" > "$CLONE_PARAMS"

# Apply any --override key=value pairs
for ov in "${OVERRIDES[@]}"; do
  key="${ov%%=*}"
  val="${ov#*=}"
  _log "Applying override: ${key} = ${val}"
  # Convert dotted key to jq path: connectors.0.properties.dataSource → .parameters.connectors.value[0].properties.dataSource
  jq_path=".parameters.$(echo "$key" | sed 's/\.\([0-9][0-9]*\)/[\1]/g; s/^\.//')"
  CLONE_PARAMS_TMP=$(mktemp)
  if jq --arg v "$val" "${jq_path} = \$v" "$CLONE_PARAMS" > "$CLONE_PARAMS_TMP" 2>/dev/null; then
    mv "$CLONE_PARAMS_TMP" "$CLONE_PARAMS"
  else
    rm -f "$CLONE_PARAMS_TMP"
    _warn "Override '${key}' could not be applied — path not found"
  fi
done

_log "Clone parameters written to ${CLONE_PARAMS}"
echo

# 6a. Deploy via deploy.sh (Bicep — ARM resources)
_log "Running deploy.sh..."
if [[ -f "${SCRIPT_DIR}/deploy.sh" ]]; then
  bash "${SCRIPT_DIR}/deploy.sh" "$CLONE_PARAMS" "${NEW_AGENT}-clone-$(date +%Y%m%d-%H%M%S)"
else
  _warn "deploy.sh not found at ${SCRIPT_DIR}/deploy.sh"
  _log "Running az deployment directly..."
  az deployment sub create \
    --location "$NEW_LOC" \
    --name "${NEW_AGENT}-clone-$(date +%Y%m%d-%H%M%S)" \
    --template-file "${SCRIPT_DIR}/../bicep/main.bicep" \
    --parameters "@${CLONE_PARAMS}" \
    --output json
fi

echo

# 6b. Apply extras (data-plane — hooks, repos, knowledge, etc.)
if [[ "$SKIP_EXTRAS" == "false" && -n "$EXTRAS" ]]; then
  _log "Running apply-extras.sh..."
  if [[ -f "${SCRIPT_DIR}/../bicep/apply-extras.sh" ]]; then
    bash "${SCRIPT_DIR}/../bicep/apply-extras.sh" "$NEW_SUB" "$NEW_RG" "$NEW_AGENT" "$EXTRAS"
  else
    _warn "apply-extras.sh not found — data-plane config not applied"
    _log "Run manually: ./apply-extras.sh ${NEW_SUB} ${NEW_RG} ${NEW_AGENT} ${EXTRAS}"
  fi
fi

echo
_info "Clone complete"
echo
echo "  Source:  ${SRC_AGENT} (${SRC_LOC})"
echo "  Clone:   ${NEW_AGENT} (${NEW_LOC})"
echo "  Portal:  https://sre.azure.com/#/agent/${NEW_SUB}/${NEW_RG}/${NEW_AGENT}"
echo
echo "Post-clone checklist:"
echo "  □ Verify connectors are healthy (portal → Connectors)"
echo "  □ Enable feature flags in portal → Features settings:"
echo "      EnableWorkspaceTools, EnableV2AgentLoop, EnableTaskToolsV2"
echo "  □ Set LLM model provider in portal Settings (Anthropic recommended)"
echo "  □ Sign in to GitHub/ADO if repos are configured"
echo "  □ Re-upload knowledge documents (AgentMemory uploads)"
echo "  □ Re-create knowledge items (KnowledgeText/File/WebPage)"
echo "  □ Re-upload synthesized knowledge (POST tar.gz to /api/v1/WorkspaceMemory/synthesized-knowledge)"
echo "  □ Re-upload repo instructions (apply-extras.sh handles these)"
echo "  □ Test a sample investigation to confirm skills + tools work"
echo
