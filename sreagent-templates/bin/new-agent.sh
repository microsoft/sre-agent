#!/usr/bin/env bash
# new-agent.sh — Create a new SRE Agent config from a recipe template.
#
# Interactive setup: pick a recipe, answer prompts, get a ready-to-deploy directory.
# The output uses the same directory layout as export-agent.sh, so you can
# assemble + deploy, or use clone-agent.sh to validate + deploy.
#
# Usage:
#   ./new-agent.sh                              # Interactive — lists recipes
#   ./new-agent.sh --recipe generic           # Skip recipe picker
#   ./new-agent.sh --recipe dynatrace -o my-dt-agent  # Non-interactive with defaults
#   ./new-agent.sh --recipe generic --set agentName=prod-agent --set location=swedencentral
#
# After setup:
#   ./clone-agent.sh --source <output-dir> --agent-name <name> --resource-group <rg>
#   # or:
#   ./assemble-agent.sh <output-dir> && ./deploy.sh <output-dir>.parameters.json

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RECIPES_DIR="${SCRIPT_DIR}/../recipes"
source "${SCRIPT_DIR}/telemetry.sh"

# ─────────────────────────── Argument parsing ───────────────────────────
usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  --recipe <name>    Recipe template to use (skip interactive picker)
  --list               List available recipes and exit
  -o, --output <dir>   Output directory (default: ./<agentName>)
  --set key=value      Pre-set a prompt value (repeatable, skips that prompt)
  --non-interactive    Use defaults for all unset prompts (no interactive input)
  --no-telemetry       Disable anonymous usage tracking
  -h, --help           Show this help

Available recipes:
EOF
  for d in "${RECIPES_DIR}"/*/; do
    [[ -f "${d}agent.json" ]] || continue
    local name desc
    name=$(basename "$d")
    desc=$(jq -r '._description // "No description"' "${d}agent.json")
    printf '  %-20s %s\n' "$name" "$desc"
  done
  exit "${1:-0}"
}

RECIPE="" OUTPUT="" NON_INTERACTIVE=false LIST_ONLY=false
PRESET_FILE=$(mktemp /tmp/preset.XXXXXX)
VALUES_FILE=$(mktemp /tmp/values.XXXXXX)
_set() { local file="$1" key="$2" val="$3"; echo "${key}=${val}" >> "$file"; }
_get() { local file="$1" key="$2"; grep "^${key}=" "$file" 2>/dev/null | tail -1 | cut -d= -f2- || true; }
_has() { grep -q "^${1}=" "$2" 2>/dev/null; }
trap 'rm -f "$PRESET_FILE" "$VALUES_FILE" 2>/dev/null' EXIT

while [[ $# -gt 0 ]]; do
  case "$1" in
    --recipe)          RECIPE="$2"; shift 2 ;;
    --list)              LIST_ONLY=true; shift ;;
    -o|--output)         OUTPUT="$2"; shift 2 ;;
    --set)
      key="${2%%=*}"; val="${2#*=}"
      _set "$PRESET_FILE" "$key" "$val"
      shift 2 ;;
    --non-interactive)   NON_INTERACTIVE=true; shift ;;
    --no-telemetry)      _NO_TELEMETRY=true; shift ;;
    -h|--help)           usage 0 ;;
    *)                   echo "Unknown option: $1" >&2; usage 1 ;;
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
    prereqs=$(jq -r '._prerequisites // [] | map("    - " + .) | join("\n")' "${d}agent.json")
    echo "  ${name}"
    echo "    ${desc}"
    [[ -n "$prereqs" ]] && echo "$prereqs"
    echo
  done
  exit 0
fi

# ─────────────────────────── Pick recipe ───────────────────────────

if [[ -z "$RECIPE" ]]; then
  echo "┌──────────────────────────────────────────────┐"
  echo "│       SRE Agent — New Agent Setup             │"
  echo "└──────────────────────────────────────────────┘"
  echo
  echo "Available recipes:"
  echo
  recipes=()
  i=0
  for d in "${RECIPES_DIR}"/*/; do
    [[ -f "${d}agent.json" ]] || continue
    name=$(basename "$d")
    desc=$(jq -r '._description // ""' "${d}agent.json")
    recipes+=("$name")
    i=$((i + 1))
    printf '  %d) %-18s %s\n' "$i" "$name" "$desc"
  done
  echo
  read -rp "Pick a recipe [1-${#recipes[@]}]: " pick
  if [[ "$pick" =~ ^[0-9]+$ ]] && [[ "$pick" -ge 1 ]] && [[ "$pick" -le ${#recipes[@]} ]]; then
    RECIPE="${recipes[$((pick - 1))]}"
  else
    echo "Invalid selection." >&2; exit 1
  fi
fi

RECIPE_DIR="${RECIPES_DIR}/${RECIPE}"
[[ -d "$RECIPE_DIR" ]] || { echo "Recipe not found: ${RECIPE}" >&2; echo "Run $0 --list to see available recipes." >&2; exit 1; }
[[ -f "${RECIPE_DIR}/agent.json" ]] || { echo "Recipe missing agent.json: ${RECIPE}" >&2; exit 1; }

echo
echo "── Recipe: ${RECIPE} ──"
jq -r '._description // ""' "${RECIPE_DIR}/agent.json"
echo

# ─────────────────────────── Collect inputs ───────────────────────────

# Read prompts from agent.json._prompts
PROMPTS=$(jq -c '._prompts // {}' "${RECIPE_DIR}/agent.json")
PROMPT_KEYS=$(echo "$PROMPTS" | jq -r 'keys[]')



for key in $PROMPT_KEYS; do
  ask=$(echo "$PROMPTS" | jq -r --arg k "$key" '.[$k].ask // $k')
  default=$(echo "$PROMPTS" | jq -r --arg k "$key" '.[$k].default // ""')
  options=$(echo "$PROMPTS" | jq -r --arg k "$key" '.[$k].options // [] | join(", ")')
  required=$(echo "$PROMPTS" | jq -r --arg k "$key" '.[$k].required // false')
  is_secret=$(echo "$PROMPTS" | jq -r --arg k "$key" '.[$k].secret // false')

  # Use preset value if provided
  if _has "$key" "$PRESET_FILE"; then
    _set "$VALUES_FILE" "$key" "$(_get "$PRESET_FILE" "$key")"
    echo "  ${ask}: $(_get "$PRESET_FILE" "$key") (preset)"
    continue
  fi

  # Non-interactive: use default
  if [[ "$NON_INTERACTIVE" == "true" ]]; then
    if [[ -n "$default" ]]; then
      _set "$VALUES_FILE" "$key" "$default"
      echo "  ${ask}: ${default} (default)"
    elif [[ "$required" == "true" ]]; then
      echo "Error: ${key} is required but no default and --non-interactive set" >&2
      exit 1
    fi
    continue
  fi

  # Interactive prompt
  prompt_text="  ${ask}"
  [[ -n "$options" ]] && prompt_text="${prompt_text} [${options}]"
  [[ -n "$default" ]] && prompt_text="${prompt_text} (${default})"
  prompt_text="${prompt_text}: "

  if [[ "$is_secret" == "true" ]]; then
    read -rsp "$prompt_text" val
    echo "(hidden)"
  else
    read -rp "$prompt_text" val
  fi

  # Apply default
  [[ -z "$val" ]] && val="$default"

  # Validate required
  if [[ -z "$val" && "$required" == "true" ]]; then
    echo "    Error: ${key} is required" >&2
    exit 1
  fi

  _set "$VALUES_FILE" "$key" "$val"
done

echo

# ─────────────────────────── Resolve output dir ───────────────────────────

AGENT_NAME="$(_get "$VALUES_FILE" "agentName")"
[[ -n "$AGENT_NAME" ]] || AGENT_NAME="${RECIPE}-agent"
[[ -n "$OUTPUT" ]] || OUTPUT="./${AGENT_NAME}"

echo "── Creating agent config: ${OUTPUT}/ ──"
echo

# ─────────────────────────── Copy + stamp template ───────────────────────────

# Copy entire recipe directory
mkdir -p "$OUTPUT"
cp -r "${RECIPE_DIR}/." "$OUTPUT/"

# Remove metadata fields from agent.json (they're template-only)
jq 'del(._recipe, ._description, ._prerequisites, ._prompts)' "${OUTPUT}/agent.json" > "${OUTPUT}/agent.json.tmp"
mv "${OUTPUT}/agent.json.tmp" "${OUTPUT}/agent.json"

# Map friendly names to API values
_map_value() {
  local v="$1"
  case "$v" in
    "Azure OpenAI"|"azure openai"|"AzureOpenAI") echo "MicrosoftFoundry" ;;
    *) echo "$v" ;;
  esac
}
# Apply mappings to collected values
MAPPED_FILE=$(mktemp /tmp/mapped.XXXXXX)
while IFS="=" read -r key val || [[ -n "$key" ]]; do
  echo "${key}=$(_map_value "$val")" >> "$MAPPED_FILE"
done < "$VALUES_FILE"
mv "$MAPPED_FILE" "$VALUES_FILE"

# Replace {{placeholders}} with user values in all JSON and YAML files
for file in $(find "$OUTPUT" -name '*.json' -o -name '*.yaml' -type f); do
  content=$(cat "$file")
  while IFS="=" read -r key val || [[ -n "$key" ]]; do
    # Handle {{key:bool}} — converts non-empty to true, empty to false
    content=$(echo "$content" | sed "s|\"{{${key}:bool}}\"|$(if [[ -n "$val" ]]; then echo "true"; else echo "false"; fi)|g")
    # Handle {{key}} that's a comma-separated list → JSON array
    if [[ "$key" == "targetRGs" && "$val" == *,* ]]; then
      json_array=$(echo "$val" | tr ',' '\n' | sed 's/^ */"/;s/ *$/"/;' | paste -sd, | sed 's/^/[/;s/$/]/')
      content=$(echo "$content" | sed "s|\"{{${key}}}\"| ${json_array}|g")
    else
      content=$(echo "$content" | sed "s|{{${key}}}|${val}|g")
    fi
  done < "$VALUES_FILE"
  # Replace any remaining {{...:bool}} placeholders with false (optional params not set)
  content=$(echo "$content" | sed 's|"{{[^}]*:bool}}"| false|g')
  # Replace any remaining {{...}} placeholders with empty string
  content=$(echo "$content" | sed 's|{{[^}]*}}||g')
  echo "$content" > "$file"
done

# Handle targetRGs in agent.json — ensure it's a proper JSON array
TRGS="$(_get "$VALUES_FILE" "targetRGs")"
if [[ -n "$TRGS" ]]; then
  TRG_JSON=$(echo "$TRGS" | tr ',' '\n' | jq -R . | jq -sc .)
  jq --argjson rgs "$TRG_JSON" '.identity.targetResourceGroups = $rgs' "$OUTPUT/agent.json" > "$OUTPUT/agent.json.tmp"
  mv "$OUTPUT/agent.json.tmp" "$OUTPUT/agent.json"
fi

# Write secrets to connectors.secrets.env
SECRETS_ENV="${OUTPUT}/connectors.secrets.env"
echo "# SRE Agent connector secrets — DO NOT commit this file." > "$SECRETS_ENV"
echo "# Generated $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$SECRETS_ENV"
echo "" >> "$SECRETS_ENV"

# Write any secret prompt values
while IFS="=" read -r key _val || [[ -n "$key" ]]; do
  is_secret=$(echo "$PROMPTS" | jq -r --arg k "$key" '.[$k].secret // false')
  if [[ "$is_secret" == "true" && -n "$(_get "$VALUES_FILE" "$key")" ]]; then
    env_name=$(echo "$key" | sed 's/[a-z]/\U&/g;s/[^A-Z0-9]/_/g')
    # Map known secrets to their connector env var names
    case "$key" in
      dtToken) echo "DYNATRACE_BEARER_TOKEN=$(_get "$VALUES_FILE" "$key")" >> "$SECRETS_ENV" ;;
      *)       echo "${env_name}=$(_get "$VALUES_FILE" "$key")" >> "$SECRETS_ENV" ;;
    esac
  fi
done < "$VALUES_FILE"

# Create .gitignore if not present
if [[ ! -f "${OUTPUT}/.gitignore" ]]; then
  cat > "${OUTPUT}/.gitignore" << 'GITIGNORE'
connectors.secrets.env
*.secrets.env
GITIGNORE
fi

# Ensure data directories exist so users know where to place files
mkdir -p "${OUTPUT}/data/knowledge"
mkdir -p "${OUTPUT}/data/synthesized-knowledge"
touch "${OUTPUT}/data/knowledge/.gitkeep"
touch "${OUTPUT}/data/synthesized-knowledge/.gitkeep"

# Fill subscription from current az context
CURRENT_SUB=$(az account show --query id -o tsv 2>/dev/null || echo "")
if [[ -n "$CURRENT_SUB" ]]; then
  jq --arg s "$CURRENT_SUB" '.identity.subscription = $s' "$OUTPUT/agent.json" > "$OUTPUT/agent.json.tmp"
  mv "$OUTPUT/agent.json.tmp" "$OUTPUT/agent.json"
fi

echo

# ─────────────────────────── Summary ───────────────────────────

echo "── Setup complete ──"
echo
echo "  ${OUTPUT}/"
echo "    agent.json               ← Review and adjust if needed"
echo "    connectors.json          ← Connector configs"
[[ -s "$SECRETS_ENV" ]] && echo "    connectors.secrets.env   ← Secrets (gitignored)"
echo "    config/"
for d in skills subagents tools hooks common-prompts plugin-configs repos; do
  [[ -d "${OUTPUT}/config/${d}" ]] && {
    count=$(find "${OUTPUT}/config/${d}" -maxdepth 1 \( -name '*.json' -o -name '*.yaml' \) 2>/dev/null | wc -l | tr -d ' ')
    [[ "$count" -gt 0 ]] && printf '      %-24s ← %s file(s)\n' "${d}/" "$count"
  }
done
if ls "${OUTPUT}/automations/"*/* >/dev/null 2>&1; then
  echo "    automations/"
  for d in scheduled-tasks incident-filters http-triggers incident-platforms; do
    [[ -d "${OUTPUT}/automations/${d}" ]] && {
      count=$(find "${OUTPUT}/automations/${d}" -maxdepth 1 \( -name '*.json' -o -name '*.yaml' \) 2>/dev/null | wc -l | tr -d ' ')
      [[ "$count" -gt 0 ]] && printf '      %-24s ← %s file(s)\n' "${d}/" "$count"
    }
  done
fi
if [[ -d "${OUTPUT}/data" ]]; then
  data_count=$(find "${OUTPUT}/data" -maxdepth 1 -name "*.md" -type f 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$data_count" -gt 0 ]]; then
    echo "    data/"
    printf '      %-24s ← %s knowledge file(s)\n' "" "$data_count"
    for kf in "${OUTPUT}"/data/*.md; do
      [[ -f "$kf" ]] && echo "        $(basename "$kf")"
    done
  fi
fi
echo
echo "Next steps:"
echo "  1. Review ${OUTPUT}/agent.json"
echo "  2. Dry run:"
echo "       ./bin/deploy.sh ${OUTPUT}/ --dry-run"
echo "  3. Deploy:"
echo "       ./bin/deploy.sh ${OUTPUT}/"
echo "  3. When validation passes, remove --validate-only to deploy."

# ── Data residency warning ──
_model=$(jq -r '.defaultModelProvider // "Anthropic"' "${OUTPUT}/agent.json" 2>/dev/null)
_location=$(jq -r '.identity.location // ""' "${OUTPUT}/agent.json" 2>/dev/null)
if [[ "$_model" == "Anthropic" ]]; then
  case "$_location" in
    swedencentral|uksouth|australiaeast)
      echo
      echo "  ⚠  WARNING: Anthropic model selected with region '$_location'."
      echo "     Some organizations block Anthropic in EU/regulated regions due to"
      echo "     data residency policy. If you see 'Anthropic is not available due to"
      echo "     your organization's data residency policy' in the portal, switch to"
      echo "     Azure OpenAI:"
      echo "       Edit ${OUTPUT}/agent.json → set \"defaultModelProvider\": \"Azure OpenAI\""
      echo
      ;;
  esac
fi
echo

# ── Telemetry ──
REGION="$(_get "$VALUES_FILE" "location")"
send_telemetry "new-agent" "$RECIPE" "${REGION:-unknown}"
