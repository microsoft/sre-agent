#!/bin/bash
# =============================================================================
# laptop-request-demo.sh — File a sample laptop replacement request against
# the IT portal so the it-support-handler agent has work to do.
# =============================================================================
set -euo pipefail

IT_PORTAL_URL=$(azd env get-value AZURE_IT_PORTAL_URL 2>/dev/null || echo "")
if [ -z "$IT_PORTAL_URL" ]; then
  echo "✗ AZURE_IT_PORTAL_URL not set — run azd up first"
  exit 1
fi

EMPLOYEE_ID="${EMPLOYEE_ID:-E1042}"
SERIAL="${SERIAL:-ZV-LT-2021-0987}"
REASON="${REASON:-Screen flickering and battery swelling. Need replacement ASAP.}"

echo "Submitting laptop replacement request to: $IT_PORTAL_URL"
echo "  employee_id: $EMPLOYEE_ID"
echo "  serial:      $SERIAL"
echo ""

# Try a few common endpoints — keep it best-effort.
for ep in "/api/requests" "/requests" "/submit"; do
  CODE=$(curl -s -o /tmp/itportal-resp.json -w "%{http_code}" \
    -X POST "${IT_PORTAL_URL}${ep}" \
    -H "Content-Type: application/json" \
    -d "{\"employeeId\":\"$EMPLOYEE_ID\",\"serial\":\"$SERIAL\",\"reason\":\"$REASON\"}" || echo "000")
  if [ "$CODE" = "200" ] || [ "$CODE" = "201" ] || [ "$CODE" = "202" ]; then
    echo "✓ Submitted via $ep (HTTP $CODE)"
    cat /tmp/itportal-resp.json 2>/dev/null && echo
    exit 0
  fi
done

echo "⚠ Could not reach a known endpoint on the IT portal."
echo "  Open it manually: $IT_PORTAL_URL"
