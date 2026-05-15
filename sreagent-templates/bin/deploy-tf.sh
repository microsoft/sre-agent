#!/usr/bin/env bash
# deploy-tf.sh — deploy an SRE Agent via Terraform.
#
# Same interface as deploy.sh but uses Terraform instead of Bicep.
# Accepts a config directory (agent.json + connectors.json + config/*.yaml)
# produced by new-agent.sh, export-agent.sh, or clone-agent.sh.
#
# Usage:
#   ./deploy-tf.sh <config-directory>
#   ./deploy-tf.sh <config-directory> --dry-run     # terraform plan only
#   ./deploy-tf.sh <config-directory> --destroy      # tear down
#
# Prerequisites: az, jq, terraform, python3+pyyaml

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TF_DIR="${SCRIPT_DIR}/../terraform"

# ── Parse args ──
DRY_RUN=""
FORCE=""
DESTROY=""
INPUT=""
for arg in "$@"; do
  case "$arg" in
    --dry-run)       DRY_RUN="true" ;;
    --force)         FORCE="true" ;;
    --destroy)       DESTROY="true" ;;
    --no-telemetry)  export _NO_TELEMETRY="true" ;;
    *)               [[ -z "$INPUT" ]] && INPUT="$arg" ;;
  esac
done

[[ -z "$INPUT" ]] && { echo "Usage: deploy-tf.sh <config-dir> [--dry-run] [--destroy]" >&2; exit 1; }
[[ -d "$INPUT" ]] || { echo "Error: ${INPUT} is not a directory" >&2; exit 1; }
[[ -f "${INPUT}/agent.json" ]] || { echo "Error: ${INPUT}/agent.json not found" >&2; exit 1; }

for cmd in jq az terraform; do
  command -v "$cmd" >/dev/null || { echo "Error: $cmd is required" >&2; exit 1; }
done

# ── Step 1: Assemble (reuse same assemble-agent.sh) ──
echo "── Assembling from directory: ${INPUT}/ ──"
ASSEMBLE_OUT=$(mktemp -d)/assembled
bash "${SCRIPT_DIR}/../bicep/assemble-agent.sh" "$INPUT" --output "$ASSEMBLE_OUT"
PARAMS_FILE="${ASSEMBLE_OUT}.parameters.json"
EXTRAS_FILE="${ASSEMBLE_OUT}.extras.json"
echo

[[ -f "$PARAMS_FILE" ]] || { echo "Error: assemble failed — no parameters file" >&2; exit 1; }

# ── Step 2: Convert parameters.json → terraform.tfvars.json ──
echo "── Converting to Terraform variables ──"

# The parameters.json has Bicep format: { "parameters": { "key": { "value": ... } } }
# Convert to TF format: { "var_name": value }
TFVARS_FILE="${TF_DIR}/terraform.tfvars.json"

jq '{
  agent_name:                    .parameters.agentName.value,
  resource_group_name:           .parameters.agentResourceGroupName.value,
  location:                      .parameters.location.value,
  target_resource_groups:        .parameters.targetResourceGroups.value,
  access_level:                  .parameters.accessLevel.value,
  action_mode:                   .parameters.actionMode.value,
  upgrade_channel:               (.parameters.upgradeChannel.value // "Preview"),
  monthly_agent_unit_limit:      (.parameters.monthlyAgentUnitLimit.value // 10000),
  default_model_provider:        (.parameters.defaultModelProvider.value // "Anthropic"),
  tags:                          (.parameters.tags.value // {}),
  existing_managed_identity_id:  (.parameters.existingManagedIdentityId.value // ""),
  existing_agent_app_insights_id:(.parameters.existingAgentAppInsightsId.value // ""),

  enable_app_insights_connector: (.parameters.enableAppInsightsConnector.value // false),
  app_insights_resource_id:      (.parameters.appInsightsResourceId.value // ""),
  app_insights_app_id:           (.parameters.appInsightsAppId.value // ""),
  enable_log_analytics_connector:(.parameters.enableLogAnalyticsConnector.value // false),
  law_resource_id:               (.parameters.lawResourceId.value // ""),
  enable_azure_monitor_connector:(.parameters.enableAzureMonitorConnector.value // false),
  azure_monitor_lookback_days:   (.parameters.azureMonitorLookbackDays.value // 7),

  enable_webhook_bridge:         (.parameters.enableWebhookBridge.value // false),
  webhook_bridge_trigger_url:    (.parameters.webhookBridgeTriggerUrl.value // ""),

  connectors: [(.parameters.connectors.value // [])[] | {
    name: .name,
    properties: .properties
  }],

  skills: [],
  subagents: [],
  tools: [],
  common_prompts: []
}' "$PARAMS_FILE" > "$TFVARS_FILE"

# Summary
AG=$(jq -r '.agent_name' "$TFVARS_FILE")
RG=$(jq -r '.resource_group_name' "$TFVARS_FILE")
LOC=$(jq -r '.location' "$TFVARS_FILE")
echo "  Agent:       $AG"
echo "  RG:          $RG"
echo "  Location:    $LOC"
echo "  Connectors:  $(jq '.connectors | length' "$TFVARS_FILE") custom + toggles"
echo "  Skills, subagents, tools, prompts: deployed via data-plane (apply-extras.sh)"
echo "  Wrote:       ${TFVARS_FILE}"
echo

# ── Step 3: Terraform init + workspace ──
# Each agent gets its own state via a TF workspace named after the agent.
echo "── Terraform init ──"
cd "$TF_DIR"
terraform init -input=false -no-color 2>&1 | tail -3

# Select or create workspace for this agent
WORKSPACE="${AG}"
if terraform workspace list 2>/dev/null | grep -qw "$WORKSPACE"; then
  terraform workspace select "$WORKSPACE" -no-color 2>/dev/null
else
  terraform workspace new "$WORKSPACE" -no-color 2>/dev/null
fi
echo "  Workspace: $WORKSPACE"
echo

# ── Step 4: Destroy path ──
if [[ -n "$DESTROY" ]]; then
  echo "── Terraform destroy ──"
  terraform destroy -input=false -auto-approve -no-color
  rm -f "$TFVARS_FILE"
  terraform workspace select default -no-color 2>/dev/null
  terraform workspace delete "$WORKSPACE" -no-color 2>/dev/null || true
  rm -rf "$(dirname "$ASSEMBLE_OUT")"
  echo "✅ Destroyed."
  exit 0
fi

# ── Step 5: Plan ──
echo "── Terraform plan ──"
terraform plan -input=false -no-color -out=tf.plan 2>&1 | tail -20
echo

if [[ -n "$DRY_RUN" ]]; then
  echo "── DRY RUN — no deployment performed ──"
  echo "  Plan saved to: ${TF_DIR}/tf.plan"
  echo "  To apply: cd ${TF_DIR} && terraform apply tf.plan"
  rm -rf "$(dirname "$ASSEMBLE_OUT")"
  exit 0
fi

# ── Step 6: Apply ──
echo "── Terraform apply ──"
terraform apply -input=false -no-color tf.plan
rm -f tf.plan

echo
echo "─────────────── Deployment Succeeded ───────────────"
echo "  Agent (portal):  https://sre.azure.com/#/agent/$(az account show --query id -o tsv)/${RG}/${AG}"
echo "  Data plane:      https://${AG}.${LOC}.azuresre.ai"
echo

# ── Step 7: Apply extras (same as Bicep flow) ──
if [[ -f "$EXTRAS_FILE" ]]; then
  EXTRAS_SIZE=$(jq 'del(._exported_from) | to_entries | map(select(.value | if type == "array" then length > 0 elif type == "object" then length > 0 else false end)) | length' "$EXTRAS_FILE" 2>/dev/null || echo 0)
  if [[ "$EXTRAS_SIZE" -gt 0 ]]; then
    SUB=$(az account show --query id -o tsv)
    echo "── Applying data-plane config (extras) ──"
    export INPUT
    bash "${SCRIPT_DIR}/../bicep/apply-extras.sh" "$SUB" "$RG" "$AG" "$EXTRAS_FILE" ${FORCE:+--force}
  else
    echo "No data-plane extras to apply."
  fi
fi

rm -rf "$(dirname "$ASSEMBLE_OUT")"
echo "─────────────────────────────────────────────────────"
