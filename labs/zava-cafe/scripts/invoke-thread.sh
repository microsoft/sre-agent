#!/bin/bash
# =============================================================================
# invoke-thread.sh — fire a smoke-test thread at sql-performance-investigator
# =============================================================================
set -euo pipefail

if ! command -v srectl >/dev/null 2>&1; then
  echo "✗ srectl not on PATH — install via aka.ms/sreagent-onboarding"
  exit 2
fi

AGENT_ENDPOINT=$(azd env get-value SRE_AGENT_ENDPOINT 2>/dev/null || echo "")
if [ -z "$AGENT_ENDPOINT" ]; then
  echo "✗ SRE_AGENT_ENDPOINT not set in azd env — run azd up first"
  exit 1
fi

PROMPT="${1:-Use the sql-query-diagnosis skill to inspect the top 5 slowest queries on the Zava SQL DB and summarize what you find in 3 bullets.}"
AGENT="${AGENT:-sql-performance-investigator}"

echo ""
echo "═══ Invoking $AGENT thread ═══"
echo "  endpoint: $AGENT_ENDPOINT"
echo "  prompt:   $PROMPT"
echo ""

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WS_DIR="$SCRIPT_DIR/../sre-config/agent1"
( cd "$WS_DIR" && srectl init --resource-url "$AGENT_ENDPOINT" >/dev/null 2>&1 || true )

OUTPUT=$(cd "$WS_DIR" && srectl thread new --agent "$AGENT" --message "$PROMPT" --no-wait 2>&1)
echo "$OUTPUT"
echo ""

THREAD_URL=$(echo "$OUTPUT" | grep -oE 'https://sre\.azure\.com/[^ ]+' | head -1 || true)
THREAD_ID=$(echo "$OUTPUT"  | grep -oE 'Thread ID: [a-f0-9-]+' | awk '{print $3}' | head -1 || true)

if [ -n "$THREAD_URL" ]; then
  echo "✓ Thread URL: $THREAD_URL"
elif [ -n "$THREAD_ID" ]; then
  echo "✓ Thread ID: $THREAD_ID — open https://sre.azure.com to follow"
else
  echo "⚠ Could not auto-detect thread URL — check output above."
fi
