#!/usr/bin/env bash
# deploy.sh — deploy an SRE Agent via Bicep.
#
# Accepts either:
#   (a) A config directory (agent.json + connectors.json + config/*.yaml)
#       → runs assemble-agent.sh internally, then deploys
#   (b) A legacy .parameters.json file → deploys directly
#
# Usage:
#   ./deploy.sh <config-directory>              # new format
#   ./deploy.sh <parameters-file.json>          # legacy format
#   ./deploy.sh <config-directory> [deploy-name]
#
# After deploy, run apply-extras.sh for data-plane config (repos, hooks, etc.)

set -euo pipefail

# Source telemetry
SCRIPT_DIR_EARLY="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR_EARLY}/telemetry.sh"

# Parse args
DRY_RUN=""
FORCE=""
WHAT_IF=""
INPUT=""
NAME=""
for arg in "$@"; do
  case "$arg" in
    --dry-run)  DRY_RUN="true" ;;
    --what-if)  WHAT_IF="true" ;;
    --force)    FORCE="true" ;;
    --no-telemetry) _NO_TELEMETRY="true" ;;
    *)
      if [[ -z "$INPUT" ]]; then INPUT="$arg"
      elif [[ -z "$NAME" ]]; then NAME="$arg"
      fi ;;
  esac
done
[[ -z "$INPUT" ]] && { echo "Usage: deploy.sh <config-dir|params.json> [deploy-name] [--dry-run] [--force]" >&2; exit 1; }
[[ -z "$NAME" ]] && NAME="sre-agent-$(date +%Y%m%d-%H%M%S)"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE="${SCRIPT_DIR}/../bicep/main.bicep"

command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }

# ── Detect input type and resolve to parameters.json ──
CLEANUP_FILES=()
if [[ -d "$INPUT" ]]; then
  # Directory input → run assemble to produce parameters.json + extras.json
  [[ -f "${INPUT}/agent.json" ]] || { echo "Error: ${INPUT}/agent.json not found" >&2; exit 1; }
  echo "── Assembling from directory: ${INPUT}/ ──"
  ASSEMBLE_OUT=$(mktemp -d)/assembled
  bash "${SCRIPT_DIR}/../bicep/assemble-agent.sh" "$INPUT" --output "$ASSEMBLE_OUT"
  FILE="${ASSEMBLE_OUT}.parameters.json"
  EXTRAS_FILE="${ASSEMBLE_OUT}.extras.json"
  CLEANUP_FILES+=("$FILE" "$EXTRAS_FILE" "$(dirname "$ASSEMBLE_OUT")")
  echo
elif [[ -f "$INPUT" ]]; then
  FILE="$INPUT"
  EXTRAS_FILE=""
else
  echo "Error: ${INPUT} not found (expected directory or .json file)" >&2
  exit 1
fi

cleanup() { for f in ${CLEANUP_FILES[@]+"${CLEANUP_FILES[@]}"}; do rm -rf "$f" 2>/dev/null; done; }
trap cleanup EXIT

[[ -f "$FILE" ]] || { echo "parameters file not found: $FILE" >&2; exit 1; }

# ── Pre-flight: parse params and show summary ──
echo "──────────────── SRE Agent deployment ────────────────"
LOC=$(jq -r '.parameters.location.value // "eastus2"' "$FILE")
AG=$(jq -r '.parameters.agentName.value' "$FILE")
RG=$(jq -r '.parameters.agentResourceGroupName.value' "$FILE")
TGT=$(jq -r '.parameters.targetResourceGroups.value | join(", ")' "$FILE")
SUB=$(az account show --query id -o tsv)

echo "  Subscription:  $(az account show --query name -o tsv) ($SUB)"
echo "  Region:        $LOC"
echo "  Agent name:    $AG"
echo "  Agent RG:      $RG  $([[ "$(az group exists -n "$RG")" == "true" ]] && echo "(exists)" || echo "(will be created)")"
echo "  Target RGs:    ${TGT:-<none>}"
echo "  Access level:  $(jq -r '.parameters.accessLevel.value // "Low"' "$FILE")"
echo "  Action mode:   $(jq -r '.parameters.actionMode.value // "Review"' "$FILE")"
echo "  Upgrade chan:  $(jq -r '.parameters.upgradeChannel.value // "Preview"' "$FILE")"
echo "  Model:         $(jq -r '.parameters.defaultModelProvider.value // "Anthropic"' "$FILE")"
echo "  Monthly limit: $(jq -r '.parameters.monthlyAgentUnitLimit.value // 10000' "$FILE") AU"
echo

# Show what will be deployed (unified view)
echo "  Bicep (ARM) resources:"
# Webhook bridge / Logic App
WH=$(jq -r '.parameters.enableWebhookBridge.value // false' "$FILE")
[[ "$WH" == "true" ]] && echo "    ✓ Webhook bridge (Logic App)"
# Toggle connectors
for tog in enableLogAnalyticsConnector enableAppInsightsConnector enableAzureMonitorConnector; do
  v=$(jq -r ".parameters.${tog}.value // false" "$FILE")
  if [[ "$v" == "true" ]]; then
    case "$tog" in
      enableLogAnalyticsConnector) echo "    ✓ Log Analytics connector" ;;
      enableAppInsightsConnector)  echo "    ✓ App Insights connector" ;;
      enableAzureMonitorConnector) echo "    ✓ Azure Monitor connector" ;;
    esac
  fi
done
# Array connectors (MCP, Kusto, etc.)
n=$(jq -r '.parameters.connectors.value // [] | length' "$FILE")
if [[ "$n" -gt 0 ]]; then
  for cname in $(jq -r '.parameters.connectors.value[].name' "$FILE" 2>/dev/null); do
    ctype=$(jq -r ".parameters.connectors.value[] | select(.name==\"$cname\") | .properties.dataConnectorType" "$FILE")
    echo "    ✓ Connector: ${cname} (${ctype})"
  done
fi
# Skills + subagents (now in extras, not Bicep)
echo
echo "  Data-plane (apply-extras):"
EXTRAS_FILE="${FILE%.parameters.json}.extras.json"
[[ ! -f "$EXTRAS_FILE" ]] && EXTRAS_FILE="$(dirname "$FILE")/assembled.extras.json"
if [[ -f "$EXTRAS_FILE" ]]; then
  for key in skills subagents tools hooks commonPrompts incidentPlatforms incidentFilters scheduledTasks httpTriggers repos knowledgeItems knowledge pluginConfigs; do
    n=$(jq -r ".${key} // [] | length" "$EXTRAS_FILE" 2>/dev/null)
    if [[ "$n" -gt 0 ]]; then
      case "$key" in
        skills)             echo "    ✓ Skills: ${n}" ;;
        subagents)          echo "    ✓ Subagents: ${n}" ;;
        tools)              echo "    ✓ Tools: ${n}" ;;
        hooks)              echo "    ✓ Hooks: ${n}" ;;
        commonPrompts)      echo "    ✓ Common prompts: ${n}" ;;
        incidentPlatforms)  echo "    ✓ Incident platforms: ${n}" ;;
        incidentFilters)    echo "    ✓ Incident filters (response plans): ${n}" ;;
        scheduledTasks)     echo "    ✓ Scheduled tasks: ${n}" ;;
        httpTriggers)       echo "    ✓ HTTP triggers: ${n}" ;;
        repos)              echo "    ✓ Repos: ${n}" ;;
        knowledgeItems)     echo "    ✓ Knowledge files: ${n}" ;;
        knowledge)          echo "    ✓ Knowledge docs: ${n}" ;;
        pluginConfigs)      echo "    ✓ Plugin configs: ${n}" ;;
      esac
    fi
  done
else
  echo "    (extras file not found — data-plane items shown in change detection below)"
fi

echo
echo "  Deployment name: $NAME"
echo "─────────────────────────────────────────────────────"
echo

# ── Pre-deploy: change detection ──
CHANGES_DETECTED=""
if [[ -d "$INPUT" ]]; then
  echo "── Change detection ──"
  DIFF_EXIT=0
  "${SCRIPT_DIR}/diff-agent.sh" "$SUB" "$RG" "$AG" "$INPUT" 2>/dev/null || DIFF_EXIT=$?
  if [[ "$DIFF_EXIT" -eq 0 ]]; then
    echo "  No changes detected."
    if [[ -z "$FORCE" ]]; then
      echo "  Skipping deployment. Use --force to redeploy anyway."
      echo
      # Check connector health even when skipping deploy
      check_connector_health "$SUB" "$RG" "$AG"
      # Still run verify to confirm current state
      echo "── Current state verification ──"
      "${SCRIPT_DIR}/verify-agent.sh" "$SUB" "$RG" "$AG" --expected "$INPUT" 2>&1 || true
      exit 0
    else
      echo "  --force: redeploying anyway."
    fi
  elif [[ "$DIFF_EXIT" -eq 2 ]]; then
    CHANGES_DETECTED="new"
  else
    CHANGES_DETECTED="update"
  fi
  echo
fi

# ── Dry-run: stop here ──
if [[ -n "$DRY_RUN" ]]; then
  echo "── DRY RUN — no deployment performed ──"
  echo "  Assemble: ✅ (parameters + extras built)"
  echo "  To validate against ARM without deploying: --what-if"
  echo "  To deploy for real: remove --dry-run"
  exit 0
fi

# ── What-if: validate against ARM without deploying ──
if [[ -n "$WHAT_IF" ]]; then
  echo "── What-if validation (ARM preflight) ──"
  echo
  if az deployment sub what-if \
    --location "$LOC" \
    --name "$NAME" \
    --template-file "$TEMPLATE" \
    --parameters "@${FILE}" \
    --no-pretty-print 2>&1
  then
    echo
    echo "✅ What-if passed — deployment should succeed."
  else
    echo
    echo "❌ What-if found errors — fix before deploying."
  fi
  exit 0
fi

# ── Run the deployment with progress visible ──
TMP=$(mktemp)

echo "Starting deployment (this typically takes 3-5 min)..."
echo "Tip: open another terminal and run 'az deployment operation sub list -n $NAME -o table' to watch progress."
echo

az deployment sub create \
  --location "$LOC" \
  --name "$NAME" \
  --template-file "$TEMPLATE" \
  --parameters "@${FILE}" \
  --output json > "$TMP" 2>&1
AZ_RC=$?
cat "$TMP"

# ── Post-deploy: print key links ──
STATE=$(jq -r '.properties.provisioningState // "?"' "$TMP" 2>/dev/null || echo "Failed")
# If az exited non-zero but jq can't parse the output, fall back to querying ARM
if [[ "$STATE" == "?" && $AZ_RC -ne 0 ]]; then
  STATE=$(az deployment sub show -n "$NAME" --query 'properties.provisioningState' -o tsv 2>/dev/null || echo "Failed")
fi
# ── Colors (if terminal supports it) ──
if [[ -t 1 ]]; then
  RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m' CYAN='\033[0;36m' BOLD='\033[1m' NC='\033[0m'
else
  RED='' GREEN='' YELLOW='' CYAN='' BOLD='' NC=''
fi

# ── Connector health check (reused in multiple paths) ──
check_connector_health() {
  local sub="$1" rg="$2" ag="$3"
  local api_url="https://management.azure.com/subscriptions/${sub}/resourceGroups/${rg}/providers/Microsoft.App/agents/${ag}/connectors?api-version=2025-05-01-preview"
  local conn_json
  conn_json=$(az rest --method GET --url "$api_url" 2>/dev/null || true)
  local count
  count=$(echo "$conn_json" | jq '.value | length' 2>/dev/null || echo 0)
  [[ "$count" -gt 0 ]] || return 0

  echo -e "  ${BOLD}Connectors:${NC}"
  local warn=false
  for i in $(seq 0 $((count - 1))); do
    local cname cstate ctype
    cname=$(echo "$conn_json" | jq -r ".value[$i].name")
    cstate=$(echo "$conn_json" | jq -r ".value[$i].properties.provisioningState // \"Unknown\"")
    ctype=$(echo "$conn_json" | jq -r ".value[$i].properties.dataConnectorType // \"\"")

    # Note: ARM redacts extendedProperties (bearerToken, endpoint, etc.)
    # on GET — they always appear null. Only provisioningState is reliable.
    if [[ "$cstate" == "Succeeded" ]]; then
      echo -e "    ${GREEN}✓ ${cname} (${ctype}): ${cstate}${NC}"
    else
      echo -e "    ${YELLOW}⚠ ${cname} (${ctype}): ${cstate}${NC}"
      warn=true
    fi
  done
  if [[ "$warn" == "true" ]]; then
    echo
    echo -e "  ${YELLOW}${BOLD}⚠ Some connectors are not healthy. Check the portal or redeploy.${NC}"
  fi
  echo
}

if [[ "$STATE" != "Succeeded" ]]; then
  echo
  echo -e "${RED}${BOLD}══════════ Deployment FAILED ══════════${NC}"
  # Extract the most useful error message
  ERR_MSG=$(jq -r '.. | .message? // empty' "$TMP" 2>/dev/null | grep -v "^At least" | head -3)
  if [[ -n "$ERR_MSG" ]]; then
    echo
    echo -e "  ${RED}Root cause:${NC}"
    echo "$ERR_MSG" | sed 's/^/    /'
  fi
  echo
  echo "  Debug: az deployment operation sub list -n $NAME -o table"
  echo
  exit 1
fi

echo
echo -e "${GREEN}${BOLD}─────────────── Deployment Succeeded ───────────────${NC}"
echo -e "  Agent (portal):  ${CYAN}$(jq -r '.properties.outputs.agentPortalUrl.value // empty' "$TMP")${NC}"
echo -e "  Resource group:  ${CYAN}$(jq -r '.properties.outputs.resourceGroupPortalUrl.value // empty' "$TMP")${NC}"
echo -e "  Data plane:      ${CYAN}$(jq -r '.properties.outputs.agentDataPlaneUrl.value // empty' "$TMP")${NC}"
echo

# ── Telemetry ──
RECIPE_NAME="unknown"
[[ -d "$INPUT" && -f "${INPUT}/agent.json" ]] && RECIPE_NAME=$(jq -r '._scenario // "custom"' "${INPUT}/agent.json" 2>/dev/null)
send_telemetry "deploy" "$RECIPE_NAME" "$LOC"

# Auto-run apply-extras.sh if we assembled from a directory and have extras
if [[ -n "${EXTRAS_FILE:-}" && -f "$EXTRAS_FILE" ]]; then
  EXTRAS_SIZE=$(jq 'del(._exported_from) | to_entries | map(select(.value | if type == "array" then length > 0 elif type == "object" then length > 0 else false end)) | length' "$EXTRAS_FILE" 2>/dev/null || echo 0)
  if [[ "$EXTRAS_SIZE" -gt 0 ]]; then
    echo "── Applying data-plane config (extras) ──"
    export INPUT
    bash "${SCRIPT_DIR}/../bicep/apply-extras.sh" "$SUB" "$RG" "$AG" "$EXTRAS_FILE" ${FORCE:+--force}
  else
    echo "No data-plane extras to apply."
  fi
else
  echo "Next: apply data-plane config (repos, hooks, knowledge, GitHub/ADO auth):"
  echo "  ./apply-extras.sh $SUB $RG $AG <extras-file>"
fi
echo "─────────────────────────────────────────────────────"

# ── Check connector health (after apply-extras, which deploys connectors) ──
check_connector_health "$SUB" "$RG" "$AG"

# ── Deployment log ──
LOG_DIR="${INPUT}"
[[ -d "$INPUT" ]] && LOG_DIR="$INPUT" || LOG_DIR="$(dirname "$INPUT")"
DEPLOY_LOG="${LOG_DIR}/deploy-$(date +%Y%m%d-%H%M%S).log"

{
  echo "Deployment: ${NAME}"
  echo "Timestamp:  $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "Agent:      ${AG}"
  echo "RG:         ${RG}"
  echo "Region:     ${LOC}"
  echo "State:      ${STATE}"
  echo "Duration:   $(jq -r '.properties.duration // "?"' "$TMP")"
  echo "Portal:     $(jq -r '.properties.outputs.agentPortalUrl.value // empty' "$TMP")"
  echo ""
} > "$DEPLOY_LOG" 2>/dev/null || true

# ── Post-deploy verification ──
if [[ -d "$INPUT" ]]; then
  echo
  echo "── Post-deploy verification ──"
  VERIFY_OUTPUT=$("${SCRIPT_DIR}/verify-agent.sh" "$SUB" "$RG" "$AG" --expected "$INPUT" 2>&1) || true
  echo "$VERIFY_OUTPUT"
  # Append verify results to log
  {
    echo "── Verification Results ──"
    echo "$VERIFY_OUTPUT"
    echo ""
  } >> "$DEPLOY_LOG" 2>/dev/null || true
  echo
  echo "  Log saved: ${DEPLOY_LOG}"
fi

# ── Post-deploy: process roles.yaml if present ──
ROLES_FILE=""
if [[ -d "$INPUT" && -f "${INPUT}/roles.yaml" ]]; then
  ROLES_FILE="${INPUT}/roles.yaml"
fi

# Also check the scenario template if we came from new-agent.sh
[[ -z "$ROLES_FILE" && -d "$INPUT" ]] && {
  for rf in "${INPUT}/roles.yaml" "${INPUT}/../roles.yaml"; do
    [[ -f "$rf" ]] && ROLES_FILE="$rf" && break
  done
}

UAMI_ID=$(jq -r '.properties.outputs.managedIdentityId.value // empty' "$TMP" 2>/dev/null)
UAMI_PRINCIPAL=$(az identity show --ids "$UAMI_ID" --query principalId -o tsv 2>/dev/null || echo "")

if [[ -n "$ROLES_FILE" && -f "$ROLES_FILE" ]]; then
  echo
  echo "── Setting up UAMI roles (from roles.yaml) ──"
  [[ -n "$UAMI_PRINCIPAL" ]] && echo "  UAMI principal ID: ${UAMI_PRINCIPAL}"
  echo

  python3 -c "
import yaml, sys, os

uami = '${UAMI_PRINCIPAL}'
sub = '${SUB}'
rg = '${RG}'
ag = '${AG}'
loc = '${LOC}'

with open('${ROLES_FILE}') as f:
    data = yaml.safe_load(f)

for role in (data.get('roles') or []):
    rtype = role.get('type', 'manual')
    name = role.get('name', 'unnamed')
    instructions = role.get('instructions', '')

    if rtype == 'azure-role':
        scope = role.get('scope', '')
        role_id = role.get('role_definition_id', '')
        print(f'  Granting Azure role: {name}')
        cmd = f'az role assignment create --assignee-object-id {uami} --assignee-principal-type ServicePrincipal --role \"{role_id}\" --scope \"{scope}\"'
        print(f'    Command: {cmd}')
        if uami:
            os.system(cmd)
        else:
            print('    SKIPPED — UAMI principal ID not available')

    elif rtype == 'adx-principal':
        scope = role.get('scope', '')
        adx_role = role.get('role', 'Viewer')
        print(f'  Granting ADX role: {name} ({adx_role})')
        parts = scope.split('/databases/')
        if len(parts) == 2 and uami:
            cluster_url = parts[0]
            db = parts[1]
            # Try to run automatically
            cmd = f'az kusto database-principal-assignment create --cluster-name \"{cluster_url.split(\"/\")[-1]}\" --database-name \"{db}\" --principal-id \"{uami}\" --principal-type App --role \"{adx_role}\" --principal-assignment-name \"sre-agent-{ag}\" --subscription \"{sub}\" 2>/dev/null || az kusto database add-principal --cluster-name \"{cluster_url.split(\"/\")[-1]}\" --database-name \"{db}\" --value name=\"sre-agent-{ag}\" type=\"App\" app-id=\"{uami}\" role=\"{adx_role}\" 2>/dev/null'
            if os.system(cmd) == 0:
                print(f'    ✅ ADX {adx_role} granted on {db}')
            else:
                print(f'    ⚠ Could not auto-grant. Run manually:')
                print(f'    az kusto database add-principal --cluster-name \"{cluster_url.split(\"/\")[-1]}\" --database-name \"{db}\" --value name=\"sre-agent-{ag}\" type=\"App\" app-id=\"{uami}\" role=\"{adx_role}\"')
        else:
            print(f'    Run manually after deploy — scope: {scope}')

    elif rtype == 'token':
        env_var = role.get('env_var', '')
        print(f'  Token required: {name}')
        if env_var:
            print(f'    Set in connectors.secrets.env: {env_var}=<value>')
        if instructions:
            for line in instructions.strip().split(chr(10)):
                print(f'    {line}')

    elif rtype == 'manual':
        print(f'  Manual setup required: {name}')
        if instructions:
            for line in instructions.strip().split(chr(10)):
                print(f'    {line}')
        if uami:
            print(f'    UAMI principal ID: {uami}')

    elif rtype == 'api-connection':
        api_name = role.get('api', '')
        conn_name = f'{ag}-{api_name}'
        print(f'  Creating API connection: {name} ({api_name})')
        # Create the Microsoft.Web/connections resource
        create_cmd = (
            f'az resource create '
            f'--resource-group \"{rg}\" '
            f'--resource-type \"Microsoft.Web/connections\" '
            f'--name \"{conn_name}\" '
            f'--location \"{loc}\" '
            f'--properties \'{{\"displayName\":\"{name}\",\"api\":{{\"id\":\"/subscriptions/{sub}/providers/Microsoft.Web/locations/{loc}/managedApis/{api_name}\"}}}}\' '
            f'--api-version 2016-06-01'
        )
        print(f'    Creating connection resource...')
        if os.system(create_cmd) == 0:
            # Get the consent URL
            consent_cmd = (
                f'az rest --method POST '
                f'--url \"/subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.Web/connections/{conn_name}/listConsentLinks?api-version=2016-06-01\" '
                f'--body \'{{\"parameters\":[{{\"parameterName\":\"token\",\"redirectUrl\":\"https://portal.azure.com\"}}]}}\' '
                f'--query \"value[0].link\" -o tsv 2>/dev/null'
            )
            import subprocess
            result = subprocess.run(consent_cmd, shell=True, capture_output=True, text=True)
            consent_url = result.stdout.strip()
            if consent_url:
                print(f'    ✅ Connection created. Open this URL to sign in:')
                print(f'    {consent_url}')
            else:
                print(f'    ✅ Connection created. Get consent URL from portal:')
                print(f'    Portal → Resource Group → {conn_name} → Edit API Connection → Authorize')
        else:
            print(f'    ❌ Failed to create connection. Create manually in portal.')

    print()
" 2>/dev/null || echo "  Could not process roles.yaml (python3 + pyyaml required)"
fi

# ── Recipe-specific post-deploy instructions ──
if [[ -d "$INPUT" ]]; then
  SCENARIO=$(jq -r '._scenario // empty' "${INPUT}/agent.json" 2>/dev/null)
  WH_ENABLED=$(jq -r '.toggles.enableWebhookBridge // false' "${INPUT}/agent.json" 2>/dev/null)
  WH_URL=$(jq -r '.properties.outputs.webhookBridgeTriggerUrl.value // empty' "$TMP" 2>/dev/null)

  case "$SCENARIO" in
    dynatrace-mcp)
      # Try to get the Logic App callback URL
      WH_CALLBACK=$(az rest --method POST \
        --url "/subscriptions/${SUB}/resourceGroups/${RG}/providers/Microsoft.Logic/workflows/${AG}-webhook-bridge/triggers/incoming_webhook/listCallbackUrl?api-version=2019-05-01" \
        --query value -o tsv 2>/dev/null || echo "")
      echo
      echo "── Dynatrace setup (required to receive alerts) ──"
      echo
      if [[ -n "$WH_CALLBACK" ]]; then
        echo "  Webhook bridge URL (use this in Dynatrace):"
        echo "     ${WH_CALLBACK}"
      else
        echo "  ⚠ Webhook bridge not found. Check Azure portal → ${RG} → ${AG}-webhook-bridge"
      fi
      echo
      echo "  Option A: Dynatrace Workflow (recommended)"
      echo "  ─────────────────────────────────────────────"
      echo "  1. Go to Dynatrace → Automations → Workflows → + Workflow"
      echo "  2. Add trigger: 'Davis problem' trigger"
      echo "     - Filter: event.status_transition == \"CREATED\""
      echo "       (fires once per problem, not on every status update)"
      echo "  3. Add action: 'Send HTTP request'"
      echo "     - Method: POST"
      if [[ -n "$WH_CALLBACK" ]]; then
        echo "     - URL: ${WH_CALLBACK}"
      else
        echo "     - URL: <webhook bridge URL>"
      fi
      echo "     - Headers: Content-Type: application/json"
      echo "     - Payload:"
      echo '       {'
      echo '         "ProblemID": "{{ event()['"'"'event.id'"'"'] }}",'
      echo '         "ProblemTitle": "{{ event()['"'"'display_id'"'"'] }}: {{ event()['"'"'event.name'"'"'] }}",'
      echo '         "State": "{{ event()['"'"'event.status'"'"'] }}",'
      echo '         "ProblemSeverity": "{{ event()['"'"'event.category'"'"'] }}",'
      echo '         "ProblemURL": "{{ environment().url }}/ui/apps/dynatrace.classic.problems/#problems/problemdetails;pid={{ event()['"'"'event.id'"'"'] }}",'
      echo '         "ImpactedEntities": "{{ event()['"'"'affected_entity_ids'"'"'] }}",'
      echo '         "ProblemDetailsText": "{{ event()['"'"'event.name'"'"'] }}"'
      echo '       }'
      echo "  4. Grant workflow permissions:"
      echo "     Settings → Authorization → Automation Service → grant permissions"
      echo "  5. Activate the workflow"
      echo
      echo "  Option B: Classic webhook (simpler but less control)"
      echo "  ────────────────────────────────────────────────────"
      echo "  1. Go to Settings → Integration → Problem notifications"
      echo "  2. Add 'Custom Integration' webhook"
      if [[ -n "$WH_CALLBACK" ]]; then
        echo "  3. URL: ${WH_CALLBACK}"
      else
        echo "  3. URL: <webhook bridge URL>"
      fi
      echo "  4. Send test notification to verify"
      echo
      echo "  Test: trigger a problem in Dynatrace (or use the test button)"
      echo "  Then check the agent portal for the incoming investigation:"
      echo "  Portal: https://sre.azure.com/#/agent/${SUB}/${RG}/${AG}"
      echo
      ;;
    pagerduty-law-vmcosmos)
      echo
      echo "── PagerDuty setup ──"
      echo
      echo "  1. Open the agent portal: https://sre.azure.com/#/agent/${SUB}/${RG}/${AG}"
      echo "  2. Navigate to Incident Platforms → PagerDuty"
      echo "  3. Complete the OAuth flow to connect your PagerDuty account"
      echo "  4. Select which PagerDuty services to monitor"
      echo "  5. The pd-p1p2 response plan routes P1/P2 incidents with customInstructions"
      echo
      ;;
  esac
fi

rm -f "$TMP"
