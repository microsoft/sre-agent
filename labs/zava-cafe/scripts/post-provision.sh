#!/bin/bash
# =============================================================================
# post-provision.sh — Runs after `azd provision` succeeds.
#
# Steps:
#   1. Seed Azure SQL DB from infra/seed-database.sql (best-effort)
#   2. Deploy the .NET web app from source via `az webapp deploy`
#         - .NET (src/)
#   3. Optional: register srectl resources (tools, agents, skills, hooks,
#      scheduled tasks) under sre-config/agent1, and fire a smoke-test
#      thread.
#   4. Print a summary + write labs/.deployed/zava-cafe.json
# =============================================================================
set -uo pipefail

if command -v python3 &>/dev/null; then PYTHON=python3; elif command -v python &>/dev/null; then PYTHON=python; else PYTHON=""; fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

TEMP_DIR="${SCRIPT_DIR}/.tmp"
mkdir -p "$TEMP_DIR"

# Convert MSYS/Cygwin paths (/c/foo) to native form (C:/foo) for tools like
# Python and az CLI on Windows Git-Bash. No-op on macOS/Linux.
to_native () {
  if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi
}
NATIVE_TMP="$(to_native "$TEMP_DIR")"
NATIVE_PROJECT="$(to_native "$PROJECT_DIR")"

echo ""
echo "============================================="
echo "  Zava — Zava Café Lab — Post-Provision"
echo "============================================="

# ── Read azd outputs ─────────────────────────────────────────
AZURE_RESOURCE_GROUP=$(azd env get-value AZURE_RESOURCE_GROUP 2>/dev/null || echo "")
AZURE_LOCATION=$(azd env get-value AZURE_LOCATION 2>/dev/null || echo "")
SRE_AGENT_ENDPOINT=$(azd env get-value SRE_AGENT_ENDPOINT 2>/dev/null || echo "")
SRE_AGENT_NAME=$(azd env get-value SRE_AGENT_NAME 2>/dev/null || echo "")
AZURE_SQL_SERVER_FQDN=$(azd env get-value AZURE_SQL_SERVER_FQDN 2>/dev/null || echo "")
AZURE_SQL_DATABASE=$(azd env get-value AZURE_SQL_DATABASE 2>/dev/null || echo "")

echo ""
echo "  Resource Group:     ${AZURE_RESOURCE_GROUP:-(unknown)}"
echo "  SRE Agent endpoint: ${SRE_AGENT_ENDPOINT:-(unknown)}"
echo ""

# Add deployer's public IP to SQL firewall once — used by seed + MI grant steps
if [ -n "$AZURE_SQL_SERVER_FQDN" ] && [ -n "$AZURE_RESOURCE_GROUP" ]; then
  MYIP=$(curl -s --max-time 5 https://api.ipify.org || echo "")
  if [ -n "$MYIP" ]; then
    az sql server firewall-rule create \
      --resource-group "$AZURE_RESOURCE_GROUP" \
      --server "$(echo "$AZURE_SQL_SERVER_FQDN" | cut -d'.' -f1)" \
      --name "AllowDeployerIP" \
      --start-ip-address "$MYIP" --end-ip-address "$MYIP" \
      >/dev/null 2>&1 && echo "   • Added deployer IP $MYIP to SQL firewall"
  fi
fi

# SQL_ACCESS_TOKEN is no longer used here — sql_entra.py acquires its own token
# via DefaultAzureCredential. (Kept the firewall rule above, which is still useful.)

# ── Step 1/5: Seed SQL DB (Entra via pyodbc helper) ─────────
echo "🗄️  Step 1/5: Seeding SQL database..."
SEED_FILE="$PROJECT_DIR/infra/seed-database.sql"
if [ -z "$AZURE_SQL_SERVER_FQDN" ]; then
  echo "   ⏭️  Skipped — missing SQL server FQDN."
elif [ ! -f "$SEED_FILE" ]; then
  echo "   ⏭️  Skipped — $SEED_FILE not found."
elif [ -z "$PYTHON" ]; then
  echo "   ⏭️  Skipped — Python not on PATH."
else
  set +e
  "$PYTHON" "$SCRIPT_DIR/sql_entra.py" \
    --server "$AZURE_SQL_SERVER_FQDN" \
    --database "$AZURE_SQL_DATABASE" \
    --file "$(to_native "$SEED_FILE")" > "$TEMP_DIR/seed.log" 2>&1
  RC=$?
  set -e
  if [ $RC -eq 0 ]; then
    echo "   ✅ Seed completed."
  elif [ $RC -eq 2 ]; then
    echo "   ⏭️  Skipped — pyodbc/azure-identity not installed."
    echo "      Install with: pip install pyodbc azure-identity"
    sed 's/^/      /' "$TEMP_DIR/seed.log" | head -5
  else
    echo "   ⚠️  Seed failed (rc=$RC). Tail:"; tail -10 "$TEMP_DIR/seed.log" | sed 's/^/      /'
  fi
fi

# ── Step 1.5/5: Grant Web App MI access to SQL DB ───────────
echo ""
echo "🔐 Step 1.5/5: Granting Web App MI access to SQL DB..."
WEBAPP_NAME="$(azd env get-value AZURE_APP_NAME 2>/dev/null || azd env get-value WEBAPP_NAME 2>/dev/null)"
SQL_FQDN="$(azd env get-value AZURE_SQL_SERVER_FQDN 2>/dev/null)"
SQL_DB="$(azd env get-value AZURE_SQL_DATABASE 2>/dev/null)"
if [ -z "$WEBAPP_NAME" ] || [ -z "$SQL_FQDN" ] || [ -z "$SQL_DB" ]; then
  echo "   ⚠️  Required env vars missing — skipping MI SQL grant"
elif [ -z "$PYTHON" ]; then
  echo "   ⚠️  Python not on PATH — skipping MI SQL grant"
else
  GRANT_SQL="$TEMP_DIR/mi-grant.sql"
  cat > "$GRANT_SQL" <<EOF
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = '${WEBAPP_NAME}')
BEGIN
  CREATE USER [${WEBAPP_NAME}] FROM EXTERNAL PROVIDER;
END
GO
ALTER ROLE db_datareader ADD MEMBER [${WEBAPP_NAME}];
GO
ALTER ROLE db_datawriter ADD MEMBER [${WEBAPP_NAME}];
GO
ALTER ROLE db_ddladmin ADD MEMBER [${WEBAPP_NAME}];
GO
EOF
  set +e
  "$PYTHON" "$SCRIPT_DIR/sql_entra.py" \
    --server "$SQL_FQDN" \
    --database "$SQL_DB" \
    --file "$(to_native "$GRANT_SQL")" > "$TEMP_DIR/mi-grant.log" 2>&1
  RC=$?
  set -e
  if [ $RC -eq 0 ]; then
    echo "   ✓ MI SQL access granted to $WEBAPP_NAME"
  elif [ $RC -eq 2 ]; then
    echo "   ⚠️  Skipped — pyodbc/azure-identity not installed."
    echo "      Install with: pip install pyodbc azure-identity"
  else
    echo "   ⚠️  MI grant failed (rc=$RC). Tail:"; tail -10 "$TEMP_DIR/mi-grant.log" | sed 's/^/      /'
  fi
fi

# ── Step 2/5: Deploy the .NET web app from source ───────────
echo ""
echo "🚀 Step 2/5: Deploying .NET web app from source..."

deploy_zip () {
  local app_name="$1"
  local zip_path="$2"
  local label="$3"
  if [ -z "$app_name" ]; then echo "   ⚠️  $label: app name missing — skipped"; return; fi
  if [ ! -f "$zip_path" ]; then echo "   ⚠️  $label: zip not found at $zip_path — skipped"; return; fi
  echo "   • $label → $app_name"
  set +e
  az webapp deploy \
    --resource-group "$AZURE_RESOURCE_GROUP" \
    --name "$app_name" \
    --src-path "$(to_native "$zip_path")" \
    --type zip \
    --output none 2>"$TEMP_DIR/deploy-$label.log"
  RC=$?
  set -e
  [ $RC -eq 0 ] && echo "     ✅ deploy queued" || { echo "     ⚠️  deploy failed (rc=$RC):"; head -10 "$TEMP_DIR/deploy-$label.log" | sed 's/^/        /'; }
}

# Helper: zip a directory's contents using Python's shutil.make_archive.
# Both arguments must be NATIVE paths (use to_native on the bash side).
make_zip () {
  local out_base_native="$1"   # e.g. C:/.../scripts/.tmp/dotnet-app  (no .zip)
  local src_native="$2"        # e.g. C:/.../scripts/.tmp/dotnet-publish
  if [ -z "$PYTHON" ]; then
    echo "     ⚠️  Python not on PATH — cannot create zip"
    return 1
  fi
  "$PYTHON" -c "import shutil,sys; shutil.make_archive(sys.argv[1],'zip',sys.argv[2])" \
    "$out_base_native" "$src_native"
}

# 2a) .NET app — publish + zip
DOTNET_ZIP="$TEMP_DIR/dotnet-app.zip"
if [ -d "$PROJECT_DIR/src" ] && command -v dotnet &>/dev/null; then
  echo "   • Publishing .NET app..."
  set +e
  ( cd "$PROJECT_DIR/src" && dotnet publish -c Release -o "$TEMP_DIR/dotnet-publish" --nologo -v quiet ) > "$TEMP_DIR/dotnet-build.log" 2>&1
  RC=$?
  set -e
  if [ $RC -eq 0 ]; then
    set +e
    make_zip "${NATIVE_TMP}/dotnet-app" "${NATIVE_TMP}/dotnet-publish" > "$TEMP_DIR/zip-dotnet.log" 2>&1
    set -e
    if [ ! -f "$DOTNET_ZIP" ]; then
      echo "     ⚠️  zip creation failed:"; sed 's/^/        /' "$TEMP_DIR/zip-dotnet.log" | head -10
    else
      deploy_zip "$AZURE_APP_NAME" "$DOTNET_ZIP" "dotnet-app"
    fi
  else
    echo "     ⚠️  dotnet publish failed (rc=$RC). Tail:"; tail -10 "$TEMP_DIR/dotnet-build.log" | sed 's/^/        /'
  fi
elif [ -d "$PROJECT_DIR/src" ]; then
  echo "   ⚠️  dotnet CLI not on PATH — skipping .NET app deploy."
fi

# ── Step 3/5: srectl orchestration (optional) ───────────────
echo ""
echo "🔧 Step 3/5: Registering SRE Agent resources via srectl..."
if [ "${LABS_SKIP_SRECTL:-0}" = "1" ]; then
  echo "   ⏭️  Skipped (LABS_SKIP_SRECTL=1)"
elif ! command -v srectl >/dev/null 2>&1; then
  echo "   ⏭️  Skipped — srectl not on PATH (private preview via aka.ms/sreagent-onboarding)"
elif [ -z "$SRE_AGENT_ENDPOINT" ]; then
  echo "   ⏭️  Skipped — SRE_AGENT_ENDPOINT not set"
else
  set +e
  srectl_apply_workspace () {
    local workspace="$1"   # e.g. sre-config/agent1
    local label="$2"
    local ws_dir="$PROJECT_DIR/$workspace"
    local slug; slug="$(echo "$workspace" | tr '/' '-')"   # filesystem-safe log key
    [ ! -d "$ws_dir" ] && { echo "   ⏭️  $label: $workspace not found"; return; }

    echo "   ── $label ($workspace) ──"
    ( cd "$ws_dir" && srectl init --resource-url "$SRE_AGENT_ENDPOINT" ) > "$TEMP_DIR/srectl-init-$slug.log" 2>&1
    RC=$?
    if [ $RC -ne 0 ]; then
      echo "     ⚠️  srectl init failed (rc=$RC):"; tail -10 "$TEMP_DIR/srectl-init-$slug.log" | sed 's/^/        /'
      return
    fi

    # Tools — apply-yaml each tools/<Name>/<Name>.yaml
    if [ -d "$ws_dir/tools" ]; then
      for d in "$ws_dir/tools"/*/; do
        [ -d "$d" ] || continue
        n=$(basename "$d")
        f="tools/$n/$n.yaml"
        [ -f "$ws_dir/$f" ] || continue
        ( cd "$ws_dir" && srectl apply-yaml -f "$f" ) > "$TEMP_DIR/srectl-tool-$n.log" 2>&1
        RC=$?
        [ $RC -eq 0 ] && echo "     ✅ tool: $n" || { echo "     ⚠️  tool $n failed (rc=$RC):"; tail -5 "$TEMP_DIR/srectl-tool-$n.log" | sed 's/^/        /'; }
      done
    fi

    # Hooks — yaml files under hooks/
    if [ -d "$ws_dir/hooks" ]; then
      for f in "$ws_dir/hooks"/*.yaml; do
        [ -f "$f" ] || continue
        rel="hooks/$(basename "$f")"
        ( cd "$ws_dir" && srectl hook apply --file "$rel" ) > "$TEMP_DIR/srectl-hook-$(basename "$f").log" 2>&1
        RC=$?
        [ $RC -eq 0 ] && echo "     ✅ hook: $(basename "$f")" || { echo "     ⚠️  hook $(basename "$f") failed (rc=$RC):"; tail -5 "$TEMP_DIR/srectl-hook-$(basename "$f").log" | sed 's/^/        /'; }
      done
    fi

    # Scheduled tasks — apply-yaml each scheduledtasks/<Name>/<Name>.yaml
    if [ -d "$ws_dir/scheduledtasks" ]; then
      for d in "$ws_dir/scheduledtasks"/*/; do
        [ -d "$d" ] || continue
        n=$(basename "$d")
        f="scheduledtasks/$n/$n.yaml"
        [ -f "$ws_dir/$f" ] || continue
        ( cd "$ws_dir" && srectl scheduledtask apply --file "$f" ) > "$TEMP_DIR/srectl-task-$n.log" 2>&1
        RC=$?
        [ $RC -eq 0 ] && echo "     ✅ scheduled task: $n" || { echo "     ⚠️  task $n failed (rc=$RC):"; tail -5 "$TEMP_DIR/srectl-task-$n.log" | sed 's/^/        /'; }
      done
    fi

    # Skills — `srectl skill apply --name <name>` (workspace-aware)
    if [ -d "$ws_dir/skills" ]; then
      for d in "$ws_dir/skills"/*/; do
        [ -d "$d" ] || continue
        n=$(basename "$d")
        [ -f "$ws_dir/skills/$n/SKILL.md" ] || continue
        ( cd "$ws_dir" && srectl skill apply --name "$n" ) > "$TEMP_DIR/srectl-skill-$n.log" 2>&1
        RC=$?
        [ $RC -eq 0 ] && echo "     ✅ skill: $n" || { echo "     ⚠️  skill $n failed (rc=$RC):"; tail -5 "$TEMP_DIR/srectl-skill-$n.log" | sed 's/^/        /'; }
      done
    fi

    # Agents — apply-yaml each agents/<Name>/<Name>.yaml
    if [ -d "$ws_dir/agents" ]; then
      for d in "$ws_dir/agents"/*/; do
        [ -d "$d" ] || continue
        n=$(basename "$d")
        f="agents/$n/$n.yaml"
        [ -f "$ws_dir/$f" ] || continue
        ( cd "$ws_dir" && srectl apply-yaml -f "$f" ) > "$TEMP_DIR/srectl-agent-$n.log" 2>&1
        RC=$?
        [ $RC -eq 0 ] && echo "     ✅ agent: $n" || { echo "     ⚠️  agent $n failed (rc=$RC):"; tail -5 "$TEMP_DIR/srectl-agent-$n.log" | sed 's/^/        /'; }
      done
    fi
  }

  srectl_apply_workspace "sre-config/agent1" "agent1 (SQL/DevOps)"

  # Smoke test — fire-and-forget thread on sql-performance-investigator
  echo ""
  echo "   🧵 Smoke test: srectl thread new --no-wait → sql-performance-investigator"
  PROMPT="Run a quick health check on the Zava SQL DB. Reply with one bullet point."
  ( cd "$PROJECT_DIR/sre-config/agent1" && srectl thread new --agent sql-performance-investigator --message "$PROMPT" --no-wait ) > "$TEMP_DIR/srectl-thread.log" 2>&1
  RC=$?
  if [ $RC -eq 0 ]; then
    THREAD_ID=$(grep -oE 'Thread ID: [a-f0-9-]+' "$TEMP_DIR/srectl-thread.log" | awk '{print $3}' | head -1)
    echo "     ✅ message sent. Thread ID: ${THREAD_ID:-(see log)}"
    echo "        Follow live: https://sre.azure.com"
  else
    echo "     ⚠️  thread creation failed (rc=$RC):"; tail -10 "$TEMP_DIR/srectl-thread.log" | sed 's/^/        /'
  fi
  set -e
fi

# ── Step 3.5/5: Register HTTP trigger for the simulator ─────
# Uses the SRE Agent REST API directly (no CLI in srectl 1.0.x yet).
# Helper: labs/_platform/http_trigger.py — idempotent (reuses existing by name).
ZAVA_HTTP_TRIGGER_URL=""
ZAVA_HTTP_TRIGGER_ID=""
echo ""
echo "🔔 Step 3.5/5: Registering HTTP trigger for simulator..."
if [ -z "$PYTHON" ]; then
  echo "   ⏭️  Skipped — python not on PATH"
elif [ -z "$SRE_AGENT_ENDPOINT" ]; then
  echo "   ⏭️  Skipped — SRE_AGENT_ENDPOINT not set"
elif ! command -v az >/dev/null 2>&1; then
  echo "   ⏭️  Skipped — az CLI not on PATH"
else
  HT_HELPER="$(to_native "$LABS_PLATFORM_DIR/http_trigger.py")"
  if [ ! -f "$LABS_PLATFORM_DIR/http_trigger.py" ]; then
    # LABS_PLATFORM_DIR not defined yet — compute it inline (kept here so block is self-contained)
    LABS_PLATFORM_DIR="$(cd "$SCRIPT_DIR/../../_platform" 2>/dev/null && pwd || echo "")"
    HT_HELPER="$(to_native "$LABS_PLATFORM_DIR/http_trigger.py")"
  fi
  if [ ! -f "$LABS_PLATFORM_DIR/http_trigger.py" ]; then
    echo "   ⏭️  Skipped — labs/_platform/http_trigger.py not found"
  else
    set +e
    HT_OUT=$("$PYTHON" "$HT_HELPER" create-and-enable \
      --endpoint "$SRE_AGENT_ENDPOINT" \
      --name "zava-cafe-incident-trigger" \
      --agent "sql-performance-investigator" \
      --mode "autonomous" \
      --description "Fired by the Zava Café lab simulator when it observes a bad deployment or SQL slowdown on the Zava app." \
      --prompt "An incoming alert payload from the Zava lab simulator. Investigate the SQL performance / health failure described in the request body, follow the runbook (sql-performance-investigator), and post a brief diagnosis + recommended remediation." \
      2> "$TEMP_DIR/http-trigger-create.log")
    RC=$?
    set -e
    if [ $RC -eq 0 ] && [ -n "$HT_OUT" ]; then
      ZAVA_HTTP_TRIGGER_URL=$("$PYTHON" -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('triggerUrl') or '')" <<< "$HT_OUT")
      ZAVA_HTTP_TRIGGER_ID=$("$PYTHON" -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('triggerId') or '')" <<< "$HT_OUT")
      if [ -n "$ZAVA_HTTP_TRIGGER_URL" ]; then
        azd env set ZAVA_HTTP_TRIGGER_URL "$ZAVA_HTTP_TRIGGER_URL" >/dev/null 2>&1 || true
        azd env set ZAVA_HTTP_TRIGGER_ID  "$ZAVA_HTTP_TRIGGER_ID"  >/dev/null 2>&1 || true
        echo "     ✅ trigger registered: $ZAVA_HTTP_TRIGGER_ID"
        echo "        URL stored in azd env as ZAVA_HTTP_TRIGGER_URL"
      else
        echo "     ⚠️  create returned no triggerUrl: $HT_OUT"
      fi
    else
      echo "     ⚠️  trigger registration failed (rc=$RC):"
      sed 's/^/        /' "$TEMP_DIR/http-trigger-create.log" 2>/dev/null | head -20
    fi
  fi
fi

# ── Step 4/5: Summary + record deployment ───────────────────
echo ""
echo "============================================="
echo "  ✅ Zava Zava Café Lab — Provision Done"
echo "============================================="
echo ""
echo "  🤖 Agent Portal:    https://sre.azure.com"
echo "  📡 Agent Endpoint:  ${SRE_AGENT_ENDPOINT:-not set}"
echo "  🔔 HTTP Trigger:    ${ZAVA_HTTP_TRIGGER_URL:-not registered}"
echo "  🌐 Zava App:        ${AZURE_APP_URL:-not deployed}"
echo "  🗄️  SQL Server:      ${AZURE_SQL_SERVER_FQDN:-not deployed}"
echo "  📦 Resource Group:  ${AZURE_RESOURCE_GROUP:-not set}"
echo ""
echo "  Next:"
echo "    • Visit the agent portal: https://sre.azure.com"
echo "    • Drive a scenario:  pwsh sre-config/simulate-dtu-spike.ps1"
echo "    • Or:                pwsh sre-config/simulate-slow-queries.ps1"
echo "    • Manual smoke:      bash scripts/invoke-thread.sh"
echo "============================================="
echo ""

# Write .deployed/zava-cafe.json (consumed by labs/.../lab.ps1 + meta-sim)
LABS_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DEPLOYED_DIR="$LABS_ROOT/.deployed"
mkdir -p "$DEPLOYED_DIR"
SUB_ID="$(az account show --query id -o tsv 2>/dev/null || echo '')"
cat > "$DEPLOYED_DIR/zava-cafe.json" <<EOF
{
  "name": "zava-cafe",
  "deployedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "subscriptionId": "$SUB_ID",
  "resourceGroup": "${AZURE_RESOURCE_GROUP}",
  "region": "${AZURE_LOCATION}",
  "sreAgentName": "${SRE_AGENT_NAME}",
  "portalUrl": "${SRE_AGENT_ENDPOINT}",
  "appUrl": "${AZURE_APP_URL}",
  "sqlServerFqdn": "${AZURE_SQL_SERVER_FQDN}",
  "sqlDatabase": "${AZURE_SQL_DATABASE}",
  "httpTriggerUrl": "${ZAVA_HTTP_TRIGGER_URL}",
  "httpTriggerId": "${ZAVA_HTTP_TRIGGER_ID}",
  "labConfigPath": ""
}
EOF
echo "  Recorded deployment in labs/.deployed/zava-cafe.json"

# Cleanup zips/builds (keep logs for debugging)
rm -rf "$TEMP_DIR/dotnet-publish" "$TEMP_DIR"/*.zip 2>/dev/null || true
