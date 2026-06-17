#!/usr/bin/env bash
set -o pipefail

# ─── E2E Test: law-dynatrace-httptrigger × tf-ps ───

SUB="cbf44432-7f45-4906-a85d-d2b14a1e8328"
LAW_CONTOSO="/subscriptions/$SUB/resourceGroups/rg-contoso-swe/providers/Microsoft.OperationalInsights/workspaces/law-7defkiyvn3r44"
DT_TENANT="dhu66396"
DT_TOKEN="${DT_TOKEN:?Set DT_TOKEN}"
GITHUB_REPO="dm-chelupati/contoso-trading"
REGION="swedencentral"

AGENT="dg-tf-ps"
RG="rg-dg-tf-ps"
DIR="/tmp/e2e-dg-tf-ps"
CLONE_AGENT="dg-tf-ps-cl"
CLONE_RG="rg-dg-tf-ps-cl"
LOG="/tmp/e2e-dg-tf-ps.log"

PASS=0; FAIL=0; RESULTS=()
record() {
  local name="$1" rc="$2"
  if [[ $rc -eq 0 ]]; then RESULTS+=("PASS: $name"); ((PASS++))
  else RESULTS+=("FAIL: $name (rc=$rc)"); ((FAIL++)); fi
}

exec > >(tee "$LOG") 2>&1
echo "Starting E2E: law-dynatrace-httptrigger × tf-ps at $(date)"
cd "$(dirname "$0")/../.." || exit 1

echo ""
echo "=== STEP 1: new-agent (PS) ==="
rm -rf "$DIR"
pwsh -NoProfile -Command "& './bin/ps/New-Agent.ps1' \
  -Recipe 'law-dynatrace-github-httptrigger-prvalidation' \
  -NonInteractive \
  -Set @{ \
    agentName='$AGENT'; \
    resourceGroup='$RG'; \
    location='$REGION'; \
    targetRGs='rg-contoso-prod,rg-contoso-staging'; \
    lawId='$LAW_CONTOSO'; \
    dtTenant='$DT_TENANT'; \
    dtToken='$DT_TOKEN'; \
    githubRepo='$GITHUB_REPO' \
  } \
  -Output '$DIR/'"
record "new-agent-ps" $?

echo ""
echo "=== STEP 2: deploy (terraform via PS) ==="
pwsh -NoProfile -Command "& './bin/ps/Deploy-Tf.ps1' -InputPath '$DIR'"
record "deploy-tf-ps" $?

echo ""
echo "=== STEP 3: verify ==="
./bin/verify-agent.sh "$SUB" "$RG" "$AGENT" --expected "$DIR/"
record "verify" $?

echo ""
echo "=== STEP 4: re-deploy / update ==="
echo -e "\n# Updated by e2e test" >> "$DIR/config/skills/deployment-guard-analysis.md"
pwsh -NoProfile -Command "& './bin/ps/Deploy-Tf.ps1' -InputPath '$DIR'"
record "re-deploy-tf-ps" $?

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
  --location "$REGION" \
  --backend terraform
record "clone-tf" $?

echo ""
echo "=== STEP 7: verify clone ==="
./bin/verify-agent.sh "$SUB" "$CLONE_RG" "$CLONE_AGENT"
record "verify-clone" $?

echo ""
echo "════════════════════════════════════════"
echo " E2E RESULTS: law-dynatrace-httptrigger × tf-ps"
echo "════════════════════════════════════════"
for r in "${RESULTS[@]}"; do echo "  $r"; done
echo "────────────────────────────────────────"
echo "  TOTAL: $PASS passed, $FAIL failed"
echo "════════════════════════════════════════"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
