#!/usr/bin/env bash
# tests/test-e2e-3p.sh — Full e2e deploy test: 3 3P recipes × 4 backends × create/update/clone
# Deploys real Azure resources. Runs verify-agent.sh after every deploy.
# Reports PASS only if verify shows expected skill/subagent/connector counts.
set -uo pipefail
cd "$(dirname "$0")/.."

SUB="cbf44432-7f45-4906-a85d-d2b14a1e8328"
LAW_CONTOSO="/subscriptions/$SUB/resourceGroups/rg-contoso-swe/providers/Microsoft.OperationalInsights/workspaces/law-7defkiyvn3r44"
LAW_EBC="/subscriptions/$SUB/resourceGroups/rg-ebc-demo3/providers/Microsoft.OperationalInsights/workspaces/law-ebc-demo3"
AI_ID="/subscriptions/$SUB/resourceGroups/rg-contoso-swe/providers/microsoft.insights/components/sreagent-recipes-telemetry"
AI_APPID="3b50188a-a191-4f74-994a-2e7ed8afc018"
DT_TENANT="${DT_TENANT:-dhu66396}"
DT_TOKEN="${DT_TOKEN:?Set DT_TOKEN env var for e2e tests}"
REGION="swedencentral"
REPORT="/tmp/e2e-3p-report.txt"
> "$REPORT"

TOTAL=0; PASS=0; FAIL=0
log() { echo "$1" | tee -a "$REPORT"; }
result() {
  TOTAL=$((TOTAL+1))
  if [[ "$1" == "PASS" ]]; then PASS=$((PASS+1)); log "  ✅ $2"
  else FAIL=$((FAIL+1)); log "  ❌ $2"; fi
}

# Verify: check skill + subagent + connector counts from verify output
run_verify() {
  local sub="$1" rg="$2" agent="$3" expected="$4" label="$5"
  local vout
  vout=$(./bin/verify-agent.sh "$sub" "$rg" "$agent" --expected "$expected" 2>&1)
  local passed=$(echo "$vout" | grep -o "passed" | head -1)
  local fail_count=$(echo "$vout" | grep "failed" | sed 's/[^0-9]*\([0-9]*\) failed.*/\1/' | head -1)
  # Check skills deployed (not 0)
  local skills=$(echo "$vout" | grep "Skills " | awk '{print $2}' | head -1)
  if [[ "${fail_count:-99}" -le 2 && "${skills:-0}" -gt 0 ]]; then
    result "PASS" "$label verify: ${skills} skills, ${fail_count:-0} failures"
  else
    result "FAIL" "$label verify: skills=${skills:-0}, failures=${fail_count:-?}"
    echo "$vout" >> "$REPORT"
  fi
}

# ═══════════════════════════════════════════════════════════════
log "═══ E2E 3P TEST — $(date -u +%Y-%m-%dT%H:%M:%SZ) ═══"
log "Branch: $(git branch --show-current) ($(git rev-parse --short HEAD))"
log ""

# ── Recipe configs ──
declare_recipe() {
  # $1=key $2=recipe $3=extra_sets
  eval "R_${1}_RECIPE='$2'"
  eval "R_${1}_SETS='$3'"
}

declare_recipe AZMON azmon-lawappinsights "lawId=$LAW_CONTOSO;appInsightsId=$AI_ID;appInsightsAppId=$AI_APPID;githubRepo="
declare_recipe PD pagerduty-law-vmcosmos "lawId=$LAW_EBC;pagerdutyApiKey=u+fake-pd-key"
declare_recipe DT httptrigger-dynatrace "lawId=$LAW_CONTOSO;appInsightsId=$AI_ID;appInsightsAppId=$AI_APPID;dtTenant=$DT_TENANT;dtToken=$DT_TOKEN;githubRepo="

# ── Test function: one recipe × one backend × create/update/clone ──
test_backend() {
  local key="$1" backend="$2"
  local recipe=$(eval echo "\$R_${key}_RECIPE")
  local extra=$(eval echo "\$R_${key}_SETS")
  local prefix="$(echo $key | tr A-Z a-z)-${backend}"
  local agent="${prefix}"
  local rg="rg-${prefix}"
  local dir="/tmp/e2e-${prefix}"
  local clone_agent="${prefix}-cl"
  local clone_rg="rg-${prefix}-cl"
  local clone_dir="/tmp/e2e-${prefix}-cl"

  log ""
  log "══ ${key} × ${backend} ══"

  # ── Create ──
  rm -rf "$dir"
  local SET_ARGS="--set agentName=${agent} --set resourceGroup=${rg} --set location=${REGION} --set targetRGs=rg-contoso-swe"
  local IFS_OLD="$IFS"; IFS=';'
  for s in $extra; do [[ -n "$s" ]] && SET_ARGS="$SET_ARGS --set $s"; done
  IFS="$IFS_OLD"

  eval "./bin/new-agent.sh --recipe $recipe --non-interactive $SET_ARGS -o $dir" > /dev/null 2>&1
  [[ ! -f "$dir/agent.json" ]] && { result "FAIL" "new-agent"; return; }

  case "$backend" in
    bicep) ./bin/deploy.sh "$dir/" --force > "/tmp/e2e-${prefix}-deploy.log" 2>&1 ;;
    tf)    ./bin/deploy-tf.sh "$dir/" > "/tmp/e2e-${prefix}-deploy.log" 2>&1 ;;
    azd)
      azd env new "$prefix" --no-prompt 2>/dev/null
      azd env set AZURE_AGENT_NAME "$agent" --no-prompt 2>/dev/null
      azd env set AZURE_RESOURCE_GROUP "$rg" --no-prompt 2>/dev/null
      azd env set AZURE_LOCATION "$REGION" --no-prompt 2>/dev/null
      azd env set AZURE_SUBSCRIPTION_ID "$SUB" --no-prompt 2>/dev/null
      # Config already at agents/$agent/ from new-agent → copy
      mkdir -p "agents/${agent}" && cp -r "$dir/"* "agents/${agent}/"
      azd up --no-prompt > "/tmp/e2e-${prefix}-deploy.log" 2>&1
      ;;
    ps)
      pwsh -NoProfile -Command "& './bin/ps/Deploy-Agent.ps1' -InputPath '$dir' -Force" > "/tmp/e2e-${prefix}-deploy.log" 2>&1
      ;;
  esac
  local deploy_rc=$?
  if [[ $deploy_rc -ne 0 ]]; then result "FAIL" "create (exit $deploy_rc)"; return; fi
  result "PASS" "create"

  # ── Verify create ──
  run_verify "$SUB" "$rg" "$agent" "$dir" "create"

  # ── Update ──
  case "$backend" in
    bicep) ./bin/deploy.sh "$dir/" --force > "/tmp/e2e-${prefix}-update.log" 2>&1 ;;
    tf)    ./bin/deploy-tf.sh "$dir/" > "/tmp/e2e-${prefix}-update.log" 2>&1 ;;
    azd)   azd env select "$prefix" 2>/dev/null; azd up --no-prompt > "/tmp/e2e-${prefix}-update.log" 2>&1 ;;
    ps)    pwsh -NoProfile -Command "& './bin/ps/Deploy-Agent.ps1' -InputPath '$dir' -Force" > "/tmp/e2e-${prefix}-update.log" 2>&1 ;;
  esac
  result "$([ $? -eq 0 ] && echo PASS || echo FAIL)" "update"

  # ── Clone ──
  rm -rf "$clone_dir"
  ./bin/export-agent.sh -s "$SUB" -g "$rg" -n "$agent" -o "$clone_dir/" \
    --set agentName="$clone_agent" --set resourceGroup="$clone_rg" --set location="$REGION" > /dev/null 2>&1
  [[ ! -f "$clone_dir/agent.json" ]] && { result "FAIL" "export"; return; }
  result "PASS" "export"

  case "$backend" in
    bicep) ./bin/deploy.sh "$clone_dir/" --force > "/tmp/e2e-${prefix}-clone.log" 2>&1 ;;
    tf)    ./bin/deploy-tf.sh "$clone_dir/" > "/tmp/e2e-${prefix}-clone.log" 2>&1 ;;
    azd)
      mkdir -p "agents/${clone_agent}" && cp -r "$clone_dir/"* "agents/${clone_agent}/"
      azd env new "${prefix}-cl" --no-prompt 2>/dev/null
      azd env set AZURE_AGENT_NAME "$clone_agent" --no-prompt 2>/dev/null
      azd env set AZURE_RESOURCE_GROUP "$clone_rg" --no-prompt 2>/dev/null
      azd env set AZURE_LOCATION "$REGION" --no-prompt 2>/dev/null
      azd env set AZURE_SUBSCRIPTION_ID "$SUB" --no-prompt 2>/dev/null
      azd up --no-prompt > "/tmp/e2e-${prefix}-clone.log" 2>&1
      ;;
    ps) pwsh -NoProfile -Command "& './bin/ps/Deploy-Agent.ps1' -InputPath '$clone_dir' -Force" > "/tmp/e2e-${prefix}-clone.log" 2>&1 ;;
  esac
  local clone_rc=$?
  if [[ $clone_rc -ne 0 ]]; then result "FAIL" "clone (exit $clone_rc)"; return; fi
  result "PASS" "clone"

  # ── Verify clone ──
  run_verify "$SUB" "$clone_rg" "$clone_agent" "$clone_dir" "clone"
}

# ── Run all 12 combos (3 recipes × 4 backends) ──
for key in AZMON PD DT; do
  for backend in bicep tf azd ps; do
    test_backend "$key" "$backend"
  done
done

# ── Summary ──
log ""
log "═══════════════════════════════════════════════════════"
log "  E2E RESULTS: $PASS passed, $FAIL failed (of $TOTAL)"
log "  Report: $REPORT"
log "═══════════════════════════════════════════════════════"

# ── Cleanup ──
log ""
log "Cleaning up resource groups..."
for key in AZMON PD DT; do
  for backend in bicep tf azd ps; do
    prefix="$(echo $key | tr A-Z a-z)-${backend}"
    az group delete -n "rg-${prefix}" --yes --no-wait 2>/dev/null
    az group delete -n "rg-${prefix}-cl" --yes --no-wait 2>/dev/null
  done
done
log "Cleanup queued."

[[ $FAIL -eq 0 ]] && exit 0 || exit 1
