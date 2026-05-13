#!/bin/bash
# =============================================================================
# invoke-thread.sh — smoke-test the SRE Agent end-to-end via srectl
#
# Calls `srectl thread new` against the deployed agent with a sample prompt,
# then prints the thread URL for the user to follow in the portal.
#
# Prereqs:
#   - srectl on PATH (private preview)
#   - azd env set up (post-provision has run)
# =============================================================================
set -euo pipefail

if ! command -v srectl >/dev/null 2>&1; then
  echo "✗ srectl not on PATH — install via aka.ms/sreagent-onboarding"
  exit 2
fi

AGENT_ENDPOINT=$(azd env get-value SRE_AGENT_ENDPOINT 2>/dev/null || echo "")
if [ -z "$AGENT_ENDPOINT" ]; then
  echo "✗ SRE_AGENT_ENDPOINT not set in azd env — run: azd env get-values"
  exit 1
fi

PROMPT="${1:-Use the grubify-diagnosis skill and the CheckGrubifyHealth tool to confirm the Grubify app is healthy. Summarize what you found in 3 bullet points.}"

echo ""
echo "═══ Invoking incident-handler thread ═══"
echo "  agent endpoint: $AGENT_ENDPOINT"
echo "  prompt:         $PROMPT"
echo ""

srectl init --resource-url "$AGENT_ENDPOINT" >/dev/null 2>&1 || true

# Create the thread; capture stdout for thread URL parsing
OUTPUT=$(srectl thread new \
  --agent incident-handler \
  --message "$PROMPT" \
  --no-wait 2>&1)

echo "$OUTPUT"
echo ""

# Best-effort: extract a thread URL or ID from output
THREAD_URL=$(echo "$OUTPUT" | grep -oE 'https://sre\.azure\.com/[^ ]+' | head -1 || true)
THREAD_ID=$(echo  "$OUTPUT" | grep -oE 'thread[_-]?[iI]d[":[:space:]=]+[a-zA-Z0-9-]+' | head -1 || true)

if [ -n "$THREAD_URL" ]; then
  echo "✓ Thread URL: $THREAD_URL"
elif [ -n "$THREAD_ID" ]; then
  echo "✓ Thread reference: $THREAD_ID"
else
  echo "⚠ Could not auto-detect thread URL — check output above for the link."
fi
