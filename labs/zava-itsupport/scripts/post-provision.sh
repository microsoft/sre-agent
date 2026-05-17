#!/bin/bash
# =============================================================================
# post-provision.sh — Runs after `azd provision` succeeds for zava-itsupport.
#
# Steps:
#   1. Build + push the 2 container images to ACR via `az acr build`
#         - laptop-request-site (Node.js)
#         - warranty-tool (Python / FastAPI)
#   2. Update the 2 Container Apps to the new image tags.
#   3. Optional: register srectl resources (it-support-handler agent +
#      CheckWarranty / LookupServiceNowIncident tools) under sre-config/.
#   4. Register an HTTP trigger named `zava-itsupport-incident-trigger`
#      bound to the it-support-handler agent.
#   5. Print summary + write labs/.deployed/zava-itsupport.json
# =============================================================================
set -uo pipefail

# Force UTF-8 — avoids Windows cp1252 UnicodeEncodeError when `az acr build` streams logs
export PYTHONIOENCODING=utf-8
export PYTHONUTF8=1
if command -v chcp.com &>/dev/null; then chcp.com 65001 >/dev/null 2>&1 || true; fi

if command -v python3 &>/dev/null; then PYTHON=python3;elif command -v python &>/dev/null; then PYTHON=python; else PYTHON=""; fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LABS_PLATFORM_DIR="$(cd "$SCRIPT_DIR/../../_platform" 2>/dev/null && pwd || echo "")"
cd "$PROJECT_DIR"

TEMP_DIR="${SCRIPT_DIR}/.tmp"
mkdir -p "$TEMP_DIR"

to_native () {
  if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi
}

echo ""
echo "================================================="
echo "  Zava — IT Support Lab — Post-Provision"
echo "================================================="

# ── Read azd outputs ─────────────────────────────────────────
AZURE_RESOURCE_GROUP=$(azd env get-value AZURE_RESOURCE_GROUP 2>/dev/null || echo "")
AZURE_LOCATION=$(azd env get-value AZURE_LOCATION 2>/dev/null || echo "")
SRE_AGENT_ENDPOINT=$(azd env get-value SRE_AGENT_ENDPOINT 2>/dev/null || echo "")
SRE_AGENT_NAME=$(azd env get-value SRE_AGENT_NAME 2>/dev/null || echo "")
ACR_NAME=$(azd env get-value AZURE_CONTAINER_REGISTRY_NAME 2>/dev/null || echo "")
ACR_LOGIN_SERVER=$(azd env get-value AZURE_CONTAINER_REGISTRY_LOGIN_SERVER 2>/dev/null || echo "")
IT_PORTAL_NAME=$(azd env get-value AZURE_IT_PORTAL_NAME 2>/dev/null || echo "")
IT_PORTAL_URL=$(azd env get-value AZURE_IT_PORTAL_URL 2>/dev/null || echo "")
WARRANTY_API_NAME=$(azd env get-value AZURE_WARRANTY_API_NAME 2>/dev/null || echo "")
WARRANTY_API_URL=$(azd env get-value AZURE_WARRANTY_API_URL 2>/dev/null || echo "")

echo ""
echo "  Resource Group:     ${AZURE_RESOURCE_GROUP:-(unknown)}"
echo "  ACR:                ${ACR_LOGIN_SERVER:-(unknown)}"
echo "  SRE Agent endpoint: ${SRE_AGENT_ENDPOINT:-(unknown)}"
echo ""

IMAGE_TAG="${IMAGE_TAG:-$(date -u +%Y%m%d-%H%M%S)}"

# ── Step 1/4: Build + push container images ─────────────────
echo "🐳 Step 1/4: Building + pushing container images (tag=$IMAGE_TAG)..."

build_and_push () {
  local svc="$1"           # laptop-request-site | warranty-tool
  local context_dir="$2"   # absolute dir
  if [ -z "$ACR_NAME" ]; then echo "   ⚠️  $svc: ACR_NAME missing — skipped"; return 1; fi
  if [ ! -f "$context_dir/Dockerfile" ]; then echo "   ⚠️  $svc: Dockerfile missing at $context_dir — skipped"; return 1; fi
  echo "   • building $svc → $ACR_LOGIN_SERVER/$svc:$IMAGE_TAG"
  set +e
  az acr build \
    --registry "$ACR_NAME" \
    --image "$svc:$IMAGE_TAG" \
    --image "$svc:latest" \
    --file "$context_dir/Dockerfile" \
    "$context_dir" \
    --output none 2> "$TEMP_DIR/acr-build-$svc.log"
  RC=$?
  set -e
  if [ $RC -eq 0 ]; then
    echo "     ✅ pushed $svc:$IMAGE_TAG"
  else
    echo "     ⚠️  build failed (rc=$RC). Tail:"
    tail -10 "$TEMP_DIR/acr-build-$svc.log" | sed 's/^/        /'
    return 1
  fi
}

build_and_push "laptop-request-site" "$PROJECT_DIR/laptop-request-site" || true
build_and_push "warranty-tool" "$PROJECT_DIR/warranty-tool" || true

# ── Step 2/4: Update Container Apps to new image ────────────
echo ""
echo "🚀 Step 2/4: Updating Container Apps to new image..."

update_aca () {
  local app="$1"
  local svc="$2"
  if [ -z "$app" ]; then echo "   ⚠️  $svc: app name missing — skipped"; return; fi
  if [ -z "$ACR_LOGIN_SERVER" ]; then echo "   ⚠️  $svc: ACR login server missing — skipped"; return; fi
  echo "   • $svc → $app"
  set +e
  az containerapp update \
    --name "$app" \
    --resource-group "$AZURE_RESOURCE_GROUP" \
    --image "$ACR_LOGIN_SERVER/$svc:$IMAGE_TAG" \
    --output none 2> "$TEMP_DIR/aca-update-$svc.log"
  RC=$?
  set -e
  if [ $RC -eq 0 ]; then
    echo "     ✅ revision update queued"
  else
    echo "     ⚠️  update failed (rc=$RC):"
    tail -10 "$TEMP_DIR/aca-update-$svc.log" | sed 's/^/        /'
  fi
}

update_aca "$IT_PORTAL_NAME" "laptop-request-site"
update_aca "$WARRANTY_API_NAME" "warranty-tool"

# ── Step 3/4: srectl orchestration (optional) ───────────────
echo ""
echo "🔧 Step 3/4: Registering SRE Agent resources via srectl..."
if [ "${LABS_SKIP_SRECTL:-0}" = "1" ]; then
  echo "   ⏭️  Skipped (LABS_SKIP_SRECTL=1)"
elif ! command -v srectl >/dev/null 2>&1; then
  echo "   ⏭️  Skipped — srectl not on PATH (private preview)"
elif [ -z "$SRE_AGENT_ENDPOINT" ]; then
  echo "   ⏭️  Skipped — SRE_AGENT_ENDPOINT not set"
else
  WS_DIR="$PROJECT_DIR/sre-config"
  set +e
  ( cd "$WS_DIR" && srectl init --resource-url "$SRE_AGENT_ENDPOINT" ) > "$TEMP_DIR/srectl-init.log" 2>&1
  RC=$?
  if [ $RC -ne 0 ]; then
    echo "   ⚠️  srectl init failed (rc=$RC):"; tail -10 "$TEMP_DIR/srectl-init.log" | sed 's/^/      /'
  else
    if [ -d "$WS_DIR/tools" ]; then
      for d in "$WS_DIR/tools"/*/; do
        [ -d "$d" ] || continue
        n=$(basename "$d")
        f="tools/$n/$n.yaml"
        [ -f "$WS_DIR/$f" ] || continue
        ( cd "$WS_DIR" && srectl apply-yaml -f "$f" ) > "$TEMP_DIR/srectl-tool-$n.log" 2>&1
        RC=$?
        [ $RC -eq 0 ] && echo "   ✅ tool: $n" || { echo "   ⚠️  tool $n failed (rc=$RC):"; tail -5 "$TEMP_DIR/srectl-tool-$n.log" | sed 's/^/      /'; }
      done
    fi
    if [ -d "$WS_DIR/agents" ]; then
      for d in "$WS_DIR/agents"/*/; do
        [ -d "$d" ] || continue
        n=$(basename "$d")
        f="agents/$n/$n.yaml"
        [ -f "$WS_DIR/$f" ] || continue
        ( cd "$WS_DIR" && srectl apply-yaml -f "$f" ) > "$TEMP_DIR/srectl-agent-$n.log" 2>&1
        RC=$?
        [ $RC -eq 0 ] && echo "   ✅ agent: $n" || { echo "   ⚠️  agent $n failed (rc=$RC):"; tail -5 "$TEMP_DIR/srectl-agent-$n.log" | sed 's/^/      /'; }
      done
    fi
  fi
  set -e
fi

# ── Step 3.5/4: Register HTTP trigger ───────────────────────
ZAVA_HTTP_TRIGGER_URL=""
ZAVA_HTTP_TRIGGER_ID=""
echo ""
echo "🔔 Step 3.5/4: Registering HTTP trigger for IT-support agent..."
if [ -z "$PYTHON" ]; then
  echo "   ⏭️  Skipped — python not on PATH"
elif [ -z "$SRE_AGENT_ENDPOINT" ]; then
  echo "   ⏭️  Skipped — SRE_AGENT_ENDPOINT not set"
elif ! command -v az >/dev/null 2>&1; then
  echo "   ⏭️  Skipped — az CLI not on PATH"
elif [ -z "$LABS_PLATFORM_DIR" ] || [ ! -f "$LABS_PLATFORM_DIR/http_trigger.py" ]; then
  echo "   ⏭️  Skipped — labs/_platform/http_trigger.py not found"
else
  HT_HELPER="$(to_native "$LABS_PLATFORM_DIR/http_trigger.py")"
  set +e
  HT_OUT=$("$PYTHON" "$HT_HELPER" create-and-enable \
    --endpoint "$SRE_AGENT_ENDPOINT" \
    --name "zava-itsupport-incident-trigger" \
    --agent "it-support-handler" \
    --mode "autonomous" \
    --description "Fired by ServiceNow / lab demo when a laptop replacement request needs to be processed." \
    --prompt "An incoming ServiceNow-style laptop replacement request. Look up the incident, check warranty via CheckWarranty, and process the replacement workflow per the it-support-handler runbook." \
    2> "$TEMP_DIR/http-trigger-create.log")
  RC=$?
  set -e
  if [ $RC -eq 0 ] && [ -n "$HT_OUT" ]; then
    ZAVA_HTTP_TRIGGER_URL=$("$PYTHON" -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('triggerUrl') or '')" <<< "$HT_OUT")
    ZAVA_HTTP_TRIGGER_ID=$("$PYTHON" -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('triggerId') or '')" <<< "$HT_OUT")
    if [ -n "$ZAVA_HTTP_TRIGGER_URL" ]; then
      azd env set ZAVA_HTTP_TRIGGER_URL "$ZAVA_HTTP_TRIGGER_URL" >/dev/null 2>&1 || true
      azd env set ZAVA_HTTP_TRIGGER_ID  "$ZAVA_HTTP_TRIGGER_ID"  >/dev/null 2>&1 || true
      echo "   ✅ trigger registered: $ZAVA_HTTP_TRIGGER_ID"
    else
      echo "   ⚠️  create returned no triggerUrl: $HT_OUT"
    fi
  else
    echo "   ⚠️  trigger registration failed (rc=$RC):"
    sed 's/^/      /' "$TEMP_DIR/http-trigger-create.log" 2>/dev/null | head -20
  fi
fi

# ── Step 4/4: Summary + record deployment ───────────────────
echo ""
echo "================================================="
echo "  ✅ Zava IT Support Lab — Provision Done"
echo "================================================="
echo ""
echo "  🤖 Agent Portal:    https://sre.azure.com"
echo "  📡 Agent Endpoint:  ${SRE_AGENT_ENDPOINT:-not set}"
echo "  🔔 HTTP Trigger:    ${ZAVA_HTTP_TRIGGER_URL:-not registered}"
echo "  💼 IT Portal:       ${IT_PORTAL_URL:-not deployed}"
echo "  🛡️  Warranty API:    ${WARRANTY_API_URL:-not deployed}"
echo "  📦 Resource Group:  ${AZURE_RESOURCE_GROUP:-not set}"
echo ""
echo "  Next:"
echo "    • Visit the agent portal: https://sre.azure.com"
echo "    • File a sample request:  bash scripts/laptop-request-demo.sh"
echo "================================================="
echo ""

LABS_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DEPLOYED_DIR="$LABS_ROOT/.deployed"
mkdir -p "$DEPLOYED_DIR"
SUB_ID="$(az account show --query id -o tsv 2>/dev/null || echo '')"
cat > "$DEPLOYED_DIR/zava-itsupport.json" <<EOF
{
  "name": "zava-itsupport",
  "deployedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "subscriptionId": "$SUB_ID",
  "resourceGroup": "${AZURE_RESOURCE_GROUP}",
  "region": "${AZURE_LOCATION}",
  "sreAgentName": "${SRE_AGENT_NAME}",
  "portalUrl": "${SRE_AGENT_ENDPOINT}",
  "itPortalUrl": "${IT_PORTAL_URL}",
  "warrantyApiUrl": "${WARRANTY_API_URL}",
  "containerRegistry": "${ACR_LOGIN_SERVER}",
  "imageTag": "${IMAGE_TAG}",
  "httpTriggerUrl": "${ZAVA_HTTP_TRIGGER_URL}",
  "httpTriggerId": "${ZAVA_HTTP_TRIGGER_ID}"
}
EOF
echo "  Recorded deployment in labs/.deployed/zava-itsupport.json"
