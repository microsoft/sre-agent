#!/usr/bin/env bash
# run-all-e2e.sh — Run all 15 e2e tests sequentially, collect results.
set -o pipefail

REPORT="/tmp/e2e-all-results.txt"
> "$REPORT"

SCRIPTS=(
  test-azmon-bicep-bash.sh
  test-azmon-bicep-ps.sh
  test-azmon-tf-bash.sh
  test-azmon-tf-ps.sh
  test-azmon-azd-bash.sh
  test-pd-bicep-bash.sh
  test-pd-bicep-ps.sh
  test-pd-tf-bash.sh
  test-pd-tf-ps.sh
  test-pd-azd-bash.sh
  test-dt-bicep-bash.sh
  test-dt-bicep-ps.sh
  test-dt-tf-bash.sh
  test-dt-tf-ps.sh
  test-dt-azd-bash.sh
)

TOTAL=0; PASS=0; FAIL=0
declare -a SUMMARY

log() { echo "$1" | tee -a "$REPORT"; }

log "═══════════════════════════════════════════════════════════════"
log "  SRE Agent E2E Test Suite — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
log "  Scripts: ${#SCRIPTS[@]}"
log "═══════════════════════════════════════════════════════════════"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

for script in "${SCRIPTS[@]}"; do
  ((TOTAL++))
  log ""
  log "───────────────────────────────────────────────────────────────"
  log "  [$TOTAL/${#SCRIPTS[@]}] Running: $script"
  log "  Started: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  log "───────────────────────────────────────────────────────────────"

  START_TS=$(date +%s)
  bash "$SCRIPT_DIR/$script" 2>&1 | tee -a "$REPORT"
  RC=${PIPESTATUS[0]}
  END_TS=$(date +%s)
  ELAPSED=$(( END_TS - START_TS ))

  if [[ $RC -eq 0 ]]; then
    ((PASS++))
    SUMMARY+=("PASS  ${script}  (${ELAPSED}s)")
    log "  >>> $script: PASS (${ELAPSED}s)"
  else
    ((FAIL++))
    SUMMARY+=("FAIL  ${script}  (${ELAPSED}s, rc=$RC)")
    log "  >>> $script: FAIL rc=$RC (${ELAPSED}s)"
  fi
done

log ""
log "═══════════════════════════════════════════════════════════════"
log "  E2E TEST SUITE RESULTS"
log "  Completed: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
log "═══════════════════════════════════════════════════════════════"
for s in "${SUMMARY[@]}"; do log "  $s"; done
log "───────────────────────────────────────────────────────────────"
log "  TOTAL: $PASS passed, $FAIL failed out of $TOTAL"
log "═══════════════════════════════════════════════════════════════"
log "  Full report: $REPORT"
log "  Individual logs: /tmp/e2e-*.log"

[[ $FAIL -eq 0 ]] && exit 0 || exit 1
