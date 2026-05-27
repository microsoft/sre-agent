#!/usr/bin/env bash
set -o pipefail

# ─── E2E Test: law-dynatrace-httptrigger × bicep-bash ───

SUB="cbf44432-7f45-4906-a85d-d2b14a1e8328"
LAW_CONTOSO="/subscriptions/$SUB/resourceGroups/rg-contoso-swe/providers/Microsoft.OperationalInsights/workspaces/law-7defkiyvn3r44"
DT_TENANT="dhu66396"
DT_TOKEN="${DT_TOKEN:?Set DT_TOKEN}"
GITHUB_REPO="dm-chelupati/contoso-trading"
REGION="swedencentral"

AGENT="dg-bicep-bash"
RG="rg-dg-bicep-bash"
DIR="/tmp/e2e-dg-bicep-bash"
CLONE_AGENT="dg-bicep-bash-cl"
CLONE_RG="rg-dg-bicep-bash-cl"
LOG="/tmp/e2e-dg-bicep-bash.log"

PASS=0; FAIL=0; RESULTS=()
record() {
  local name="$1" rc="$2"
  if [[ $rc -eq 0 ]]; then RESULTS+=("PASS: $name"); ((PASS++))
  else RESULTS+=("FAIL: $name (rc=$rc)"); ((FAIL++)); fi
}

exec > >(tee "$LOG") 2>&1
echo "Starting E2E: law-dynatrace-httptrigger × bicep-bash at $(date)"
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
echo "=== STEP 2: deploy ==="
./bin/deploy.sh "$DIR/" --force
record "deploy" $?

echo ""
echo "=== STEP 3: verify (waiting 15s for data-plane) ==="
sleep 15
./bin/verify-agent.sh "$SUB" "$RG" "$AGENT" --expected "$DIR/"
record "verify" $?

echo ""
echo "=== STEP 4: re-deploy (update — tweak skill) ==="
# Add a line to the deployment-guard skill to test update path
echo -e "\n# Updated by e2e test" >> "$DIR/config/skills/deployment-guard-analysis.md"
./bin/deploy.sh "$DIR/" --force
record "re-deploy" $?

echo ""
echo "=== STEP 5: verify after update ==="
./bin/verify-agent.sh "$SUB" "$RG" "$AGENT" --expected "$DIR/"
record "verify-update" $?

echo ""
echo "=== STEP 5b: create memory via chat ==="
AGENT_EP=$(az resource show --resource-group "$RG" --resource-type Microsoft.App/agents --name "$AGENT" --query "properties.agentEndpoint" -o tsv)
TOKEN=$(az account get-access-token --resource "https://azuresre.dev" --query accessToken -o tsv)
# Create a thread with a message that triggers memory save
HTTP_CODE=$(curl -s -o /tmp/e2e-thread.json -w "%{http_code}" -X POST "$AGENT_EP/api/v1/threads" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"StartMessage":"Save these as my user preferences: For contoso-trading, prod RG is rg-contoso-prod, staging is rg-contoso-staging. Always check DATABASE_URL env var consistency. Flag >2x latency as HIGH."}')
if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "201" ]]; then
  echo "Memory thread created (HTTP $HTTP_CODE). Waiting 60s for agent to process..."
  sleep 60
  # Check if memory was created
  MEM_COUNT=$(curl -s "$AGENT_EP/api/v1/WorkspaceMemory/list" -H "Authorization: Bearer $TOKEN" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len([f for f in d.get('files',[]) if f['size']>0]))" 2>/dev/null || echo "0")
  echo "Synthesized knowledge files with content: $MEM_COUNT"
  [[ "$MEM_COUNT" -gt 0 ]] && record "create-memory" 0 || record "create-memory" 1
else
  echo "Thread creation returned HTTP $HTTP_CODE"
  record "create-memory" 1
fi

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
echo "=== STEP 7b: verify clone has memory ==="
CLONE_EP=$(az resource show --resource-group "$CLONE_RG" --resource-type Microsoft.App/agents --name "$CLONE_AGENT" --query "properties.agentEndpoint" -o tsv 2>/dev/null)
if [[ -n "$CLONE_EP" ]]; then
  TOKEN=$(az account get-access-token --resource "https://azuresre.dev" --query accessToken -o tsv)
  CLONE_MEM=$(curl -s "$CLONE_EP/api/v1/WorkspaceMemory/list" -H "Authorization: Bearer $TOKEN" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len([f for f in d.get('files',[]) if f['size']>0]))" 2>/dev/null || echo "0")
  echo "Clone synthesized knowledge files with content: $CLONE_MEM"
  [[ "$CLONE_MEM" -gt 0 ]] && record "clone-has-memory" 0 || record "clone-has-memory" 1
else
  record "clone-has-memory" 1
fi

echo ""
echo "════════════════════════════════════════"
echo " E2E RESULTS: law-dynatrace-httptrigger × bicep-bash"
echo "════════════════════════════════════════"
for r in "${RESULTS[@]}"; do echo "  $r"; done
echo "────────────────────────────────────────"
echo "  TOTAL: $PASS passed, $FAIL failed"
echo "════════════════════════════════════════"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
