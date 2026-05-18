#!/usr/bin/env bash
# run-all-ps-e2e.sh — Run all 12 PS e2e tests (4 recipes × 3 backends)
# Run from sreagent-templates/ directory
# Usage:
#   ./tests/e2e-ps/run-all-ps-e2e.sh              # run all 12 tests
#   ./tests/e2e-ps/run-all-ps-e2e.sh azmon         # run only azmon tests
#   ./tests/e2e-ps/run-all-ps-e2e.sh dt bicep      # run dt-bicep only
#
# Requires: DT_TOKEN env var (for dynatrace tests)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPORT="/tmp/e2e-ps-matrix-results.txt"
> "$REPORT"

TOTAL_PASS=0; TOTAL_FAIL=0; TOTAL_SKIP=0
RESULTS=()

FILTER_RECIPE="${1:-}"
FILTER_BACKEND="${2:-}"

TESTS=(
  "test-azmon-bicep-ps.sh"
  "test-azmon-tf-ps.sh"
  "test-azmon-azd-ps.sh"
  "test-pd-bicep-ps.sh"
  "test-pd-tf-ps.sh"
  "test-pd-azd-ps.sh"
  "test-dt-bicep-ps.sh"
  "test-dt-tf-ps.sh"
  "test-dt-azd-ps.sh"
  "test-min-bicep-ps.sh"
  "test-min-tf-ps.sh"
  "test-min-azd-ps.sh"
)

log() { echo "$1" | tee -a "$REPORT"; }

log "╔══════════════════════════════════════════════════════╗"
log "║  E2E PS Matrix — 4 recipes × 3 backends             ║"
log "║  Started: $(date)       ║"
log "╚══════════════════════════════════════════════════════╝"
log ""

# Pre-flight: check DT_TOKEN for dt tests
if [[ -z "${DT_TOKEN:-}" ]]; then
  log "⚠️  DT_TOKEN not set — dynatrace tests will be skipped"
fi

for test in "${TESTS[@]}"; do
  # Extract recipe and backend from filename: test-{recipe}-{backend}-ps.sh
  recipe=$(echo "$test" | sed 's/test-//' | sed 's/-ps\.sh//' | rev | cut -d- -f2- | rev)
  backend=$(echo "$test" | sed 's/test-//' | sed 's/-ps\.sh//' | rev | cut -d- -f1 | rev)

  # Apply filters
  if [[ -n "$FILTER_RECIPE" && "$recipe" != *"$FILTER_RECIPE"* ]]; then
    continue
  fi
  if [[ -n "$FILTER_BACKEND" && "$backend" != *"$FILTER_BACKEND"* ]]; then
    continue
  fi

  # Skip dt tests if no DT_TOKEN
  if [[ "$recipe" == *"dt"* && -z "${DT_TOKEN:-}" ]]; then
    log "⏭️  SKIP: $test (DT_TOKEN not set)"
    RESULTS+=("SKIP: $test")
    ((TOTAL_SKIP++))
    continue
  fi

  log "────────────────────────────────────────"
  log "▶ Running: $test"
  log "────────────────────────────────────────"

  START_TIME=$(date +%s)
  bash "$SCRIPT_DIR/$test"
  RC=$?
  END_TIME=$(date +%s)
  DURATION=$((END_TIME - START_TIME))

  if [[ $RC -eq 0 ]]; then
    log "✅ PASS: $test (${DURATION}s)"
    RESULTS+=("PASS: $test (${DURATION}s)")
    ((TOTAL_PASS++))
  else
    log "❌ FAIL: $test (rc=$RC, ${DURATION}s)"
    RESULTS+=("FAIL: $test (rc=$RC, ${DURATION}s)")
    ((TOTAL_FAIL++))
  fi
  log ""
done

log ""
log "╔══════════════════════════════════════════════════════╗"
log "║  FINAL RESULTS                                       ║"
log "╠══════════════════════════════════════════════════════╣"
for r in "${RESULTS[@]}"; do
  log "║  $r"
done
log "╠══════════════════════════════════════════════════════╣"
log "║  PASS: $TOTAL_PASS  FAIL: $TOTAL_FAIL  SKIP: $TOTAL_SKIP"
log "║  Finished: $(date)"
log "╚══════════════════════════════════════════════════════╝"
log ""
log "Full report: $REPORT"

[[ $TOTAL_FAIL -eq 0 ]] && exit 0 || exit 1
