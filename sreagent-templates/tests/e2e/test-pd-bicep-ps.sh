#!/usr/bin/env bash
set -o pipefail

# ─── E2E Test: pd × bicep-ps (all PowerShell commands) ───

SUB="cbf44432-7f45-4906-a85d-d2b14a1e8328"
LAW_EBC="/subscriptions/$SUB/resourceGroups/rg-ebc-demo3/providers/Microsoft.OperationalInsights/workspaces/law-ebc-demo3"
REGION="swedencentral"

AGENT="pd-bicep-ps"
RG="rg-pd-bicep-ps"
DIR="/tmp/e2e-pd-bicep-ps"
CLONE_AGENT="pd-bicep-ps-cl"
CLONE_RG="rg-pd-bicep-ps-cl"
LOG="/tmp/e2e-pd-bicep-ps.log"

PASS=0; FAIL=0; RESULTS=()
record() {
  local name="$1" rc="$2"
  if [[ $rc -eq 0 ]]; then RESULTS+=("PASS: $name"); ((PASS++))
  else RESULTS+=("FAIL: $name (rc=$rc)"); ((FAIL++)); fi
}

exec > >(tee "$LOG") 2>&1
echo "Starting E2E: pd × bicep-ps at $(date)"
cd "$(dirname "$0")/../.." || exit 1

echo ""
echo "=== STEP 1: new-agent (PS) ==="
pwsh -NoProfile -Command "& './bin/ps/New-Agent.ps1' \
  -Recipe 'pagerduty-law-vmcosmos' \
  -NonInteractive \
  -Set @{ \
    agentName='$AGENT'; \
    resourceGroup='$RG'; \
    location='$REGION'; \
    targetRGs='rg-ebc-demo3'; \
    lawId='$LAW_EBC'; \
    pagerdutyApiKey='test-pd-key-v4' \
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
echo " E2E RESULTS: pd × bicep-ps"
echo "════════════════════════════════════════"
for r in "${RESULTS[@]}"; do echo "  $r"; done
echo "────────────────────────────────────────"
echo "  TOTAL: $PASS passed, $FAIL failed"
echo "════════════════════════════════════════"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
