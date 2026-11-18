#!/usr/bin/env bash
# assemble-agent.sh — Reconstruct deploy-ready files from exported directory layout.
#
# Reads the structured directory produced by export-agent.sh and assembles:
#   <dir>.parameters.json  — Bicep-deployable (for deploy.sh)
#   <dir>.extras.json      — Data-plane config (for apply-extras.sh)
#
# Usage:
#   ./assemble-agent.sh <export-directory> [--secrets <env-file>]
#   ./assemble-agent.sh my-agent-export
#   ./assemble-agent.sh my-agent-export --secrets connectors.secrets.env
#
# The directory must contain agent.json. All other files are optional.
# File references in config/ JSONs (paths to .md files) are resolved inline.

set -euo pipefail

usage() {
  cat <<EOF
Usage: $0 <export-directory> [options]

Required:
  <export-directory>     Directory created by export-agent.sh

Options:
  --secrets <file>       Secrets env file (default: <dir>/connectors.secrets.env)
  --output <prefix>      Output file prefix (default: <dir>)
  -h, --help             Show this help
EOF
  exit "${1:-0}"
}

DIR="" SECRETS="" OUT_PREFIX=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --secrets)  SECRETS="$2"; shift 2 ;;
    --output)   OUT_PREFIX="$2"; shift 2 ;;
    -h|--help)  usage 0 ;;
    -*)         echo "Unknown option: $1" >&2; usage 1 ;;
    *)          DIR="$1"; shift ;;
  esac
done

[[ -n "$DIR" ]] || { echo "Error: export directory required" >&2; usage 1; }
[[ -d "$DIR" ]] || { echo "Error: directory not found: $DIR" >&2; exit 1; }
[[ -f "${DIR}/agent.json" ]] || { echo "Error: ${DIR}/agent.json not found" >&2; exit 1; }
command -v jq >/dev/null || { echo "Error: jq is required" >&2; exit 1; }

[[ -n "$OUT_PREFIX" ]] || OUT_PREFIX="$DIR"
[[ -n "$SECRETS" ]] || SECRETS="${DIR}/connectors.secrets.env"

PARAMS_FILE="${OUT_PREFIX}.parameters.json"
EXTRAS_FILE="${OUT_PREFIX}.extras.json"

ASSEMBLE_SCRATCH=$(mktemp -d)
trap 'rm -rf "$ASSEMBLE_SCRATCH"' EXIT
_stage_json() {
  printf '%s' "$2" > "${ASSEMBLE_SCRATCH}/$1.json"
}

_log()  { echo "  $*"; }
_info() { echo "── $* ──"; }

# ── Load secrets into env vars (for connector token substitution) ──
if [[ -f "$SECRETS" ]]; then
  _info "Loading secrets from ${SECRETS}"
  set -a
  # shellcheck disable=SC1090
  source "$SECRETS"
  set +a
fi

# ── Helper: resolve file references in JSON ──
# Config JSONs use relative paths like "skills/my-skill.md" for content fields.
# This function reads the file and inlines its content.
resolve_file_refs() {
  local json="$1" base_dir="$2"
  printf '%s' "$json" | python3 -c '
import json, sys, os
base = sys.argv[1]
data = json.load(sys.stdin)
def resolve(obj):
    if isinstance(obj, str):
        # Check if it is a relative path to a file in config/
        for prefix in ["skills/", "subagents/", "common-prompts/"]:
            if obj.startswith(prefix) and obj.endswith((".md", ".txt")):
                for config_base in ["config"]:
                    path = os.path.join(base, config_base, obj)
                    if os.path.isfile(path):
                        with open(path) as f:
                            return f.read()
        # Also handle _file: prefix (legacy)
        if obj.startswith("_file:"):
            path = os.path.join(base, obj[6:])
            if os.path.isfile(path):
                with open(path) as f:
                    return f.read()
        return obj
    elif isinstance(obj, dict):
        return {k: resolve(v) for k, v in obj.items()}
    elif isinstance(obj, list):
        return [resolve(v) for v in obj]
    return obj
print(json.dumps(resolve(data)))
' "$base_dir" 2>/dev/null || printf '%s' "$json"
}

# ── Helper: collect all YAML (or JSON) files from a config subdirectory into a JSON array ──
# Reads from config/ and automations/
collect_config() {
  local subdir="$1"
  local result="[]"
  for base in "${DIR}/config" "${DIR}/automations"; do
    local full="${base}/${subdir}"
    if [[ -d "$full" ]]; then
      local items="[]"
      # Read YAML files
      for f in "${full}"/*.yaml "${full}"/*.yml; do
        [[ -f "$f" ]] || continue
        local item
        item=$(python3 -c '
import sys, yaml, json
with open(sys.argv[1]) as fh:
    data = yaml.safe_load(fh)
print(json.dumps(data))
' "$f" 2>/dev/null) || continue
        items=$(printf '%s\n%s\n' "$items" "$item" | jq -sc 'if length == 2 then .[0] + [.[1]] else error("expected single JSON value") end')
      done
      # Also read JSON files (for backward compat)
      for f in "${full}"/*.json; do
        [[ -f "$f" ]] || continue
        local item
        item=$(cat "$f") || continue
        items=$(printf '%s\n%s\n' "$items" "$item" | jq -sc 'if length == 2 then .[0] + [.[1]] else error("expected single JSON value") end' 2>/dev/null) || continue
      done
      result=$(printf '%s\n%s\n' "$result" "$items" | jq -sc 'add // []')
    fi
  done
  printf '%s\n' "$result"
}

# ── Helper: substitute env vars in connector JSON ──
resolve_env_vars() {
  local json="$1"
  printf '%s' "$json" | python3 -c "
import json, sys, os, re
data = json.load(sys.stdin)
def sub(obj):
    if isinstance(obj, str):
        return re.sub(r'\\\$\{(\w+)\}', lambda m: os.environ.get(m.group(1), m.group(0)), obj)
    elif isinstance(obj, dict):
        return {k: sub(v) for k, v in obj.items()}
    elif isinstance(obj, list):
        return [sub(v) for v in obj]
    return obj
print(json.dumps(sub(data)))
" 2>/dev/null || printf '%s' "$json"
}

# ═══════ Read agent.json ═══════

_info "Reading agent.json"
AGENT_JSON=$(cat "${DIR}/agent.json")

AGENT_NAME=$(echo "$AGENT_JSON"  | jq -r '.identity.agentName')
AGENT_RG=$(echo "$AGENT_JSON"    | jq -r '.identity.resourceGroup')
AGENT_SUB=$(echo "$AGENT_JSON"   | jq -r '.identity.subscription // ""')
AGENT_LOC=$(echo "$AGENT_JSON"   | jq -r '.identity.location')
TARGET_RGS=$(echo "$AGENT_JSON"  | jq -c 'if .identity.targetResourceGroups | type == "array" then .identity.targetResourceGroups elif .identity.targetResourceGroups | type == "string" and length > 0 then [.identity.targetResourceGroups | split(",")[] | gsub("^\\s+|\\s+$"; "")] else [] end')
ACCESS=$(echo "$AGENT_JSON"      | jq -r '.access.accessLevel')
ACTION=$(echo "$AGENT_JSON"      | jq -r '.access.actionMode')
TOGGLES=$(echo "$AGENT_JSON"     | jq -c '.toggles // {}')
UPGRADE_CHANNEL=$(echo "$AGENT_JSON" | jq -r '.upgradeChannel // "Preview"')
MODEL_PROVIDER=$(echo "$AGENT_JSON"  | jq -r '.defaultModelProvider // "Anthropic"')
case "$MODEL_PROVIDER" in
  "Azure OpenAI"|"azure openai"|"AzureOpenAI") MODEL_PROVIDER="MicrosoftFoundry" ;;
esac
MONTHLY_LIMIT=$(echo "$AGENT_JSON"   | jq -r '.monthlyAgentUnitLimit // 10000')
TAGS=$(echo "$AGENT_JSON"            | jq -c '.tags // {}')
EXISTING_UAMI=$(echo "$AGENT_JSON"   | jq -r '.existingUamiId // ""')
EXISTING_AI=$(echo "$AGENT_JSON"    | jq -r '.existingAgentAppInsightsId // ""')

# ── Network configuration ──
NET_TYPE=$(echo "$AGENT_JSON" | jq -r '.networkConfiguration.type // "unrestricted"' | tr '[:upper:]' '[:lower:]')
NET_SUBNET_ID=$(echo "$AGENT_JSON" | jq -r '.networkConfiguration.subnetId // ""')
NET_RG=$(echo "$AGENT_JSON" | jq -r '.networkConfiguration.resourceGroup // ""')
NET_VNET=$(echo "$AGENT_JSON" | jq -r '.networkConfiguration.vnetName // ""')
NET_SUBNET_NAME=$(echo "$AGENT_JSON" | jq -r '.networkConfiguration.subnetName // "agent-subnet"')
NET_SUBNET_PREFIX=$(echo "$AGENT_JSON" | jq -r '.networkConfiguration.subnetPrefix // "10.2.0.0/28"')
NET_ALLOWED_HOSTS=$(echo "$AGENT_JSON" | jq -c '.networkConfiguration.allowedHosts // []')
NET_ALLOWED_REGISTRIES=$(echo "$AGENT_JSON" | jq -c '.networkConfiguration.allowedRegistries // []')
NET_ALLOWED_CODE_REPOS=$(echo "$AGENT_JSON" | jq -c '.networkConfiguration.allowedCodeRepositories // []')
NET_ALLOW_MCP=$(echo "$AGENT_JSON" | jq -r '.networkConfiguration.allowHttpMcpServerNetworkAccess // true')
NET_PRIVATE_DNS=$(echo "$AGENT_JSON" | jq -r '.networkConfiguration.usePrivateDnsResolution // false')

# Map type to Bicep egressMode
case "$NET_TYPE" in
  vnet|azurevnet) EGRESS_MODE="AzureVNet" ;;
  limited)        EGRESS_MODE="Limited" ;;
  *)              EGRESS_MODE="Unrestricted" ;;
esac

# If broken-out VNet fields provided (not subnetId), resolve to full subnet ID
if [[ -z "$NET_SUBNET_ID" && -n "$NET_VNET" && -n "$NET_RG" ]]; then
  NET_SUBNET_ID="/subscriptions/${AGENT_SUB}/resourceGroups/${NET_RG}/providers/Microsoft.Network/virtualNetworks/${NET_VNET}/subnets/${NET_SUBNET_NAME}"
fi

_log "Agent: ${AGENT_NAME} (${AGENT_LOC}, ${AGENT_RG})"

# ═══════ Read connectors.json ═══════

_info "Reading connectors.json"
CONNECTORS="[]"
CONNECTOR_TOGGLES="{}"
if [[ -f "${DIR}/connectors.json" ]]; then
  RAW_CONN=$(resolve_env_vars "$(cat "${DIR}/connectors.json")")
  # connectors.json can be an array (legacy) or object { toggles, connectors }
  if echo "$RAW_CONN" | jq -e 'type == "array"' >/dev/null 2>&1; then
    CONNECTORS="$RAW_CONN"
  else
    CONNECTOR_TOGGLES=$(echo "$RAW_CONN" | jq -c '.toggles // {}')
    CONNECTORS=$(echo "$RAW_CONN" | jq -c '.connectors // []')
  fi
  _log "$(echo "$CONNECTORS" | jq 'length') connector(s) from connectors.json"
fi

_log "Total: $(echo "$CONNECTORS" | jq 'length') connector(s)"

# ═══════ Read config/ ═══════

_info "Assembling config/"

# Skills — read JSON, resolve .md file references
RAW_SKILLS=$(collect_config "skills")
SKILLS=$(resolve_file_refs "$RAW_SKILLS" "$DIR")
_log "skills: $(echo "$SKILLS" | jq 'length')"

# Subagents — read JSON, resolve .md file references
RAW_SUBAGENTS=$(collect_config "subagents")
SUBAGENTS=$(resolve_file_refs "$RAW_SUBAGENTS" "$DIR")
_log "subagents: $(echo "$SUBAGENTS" | jq 'length')"

# Simple config arrays (no file refs needed)
TOOLS=$(collect_config "tools")
_log "tools: $(echo "$TOOLS" | jq 'length')"

HOOKS=$(collect_config "hooks")
_log "hooks: $(echo "$HOOKS" | jq 'length')"

RAW_PROMPTS=$(collect_config "common-prompts")
COMMON_PROMPTS=$(resolve_file_refs "$RAW_PROMPTS" "$DIR")
_log "common-prompts: $(echo "$COMMON_PROMPTS" | jq 'length')"

SCHEDULED_TASKS=$(collect_config "scheduled-tasks")
_log "scheduled-tasks: $(echo "$SCHEDULED_TASKS" | jq 'length')"

INCIDENT_FILTERS=$(collect_config "incident-filters")
_log "incident-filters: $(echo "$INCIDENT_FILTERS" | jq 'length')"

HTTP_TRIGGERS=$(collect_config "http-triggers")
_log "http-triggers: $(echo "$HTTP_TRIGGERS" | jq 'length')"

PLUGIN_CONFIGS=$(collect_config "plugin-configs")
_log "plugin-configs: $(echo "$PLUGIN_CONFIGS" | jq 'length')"

INCIDENT_PLATFORMS=$(resolve_env_vars "$(collect_config "incident-platforms")")
_log "incident-platforms: $(echo "$INCIDENT_PLATFORMS" | jq 'length')"

REPOS=$(collect_config "repos")
_log "repos: $(echo "$REPOS" | jq 'length')"

# Tool permissions — single file (not a collection)
TOOL_PERMISSIONS='{}'
if [[ -f "${DIR}/tool-permissions.json" ]]; then
  TOOL_PERMISSIONS=$(cat "${DIR}/tool-permissions.json")
  _log "tool-permissions: loaded"
fi

# GitHub domains (BYO App / PAT auth) — config/github-domains/*.yaml
GITHUB_DOMAINS=$(resolve_env_vars "$(collect_config "github-domains")")
_log "github-domains: $(echo "$GITHUB_DOMAINS" | jq 'length')"

# ConnectorV2 (Jira, Slack, etc.) — config/connectorv2/*.yaml
CONNECTORV2=$(collect_config "connectorv2")
_log "connectorv2: $(echo "$CONNECTORV2" | jq 'length')"

MARKETPLACES="[]"
[[ -d "${DIR}/config/plugins/marketplaces" ]] && MARKETPLACES=$(collect_config "plugins/marketplaces")
INSTALLATIONS="[]"
[[ -d "${DIR}/config/plugins/installations" ]] && INSTALLATIONS=$(collect_config "plugins/installations")

# ═══════ Read data/ ═══════

_info "Reading data/"

KNOWLEDGE="[]"
[[ -f "${DIR}/data/knowledge.json" ]] && KNOWLEDGE=$(cat "${DIR}/data/knowledge.json")
KNOWLEDGE_ITEMS="[]"
[[ -f "${DIR}/data/knowledge-items.json" ]] && KNOWLEDGE_ITEMS=$(cat "${DIR}/data/knowledge-items.json")
SYNTH_KNOWLEDGE="[]"
SYNTH_KNOWLEDGE_DIR=""
[[ -f "${DIR}/data/synthesized-knowledge.json" ]] && SYNTH_KNOWLEDGE=$(cat "${DIR}/data/synthesized-knowledge.json")
# Discover synthesized knowledge files on disk
if [[ -d "${DIR}/data/synthesized-knowledge" ]]; then
  SYNTH_DIR_ABS="$(cd "${DIR}/data/synthesized-knowledge" && pwd)"
  SK_COUNT=$(find "$SYNTH_DIR_ABS" -type f ! -name '.*' | wc -l | tr -d ' ')
  if [[ "$SK_COUNT" -gt 0 ]]; then
    SYNTH_KNOWLEDGE_DIR="$SYNTH_DIR_ABS"
    _log "Found ${SK_COUNT} synthesized knowledge file(s) in data/synthesized-knowledge/"
  fi
fi
REPO_INSTRUCTIONS="[]"
[[ -f "${DIR}/data/repo-instructions.json" ]] && REPO_INSTRUCTIONS=$(cat "${DIR}/data/repo-instructions.json")

# Auto-discover .md files in data/, data/knowledge/, data/session-insights/ → knowledgeItems
# Deployed via data-plane PUT /api/v2/extendedAgent/connectors/{name} as KnowledgeItem.
# Session insights from a prior agent are made available as knowledge items on the new agent.
MD_FILES=$(find "${DIR}/data" -maxdepth 1 -name "*.md" -type f 2>/dev/null || true; \
           find "${DIR}/data/knowledge" -maxdepth 1 -name "*.md" -type f 2>/dev/null || true; \
           find "${DIR}/data/session-insights" -maxdepth 1 -name "*.md" -type f 2>/dev/null || true)
if [[ -n "$MD_FILES" ]]; then
  MD_COUNT=$(echo "$MD_FILES" | wc -l | tr -d ' ')
  _log "Found ${MD_COUNT} knowledge .md file(s) in data/"
  for mdf in $MD_FILES; do
    fname=$(basename "$mdf")
    KNOWLEDGE_ITEMS=$(printf '%s' "$KNOWLEDGE_ITEMS" | jq --arg name "$fname" --rawfile content "$mdf" \
      '. + [{"name": $name, "type": "KnowledgeText", "content": ($content | sub("\\n+$"; ""))}]')
  done
fi

_log "knowledge: $(printf '%s' "$KNOWLEDGE" | jq 'length'), items: $(printf '%s' "$KNOWLEDGE_ITEMS" | jq 'length')"

# Stage JSON collections on disk so jq reads via --slurpfile instead of hitting
# Linux MAX_ARG_STRLEN (131,071 bytes) on large --argjson payloads.
_stage_json tags "$TAGS"
_stage_json allowedHosts "$NET_ALLOWED_HOSTS"
_stage_json allowedRegistries "$NET_ALLOWED_REGISTRIES"
_stage_json allowedCodeRepositories "$NET_ALLOWED_CODE_REPOS"
_stage_json targetRgs "$TARGET_RGS"
_stage_json toggles "$TOGGLES"
_stage_json ctog "$CONNECTOR_TOGGLES"
_stage_json connectors "$CONNECTORS"
_stage_json repos "$REPOS"
_stage_json incidentPlatforms "$INCIDENT_PLATFORMS"
_stage_json incidentFilters "$INCIDENT_FILTERS"
_stage_json scheduledTasks "$SCHEDULED_TASKS"
_stage_json hooks "$HOOKS"
_stage_json commonPrompts "$COMMON_PROMPTS"
_stage_json httpTriggers "$HTTP_TRIGGERS"
_stage_json knowledge "$KNOWLEDGE"
_stage_json knowledgeItems "$KNOWLEDGE_ITEMS"
_stage_json synthesizedKnowledge "$SYNTH_KNOWLEDGE"
_stage_json repoInstructions "$REPO_INSTRUCTIONS"
_stage_json marketplaces "$MARKETPLACES"
_stage_json installations "$INSTALLATIONS"
_stage_json skills "$SKILLS"
_stage_json subagents "$SUBAGENTS"
_stage_json tools "$TOOLS"
_stage_json pluginConfigs "$PLUGIN_CONFIGS"
_stage_json toolPermissions "$TOOL_PERMISSIONS"
_stage_json githubDomains "$GITHUB_DOMAINS"
_stage_json connectorV2 "$CONNECTORV2"

# ═══════ Write parameters.json (Bicep) ═══════

_info "Writing ${PARAMS_FILE}"

jq -n \
  --arg agent "$AGENT_NAME" \
  --arg rg "$AGENT_RG" \
  --arg loc "$AGENT_LOC" \
  --arg access "$ACCESS" \
  --arg action "$ACTION" \
  --arg upgradeChannel "$UPGRADE_CHANNEL" \
  --arg modelProvider "$MODEL_PROVIDER" \
  --argjson monthlyLimit "$MONTHLY_LIMIT" \
  --slurpfile tags "${ASSEMBLE_SCRATCH}/tags.json" \
  --arg existingUami "$EXISTING_UAMI" \
  --arg existingAi "$EXISTING_AI" \
  --arg vnetSubnetId "$NET_SUBNET_ID" \
  --arg egressMode "$EGRESS_MODE" \
  --slurpfile allowedHosts "${ASSEMBLE_SCRATCH}/allowedHosts.json" \
  --slurpfile allowedRegistries "${ASSEMBLE_SCRATCH}/allowedRegistries.json" \
  --slurpfile allowedCodeRepositories "${ASSEMBLE_SCRATCH}/allowedCodeRepositories.json" \
  --argjson allowMcp "$NET_ALLOW_MCP" \
  --argjson privateDns "$NET_PRIVATE_DNS" \
  --slurpfile targetRgs "${ASSEMBLE_SCRATCH}/targetRgs.json" \
  --slurpfile toggles "${ASSEMBLE_SCRATCH}/toggles.json" \
  --slurpfile ctog "${ASSEMBLE_SCRATCH}/ctog.json" \
  --slurpfile connectors "${ASSEMBLE_SCRATCH}/connectors.json" \
  '
  def one($v): if ($v | length) == 1 then $v[0] else error("expected single JSON value") end;
  (one($tags)) as $tags_val |
  (one($allowedHosts)) as $allowed_hosts_val |
  (one($allowedRegistries)) as $allowed_registries_val |
  (one($allowedCodeRepositories)) as $allowed_code_repos_val |
  (one($targetRgs)) as $target_rgs_val |
  (one($toggles)) as $toggles_val |
  (one($ctog)) as $ctog_val |
  (one($connectors)) as $connectors_val |
  {
    "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
    "contentVersion": "1.0.0.0",
    "parameters": {
      "agentName":                     { "value": $agent },
      "agentResourceGroupName":        { "value": $rg },
      "location":                      { "value": $loc },
      "targetResourceGroups":          { "value": $target_rgs_val },
      "accessLevel":                   { "value": $access },
      "actionMode":                    { "value": $action },
      "upgradeChannel":                { "value": $upgradeChannel },
      "defaultModelProvider":          { "value": $modelProvider },
      "monthlyAgentUnitLimit":         { "value": $monthlyLimit },
      "tags":                            { "value": $tags_val },
      "existingManagedIdentityId":     { "value": $existingUami },
      "existingAgentAppInsightsId":    { "value": $existingAi },
      "vnetSubnetId":                  { "value": $vnetSubnetId },
      "egressMode":                    { "value": $egressMode },
      "allowedHosts":                  { "value": $allowed_hosts_val },
      "allowedRegistries":             { "value": $allowed_registries_val },
      "allowedCodeRepositories":       { "value": $allowed_code_repos_val },
      "allowHttpMcpServerNetworkAccess": { "value": $allowMcp },
      "usePrivateDnsResolution":       { "value": $privateDns },
      "enableAppInsightsConnector":    { "value": ($ctog_val.enableAppInsightsConnector // false) },
      "appInsightsResourceId":         { "value": ($ctog_val.appInsightsResourceId // "") },
      "appInsightsAppId":              { "value": ($ctog_val.appInsightsAppId // "") },
      "enableLogAnalyticsConnector":   { "value": ($ctog_val.enableLogAnalyticsConnector // false) },
      "lawResourceId":                 { "value": ($ctog_val.lawResourceId // "") },
      "enableAzureMonitorConnector":   { "value": ($ctog_val.enableAzureMonitorConnector // false) },
      "azureMonitorLookbackDays":      { "value": ($ctog_val.azureMonitorLookbackDays // 7) },
      "enableDailyHealthCheckTask":    { "value": ($toggles_val.enableDailyHealthCheckTask // false) },
      "enableDenyProdDeletesHook":     { "value": ($toggles_val.enableDenyProdDeletesHook // false) },
      "enableSafetyRulesPrompt":       { "value": ($toggles_val.enableSafetyRulesPrompt // false) },
      "enableWebhookBridge":           { "value": ($toggles_val.enableWebhookBridge // false) },
      "webhookBridgeTriggerUrl":       { "value": ($toggles_val.webhookBridgeTriggerUrl // "") },
      "connectors":                    { "value": [$connectors_val[] | select(.properties.dataConnectorType != "KnowledgeFile")] },
      "tools":                         { "value": [] },
      "skills":                        { "value": [] },
      "subagents":                     { "value": [] },
      "scheduledTasks":                { "value": [] },
      "incidentFilters":               { "value": [] },
      "commonPrompts":                 { "value": [] },
      "pluginConfigs":                 { "value": [] }
    }
  }' > "$PARAMS_FILE"

_log "Wrote $(wc -c < "$PARAMS_FILE" | tr -d ' ') bytes"

# ═══════ Write extras.json (data-plane) ═══════

_info "Writing ${EXTRAS_FILE}"

jq -n \
  --slurpfile repos "${ASSEMBLE_SCRATCH}/repos.json" \
  --slurpfile incidentPlatforms "${ASSEMBLE_SCRATCH}/incidentPlatforms.json" \
  --slurpfile incidentFilters "${ASSEMBLE_SCRATCH}/incidentFilters.json" \
  --slurpfile scheduledTasks "${ASSEMBLE_SCRATCH}/scheduledTasks.json" \
  --slurpfile hooks "${ASSEMBLE_SCRATCH}/hooks.json" \
  --slurpfile commonPrompts "${ASSEMBLE_SCRATCH}/commonPrompts.json" \
  --slurpfile httpTriggers "${ASSEMBLE_SCRATCH}/httpTriggers.json" \
  --slurpfile knowledge "${ASSEMBLE_SCRATCH}/knowledge.json" \
  --slurpfile knowledgeItems "${ASSEMBLE_SCRATCH}/knowledgeItems.json" \
  --slurpfile synthesizedKnowledge "${ASSEMBLE_SCRATCH}/synthesizedKnowledge.json" \
  --arg synthesizedKnowledgeDir "$SYNTH_KNOWLEDGE_DIR" \
  --slurpfile repoInstructions "${ASSEMBLE_SCRATCH}/repoInstructions.json" \
  --slurpfile marketplaces "${ASSEMBLE_SCRATCH}/marketplaces.json" \
  --slurpfile installations "${ASSEMBLE_SCRATCH}/installations.json" \
  --slurpfile connectors "${ASSEMBLE_SCRATCH}/connectors.json" \
  --slurpfile skills "${ASSEMBLE_SCRATCH}/skills.json" \
  --slurpfile subagents "${ASSEMBLE_SCRATCH}/subagents.json" \
  --slurpfile tools "${ASSEMBLE_SCRATCH}/tools.json" \
  --slurpfile pluginConfigs "${ASSEMBLE_SCRATCH}/pluginConfigs.json" \
  --slurpfile toolPermissions "${ASSEMBLE_SCRATCH}/toolPermissions.json" \
  --slurpfile githubDomains "${ASSEMBLE_SCRATCH}/githubDomains.json" \
  --slurpfile connectorV2 "${ASSEMBLE_SCRATCH}/connectorV2.json" \
  '
  def one($v): if ($v | length) == 1 then $v[0] else error("expected single JSON value") end;
  (one($hooks)) as $hooks_val |
  (one($commonPrompts)) as $common_prompts_val |
  (one($connectors)) as $connectors_val |
  (one($pluginConfigs)) as $plugin_configs_val |
  {
    "repos": one($repos),
    "incidentPlatforms": one($incidentPlatforms),
    "incidentFilters": one($incidentFilters),
    "scheduledTasks": one($scheduledTasks),
    "hooks": [($hooks_val // [])[] | {name: (.metadata.name // .name), type: (.type // "GlobalHook"), tags: (.tags // []), properties: (.spec // .properties // {})}],
    "commonPrompts": [($common_prompts_val // [])[] | {name: (.metadata.name // .name), type: (.type // "CommonPrompt"), tags: (.tags // []), properties: (.spec // .properties // {})}],
    "httpTriggers": one($httpTriggers),
    "knowledge": one($knowledge),
    "knowledgeItems": one($knowledgeItems),
    "synthesizedKnowledge": one($synthesizedKnowledge),
    "synthesizedKnowledgeDir": $synthesizedKnowledgeDir,
    "repoInstructions": one($repoInstructions),
    "plugins": {
      "marketplaces": one($marketplaces),
      "installations": one($installations)
    },
    "connectors": [$connectors_val[] | select(.properties.dataConnectorType == "Mcp")],
    "skills": one($skills),
    "subagents": one($subagents),
    "tools": one($tools),
    "pluginConfigs": [($plugin_configs_val // [])[] | {name: (.metadata.name // .name), type: (.type // "Plugin"), tags: (.tags // []), properties: (.spec // .properties // {})}],
    "toolPermissions": one($toolPermissions),
    "githubDomains": one($githubDomains),
    "connectorV2": one($connectorV2)
  }' > "$EXTRAS_FILE"

if [[ -f "${DIR}/custom-instructions.md" ]]; then
  jq --rawfile instructions "${DIR}/custom-instructions.md" \
    '.customInstructions = $instructions' "$EXTRAS_FILE" > "${ASSEMBLE_SCRATCH}/extras.merged.json"
  mv "${ASSEMBLE_SCRATCH}/extras.merged.json" "$EXTRAS_FILE"
fi

# Merge admin settings if present (adminUsers for cross-tenant access)
if [[ -f "${DIR}/admin-settings.json" ]]; then
  _log "Merging admin-settings.json (adminUsers) into extras"
  jq -s '.[0] * {
    "adminUsers": (.[1].adminUsers // [])
  }' "$EXTRAS_FILE" "${DIR}/admin-settings.json" > "${ASSEMBLE_SCRATCH}/extras.merged.json"
  mv "${ASSEMBLE_SCRATCH}/extras.merged.json" "$EXTRAS_FILE"
fi

_log "Wrote $(wc -c < "$EXTRAS_FILE" | tr -d ' ') bytes"

echo
_info "Assembly complete"
echo
echo "  ${PARAMS_FILE}  ← for deploy.sh (Bicep)"
echo "  ${EXTRAS_FILE}  ← for apply-extras.sh (data-plane)"
echo
echo "Deploy with:"
echo "  ./deploy.sh ${PARAMS_FILE}"
echo "  ./apply-extras.sh ${AGENT_SUB:-\$(az account show -q id -o tsv)} ${AGENT_RG} ${AGENT_NAME} ${EXTRAS_FILE}"
echo
