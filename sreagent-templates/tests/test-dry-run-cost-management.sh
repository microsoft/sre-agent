#!/usr/bin/env bash
# tests/test-dry-run-cost-management.sh — cost-management recipe dry-run
set -uo pipefail
cd "$(dirname "$0")/.."
REPORT=/dev/null
source tests/lib/test-helpers.sh

RECIPE="cost-management"
EXTRA_SETS="existingUamiId=;existingAgentAppInsightsId="
EXP_SKILLS=1 EXP_SA=3 EXP_HOOKS=0 EXP_PROMPTS=1 EXP_SCHED=17 EXP_FILTERS=0 EXP_PLAT=0 EXP_HT=0
OUT="tests/.dryrun-${RECIPE}-$$"
if ! mkdir "$OUT"; then
  echo "Could not create test output directory: $OUT" >&2
  exit 1
fi
trap 'rm -rf "$OUT"' EXIT

log "═══ $RECIPE ═══"
log "── bash new-agent ──"
if ./bin/new-agent.sh --recipe "$RECIPE" --subscription ci-subscription --non-interactive --no-telemetry \
    --set agentName=dry-cost-management --set resourceGroup=rg-dry \
    --set location=swedencentral --set targetRGs=rg-fake \
    --set existingUamiId= --set 'modelProvider=Azure OpenAI' --set existingAgentAppInsightsId= \
    -o "$OUT/agent" >/dev/null 2>&1 && [[ -f "$OUT/agent/agent.json" ]]; then
  pass "new-agent"
else
  fail "new-agent"
  print_summary "$RECIPE"
  exit 1
fi

validate_config_dir "$OUT/agent" "$EXP_SKILLS" "$EXP_SA" "$EXP_HOOKS" "$EXP_PROMPTS" \
  "$EXP_SCHED" "$EXP_FILTERS" "$EXP_PLAT" "$EXP_HT"
validate_bicep_dryrun "$OUT/agent"
SRE_AGENT_NO_TELEMETRY=1 validate_ps_newagent "$RECIPE" "$EXTRA_SETS"
PS_OUT="/tmp/dryrun-ps-${RECIPE}"
if [[ -f "$PS_OUT/agent.json" ]]; then
  validate_config_dir "$PS_OUT" "$EXP_SKILLS" "$EXP_SA" "$EXP_HOOKS" "$EXP_PROMPTS" \
    "$EXP_SCHED" "$EXP_FILTERS" "$EXP_PLAT" "$EXP_HT"
fi

log "── validate assembled content ──"
if bash bicep/assemble-agent.sh "$OUT/agent" --output "$OUT/assembled" >/dev/null 2>&1; then
  pass "assemble"
else
  fail "assemble"
  print_summary "$RECIPE"
  exit 1
fi

EXTRAS="$OUT/assembled.extras.json"
for ((i=0; i<EXP_SKILLS; i++)); do
  sname=$(jq -r --argjson i "$i" '.skills[$i].metadata.name' "$EXTRAS")
  sclen=$(jq -r --argjson i "$i" '.skills[$i].skillContent | length' "$EXTRAS")
  assert_gt "skill $sname content" "$sclen" 50
done
for ((i=0; i<EXP_SA; i++)); do
  saname=$(jq -r --argjson i "$i" '.subagents[$i].metadata.name' "$EXTRAS")
  salen=$(jq -r --argjson i "$i" '.subagents[$i].spec.instructions | length' "$EXTRAS")
  assert_gt "subagent $saname instructions" "$salen" 50
done
assert_nonempty "custom instructions" "$(jq -r '.customInstructions // empty' "$EXTRAS")"
assert_eq "custom tools" "$(jq '.tools | length' "$EXTRAS")" 13
assert_eq "microsoft-teams connector operations" \
  "$(jq '[.connectorV2[]? | select(.metadata.name == "microsoft-teams") | .spec.operations | length] | if length == 1 then .[0] else null end' "$EXTRAS")" 7

log "── validate PowerShell assembled content ──"
if pwsh -NoProfile -File bicep/Assemble-Agent.ps1 -ConfigDir "$PS_OUT" -Output "$OUT/assembled-ps" >/dev/null 2>&1; then
  pass "PS assemble"
  PS_EXTRAS="$OUT/assembled-ps.extras.json"
  assert_nonempty "PS custom instructions" "$(jq -r '.customInstructions // empty' "$PS_EXTRAS")"
  assert_eq "PS custom tools" "$(jq '.tools | length' "$PS_EXTRAS")" 13
  assert_eq "PS microsoft-teams connector operations" \
    "$(jq '[.connectorV2[]? | select(.metadata.name == "microsoft-teams") | .spec.operations | length] | if length == 1 then .[0] else null end' "$PS_EXTRAS")" 7
else
  fail "PS assemble"
fi

print_summary "$RECIPE"
