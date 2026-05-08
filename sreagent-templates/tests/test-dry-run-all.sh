#!/usr/bin/env bash
# tests/test-dry-run-all.sh — Run all 6 recipe dry-run tests
set -uo pipefail
cd "$(dirname "$0")/.."

TOTAL_PASS=0; TOTAL_FAIL=0
REPORT="/tmp/test-dry-run-all.txt"; > "$REPORT"

for test in tests/test-dry-run-*.sh; do
  [[ "$test" == *"-all.sh" ]] && continue
  recipe=$(basename "$test" .sh | sed 's/test-dry-run-//')
  echo "════════════ $recipe ════════════"
  bash "$test"
  rc=$?
  if [[ $rc -eq 0 ]]; then
    TOTAL_PASS=$((TOTAL_PASS+1))
    echo "  → $recipe: ALL PASS"
  else
    TOTAL_FAIL=$((TOTAL_FAIL+1))
    echo "  → $recipe: HAS FAILURES"
  fi
  echo ""
done

echo "═══════════════════════════════════════════════════════"
echo "  ALL RECIPES: $TOTAL_PASS passed, $TOTAL_FAIL failed (of $((TOTAL_PASS+TOTAL_FAIL)))"
echo "═══════════════════════════════════════════════════════"

[[ $TOTAL_FAIL -eq 0 ]] && exit 0 || exit 1
