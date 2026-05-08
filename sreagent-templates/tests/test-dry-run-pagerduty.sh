#!/usr/bin/env bash
# tests/test-dry-run-pagerduty.sh — pagerduty-law-vmcosmos: 4 backends × dry-run
set -uo pipefail
cd "$(dirname "$0")/.."
REPORT="/tmp/test-dry-run-pagerduty.txt"; > "$REPORT"
source tests/lib/test-helpers.sh

RECIPE="pagerduty-law-vmcosmos"
EXTRA_SETS="lawId=/sub/fake;pagerdutyApiKey=fake-pd-key"
EXP_SKILLS=3 EXP_SA=0 EXP_HOOKS=2 EXP_PROMPTS=1 EXP_SCHED=0 EXP_FILTERS=1 EXP_PLAT=1 EXP_HT=0
OUT="/tmp/dryrun-${RECIPE}"

log "═══ $RECIPE ═══"
log "── bash new-agent ──"
rm -rf "$OUT"
SET_ARGS="--set agentName=dry-${RECIPE} --set resourceGroup=rg-dry --set location=swedencentral --set targetRGs=rg-fake"
IFS_OLD="$IFS"; IFS=';'; for s in $EXTRA_SETS; do [[ -n "$s" ]] && SET_ARGS="$SET_ARGS --set $s"; done; IFS="$IFS_OLD"
eval "./bin/new-agent.sh --recipe $RECIPE --non-interactive $SET_ARGS -o $OUT" > /tmp/dryrun-new.log 2>&1
if [[ -f "$OUT/agent.json" ]]; then pass "new-agent"; else fail "new-agent"; print_summary "$RECIPE"; exit 1; fi

validate_config_dir "$OUT" $EXP_SKILLS $EXP_SA $EXP_HOOKS $EXP_PROMPTS $EXP_SCHED $EXP_FILTERS $EXP_PLAT $EXP_HT
validate_assembled_content "$OUT"
validate_bicep_dryrun "$OUT"
validate_tf_dryrun "$OUT" $EXP_SKILLS $EXP_SA $EXP_PROMPTS
validate_ps_newagent "$RECIPE" "$EXTRA_SETS"
validate_azd_dryrun "$OUT"

print_summary "$RECIPE"
exit $?
