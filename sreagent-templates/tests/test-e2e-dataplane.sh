#!/usr/bin/env bash
# tests/test-e2e-dataplane.sh — Full e2e test: 3 recipes × 5 backends × new/update/clone
# Backends: bicep-bash, bicep-ps, tf-bash, tf-ps, azd-bash
# Note: azd-ps not available (no PS azd script)
set -o pipefail
cd "$(dirname "$0")/.."

SUB="cbf44432-7f45-4906-a85d-d2b14a1e8328"
LAW_CONTOSO="/subscriptions/$SUB/resourceGroups/rg-contoso-swe/providers/Microsoft.OperationalInsights/workspaces/law-7defkiyvn3r44"
LAW_EBC="/subscriptions/$SUB/resourceGroups/rg-ebc-demo3/providers/Microsoft.OperationalInsights/workspaces/law-ebc-demo3"
AI_ID="/subscriptions/$SUB/resourceGroups/rg-contoso-swe/providers/microsoft.insights/components/sreagent-recipes-telemetry"
AI_APPID="3b50188a-a191-4f74-994a-2e7ed8afc018"
DT_TENANT="${DT_TENANT:-dhu66396}"
DT_TOKEN="${DT_TOKEN:?Set DT_TOKEN env var}"
REGION="swedencentral"

REPORT="/tmp/e2e-dataplane-results.txt"
> "$REPORT"
TOTAL=0; PASS_CT=0; FAIL_CT=0

log()    { echo "$1" | tee -a "$REPORT"; }
result() {
  TOTAL=$((TOTAL+1))
  if [[ "$1" == "PASS" ]]; then PASS_CT=$((PASS_CT+1)); log "  ✅ $2"
  else FAIL_CT=$((FAIL_CT+1)); log "  ❌ $2"; fi
}

run_verify() {
  local sub="$1" rg="$2" agent="$3" expected="$4" label="$5"
  local vout=""
  vout=$(./bin/verify-agent.sh "$sub" "$rg" "$agent" --expected "$expected" 2>&1) || true
  local fail_count=""
  fail_count=$(echo "$vout" | sed -n 's/.*Results: [0-9]* passed, \([0-9]*\) failed.*/\1/p' | head -1) || true
  local pass_count=""
  pass_count=$(echo "$vout" | sed -n 's/.*Results: \([0-9]*\) passed.*/\1/p' | head -1) || true
  local skills=""
  skills=$(echo "$vout" | grep "Skills " | awk '{print $2}' | head -1) || true
  if [[ "${fail_count:-99}" -le 2 && "${skills:-0}" -gt 0 ]]; then
    result "PASS" "$label verify: ${pass_count:-?} passed, ${fail_count:-0} failed, ${skills:-0} skills"
  else
    result "FAIL" "$label verify: skills=${skills:-0}, failures=${fail_count:-?}"
    echo "$vout" >> "$REPORT"
  fi
}

deploy_new() {
  local dir="$1" backend="$2" shell="$3" prefix="$4" agent="$5" rg="$6"
  local logfile="/tmp/e2e-${prefix}-new.log"
  case "${backend}-${shell}" in
    bicep-bash)
      ./bin/deploy.sh "$dir/" --force > "$logfile" 2>&1 ;;
    bicep-ps)
      pwsh -NoProfile -Command "& './bin/ps/Deploy-Agent.ps1' -InputPath '$dir' -Force" > "$logfile" 2>&1 ;;
    tf-bash)
      ./bin/deploy-tf.sh "$dir/" > "$logfile" 2>&1 ;;
    tf-ps)
      pwsh -NoProfile -Command "& './bin/ps/Deploy-Tf.ps1' -InputPath '$dir'" > "$logfile" 2>&1 ;;
    azd-bash)
      azd env new "$prefix" --no-prompt 2>/dev/null || true
      azd env set AZURE_AGENT_NAME "$agent" --no-prompt 2>/dev/null || true
      azd env set AZURE_RESOURCE_GROUP "$rg" --no-prompt 2>/dev/null || true
      azd env set AZURE_LOCATION "$REGION" --no-prompt 2>/dev/null || true
      azd env set AZURE_SUBSCRIPTION_ID "$SUB" --no-prompt 2>/dev/null || true
      mkdir -p "agents/${agent}" && cp -r "$dir/"* "agents/${agent}/"
      azd up --no-prompt > "$logfile" 2>&1 ;;
  esac
  return $?
}

deploy_update() {
  local dir="$1" backend="$2" shell="$3" prefix="$4"
  local logfile="/tmp/e2e-${prefix}-update.log"
  case "${backend}-${shell}" in
    bicep-bash)
      ./bin/deploy.sh "$dir/" --force > "$logfile" 2>&1 ;;
    bicep-ps)
      pwsh -NoProfile -Command "& './bin/ps/Deploy-Agent.ps1' -InputPath '$dir' -Force" > "$logfile" 2>&1 ;;
    tf-bash)
      ./bin/deploy-tf.sh "$dir/" > "$logfile" 2>&1 ;;
    tf-ps)
      pwsh -NoProfile -Command "& './bin/ps/Deploy-Tf.ps1' -InputPath '$dir'" > "$logfile" 2>&1 ;;
    azd-bash)
      azd env select "$prefix" 2>/dev/null || true
      azd up --no-prompt > "$logfile" 2>&1 ;;
  esac
  return $?
}

deploy_clone() {
  local dir="$1" backend="$2" shell="$3" prefix="$4" agent="$5" rg="$6"
  local logfile="/tmp/e2e-${prefix}-clone.log"
  case "${backend}-${shell}" in
    bicep-bash)
      ./bin/deploy.sh "$dir/" --force > "$logfile" 2>&1 ;;
    bicep-ps)
      pwsh -NoProfile -Command "& './bin/ps/Deploy-Agent.ps1' -InputPath '$dir' -Force" > "$logfile" 2>&1 ;;
    tf-bash)
      ./bin/deploy-tf.sh "$dir/" > "$logfile" 2>&1 ;;
    tf-ps)
      pwsh -NoProfile -Command "& './bin/ps/Deploy-Tf.ps1' -InputPath '$dir'" > "$logfile" 2>&1 ;;
    azd-bash)
      local clone_env="${prefix}"
      mkdir -p "agents/${agent}" && cp -r "$dir/"* "agents/${agent}/"
      azd env new "$clone_env" --no-prompt 2>/dev/null || true
      azd env set AZURE_AGENT_NAME "$agent" --no-prompt 2>/dev/null || true
      azd env set AZURE_RESOURCE_GROUP "$rg" --no-prompt 2>/dev/null || true
      azd env set AZURE_LOCATION "$REGION" --no-prompt 2>/dev/null || true
      azd env set AZURE_SUBSCRIPTION_ID "$SUB" --no-prompt 2>/dev/null || true
      azd up --no-prompt > "$logfile" 2>&1 ;;
  esac
  return $?
}

# ═══════════════════════════════════════════════════════════════
log "═══ E2E DATAPLANE TEST — $(date -u +%Y-%m-%dT%H:%M:%SZ) ═══"
log "Branch: $(git branch --show-current) ($(git rev-parse --short HEAD))"
log ""

test_combo() {
  local recipe_key="$1" backend="$2" shell="$3"
  local recipe="" extra=""
  case "$recipe_key" in
    azmon) recipe="azmon-lawappinsights"
           extra="lawId=$LAW_CONTOSO;appInsightsId=$AI_ID;appInsightsAppId=$AI_APPID;githubRepo=" ;;
    pd)    recipe="pagerduty-law-vmcosmos"
           extra="lawId=$LAW_EBC;pagerdutyApiKey=u+fake-pd-key" ;;
    dt)    recipe="dynatrace-mcp"
           extra="lawId=$LAW_CONTOSO;appInsightsId=$AI_ID;appInsightsAppId=$AI_APPID;dtTenant=$DT_TENANT;dtToken=$DT_TOKEN;githubRepo=" ;;
  esac

  local prefix="${recipe_key}-${shell}-${backend}"
  local agent="${prefix}"
  local rg="rg-${prefix}"
  local dir="/tmp/e2e-${prefix}"
  local clone_prefix="${prefix}-cl"
  local clone_agent="${prefix}-cl"
  local clone_rg="rg-${prefix}-cl"
  local clone_dir="/tmp/e2e-${prefix}-cl"

  log ""
  log "══ ${recipe_key} × ${backend}-${shell} ══"

  # ── NEW ──
  rm -rf "$dir"
  local SET_ARGS="--set agentName=${agent} --set resourceGroup=${rg} --set location=${REGION} --set targetRGs=rg-contoso-swe"
  local IFS_OLD="$IFS"; IFS=';'
  for s in $extra; do [[ -n "$s" ]] && SET_ARGS="$SET_ARGS --set $s"; done
  IFS="$IFS_OLD"

  eval "./bin/new-agent.sh --recipe $recipe --non-interactive $SET_ARGS -o $dir" > /dev/null 2>&1
  if [[ ! -f "$dir/agent.json" ]]; then result "FAIL" "new-agent ($prefix)"; return; fi

  deploy_new "$dir" "$backend" "$shell" "$prefix" "$agent" "$rg"
  local rc=$?
  if [[ $rc -ne 0 ]]; then result "FAIL" "new (exit $rc)"; return; fi
  result "PASS" "new"

  run_verify "$SUB" "$rg" "$agent" "$dir" "new"

  # ── UPDATE ──
  deploy_update "$dir" "$backend" "$shell" "$prefix"
  result "$([ $? -eq 0 ] && echo PASS || echo FAIL)" "update"

  # ── CLONE ──
  rm -rf "$clone_dir"
  ./bin/export-agent.sh -s "$SUB" -g "$rg" -n "$agent" -o "$clone_dir/" \
    --set agentName="$clone_agent" --set resourceGroup="$clone_rg" --set location="$REGION" > /dev/null 2>&1
  if [[ ! -f "$clone_dir/agent.json" ]]; then result "FAIL" "export ($prefix)"; return; fi
  result "PASS" "export"

  deploy_clone "$clone_dir" "$backend" "$shell" "$clone_prefix" "$clone_agent" "$clone_rg"
  rc=$?
  if [[ $rc -ne 0 ]]; then result "FAIL" "clone (exit $rc)"; return; fi
  result "PASS" "clone"

  run_verify "$SUB" "$clone_rg" "$clone_agent" "$clone_dir" "clone"
}

# ── Run all combos: 3 recipes × 5 backends ──
for recipe_key in azmon pd dt; do
  for combo in bicep:bash bicep:ps tf:bash tf:ps azd:bash; do
    backend="${combo%%:*}"
    shell="${combo##*:}"
    test_combo "$recipe_key" "$backend" "$shell"
  done
done

# ── Summary ──
log ""
log "═══════════════════════════════════════════════════════"
log "  E2E RESULTS: $PASS_CT passed, $FAIL_CT failed (of $TOTAL)"
log "  Report: $REPORT"
log "═══════════════════════════════════════════════════════"
log ""
log "Note: azd-ps not tested (no PS azd deploy script exists)"
