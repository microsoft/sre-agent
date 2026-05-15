#!/usr/bin/env bash
set -o pipefail

# ─── E2E Test: azmon × bicep-ps (all PowerShell commands) ───

SUB="cbf44432-7f45-4906-a85d-d2b14a1e8328"
LAW_CONTOSO="/subscriptions/$SUB/resourceGroups/rg-contoso-swe/providers/Microsoft.OperationalInsights/workspaces/law-7defkiyvn3r44"
AI_ID="/subscriptions/$SUB/resourceGroups/rg-contoso-swe/providers/microsoft.insights/components/sreagent-recipes-telemetry"
AI_APPID="3b50188a-a191-4f74-994a-2e7ed8afc018"
REGION="swedencentral"

AGENT="azmon-bicep-ps"
RG="rg-azmon-bicep-ps"
DIR="/tmp/e2e-azmon-bicep-ps"
CLONE_AGENT="azmon-bicep-ps-cl"
CLONE_RG="rg-azmon-bicep-ps-cl"
LOG="/tmp/e2e-azmon-bicep-ps.log"

PASS=0; FAIL=0; RESULTS=()
record() {
  local name="$1" rc="$2"
  if [[ $rc -eq 0 ]]; then RESULTS+=("PASS: $name"); ((PASS++))
  else RESULTS+=("FAIL: $name (rc=$rc)"); ((FAIL++)); fi
}

exec > >(tee "$LOG") 2>&1
echo "Starting E2E: azmon × bicep-ps at $(date)"
cd "$(dirname "$0")/../.." || exit 1

echo ""
echo "=== STEP 1: new-agent (PS) ==="
pwsh -NoProfile -Command "& './bin/ps/New-Agent.ps1' \
  -Recipe 'azmon-lawappinsights' \
  -NonInteractive \
  -Set @{ \
    agentName='$AGENT'; \
    resourceGroup='$RG'; \
    location='$REGION'; \
    targetRGs='rg-contoso-swe'; \
    lawId='$LAW_CONTOSO'; \
    appInsightsId='$AI_ID'; \
    appInsightsAppId='$AI_APPID'; \
    githubRepo='dm-chelupati/contoso-trading' \
  } \
  -Output '$DIR/'"
record "new-agent" $?

echo ""
echo "=== STEP 2: deploy (PS) ==="
pwsh -NoProfile -Command "& './bin/ps/Deploy-Agent.ps1' -InputPath '$DIR' -Force"
record "deploy" $?

echo ""
echo "=== STEP 3: verify (PS) ==="
pwsh -NoProfile -Command "& './bin/ps/Verify-Agent.ps1' \
  -Subscription '$SUB' \
  -ResourceGroup '$RG' \
  -AgentName '$AGENT' \
  -Expected '$DIR/'"
record "verify" $?

echo ""
echo "=== STEP 4: re-deploy / update (PS — add rg-ebc-demo3) ==="
jq '.identity.targetResourceGroups += ["rg-ebc-demo3"]' "$DIR/agent.json" > "$DIR/agent.json.tmp" \
  && mv "$DIR/agent.json.tmp" "$DIR/agent.json"
pwsh -NoProfile -Command "& './bin/ps/Deploy-Agent.ps1' -InputPath '$DIR' -Force"
record "re-deploy" $?

echo ""
echo "=== STEP 5: verify after update (PS) ==="
pwsh -NoProfile -Command "& './bin/ps/Verify-Agent.ps1' \
  -Subscription '$SUB' \
  -ResourceGroup '$RG' \
  -AgentName '$AGENT' \
  -Expected '$DIR/'"
record "verify-update" $?

echo ""
echo "=== STEP 6: clone (PS) ==="
pwsh -NoProfile -Command "& './bin/ps/Clone-Agent.ps1' \
  -FromAgent '$AGENT' \
  -FromResourceGroup '$RG' \
  -FromSubscription '$SUB' \
  -AgentName '$CLONE_AGENT' \
  -ResourceGroup '$CLONE_RG' \
  -Location '$REGION' \
  -Force"
record "clone" $?

echo ""
echo "=== STEP 7: verify clone (PS) ==="
pwsh -NoProfile -Command "& './bin/ps/Verify-Agent.ps1' \
  -Subscription '$SUB' \
  -ResourceGroup '$CLONE_RG' \
  -AgentName '$CLONE_AGENT'"
record "verify-clone" $?

echo ""
echo "════════════════════════════════════════"
echo " E2E RESULTS: azmon × bicep-ps"
echo "════════════════════════════════════════"
for r in "${RESULTS[@]}"; do echo "  $r"; done
echo "────────────────────────────────────────"
echo "  TOTAL: $PASS passed, $FAIL failed"
echo "════════════════════════════════════════"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
