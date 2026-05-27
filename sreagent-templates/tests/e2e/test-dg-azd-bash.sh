#!/usr/bin/env bash
set -o pipefail

# ─── E2E Test: law-dynatrace-httptrigger × azd-bash ───

SUB="cbf44432-7f45-4906-a85d-d2b14a1e8328"
LAW_CONTOSO="/subscriptions/$SUB/resourceGroups/rg-contoso-swe/providers/Microsoft.OperationalInsights/workspaces/law-7defkiyvn3r44"
DT_TENANT="dhu66396"
DT_TOKEN="${DT_TOKEN:?Set DT_TOKEN}"
GITHUB_REPO="dm-chelupati/contoso-trading"
REGION="swedencentral"

AGENT="dg-azd-bash"
RG="rg-dg-azd-bash"
DIR="/tmp/e2e-dg-azd-bash"
CLONE_AGENT="dg-azd-bash-cl"
CLONE_RG="rg-dg-azd-bash-cl"
LOG="/tmp/e2e-dg-azd-bash.log"

PASS=0; FAIL=0; RESULTS=()
record() {
  local name="$1" rc="$2"
  if [[ $rc -eq 0 ]]; then RESULTS+=("PASS: $name"); ((PASS++))
  else RESULTS+=("FAIL: $name (rc=$rc)"); ((FAIL++)); fi
}

exec > >(tee "$LOG") 2>&1
echo "Starting E2E: law-dynatrace-httptrigger × azd-bash at $(date)"
cd "$(dirname "$0")/../.." || exit 1

echo ""
echo "=== STEP 1: new-agent ==="
rm -rf "$DIR"
./bin/new-agent.sh \
  --recipe law-dynatrace-httptrigger \
  --non-interactive \
  --set agentName="$AGENT" \
  --set resourceGroup="$RG" \
  --set location="$REGION" \
  --set targetRGs=rg-contoso-prod,rg-contoso-staging \
  --set lawId="$LAW_CONTOSO" \
  --set dtTenant="$DT_TENANT" \
  --set dtToken="$DT_TOKEN" \
  --set githubRepo="$GITHUB_REPO" \
  -o "$DIR/"
record "new-agent" $?

echo ""
echo "=== STEP 2: deploy (azd) ==="
mkdir -p "./agents/$AGENT"
cp -r "$DIR/"* "./agents/$AGENT/" 2>/dev/null || true
azd env select "$AGENT" --no-prompt 2>/dev/null || azd env new "$AGENT" --no-prompt
azd env set AZURE_AGENT_NAME "$AGENT" --no-prompt
azd env set AZURE_RESOURCE_GROUP "$RG" --no-prompt
azd env set AZURE_LOCATION "$REGION" --no-prompt
azd env set AZURE_SUBSCRIPTION_ID "$SUB" --no-prompt
azd env set AZURE_LAW_ID "$LAW_CONTOSO" --no-prompt
azd env set DT_TENANT "$DT_TENANT" --no-prompt
azd env set DT_TOKEN "$DT_TOKEN" --no-prompt
azd up --no-prompt
record "deploy-azd" $?

echo ""
echo "=== STEP 3: verify ==="
./bin/verify-agent.sh "$SUB" "$RG" "$AGENT" --expected "$DIR/"
record "verify" $?

echo ""
echo "=== STEP 4: re-deploy / update (azd) ==="
echo -e "\n# Updated by e2e test" >> "$DIR/config/skills/deployment-guard-analysis.md"
cp -r "$DIR/"* "./agents/$AGENT/" 2>/dev/null || true
azd env select "$AGENT"
azd up --no-prompt
record "re-deploy-azd" $?

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
echo " E2E RESULTS: law-dynatrace-httptrigger × azd-bash"
echo "════════════════════════════════════════"
for r in "${RESULTS[@]}"; do echo "  $r"; done
echo "────────────────────────────────────────"
echo "  TOTAL: $PASS passed, $FAIL failed"
echo "════════════════════════════════════════"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
