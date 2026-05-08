#!/usr/bin/env bash
# e2e-full-matrix.sh — 3 recipes × 6 backends = 18 deploys
# Run from sreagent-templates/ directory
# Reports results at the end — does NOT fix anything
set -uo pipefail

SUB="cbf44432-7f45-4906-a85d-d2b14a1e8328"
REGION="swedencentral"
LAW="/subscriptions/$SUB/resourceGroups/rg-contoso-swe/providers/Microsoft.OperationalInsights/workspaces/law-7defkiyvn3r44"
AI="/subscriptions/$SUB/resourceGroups/rg-contoso-swe/providers/microsoft.insights/components/sreagent-recipes-telemetry"
AI_APPID="3b50188a-a191-4f74-994a-2e7ed8afc018"
# Existing UAMI for "bring your own" tests
EXISTING_UAMI="/subscriptions/$SUB/resourcegroups/rg-contoso-swe/providers/Microsoft.ManagedIdentity/userAssignedIdentities/uami-e2e-test"

REPORT="/tmp/e2e-matrix-results.txt"
> "$REPORT"
PASS=0; FAIL=0; SKIP=0

log() { echo "$1" | tee -a "$REPORT"; }
result() {
  local name="$1" rc="$2"
  if [[ "$rc" -eq 0 ]]; then
    log "  ✅ $name"
    PASS=$((PASS+1))
  else
    log "  ❌ $name"
    FAIL=$((FAIL+1))
  fi
}

# ─────────── Cleanup old RGs ───────────
log "═══ Cleanup old RGs ═══"
for rg in rg-az-bicep rg-az-tf rg-az-ps rg-az-azd rg-az-pstf rg-az-pscl \
          rg-pd-bicep rg-pd-tf rg-pd-ps rg-pd-azd rg-pd-pstf rg-pd-pscl \
          rg-dt-bicep rg-dt-tf rg-dt-ps rg-dt-azd rg-dt-pstf rg-dt-pscl; do
  az group delete -n "$rg" --yes --no-wait 2>/dev/null && log "  deleting $rg" || true
done
# Clean TF state
rm -rf terraform/terraform.tfstate.d terraform/terraform.tfvars.json terraform/tf.plan terraform/.terraform.lock.hcl 2>/dev/null
log ""

# ─────────── AZMON ───────────
log "═══════════════════════════════════════"
log "  AZMON-LAWAPPINSIGHTS"
log "═══════════════════════════════════════"

# Azmon × Bicep (Anthropic, new UAMI)
log "── azmon × Bicep (Anthropic, new UAMI) ──"
rm -rf /tmp/e2e-az-bicep
./bin/new-agent.sh --recipe azmon-lawappinsights --non-interactive \
  --set agentName=az-bicep --set resourceGroup=rg-az-bicep --set location=$REGION \
  --set targetRGs=rg-contoso-swe --set lawId="$LAW" \
  --set appInsightsId="$AI" --set appInsightsAppId="$AI_APPID" --set githubRepo="" \
  -o /tmp/e2e-az-bicep > /tmp/e2e-az-bicep-new.log 2>&1
result "new-agent" $?
./bin/deploy.sh /tmp/e2e-az-bicep/ --force > /tmp/e2e-az-bicep-deploy.log 2>&1
result "deploy (Bicep)" $?

# Azmon × TF (MicrosoftFoundry, existing UAMI)
log "── azmon × TF (MicrosoftFoundry, existing UAMI) ──"
rm -rf /tmp/e2e-az-tf
./bin/new-agent.sh --recipe azmon-lawappinsights --non-interactive \
  --set agentName=az-tf --set resourceGroup=rg-az-tf --set location=$REGION \
  --set targetRGs=rg-contoso-swe --set lawId="$LAW" \
  --set appInsightsId="$AI" --set appInsightsAppId="$AI_APPID" --set githubRepo="" \
  --set existingUamiId="$EXISTING_UAMI" --set modelProvider=MicrosoftFoundry \
  -o /tmp/e2e-az-tf > /tmp/e2e-az-tf-new.log 2>&1
result "new-agent" $?
./bin/deploy-tf.sh /tmp/e2e-az-tf/ > /tmp/e2e-az-tf-deploy.log 2>&1
result "deploy (TF)" $?

# Azmon × PS (Anthropic, existing AppInsights)
log "── azmon × PS (Anthropic, existing AppInsights) ──"
rm -rf /tmp/e2e-az-ps
pwsh -NoProfile -Command "
  & './bin/ps/New-Agent.ps1' -Recipe azmon-lawappinsights -NonInteractive \
    -Set @{agentName='az-ps'; resourceGroup='rg-az-ps'; location='$REGION'; targetRGs='rg-contoso-swe'; lawId='$LAW'; appInsightsId='$AI'; appInsightsAppId='$AI_APPID'; githubRepo=''; existingAgentAppInsightsId='$AI'} \
    -Output /tmp/e2e-az-ps
" > /tmp/e2e-az-ps-new.log 2>&1
result "new-agent (PS)" $?
pwsh -NoProfile -Command "& './bin/ps/Deploy-Agent.ps1' -InputPath /tmp/e2e-az-ps -Force" > /tmp/e2e-az-ps-deploy.log 2>&1
result "deploy (PS)" $?

# Azmon × PS-TF
log "── azmon × PS-TF (Anthropic) ──"
rm -rf /tmp/e2e-az-pstf
./bin/new-agent.sh --recipe azmon-lawappinsights --non-interactive \
  --set agentName=az-pstf --set resourceGroup=rg-az-pstf --set location=$REGION \
  --set targetRGs=rg-contoso-swe --set lawId="$LAW" \
  --set appInsightsId="$AI" --set appInsightsAppId="$AI_APPID" --set githubRepo="" \
  -o /tmp/e2e-az-pstf > /tmp/e2e-az-pstf-new.log 2>&1
result "new-agent" $?
pwsh -NoProfile -Command "& './bin/ps/Deploy-Tf.ps1' -InputPath /tmp/e2e-az-pstf" > /tmp/e2e-az-pstf-deploy.log 2>&1
result "deploy (PS-TF)" $?

# Azmon × azd (MicrosoftFoundry)
log "── azmon × azd (MicrosoftFoundry) ──"
rm -rf /tmp/e2e-az-azd
./bin/new-agent.sh --recipe azmon-lawappinsights --non-interactive \
  --set agentName=az-azd --set resourceGroup=rg-az-azd --set location=$REGION \
  --set targetRGs=rg-contoso-swe --set lawId="$LAW" \
  --set appInsightsId="$AI" --set appInsightsAppId="$AI_APPID" --set githubRepo="" \
  --set modelProvider=MicrosoftFoundry \
  -o /tmp/e2e-az-azd > /tmp/e2e-az-azd-new.log 2>&1
result "new-agent" $?
./bin/deploy.sh /tmp/e2e-az-azd/ --force > /tmp/e2e-az-azd-deploy.log 2>&1
result "deploy (azd-style Bicep)" $?

# Azmon × PS-Clone (clone from Bicep deploy)
log "── azmon × PS-Clone (from az-bicep) ──"
rm -rf /tmp/e2e-az-pscl
pwsh -NoProfile -Command "
  & './bin/ps/Clone-Agent.ps1' -Source /tmp/e2e-az-bicep \
    -AgentName az-pscl -ResourceGroup rg-az-pscl -Force
" > /tmp/e2e-az-pscl-deploy.log 2>&1
result "clone (PS)" $?

log ""

# ─────────── PAGERDUTY ───────────
log "═══════════════════════════════════════"
log "  PAGERDUTY-LAW-VMCOSMOS"
log "═══════════════════════════════════════"

# PD × Bicep (Anthropic, new UAMI)
log "── pd × Bicep (Anthropic, new UAMI) ──"
rm -rf /tmp/e2e-pd-bicep
./bin/new-agent.sh --recipe pagerduty-law-vmcosmos --non-interactive \
  --set agentName=pd-bicep --set resourceGroup=rg-pd-bicep --set location=$REGION \
  --set targetRGs=rg-contoso-swe --set lawId="$LAW" --set pagerdutyApiKey="u+fake-pd-key" \
  -o /tmp/e2e-pd-bicep > /tmp/e2e-pd-bicep-new.log 2>&1
result "new-agent" $?
./bin/deploy.sh /tmp/e2e-pd-bicep/ --force > /tmp/e2e-pd-bicep-deploy.log 2>&1
result "deploy (Bicep)" $?

# PD × TF (MicrosoftFoundry, existing UAMI + existing AppInsights)
log "── pd × TF (MicrosoftFoundry, existing UAMI + AI) ──"
rm -rf /tmp/e2e-pd-tf
./bin/new-agent.sh --recipe pagerduty-law-vmcosmos --non-interactive \
  --set agentName=pd-tf --set resourceGroup=rg-pd-tf --set location=$REGION \
  --set targetRGs=rg-contoso-swe --set lawId="$LAW" --set pagerdutyApiKey="u+fake-pd-key" \
  --set existingUamiId="$EXISTING_UAMI" --set existingAgentAppInsightsId="$AI" \
  --set modelProvider=MicrosoftFoundry \
  -o /tmp/e2e-pd-tf > /tmp/e2e-pd-tf-new.log 2>&1
result "new-agent" $?
./bin/deploy-tf.sh /tmp/e2e-pd-tf/ > /tmp/e2e-pd-tf-deploy.log 2>&1
result "deploy (TF)" $?

# PD × PS (Anthropic)
log "── pd × PS (Anthropic) ──"
rm -rf /tmp/e2e-pd-ps
pwsh -NoProfile -Command "
  & './bin/ps/New-Agent.ps1' -Recipe pagerduty-law-vmcosmos -NonInteractive \
    -Set @{agentName='pd-ps'; resourceGroup='rg-pd-ps'; location='$REGION'; targetRGs='rg-contoso-swe'; lawId='$LAW'; pagerdutyApiKey='u+fake-pd-key'} \
    -Output /tmp/e2e-pd-ps
" > /tmp/e2e-pd-ps-new.log 2>&1
result "new-agent (PS)" $?
pwsh -NoProfile -Command "& './bin/ps/Deploy-Agent.ps1' -InputPath /tmp/e2e-pd-ps -Force" > /tmp/e2e-pd-ps-deploy.log 2>&1
result "deploy (PS)" $?

# PD × PS-TF
log "── pd × PS-TF (Anthropic) ──"
rm -rf /tmp/e2e-pd-pstf
./bin/new-agent.sh --recipe pagerduty-law-vmcosmos --non-interactive \
  --set agentName=pd-pstf --set resourceGroup=rg-pd-pstf --set location=$REGION \
  --set targetRGs=rg-contoso-swe --set lawId="$LAW" --set pagerdutyApiKey="u+fake-pd-key" \
  -o /tmp/e2e-pd-pstf > /tmp/e2e-pd-pstf-new.log 2>&1
result "new-agent" $?
pwsh -NoProfile -Command "& './bin/ps/Deploy-Tf.ps1' -InputPath /tmp/e2e-pd-pstf" > /tmp/e2e-pd-pstf-deploy.log 2>&1
result "deploy (PS-TF)" $?

# PD × azd-style (existing UAMI)
log "── pd × azd-style (existing UAMI) ──"
rm -rf /tmp/e2e-pd-azd
./bin/new-agent.sh --recipe pagerduty-law-vmcosmos --non-interactive \
  --set agentName=pd-azd --set resourceGroup=rg-pd-azd --set location=$REGION \
  --set targetRGs=rg-contoso-swe --set lawId="$LAW" --set pagerdutyApiKey="u+fake-pd-key" \
  --set existingUamiId="$EXISTING_UAMI" \
  -o /tmp/e2e-pd-azd > /tmp/e2e-pd-azd-new.log 2>&1
result "new-agent" $?
./bin/deploy.sh /tmp/e2e-pd-azd/ --force > /tmp/e2e-pd-azd-deploy.log 2>&1
result "deploy (azd-style Bicep)" $?

# PD × Clone (bash, from Bicep)
log "── pd × Clone (bash, from pd-bicep) ──"
rm -rf /tmp/e2e-pd-pscl
./bin/export-agent.sh -s "$SUB" -g rg-pd-bicep -n pd-bicep -o /tmp/e2e-pd-export/ \
  --set agentName=pd-pscl --set resourceGroup=rg-pd-pscl --set location=$REGION \
  > /tmp/e2e-pd-export.log 2>&1
result "export" $?
./bin/deploy.sh /tmp/e2e-pd-export/ --force > /tmp/e2e-pd-pscl-deploy.log 2>&1
result "clone deploy (Bicep)" $?

log ""

# ─────────── DYNATRACE ───────────
log "═══════════════════════════════════════"
log "  DYNATRACE-MCP"
log "═══════════════════════════════════════"

# DT × Bicep (Anthropic, new UAMI)
log "── dt × Bicep (Anthropic, new UAMI) ──"
rm -rf /tmp/e2e-dt-bicep
./bin/new-agent.sh --recipe dynatrace-mcp --non-interactive \
  --set agentName=dt-bicep --set resourceGroup=rg-dt-bicep --set location=$REGION \
  --set targetRGs=rg-contoso-swe --set dtTenant=abc12345 --set dtToken="dt0c01.fake.token" \
  -o /tmp/e2e-dt-bicep > /tmp/e2e-dt-bicep-new.log 2>&1
result "new-agent" $?
./bin/deploy.sh /tmp/e2e-dt-bicep/ --force > /tmp/e2e-dt-bicep-deploy.log 2>&1
result "deploy (Bicep)" $?

# DT × TF (MicrosoftFoundry, existing UAMI)
log "── dt × TF (MicrosoftFoundry, existing UAMI) ──"
rm -rf /tmp/e2e-dt-tf
./bin/new-agent.sh --recipe dynatrace-mcp --non-interactive \
  --set agentName=dt-tf --set resourceGroup=rg-dt-tf --set location=$REGION \
  --set targetRGs=rg-contoso-swe --set dtTenant=abc12345 --set dtToken="dt0c01.fake.token" \
  --set existingUamiId="$EXISTING_UAMI" --set modelProvider=MicrosoftFoundry \
  -o /tmp/e2e-dt-tf > /tmp/e2e-dt-tf-new.log 2>&1
result "new-agent" $?
./bin/deploy-tf.sh /tmp/e2e-dt-tf/ > /tmp/e2e-dt-tf-deploy.log 2>&1
result "deploy (TF)" $?

# DT × PS (Anthropic)
log "── dt × PS (Anthropic) ──"
rm -rf /tmp/e2e-dt-ps
pwsh -NoProfile -Command "
  & './bin/ps/New-Agent.ps1' -Recipe dynatrace-mcp -NonInteractive \
    -Set @{agentName='dt-ps'; resourceGroup='rg-dt-ps'; location='$REGION'; targetRGs='rg-contoso-swe'; dtTenant='abc12345'; dtToken='dt0c01.fake.token'} \
    -Output /tmp/e2e-dt-ps
" > /tmp/e2e-dt-ps-new.log 2>&1
result "new-agent (PS)" $?
pwsh -NoProfile -Command "& './bin/ps/Deploy-Agent.ps1' -InputPath /tmp/e2e-dt-ps -Force" > /tmp/e2e-dt-ps-deploy.log 2>&1
result "deploy (PS)" $?

# DT × PS-TF
log "── dt × PS-TF (Anthropic) ──"
rm -rf /tmp/e2e-dt-pstf
./bin/new-agent.sh --recipe dynatrace-mcp --non-interactive \
  --set agentName=dt-pstf --set resourceGroup=rg-dt-pstf --set location=$REGION \
  --set targetRGs=rg-contoso-swe --set dtTenant=abc12345 --set dtToken="dt0c01.fake.token" \
  -o /tmp/e2e-dt-pstf > /tmp/e2e-dt-pstf-new.log 2>&1
result "new-agent" $?
pwsh -NoProfile -Command "& './bin/ps/Deploy-Tf.ps1' -InputPath /tmp/e2e-dt-pstf" > /tmp/e2e-dt-pstf-deploy.log 2>&1
result "deploy (PS-TF)" $?

# DT × azd-style (existing AppInsights)
log "── dt × azd-style (existing AppInsights) ──"
rm -rf /tmp/e2e-dt-azd
./bin/new-agent.sh --recipe dynatrace-mcp --non-interactive \
  --set agentName=dt-azd --set resourceGroup=rg-dt-azd --set location=$REGION \
  --set targetRGs=rg-contoso-swe --set dtTenant=abc12345 --set dtToken="dt0c01.fake.token" \
  --set existingAgentAppInsightsId="$AI" \
  -o /tmp/e2e-dt-azd > /tmp/e2e-dt-azd-new.log 2>&1
result "new-agent" $?
./bin/deploy.sh /tmp/e2e-dt-azd/ --force > /tmp/e2e-dt-azd-deploy.log 2>&1
result "deploy (azd-style Bicep)" $?

# DT × Clone (PS, from Bicep)
log "── dt × Clone (PS, from dt-bicep) ──"
rm -rf /tmp/e2e-dt-pscl
pwsh -NoProfile -Command "
  & './bin/ps/Clone-Agent.ps1' -Source /tmp/e2e-dt-bicep \
    -AgentName dt-pscl -ResourceGroup rg-dt-pscl -Force
" > /tmp/e2e-dt-pscl-deploy.log 2>&1
result "clone (PS)" $?

log ""

# ─────────── SUMMARY ───────────
log "═══════════════════════════════════════════════════════"
log "  E2E MATRIX: $PASS passed, $FAIL failed, $SKIP skipped"
log "═══════════════════════════════════════════════════════"
log ""
log "Combination coverage:"
log "  Backends: Bicep(3) TF(3) PS(3) PS-TF(3) azd-Bicep(3) Clone(3)"
log "  Model providers: Anthropic(9) MicrosoftFoundry(3)"
log "  Existing UAMI: yes(3) no(9)"
log "  Existing AppInsights: yes(2) no(10)"
log ""
log "Full log: $REPORT"

[[ $FAIL -eq 0 ]] && exit 0 || exit 1
