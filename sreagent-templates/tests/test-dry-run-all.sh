#!/usr/bin/env bash
# tests/test-dry-run-all.sh — Run recipe dry-run and template consistency tests
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

for test in tests/test-export-prerequisites.sh tests/test-supported-regions.py; do
  name=$(basename "$test")
  echo "════════════ $name ════════════"
  if [[ "$test" == *.py ]]; then
    python_cmd=$(command -v python3 || command -v python)
    "$python_cmd" "$test"
  else
    bash "$test"
  fi
  rc=$?
  if [[ $rc -eq 0 ]]; then
    TOTAL_PASS=$((TOTAL_PASS+1))
    echo "  → $name: ALL PASS"
  else
    TOTAL_FAIL=$((TOTAL_FAIL+1))
    echo "  → $name: HAS FAILURES"
  fi
  echo ""
done

if command -v pwsh >/dev/null 2>&1; then
  test="tests/Test-ExportPrerequisites.ps1"
  name=$(basename "$test")
  echo "════════════ $name ════════════"
  pwsh -NoLogo -NoProfile -File "$test"
  rc=$?
  if [[ $rc -eq 0 ]]; then
    TOTAL_PASS=$((TOTAL_PASS+1))
    echo "  → $name: ALL PASS"
  else
    TOTAL_FAIL=$((TOTAL_FAIL+1))
    echo "  → $name: HAS FAILURES"
  fi
  echo ""
fi

echo "═══════════════════════════════════════════════════════"
echo "  ALL TESTS: $TOTAL_PASS passed, $TOTAL_FAIL failed (of $((TOTAL_PASS+TOTAL_FAIL)))"
echo "═══════════════════════════════════════════════════════"

[[ $TOTAL_FAIL -eq 0 ]] && exit 0 || exit 1
