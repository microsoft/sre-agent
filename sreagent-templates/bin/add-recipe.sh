#!/usr/bin/env bash
# add-recipe.sh — Augment an existing agent with components from a recipe.
#
# Exports the live agent config, overlays recipe files, auto-detects values
# already configured (DT, LAW, GitHub repo, etc.), and produces a merged
# directory ready for deploy.sh.
#
# Key behaviour:
#   - Does NOT overwrite agent.json identity/access/model — only merges toggles
#   - Does NOT duplicate connectors — skips if connector name already exists
#   - Does NOT re-ask for values the agent already has — auto-extracts from
#     existing connectors.json, config/repos/*.yaml, and connectors.secrets.env
#   - Only prompts for values the recipe needs that the agent doesn't have yet
#
# Usage:
#   ./bin/add-recipe.sh --recipe law-dynatrace-github-httptrigger-prvalidation --agent-dir ./demo1-dt-snow
#   ./bin/add-recipe.sh --recipe <name> --agent-dir <dir> --non-interactive

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RECIPES_DIR="${SCRIPT_DIR}/../recipes"

# ─────────────────────────── Usage ───────────────────────────
usage() {
  cat <<EOF
Usage: $0 [options]

Augment an existing agent with a recipe's components (non-destructive merge).

Options:
  --recipe <name>       Recipe to add (required)
  --agent-dir <dir>     Existing agent directory (required)
  --set key=value       Override a prompt value (repeatable)
  --non-interactive     Use auto-detected + default values, no prompts
  --list                List available recipes and exit
  -h, --help            Show this help

What it does:
  1. Auto-detects values already in the agent (DT tenant, LAW ID, GitHub repo, etc.)
  2. Copies NEW config files (skills, subagents, http-triggers, hooks) — skips existing
  3. Merges only new toggles into agent.json (preserves identity/access/model)
  4. Appends only new connectors to connectors.json (skips duplicates by name)
  5. Only prompts for values the recipe needs that the agent doesn't already have

After adding:
  ./bin/deploy.sh <agent-dir>
EOF
  exit "${1:-0}"
}

RECIPE="" AGENT_DIR="" NON_INTERACTIVE=false LIST_ONLY=false
PRESET_FILE=$(mktemp /tmp/preset-add.XXXXXX)
VALUES_FILE=$(mktemp /tmp/values-add.XXXXXX)
_set() { echo "${2}=${3}" >> "$1"; }
_get() { grep "^${2}=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true; }
_has() { grep -q "^${1}=" "$2" 2>/dev/null; }
trap 'rm -f "$PRESET_FILE" "$VALUES_FILE" 2>/dev/null' EXIT

while [[ $# -gt 0 ]]; do
  case "$1" in
    --recipe)         RECIPE="$2"; shift 2 ;;
    --agent-dir)      AGENT_DIR="$2"; shift 2 ;;
    --set)            key="${2%%=*}"; val="${2#*=}"; _set "$PRESET_FILE" "$key" "$val"; shift 2 ;;
    --non-interactive) NON_INTERACTIVE=true; shift ;;
    --list)           LIST_ONLY=true; shift ;;
    -h|--help)        usage 0 ;;
    *)                echo "Unknown option: $1" >&2; usage 1 ;;
  esac
done

# ─────────────────────────── List recipes ───────────────────────────
if [[ "$LIST_ONLY" == "true" ]]; then
  echo "Available recipes:"
  echo
  for d in "${RECIPES_DIR}"/*/; do
    [[ -f "${d}agent.json" ]] || continue
    name=$(basename "$d")
    desc=$(jq -r '._description // "No description"' "${d}agent.json")
    printf '  %-45s %s\n' "$name" "$desc"
  done
  exit 0
fi

# ─────────────────────────── Validate inputs ───────────────────────────
[[ -n "$RECIPE" ]] || { echo "Error: --recipe is required" >&2; usage 1; }
[[ -n "$AGENT_DIR" ]] || { echo "Error: --agent-dir is required" >&2; usage 1; }

RECIPE_DIR="${RECIPES_DIR}/${RECIPE}"
[[ -d "$RECIPE_DIR" ]] || { echo "Recipe not found: ${RECIPE}" >&2; echo "Run $0 --list to see available recipes." >&2; exit 1; }
[[ -f "${RECIPE_DIR}/agent.json" ]] || { echo "Recipe missing agent.json: ${RECIPE}" >&2; exit 1; }
[[ -d "$AGENT_DIR" ]] || { echo "Agent directory not found: ${AGENT_DIR}" >&2; exit 1; }
[[ -f "${AGENT_DIR}/agent.json" ]] || { echo "Not an agent directory (no agent.json): ${AGENT_DIR}" >&2; exit 1; }

echo
echo "── Adding recipe: ${RECIPE} → ${AGENT_DIR} ──"
jq -r '._description // ""' "${RECIPE_DIR}/agent.json"
echo

# ─────────────────────────── Auto-detect existing values ───────────────────────────
echo "── Auto-detecting existing agent configuration ──"

PROMPTS=$(jq -c '._prompts // {}' "${RECIPE_DIR}/agent.json")
PROMPT_KEYS=$(echo "$PROMPTS" | jq -r 'keys[]')

# Extract identity from agent.json
_auto() { local k="$1" v="$2"; if [[ -n "$v" ]] && ! _has "$k" "$PRESET_FILE"; then _set "$PRESET_FILE" "$k" "$v"; echo "  auto: ${k} = ${v}"; fi; }

_auto "agentName"    "$(jq -r '.identity.agentName // ""' "${AGENT_DIR}/agent.json")"
_auto "resourceGroup" "$(jq -r '.identity.resourceGroup // ""' "${AGENT_DIR}/agent.json")"
_auto "location"     "$(jq -r '.identity.location // ""' "${AGENT_DIR}/agent.json")"

# Extract LAW ID from connectors.json
if [[ -f "${AGENT_DIR}/connectors.json" ]]; then
  EXISTING_LAW=$(jq -r '.toggles.lawResourceId // ""' "${AGENT_DIR}/connectors.json")
  _auto "lawId" "$EXISTING_LAW"

  # Extract Dynatrace tenant from connector endpoint URL
  EXISTING_DT_ENDPOINT=$(jq -r '.connectors[]? | select(.name == "dynatrace") | .properties.extendedProperties.endpoint // ""' "${AGENT_DIR}/connectors.json" 2>/dev/null || echo "")
  if [[ -n "$EXISTING_DT_ENDPOINT" ]]; then
    # https://<tenant>.apps.dynatrace.com/... → extract tenant
    DT_TENANT_EXTRACTED=$(echo "$EXISTING_DT_ENDPOINT" | sed -n 's|https://\([^.]*\)\.apps\.dynatrace\.com.*|\1|p')
    _auto "dtTenant" "$DT_TENANT_EXTRACTED"
  fi
fi

# Extract Dynatrace token from secrets env
if [[ -f "${AGENT_DIR}/connectors.secrets.env" ]]; then
  EXISTING_DT_TOKEN=$(grep "^DYNATRACE_BEARER_TOKEN=" "${AGENT_DIR}/connectors.secrets.env" 2>/dev/null | cut -d= -f2- || echo "")
  if [[ -n "$EXISTING_DT_TOKEN" ]]; then
    _auto "dtToken" "$EXISTING_DT_TOKEN"
  fi
fi

# Extract GitHub repo from existing repos config
if compgen -G "${AGENT_DIR}/config/repos/*.yaml" > /dev/null 2>&1; then
  for rf in "${AGENT_DIR}"/config/repos/*.yaml; do
    [[ -f "$rf" ]] || continue
    EXISTING_REPO=$(grep -m1 'url:' "$rf" 2>/dev/null | sed 's/.*url: *"\{0,1\}\([^"]*\)"\{0,1\}/\1/' || echo "")
    if [[ -n "$EXISTING_REPO" && "$EXISTING_REPO" != *"{{" ]]; then
      _auto "githubRepo" "$EXISTING_REPO"
      break
    fi
  done
fi

echo

# ─────────────────────────── Collect remaining inputs ───────────────────────────
for key in $PROMPT_KEYS; do
  # Skip identity fields — already in agent.json, not changing them
  case "$key" in agentName|resourceGroup|location|targetRGs|existingUamiId|modelProvider|existingAgentAppInsightsId)
    if _has "$key" "$PRESET_FILE"; then
      _set "$VALUES_FILE" "$key" "$(_get "$PRESET_FILE" "$key")"
    fi
    continue ;;
  esac

  # Already auto-detected or preset
  if _has "$key" "$PRESET_FILE"; then
    _set "$VALUES_FILE" "$key" "$(_get "$PRESET_FILE" "$key")"
    continue
  fi

  ask=$(echo "$PROMPTS" | jq -r --arg k "$key" '.[$k].ask // $k')
  default=$(echo "$PROMPTS" | jq -r --arg k "$key" '.[$k].default // ""')
  required=$(echo "$PROMPTS" | jq -r --arg k "$key" '.[$k].required // false')
  is_secret=$(echo "$PROMPTS" | jq -r --arg k "$key" '.[$k].secret // false')

  if [[ "$NON_INTERACTIVE" == "true" ]]; then
    if [[ -n "$default" ]]; then
      _set "$VALUES_FILE" "$key" "$default"
      echo "  ${ask}: ${default} (default)"
    elif [[ "$required" == "true" ]]; then
      echo "Error: ${key} is required, not auto-detected, and --non-interactive set" >&2
      echo "  Use --set ${key}=<value> to provide it" >&2
      exit 1
    fi
    continue
  fi

  prompt_text="  ${ask}"
  [[ -n "$default" ]] && prompt_text="${prompt_text} (${default})"
  prompt_text="${prompt_text}: "

  if [[ "$is_secret" == "true" ]]; then
    read -rsp "$prompt_text" val; echo "(hidden)"
  else
    read -rp "$prompt_text" val
  fi
  [[ -z "$val" ]] && val="$default"
  if [[ -z "$val" && "$required" == "true" ]]; then
    echo "    Error: ${key} is required" >&2; exit 1
  fi
  _set "$VALUES_FILE" "$key" "$val"
done

# ─────────────────────────── Copy config files (additive) ───────────────────────────
ADDED=0 SKIPPED=0

copy_dir() {
  local src_dir="$1" dst_dir="$2" label="$3"
  [[ -d "$src_dir" ]] || return 0
  mkdir -p "$dst_dir"
  for f in "$src_dir"/*; do
    [[ -f "$f" ]] || continue
    local fname
    fname=$(basename "$f")
    if [[ -f "${dst_dir}/${fname}" ]]; then
      echo "  skip ${label}/${fname} (already exists)"
      SKIPPED=$((SKIPPED + 1))
    else
      cp "$f" "${dst_dir}/${fname}"
      echo "  add  ${label}/${fname}"
      ADDED=$((ADDED + 1))
    fi
  done
}

echo
echo "── Copying config files ──"
copy_dir "${RECIPE_DIR}/config/skills"          "${AGENT_DIR}/config/skills"          "config/skills"
copy_dir "${RECIPE_DIR}/config/subagents"       "${AGENT_DIR}/config/subagents"       "config/subagents"
copy_dir "${RECIPE_DIR}/config/hooks"           "${AGENT_DIR}/config/hooks"           "config/hooks"
copy_dir "${RECIPE_DIR}/config/common-prompts"  "${AGENT_DIR}/config/common-prompts"  "config/common-prompts"
copy_dir "${RECIPE_DIR}/config/repos"           "${AGENT_DIR}/config/repos"           "config/repos"
copy_dir "${RECIPE_DIR}/config/tools"           "${AGENT_DIR}/config/tools"           "config/tools"
copy_dir "${RECIPE_DIR}/config/plugin-configs"  "${AGENT_DIR}/config/plugin-configs"  "config/plugin-configs"

echo
echo "── Copying automations ──"
copy_dir "${RECIPE_DIR}/automations/http-triggers"     "${AGENT_DIR}/automations/http-triggers"     "automations/http-triggers"
copy_dir "${RECIPE_DIR}/automations/scheduled-tasks"   "${AGENT_DIR}/automations/scheduled-tasks"   "automations/scheduled-tasks"
copy_dir "${RECIPE_DIR}/automations/incident-filters"  "${AGENT_DIR}/automations/incident-filters"  "automations/incident-filters"
copy_dir "${RECIPE_DIR}/automations/incident-platforms" "${AGENT_DIR}/automations/incident-platforms" "automations/incident-platforms"

# ─────────────────────────── Merge toggles into agent.json ───────────────────────────
echo
echo "── Merging toggles into agent.json ──"

# Extract only the toggles from the recipe's agent.json (ignore everything else)
RECIPE_TOGGLES=$(jq -c '.toggles // {}' "${RECIPE_DIR}/agent.json")
if [[ "$RECIPE_TOGGLES" != "{}" ]]; then
  # Merge: recipe toggles override only the keys they set; existing toggles preserved
  jq --argjson rt "$RECIPE_TOGGLES" '.toggles = (.toggles // {} | . * $rt)' \
    "${AGENT_DIR}/agent.json" > "${AGENT_DIR}/agent.json.tmp"
  mv "${AGENT_DIR}/agent.json.tmp" "${AGENT_DIR}/agent.json"
  echo "  merged toggles: $(echo "$RECIPE_TOGGLES" | jq -r 'keys | join(", ")')"
else
  echo "  no toggles to merge"
fi

# ─────────────────────────── Append connectors ───────────────────────────
if [[ -f "${RECIPE_DIR}/connectors.json" ]]; then
  echo
  echo "── Merging connectors ──"

  # Merge connector toggles (LAW, AppInsights, AzMon settings)
  RECIPE_CONN_TOGGLES=$(jq -c '.toggles // {}' "${RECIPE_DIR}/connectors.json")
  if [[ "$RECIPE_CONN_TOGGLES" != "{}" ]]; then
    if [[ -f "${AGENT_DIR}/connectors.json" ]]; then
      jq --argjson rt "$RECIPE_CONN_TOGGLES" '.toggles = (.toggles // {} | . * $rt)' \
        "${AGENT_DIR}/connectors.json" > "${AGENT_DIR}/connectors.json.tmp"
      mv "${AGENT_DIR}/connectors.json.tmp" "${AGENT_DIR}/connectors.json"
      echo "  merged connector toggles"
    fi
  fi

  # Append new connectors (by name, skip duplicates)
  RECIPE_CONNECTORS=$(jq -c '.connectors // []' "${RECIPE_DIR}/connectors.json")
  if [[ "$RECIPE_CONNECTORS" != "[]" ]]; then
    EXISTING_NAMES=$(jq -r '.connectors // [] | .[].name' "${AGENT_DIR}/connectors.json" 2>/dev/null || echo "")
    TEMP_CONNECTORS=$(mktemp /tmp/conn.XXXXXX)
    echo "$RECIPE_CONNECTORS" | jq -c '.[]' | while read -r conn; do
      cname=$(echo "$conn" | jq -r '.name')
      if echo "$EXISTING_NAMES" | grep -qx "$cname"; then
        echo "  skip connector: ${cname} (already exists)"
      else
        echo "$conn" >> "$TEMP_CONNECTORS"
        echo "  add  connector: ${cname}"
      fi
    done
    if [[ -s "$TEMP_CONNECTORS" ]]; then
      NEW_CONNS=$(jq -sc '.' "$TEMP_CONNECTORS")
      jq --argjson nc "$NEW_CONNS" '.connectors = (.connectors // [] | . + $nc)' \
        "${AGENT_DIR}/connectors.json" > "${AGENT_DIR}/connectors.json.tmp"
      mv "${AGENT_DIR}/connectors.json.tmp" "${AGENT_DIR}/connectors.json"
    fi
    rm -f "$TEMP_CONNECTORS"
  fi
fi

# ─────────────────────────── Replace placeholders in new files ───────────────────────────
if [[ -s "$VALUES_FILE" ]]; then
  echo
  echo "── Replacing placeholders ──"
  # Only replace in files that came from the recipe (avoid touching existing agent files)
  for file in $(find "$AGENT_DIR" -type f \( -name '*.json' -o -name '*.yaml' -o -name '*.md' \)); do
    content=$(cat "$file")
    changed=false
    while IFS="=" read -r key val || [[ -n "$key" ]]; do
      if echo "$content" | grep -q "{{${key}}}\|{{${key}:bool}}"; then
        content=$(echo "$content" | sed "s|\"{{${key}:bool}}\"|$(if [[ -n "$val" ]]; then echo "true"; else echo "false"; fi)|g")
        content=$(echo "$content" | sed "s|{{${key}}}|${val}|g")
        changed=true
      fi
    done < "$VALUES_FILE"
    if [[ "$changed" == "true" ]]; then
      echo "$content" > "$file"
      echo "  replaced placeholders in $(basename "$file")"
    fi
  done
fi

# ─────────────────────────── Write secrets ───────────────────────────
SECRETS_ENV="${AGENT_DIR}/connectors.secrets.env"
if [[ -s "$VALUES_FILE" ]]; then
  while IFS="=" read -r key val || [[ -n "$key" ]]; do
    is_secret=$(echo "$PROMPTS" | jq -r --arg k "$key" '.[$k].secret // false')
    if [[ "$is_secret" == "true" && -n "$val" ]]; then
      case "$key" in
        dtToken)
          if ! grep -q "DYNATRACE_BEARER_TOKEN=" "$SECRETS_ENV" 2>/dev/null; then
            echo "DYNATRACE_BEARER_TOKEN=${val}" >> "$SECRETS_ENV"
            echo "  added DYNATRACE_BEARER_TOKEN to secrets"
          fi ;;
      esac
    fi
  done < "$VALUES_FILE"
fi

# ─────────────────────────── Summary ───────────────────────────
echo
echo "── Done ──"
echo "  Added: ${ADDED} files"
echo "  Skipped: ${SKIPPED} files (already existed)"
echo
echo "Next step:"
echo "  ./bin/deploy.sh ${AGENT_DIR}"
