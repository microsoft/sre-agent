#!/usr/bin/env bash
set -euo pipefail

TEMPLATES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# Execute the real bridge and recipe-instruction sections, never a deployment.
awk '/^# 4i\. Webhook bridge/ {copy=1} /^# 5\. Post-deploy auth/ {copy=0} copy' \
  "$TEMPLATES_DIR/bicep/apply-extras.sh" > "$TMP_DIR/bridge.sh"
awk '/^# .*Recipe-specific post-deploy instructions/ {copy=1} /^rm -f "\$TMP"/ {copy=0} copy' \
  "$TEMPLATES_DIR/bin/deploy.sh" > "$TMP_DIR/instructions.sh"
[[ -s "$TMP_DIR/bridge.sh" && -s "$TMP_DIR/instructions.sh" ]]
printf '%s\n' '{"_scenario":"dynatrace-mcp","toggles":{"enableWebhookBridge":true}}' > "$TMP_DIR/agent.json"

cat > "$TMP_DIR/run.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
az() {
  case "$*" in
    *listCallbackUrl*)
      echo "UNEXPECTED-CALLBACK-REQUEST" >&2
      echo 'https://callback.invalid/?sig=offline-secret'
      return 1 ;;
    'resource list '*)
      if [[ "$CASE" == "lookup-failure" ]]; then
        echo "offline resource lookup failure" >&2
        return 7
      fi
      [[ "$CASE" != "existing" ]] || echo "test-agent-webhook-bridge"
      return 0 ;;
    'group show '*) echo "eastus2" ;;
    'deployment group create '*)
      if [[ "$CASE" == "cli-failure" ]]; then
        echo "offline deployment command failure" >&2
        return 7
      fi
      state=Succeeded
      name=fixture-bridge
      [[ "$CASE" != "state-failure" ]] || state=Failed
      [[ "$CASE" != "missing-name" ]] || name=""
      [[ "$CASE" != "blank-name" ]] || name="   "
      jq -nc --arg state "$state" --arg name "$name" \
        '{properties:{provisioningState:$state,outputs:{logicAppName:{value:$name}}}}' ;;
    *) echo "Unexpected az command: $*" >&2; return 1 ;;
  esac
}
SUB=test-sub
RG=test-rg
AGENT=test-agent
AG=test-agent
INPUT="$FIXTURE"
TMP="$FIXTURE/deployment.json"
FILE="$FIXTURE/extras.json"
HTTP_TRIGGER_URL=https://agent.invalid/trigger
[[ "$CASE" != "no-trigger" ]] || HTTP_TRIGGER_URL=""
if [[ "$CASE" == "instructions" ]]; then
  source "$FIXTURE/instructions.sh"
else
  source "$FIXTURE/bridge.sh"
fi
EOF

for case_name in existing new lookup-failure cli-failure state-failure missing-name blank-name disabled no-trigger instructions; do
  printf '%s\n' '{"enableWebhookBridge":true}' > "$TMP_DIR/extras.json"
  printf '%s\n' '{}' > "$TMP_DIR/deployment.json"
  printf '%s\n' '{"_scenario":"dynatrace-mcp","toggles":{"enableWebhookBridge":true}}' > "$TMP_DIR/agent.json"
  if [[ "$case_name" == "disabled" ]]; then
    printf '%s\n' '{"enableWebhookBridge":false}' > "$TMP_DIR/extras.json"
    printf '%s\n' '{"toggles":{"enableWebhookBridge":false}}' > "$TMP_DIR/agent.json"
  fi
  if output=$(CASE="$case_name" FIXTURE="$TMP_DIR" bash "$TMP_DIR/run.sh" 2>&1); then
    result=0
  else
    result=$?
  fi
  if [[ "$output" == *offline-secret* || "$output" == *UNEXPECTED-CALLBACK-REQUEST* ]]; then
    echo "FAIL: $case_name retrieved or printed a callback credential" >&2
    exit 1
  fi
  case "$case_name" in
    lookup-failure|cli-failure|state-failure|missing-name|blank-name)
      [[ "$result" -ne 0 && "$output" != *"Webhook bridge deployed"* && "$output" != *listCallbackUrl* ]] ||
        { echo "FAIL: $case_name did not report failure" >&2; exit 1; } ;;
    disabled|no-trigger)
      [[ "$result" -eq 0 && "$output" != *listCallbackUrl* ]] ||
        { echo "FAIL: $case_name displayed bridge instructions" >&2; exit 1; } ;;
    *)
      name=test-agent-webhook-bridge
      [[ "$case_name" != "new" ]] || name=fixture-bridge
      expected="/subscriptions/test-sub/resourceGroups/test-rg/providers/Microsoft.Logic/workflows/$name/triggers/incoming_webhook/listCallbackUrl?api-version=2019-05-01"
      [[ "$result" -eq 0 && "$output" == *"$expected"* && "$output" == *"--query value -o tsv"* ]] ||
        { echo "FAIL: $case_name missing protected retrieval instructions: $output" >&2; exit 1; } ;;
  esac
  echo "PASS: Bash webhook credentials: $case_name"
done
