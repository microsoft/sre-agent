#!/usr/bin/env bash
set -o pipefail

# ─── E2E Test: azmon × azd-bash ───

SUB="cbf44432-7f45-4906-a85d-d2b14a1e8328"
LAW_CONTOSO="/subscriptions/$SUB/resourceGroups/rg-contoso-swe/providers/Microsoft.OperationalInsights/workspaces/law-7defkiyvn3r44"
AI_ID="/subscriptions/$SUB/resourceGroups/rg-contoso-swe/providers/microsoft.insights/components/sreagent-recipes-telemetry"
AI_APPID="3b50188a-a191-4f74-994a-2e7ed8afc018"
REGION="swedencentral"

AGENT="azmon-azd-bash"
RG="rg-azmon-azd-bash"
DIR="/tmp/e2e-azmon-azd-bash"
CLONE_AGENT="azmon-azd-bash-cl"
CLONE_RG="rg-azmon-azd-bash-cl"
LOG="/tmp/e2e-azmon-azd-bash.log"

PASS=0; FAIL=0; RESULTS=()
record() {
  local name="$1" rc="$2"
  if [[ $rc -eq 0 ]]; then RESULTS+=("PASS: $name"); ((PASS++))
  else RESULTS+=("FAIL: $name (rc=$rc)"); ((FAIL++)); fi
}

exec > >(tee "$LOG") 2>&1
echo "Starting E2E: azmon × azd-bash at $(date)"
cd "$(dirname "$0")/../.." || exit 1

echo ""
echo "=== STEP 1: new-agent ==="
./bin/new-agent.sh \
  --recipe azmon-lawappinsights \
  --non-interactive \
  --set agentName="$AGENT" \
  --set resourceGroup="$RG" \
  --set location="$REGION" \
  --set targetRGs=rg-contoso-swe \
  --set lawId="$LAW_CONTOSO" \
  --set appInsightsId="$AI_ID" \
  --set appInsightsAppId="$AI_APPID" \
  --set githubRepo=dm-chelupati/contoso-trading \
  -o "$DIR/"
record "new-agent" $?

echo ""
echo "=== STEP 2: deploy (azd) ==="
# Copy new-agent config into ./agents/<name>/ so azd preprovision hook finds it
mkdir -p "./agents/$AGENT"
cp -r "$DIR/"* "./agents/$AGENT/" 2>/dev/null || true
azd env select "$AGENT" --no-prompt 2>/dev/null || azd env new "$AGENT" --no-prompt
azd env set AZURE_AGENT_NAME "$AGENT" --no-prompt
azd env set AZURE_RESOURCE_GROUP "$RG" --no-prompt
azd env set AZURE_LOCATION "$REGION" --no-prompt
azd env set AZURE_SUBSCRIPTION_ID "$SUB" --no-prompt
azd env set AZURE_LAW_ID "$LAW_CONTOSO" --no-prompt
azd env set AZURE_AI_ID "$AI_ID" --no-prompt
azd env set AZURE_AI_APPID "$AI_APPID" --no-prompt
azd up --no-prompt
record "deploy" $?

echo ""
echo "=== STEP 3: verify ==="
./bin/verify-agent.sh "$SUB" "$RG" "$AGENT" --expected "$DIR/"
record "verify" $?

echo ""
echo "=== STEP 4: re-deploy / update (azd — add rg-ebc-demo3) ==="
jq '.identity.targetResourceGroups += ["rg-ebc-demo3"]' "$DIR/agent.json" > "$DIR/agent.json.tmp" \
  && mv "$DIR/agent.json.tmp" "$DIR/agent.json"
# Sync updated config to ./agents/<name>/
cp -r "$DIR/"* "./agents/$AGENT/" 2>/dev/null || true
azd env select "$AGENT"
azd up --no-prompt
record "re-deploy" $?

echo ""
echo "=== STEP 5: verify after update ==="
./bin/verify-agent.sh "$SUB" "$RG" "$AGENT" --expected "$DIR/"
record "verify-update" $?

echo ""
echo "=== STEP 6: clone ==="
echo y | ./bin/clone-agent.sh \
  --from-agent "$AGENT" \
  --from-rg "$RG" \
  --from-sub "$SUB" \
  --agent-name "$CLONE_AGENT" \
  --resource-group "$CLONE_RG" \
  --location "$REGION"
record "clone" $?

echo ""
echo "=== STEP 7: verify clone ==="
./bin/verify-agent.sh "$SUB" "$CLONE_RG" "$CLONE_AGENT"
record "verify-clone" $?

echo ""
echo "════════════════════════════════════════"
echo " E2E RESULTS: azmon × azd-bash"
echo "════════════════════════════════════════"
for r in "${RESULTS[@]}"; do echo "  $r"; done
echo "────────────────────────────────────────"
echo "  TOTAL: $PASS passed, $FAIL failed"
echo "════════════════════════════════════════"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
