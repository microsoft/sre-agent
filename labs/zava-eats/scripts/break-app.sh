#!/bin/bash
# =============================================================================
# Break App Script — Simulates memory leak on Grubify
#
# This script:
#   1. Checks app health
#   2. Floods the cart API with rapid POST requests to cause memory leak
#   3. Azure Monitor detects memory pressure / OOM / HTTP errors
#   4. The SRE Agent picks up the alert and begins investigation
#
# The /api/cart/demo-user/items endpoint accumulates cart items in memory.
# Rapid repeated calls cause memory to grow until the container OOMs or
# starts returning 500 errors from memory pressure.
# =============================================================================
set -e

# Configuration
REQUEST_COUNT=${2:-200}
SLEEP_INTERVAL=${3:-0.5}

# Get Container App URL from azd environment or argument
APP_URL="${1:-}"
if [ -z "$APP_URL" ]; then
  APP_URL=$(azd env get-values 2>/dev/null | grep "^CONTAINER_APP_URL=" | cut -d'=' -f2 | tr -d '"')
fi

if [ -z "$APP_URL" ]; then
  echo "Error: Could not determine Grubify URL."
  echo "Usage: ./scripts/break-app.sh [https://your-app-url] [request-count] [sleep-seconds]"
  echo "   Or: Run from the lab directory after 'azd up'"
  exit 1
fi

echo ""
echo "============================================="
echo "  🔥 Breaking the Grubify App (Memory Leak)"
echo "============================================="
echo ""
echo "  Target:    ${APP_URL}"
echo "  Requests:  ${REQUEST_COUNT}"
echo "  Interval:  ${SLEEP_INTERVAL}s"
echo ""

# Step 1: Check app is healthy first
echo "Step 1: Checking app health..."
HEALTH_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "${APP_URL}/health" 2>/dev/null || echo "000")
if [ "$HEALTH_STATUS" = "200" ]; then
  echo "  ✓ App is healthy (HTTP ${HEALTH_STATUS})"
else
  echo "  ⚠ App returned HTTP ${HEALTH_STATUS} — proceeding anyway"
fi
echo ""

# Step 2: Flood cart API to cause memory leak
echo "Step 2: Flooding cart API to simulate memory leak..."
echo "  Sending POST requests to /api/cart/demo-user/items"
echo "  Each request adds items to an in-memory cart, causing memory growth."
echo ""
ERROR_COUNT=0
SUCCESS_COUNT=0
for i in $(seq 1 $REQUEST_COUNT); do
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST "${APP_URL}/api/cart/demo-user/items" \
    -H "Content-Type: application/json" \
    -d '{"foodItemId":1,"quantity":1}' 2>/dev/null || echo "000")
  if [ "$STATUS" = "200" ] || [ "$STATUS" = "201" ]; then
    SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
  else
    ERROR_COUNT=$((ERROR_COUNT + 1))
  fi
  # Print progress every 25 requests
  if [ $((i % 25)) -eq 0 ]; then
    echo "  $(date '+%H:%M:%S') — Sent ${i}/${REQUEST_COUNT} requests (${SUCCESS_COUNT} ok, ${ERROR_COUNT} errors)"
  fi
  sleep $SLEEP_INTERVAL
done

echo ""
echo "  Results: ${SUCCESS_COUNT} successes, ${ERROR_COUNT} errors out of ${REQUEST_COUNT} requests"
echo ""

# Step 3: Verify app state
echo "Step 3: Checking app state after load..."
FINAL_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "${APP_URL}/health" 2>/dev/null || echo "000")
echo "  Health check: HTTP ${FINAL_STATUS}"
MENU_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "${APP_URL}/api/menu" 2>/dev/null || echo "000")
echo "  Menu API:     HTTP ${MENU_STATUS}"
echo ""

echo "============================================="
echo "  ✅ Memory leak triggered!"
echo "============================================="
echo ""
echo "  What happens next:"
echo "    1. Memory pressure builds in the container (~2-5 minutes)"
echo "    2. Azure Monitor detects high memory / OOM / HTTP errors"
echo "    3. An alert fires and flows to your SRE Agent"
echo "    4. The agent starts investigating automatically"
echo "    5. Open https://sre.azure.com → Incidents to watch"
echo ""
echo "  ⏱  Wait 5-8 minutes, then check the SRE Agent portal."
echo ""
echo "  The agent will find:"
echo "    • Memory spike in container metrics"
echo "    • Cart API accumulating items without cleanup"
echo "    • Connection to /api/cart/demo-user/items in logs"
echo "    • Root cause in source code (in-memory cart with no eviction)"
echo ""
