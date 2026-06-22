#!/usr/bin/env bash
# apply-extras.sh
#
# Applies agent configuration via ARM sub-resources (preferred) or data-plane.
#
# Two auth paths:
#
#   1. ARM sub-resources (connectors, incidentFilters, scheduledTasks,
#      commonPrompts) — uses `az rest` with management-plane token.
#      Works in Cloud Shell and CI/CD pipelines.
#
#   2. Data-plane only (hooks, httpTriggers, repos, knowledge upload)
#      — requires token for audience https://azuresre.dev.
#      Falls back gracefully: if data-plane token is unavailable,
#      prints what was skipped so you can finish from a compliant machine.
#
# Auth:
#   ARM calls         → `az login` (control-plane token, always available)
#   data-plane calls  → token with audience https://azuresre.dev
#                       (`az account get-access-token --resource ...`)
#                       Optional — script continues if unavailable
#
# Repo auth (GitHub / ADO):
#   GitHub — two paths, the script picks based on what env vars are set:
#     1. OAuth (default): no env vars needed. Script prints a sign-in URL at the
#        end. Click it, approve in the browser, GitHub redirects back to the
#        agent and the token is stored. No secrets in env.
#     2. PAT (optional, headless): export GITHUB_PAT=ghp_xxx before running.
#        Script POSTs the PAT silently — no browser.
#   ADO — set $ADO_PAT, $ADO_USE_AAD=1, or $ADO_USE_MI=1 (with $ADO_ORG).
#
# Usage:
#   ./apply-extras.sh <subscription-id> <resource-group> <agent-name> [extras-file-or-config-dir]
#
# If the 4th argument is a directory (agent config dir), extras are auto-assembled from it.

set -euo pipefail

SUB="${1:?subscription-id required}"
RG="${2:?resource-group required}"
AGENT="${3:?agent-name required}"
FILE="${4:-extras.parameters.json}"
FORCE=""
for arg in "$@"; do [[ "$arg" == "--force" ]] && FORCE="true"; done

# Auto-assemble if a config directory was passed instead of a file
if [[ -d "$FILE" ]]; then
  CONFIG_DIR="$FILE"
  ASSEMBLE_TMP="$(mktemp -d)/assembled"
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  bash "${SCRIPT_DIR}/assemble-agent.sh" "$CONFIG_DIR" --output "$ASSEMBLE_TMP"
  FILE="${ASSEMBLE_TMP}.extras.json"
fi

[[ -f "$FILE" ]] || { echo "extras file not found: $FILE (pass a config dir or pre-assembled extras.json)" >&2; exit 1; }
command -v jq    >/dev/null || { echo "jq is required"    >&2; exit 1; }
command -v tar   >/dev/null || { echo "tar is required"   >&2; exit 1; }
command -v curl  >/dev/null || { echo "curl is required"  >&2; exit 1; }

API_VERSION="2025-05-01-preview"
ARM_BASE="https://management.azure.com/subscriptions/${SUB}/resourceGroups/${RG}/providers/Microsoft.App/agents/${AGENT}"

# Look up the data-plane endpoint and the agent's user-assigned MI (we use it
# as the connector identity).
AGENT_JSON=$(az rest -m GET --url "${ARM_BASE}?api-version=${API_VERSION}" -o json 2>/dev/null || echo "{}")
AGENT_ENDPOINT=$(echo "$AGENT_JSON" | jq -r '.properties.agentEndpoint // empty')
AGENT_UAMI=$(echo "$AGENT_JSON" | jq -r '.identity.userAssignedIdentities | keys[0] // empty')
if [[ -z "$AGENT_ENDPOINT" || "$AGENT_ENDPOINT" == "null" ]]; then
  echo "Could not resolve agent endpoint. Is ${AGENT} provisioned in ${RG}?" >&2
  exit 1
fi
echo "Agent endpoint: ${AGENT_ENDPOINT}"
[[ -n "$AGENT_UAMI" ]] && echo "Agent UAMI:     ${AGENT_UAMI##*/}"

# ---------------------------------------------------------------------------
# Probe data-plane token availability (optional — ARM path is preferred).
# If unavailable, ARM items still deploy; data-plane-only items are skipped.
# ---------------------------------------------------------------------------
DP_TOKEN_AVAILABLE=false
DP_SKIPPED_ITEMS=()
if az account get-access-token --resource https://azuresre.dev --query accessToken -o tsv > /dev/null 2>&1; then
  DP_TOKEN_AVAILABLE=true
  echo "Data-plane:     token available"
else
  echo "Data-plane:     token unavailable (hooks, repos, httpTriggers will be skipped)"
  echo "                To apply later: az login --scope \"https://azuresre.dev/.default\" && re-run"
fi

# ---------------------------------------------------------------------------
# Helper: PUT an ARM sub-resource with base64-encoded value envelope.
# Used for incidentFilters, scheduledTasks, commonPrompts.
# Body: { properties: { value: "<base64 of JSON spec>" } }
# ---------------------------------------------------------------------------
arm_put_subresource() {
  local type="$1" name="$2" spec_json="$3"
  local url="${ARM_BASE}/${type}/${name}?api-version=${API_VERSION}"
  local encoded
  encoded=$(printf '%s' "$spec_json" | base64)
  local tmp
  tmp=$(mktemp)
  printf '{"properties":{"value":"%s"}}' "$encoded" > "$tmp"
  echo "  ARM PUT ${type}/${name}"
  local result
  result=$(az rest -m PUT --url "$url" --body "@${tmp}" \
       --headers "Content-Type=application/json" -o json 2>&1) && {
    echo "    ok"
  } || {
    echo "    FAILED — $(echo "$result" | grep -o '"message":"[^"]*"' | head -1 | cut -d'"' -f4)"
  }
  rm -f "$tmp"
}

# ---------------------------------------------------------------------------
# Helper: PUT an ARM connector sub-resource (native properties, no base64).
# Used for MCP connectors, KnowledgeFile connectors.
# Body: { properties: { dataConnectorType, dataSource, extendedProperties, ... } }
# ---------------------------------------------------------------------------
arm_put_connector() {
  local name="$1" body_json="$2"
  local url="${ARM_BASE}/connectors/${name}?api-version=${API_VERSION}"
  local tmp
  tmp=$(mktemp)
  printf '%s' "$body_json" > "$tmp"
  echo "  ARM PUT connectors/${name}"
  local result
  result=$(az rest -m PUT --url "$url" --body "@${tmp}" \
       --headers "Content-Type=application/json" -o json 2>&1) && {
    echo "    ok"
  } || {
    echo "    FAILED — $(echo "$result" | grep -o '"message":"[^"]*"' | head -1 | cut -d'"' -f4)"
  }
  rm -f "$tmp"
}

# ---------------------------------------------------------------------------
# Helper: build tar.gz from an inline files array, upload to data-plane.
# files JSON shape: [ { "path": "general.md", "content": "..." }, ... ]
# ---------------------------------------------------------------------------
dataplane_upload_tarball() {
  local label="$1" url="$2" files_json="$3"
  local stage tarball token
  stage=$(mktemp -d)
  trap 'rm -rf "$stage"' RETURN

  local n
  n=$(printf '%s' "$files_json" | jq 'length')
  for i in $(seq 0 $((n - 1))); do
    local p c full
    p=$(printf '%s' "$files_json" | jq -r --argjson i "$i" '.[$i].path')
    c=$(printf '%s' "$files_json" | jq -r --argjson i "$i" '.[$i].content')
    full="${stage}/${p}"
    mkdir -p "$(dirname "$full")"
    printf '%s' "$c" > "$full"
  done

  tarball=$(mktemp -t extras.XXXXXX.tar.gz)
  tar -czf "$tarball" -C "$stage" .

  token=$(az account get-access-token --resource https://azuresre.dev \
    --query accessToken -o tsv 2>/dev/null) || {
      echo "    FAILED — could not get data-plane token (audience https://azuresre.dev)"
      rm -f "$tarball"
      return 1
    }

  echo "  data-plane POST ${label}  ($n file$([[ $n -eq 1 ]] || echo s))"
  if curl -sS -f -X POST "$url" \
       -H "Authorization: Bearer ${token}" \
       -H "Content-Type: application/gzip" \
       --data-binary "@${tarball}" >/dev/null; then
    echo "    ok"
  else
    echo "    FAILED — POST ${url}"
  fi
  rm -f "$tarball"
}

# ---------------------------------------------------------------------------
# Helper: upload one file via multipart/form-data to AgentMemory.
# Used for `knowledge` entries (RAG-indexed via Azure AI Search).
# Each call uploads ONE file; service caps: ≤16MB/file, ≤100MB/request.
# Supports inline `content` (text) or `localPath` (binary).
# ---------------------------------------------------------------------------
dataplane_upload_multipart() {
  local label="$1" url="$2" filename="$3" mime="$4" trigger="$5" src_path="$6"
  local token
  token=$(_dp_token) || { echo "    FAILED — could not get data-plane token"; return 1; }

  echo "  data-plane multipart POST ${label} (${filename})"
  if curl -sS -f -X POST "${url}?triggerIndexing=${trigger}" \
       -H "Authorization: Bearer ${token}" \
       -F "files=@${src_path};filename=${filename};type=${mime}" >/dev/null; then
    echo "    ok"
  else
    echo "    FAILED — POST ${url}"
  fi
}

# ---------------------------------------------------------------------------
# Helper: POST a plugin marketplace or installation document (data-plane v2).
# ---------------------------------------------------------------------------
dataplane_post_json() {
  local label="$1" url="$2" body_json="$3"
  local token
  token=$(_dp_token) || { echo "    FAILED — could not get data-plane token"; return 1; }
  echo "  data-plane POST ${label}"
  if curl -sS -f -X POST "$url" \
       -H "Authorization: Bearer ${token}" \
       -H "Content-Type: application/json" \
       --data "$body_json" >/dev/null; then
    echo "    ok"
  else
    echo "    FAILED — POST ${url}"
  fi
}

# Reusable: get a data-plane bearer (defined here so multipart helper can use it)
_dp_token() { az account get-access-token --resource https://azuresre.dev --query accessToken -o tsv 2>/dev/null; }

# ---------------------------------------------------------------------------
# Helper: PUT to v2 extendedAgent dataplane (skills/subagents/hooks/commonprompts/etc.).
# Body shape (from Agent.Web/ApiResources/ApiRequestEnvelope.cs):
#   { name, type, tags, properties: <spec> }
# Routes (from Agent.Web/Controllers/v2/ExtendedAgentApiController.cs):
#   PUT /api/v2/extendedAgent/{kind}/{name}
# ---------------------------------------------------------------------------
dataplane_put_extended() {
  local kind="$1" name="$2" type="$3" tags_json="$4" props_json="$5"
  local TOKEN body url
  TOKEN=$(_dp_token)
  body=$(jq -nc --arg n "$name" --arg t "$type" --argjson tags "$tags_json" --argjson props "$props_json" \
    '{name:$n, type:$t, tags:$tags, properties:$props}')
  url="${AGENT_ENDPOINT}/api/v2/extendedAgent/${kind}/$(printf %s "$name" | jq -sRr @uri)"
  # Try PUT first. If the resource exists and the API doesn't update immutable
  # fields (e.g. hook type), fall back to DELETE + PUT.
  local put_result existing_type desired_type
  put_result=$(curl -sS -w "\n%{http_code}" -X PUT "$url" \
       -H "Authorization: Bearer ${TOKEN}" \
       -H "Content-Type: application/json" \
       --data "$body" 2>&1)
  local http_code
  http_code=$(echo "$put_result" | tail -1)
  if [[ "$http_code" =~ ^2 ]]; then
    # PUT succeeded — verify the update actually took effect for hooks
    if [[ "$kind" == "hooks" ]]; then
      desired_type=$(echo "$props_json" | jq -r '.hook.type // empty')
      if [[ -n "$desired_type" ]]; then
        existing_type=$(curl -sS "$url" -H "Authorization: Bearer ${TOKEN}" 2>/dev/null \
          | jq -r '.properties.hook.type // empty')
        if [[ -n "$existing_type" && "$existing_type" != "$desired_type" ]]; then
          echo "  ${kind}/${name}: type mismatch (want=${desired_type}, got=${existing_type}) — recreating"
          curl -sS -X DELETE "$url" -H "Authorization: Bearer ${TOKEN}" >/dev/null 2>&1
          TOKEN=$(_dp_token)
          if curl -sS -f -X PUT "$url" \
               -H "Authorization: Bearer ${TOKEN}" \
               -H "Content-Type: application/json" \
               --data "$body" >/dev/null 2>&1; then
            echo "  ok ${kind}/${name} (recreated as ${desired_type})"
          else
            echo "  FAILED — recreate ${kind}/${name}"
          fi
          return
        fi
      fi
    fi
    echo "  ok ${kind}/${name}"
  else
    echo "  FAILED — PUT ${kind}/${name} (HTTP ${http_code})"
  fi
}

# Generic processor for hooks / commonPrompts / pluginConfigs entries.
# Each entry: { name, type, tags?, properties }
_process_extended() {
  local jq_key="$1" kind="$2"
  local count name type tags props
  count=$(jq "(.${jq_key} // []) | length" "$FILE")
  [[ "$count" -gt 0 ]] || return 0
  echo "${jq_key}: ${count}"
  for i in $(seq 0 $((count - 1))); do
    name=$(jq -r --argjson i "$i" ".${jq_key}[\$i].name" "$FILE")
    type=$(jq -r --argjson i "$i" ".${jq_key}[\$i].type // \"\"" "$FILE")
    tags=$(jq -c --argjson i "$i" ".${jq_key}[\$i].tags // []" "$FILE")
    props=$(jq -c --argjson i "$i" ".${jq_key}[\$i].properties // {}" "$FILE")
    dataplane_put_extended "$kind" "$name" "$type" "$tags" "$props"
  done
}

echo "Applying extras to ${AGENT} in ${RG}..."

# 1. incidentPlatforms — ARM PATCH on agent resource (not sub-resource PUT)
# This sets the incident management type (AzMonitor, PagerDuty, ServiceNow, etc.)
count=$(jq '.incidentPlatforms // [] | length' "$FILE")
if [[ "$count" -gt 0 ]]; then
  echo "incidentPlatforms: ${count}"
  # Use the first platform (agent only supports one at a time)
  platform_type=$(jq -r '.incidentPlatforms[0].spec.platformType // .incidentPlatforms[0].spec.incidentPlatform // empty' "$FILE")
  if [[ -n "$platform_type" ]]; then
    # Check for connectionKey (PagerDuty/ServiceNow need API key)
    conn_key=$(jq -r '.incidentPlatforms[0].spec.connectionKey // empty' "$FILE")
    conn_url=$(jq -r '.incidentPlatforms[0].spec.connectionUrl // empty' "$FILE")
    echo "  ARM PATCH → incidentManagementConfiguration.type=${platform_type}"
    conn_name=$(echo "$platform_type" | tr '[:upper:]' '[:lower:]')
    _patch_file=$(mktemp)
    if [[ -n "$conn_key" ]]; then
      jq -n \
        --arg pt "$platform_type" \
        --arg ck "$conn_key" \
        --arg cn "$conn_name" \
        --arg cu "$conn_url" \
        '{properties:{incidentManagementConfiguration:{type:$pt, connectionKey:$ck, connectionName:$cn, connectionUrl:$cu}}}' > "$_patch_file"
    else
      jq -n \
        --arg pt "$platform_type" \
        --arg cn "$conn_name" \
        --arg cu "$conn_url" \
        '{properties:{incidentManagementConfiguration:{type:$pt, connectionName:$cn, connectionUrl:$cu}}}' > "$_patch_file"
    fi
    if az rest --method PATCH \
      --url "${ARM_BASE}?api-version=${API_VERSION}" \
      --headers "Content-Type=application/json" \
      --body @"$_patch_file" \
      --output none 2>&1; then
      echo "    ok"
    else
      echo "    FAILED — could not set incident platform"
    fi
    rm -f "$_patch_file"
    # Wait for platform to initialize
    echo "  Waiting 30s for platform to initialize..."
    sleep 30
  fi
fi

# 1b. incidentFilters — data-plane PUT
# Route: PUT /api/v2/extendedAgent/incidentFilters/{name}
# Body: { name, type: "IncidentFilter", tags: [], properties: { incidentPlatform, priorities, agentMode, ... } }
count=$(jq '.incidentFilters // [] | length' "$FILE")
if [[ "$count" -gt 0 ]]; then
  if [[ "$DP_TOKEN_AVAILABLE" == "true" ]]; then
    echo "incidentFilters (response plans): ${count}"
    for i in $(seq 0 $((count - 1))); do
      name=$(jq -r --argjson i "$i" '.incidentFilters[$i].metadata.name' "$FILE")
      spec=$(jq -c --argjson i "$i" '.incidentFilters[$i].spec' "$FILE")

      # Build filter properties
      platform=$(echo "$spec" | jq -r '.incidentPlatform // .platformType // "AzureMonitor"')
      handling=$(echo "$spec" | jq -r 'if .handlingAgent == "" or .handlingAgent == null then "default" else .handlingAgent end')
      props=$(echo "$spec" | jq -c --arg p "$platform" --arg h "$handling" \
        '. + {incidentPlatform: $p, handlingAgent: $h, isEnabled: true}')

      # Data-plane PUT with retry — platform init may still be in progress after PATCH
      filter_ok=false
      for attempt in 1 2 3 4; do
        TOKEN=$(_dp_token)
        body=$(jq -nc --arg n "$name" --argjson props "$props" \
          '{name:$n, type:"IncidentFilter", tags:[], properties:$props}')
        url="${AGENT_ENDPOINT}/api/v2/extendedAgent/incidentFilters/$(printf %s "$name" | jq -sRr @uri)"
        if curl -sS -f -X PUT "$url" \
             -H "Authorization: Bearer ${TOKEN}" \
             -H "Content-Type: application/json" \
             --data "$body" >/dev/null 2>&1; then
          echo "  ok incidentFilters/${name}"
          filter_ok=true
          break
        else
          if [[ $attempt -lt 4 ]]; then
            echo "  incidentFilters/${name} — retry ${attempt}/4 in 30s (platform init)..."
            sleep 30
          else
            echo "  FAILED — PUT incidentFilters/${name}"
          fi
        fi
      done
    done
  else
    echo "incidentFilters: ${count} — ⚠ skipped (no data-plane token)"
    for i in $(seq 0 $((count - 1))); do
      fname=$(jq -r --argjson i "$i" '.incidentFilters[$i].metadata.name' "$FILE")
      DP_SKIPPED_ITEMS+=("incidentFilter/${fname}")
    done
  fi
fi

# 1c. scheduledTasks — data-plane PUT
# Route: PUT /api/v2/extendedAgent/scheduledtasks/{name}
# Body: { name, type: "ScheduledTask", tags: [], properties: { description, cronExpression, agentPrompt, agentMode } }
count=$(jq '.scheduledTasks // [] | length' "$FILE")
if [[ "$count" -gt 0 ]]; then
  if [[ "$DP_TOKEN_AVAILABLE" == "true" ]]; then
    echo "scheduledTasks: ${count}"
    for i in $(seq 0 $((count - 1))); do
      name=$(jq -r --argjson i "$i" '.scheduledTasks[$i].metadata.name' "$FILE")
      spec=$(jq -c --argjson i "$i" '.scheduledTasks[$i].spec' "$FILE")
      # Normalize field names
      props=$(jq -c '{
        name: (.name // ""),
        description: (.description // ""),
        cronExpression: (.schedule // .cronExpression // ""),
        agentPrompt: (.prompt // .agentPrompt // ""),
        agentMode: (.mode // .agentMode // "Review"),
        isEnabled: (.enabled // true)
      }' <<< "$spec")
      dataplane_put_extended "scheduledtasks" "$name" "ScheduledTask" "[]" "$props"
    done
  else
    echo "scheduledTasks: ${count} — ⚠ skipped (no data-plane token)"
    for i in $(seq 0 $((count - 1))); do
      tname=$(jq -r --argjson i "$i" '.scheduledTasks[$i].metadata.name' "$FILE")
      DP_SKIPPED_ITEMS+=("scheduledTask/${tname}")
    done
  fi
fi

# 2. repos — data-plane only (requires azuresre.dev token)
# Split repos into two buckets:
#   - byoapp_repos: domain has a GitHubApp entry in githubDomains → push directly after githubDomains are applied
#   - oauth_repos:  domain uses OAuth/PAT → pushed in the OAuth sign-in block (step 5)
count=$(jq '[.repos // [] | .[] | select(.spec.url // "" | length > 0)] | length' "$FILE")
oauth_repos=()
byoapp_repos=()
# Build a set of domains that use GitHubApp auth (BYO App)
_byoapp_domains=$(jq -r '[.githubDomains // [] | .[] | select(.spec.authType == "GitHubApp") | .metadata.name // .name] | join("|")' "$FILE" 2>/dev/null)
if [[ "$count" -gt 0 ]]; then
  if [[ "$DP_TOKEN_AVAILABLE" == "true" ]]; then
    for i in $(seq 0 $((count - 1))); do
      name=$(jq -r --argjson i "$i" '[.repos[] | select(.spec.url // "" | length > 0)][$i].name' "$FILE")
      rurl=$(jq -r --argjson i "$i" '[.repos[] | select(.spec.url // "" | length > 0)][$i].spec.url' "$FILE")
      # Determine the domain: full URL → extract host; short "org/repo" → github.com
      if [[ "$rurl" == http* ]]; then
        rdomain=$(echo "$rurl" | sed 's|https\?://||' | cut -d/ -f1)
      else
        rdomain="github.com"
      fi
      if [[ -n "$_byoapp_domains" ]] && echo "$rdomain" | grep -qE "^(${_byoapp_domains})$"; then
        byoapp_repos+=("$name")
      else
        oauth_repos+=("$name")
      fi
    done
    if [[ ${#byoapp_repos[@]} -gt 0 ]]; then
      echo "repos: ${#byoapp_repos[@]} via BYO App (will be wired after githubDomains)"
    fi
    if [[ ${#oauth_repos[@]} -gt 0 ]]; then
      echo "repos: ${#oauth_repos[@]} via OAuth (will be wired after GitHub sign-in below)"
    fi
  else
    echo "repos: ${count} — ⚠ skipped (no data-plane token)"
    for i in $(seq 0 $((count - 1))); do
      name=$(jq -r --argjson i "$i" '.repos[$i].name' "$FILE")
      DP_SKIPPED_ITEMS+=("repo/${name}")
    done
  fi
fi

# 3. repoInstructions (data-plane tar.gz, one per repo)
count=$(jq '.repoInstructions // [] | length' "$FILE")
if [[ "$count" -gt 0 ]]; then
  if [[ "$DP_TOKEN_AVAILABLE" == "true" ]]; then
    echo "repoInstructions: ${count}"
    for i in $(seq 0 $((count - 1))); do
      repo=$(jq -r --argjson i "$i" '.repoInstructions[$i].repo' "$FILE")
      files=$(jq -c --argjson i "$i" '.repoInstructions[$i].files' "$FILE")
      url="${AGENT_ENDPOINT}/api/v1/WorkspaceMemory/repo-instructions?repo=$(printf %s "$repo" | jq -sRr @uri)"
      dataplane_upload_tarball "repo-instructions/${repo}" "$url" "$files"
    done
  else
    echo "repoInstructions: ${count} — ⚠ skipped (no data-plane token)"
    DP_SKIPPED_ITEMS+=("repoInstructions (${count} items)")
  fi
fi

# 4. knowledge — AgentMemory multipart upload (data-plane only)
count=$(jq '.knowledge // [] | length' "$FILE")
if [[ "$count" -gt 0 ]]; then
  if [[ "$DP_TOKEN_AVAILABLE" == "true" ]]; then
    echo "knowledge: ${count} file(s)"
    url="${AGENT_ENDPOINT}/api/v1/AgentMemory/upload"
    for i in $(seq 0 $((count - 1))); do
      fname=$(jq -r --argjson i "$i" '.knowledge[$i].filename' "$FILE")
      mime=$(jq -r --argjson i "$i" '.knowledge[$i].mimeType // "application/octet-stream"' "$FILE")
      trig=$(jq -r --argjson i "$i" '.knowledge[$i].triggerIndexing // true' "$FILE")
      lpath=$(jq -r --argjson i "$i" '.knowledge[$i].localPath // empty' "$FILE")
      if [[ -n "$lpath" ]]; then
        [[ -f "$lpath" ]] || { echo "    FAILED — localPath not found: $lpath"; continue; }
        dataplane_upload_multipart "knowledge#${i}" "$url" "$fname" "$mime" "$trig" "$lpath"
      else
        tmpf=$(mktemp)
        jq -r --argjson i "$i" '.knowledge[$i].content // ""' "$FILE" > "$tmpf"
        dataplane_upload_multipart "knowledge#${i}" "$url" "$fname" "$mime" "$trig" "$tmpf"
        rm -f "$tmpf"
      fi
    done
  else
    echo "knowledge: ${count} file(s) — ⚠ skipped (no data-plane token)"
    DP_SKIPPED_ITEMS+=("knowledge (${count} files)")
  fi
fi

# 4a-2. knowledgeItems — ARM PUT as KnowledgeFile connectors (visible in portal Knowledge Sources)
count=$(jq '.knowledgeItems // [] | length' "$FILE")
if [[ "$count" -gt 0 ]]; then
  echo "knowledgeItems: ${count} file(s) → Knowledge Sources (ARM)"
  for i in $(seq 0 $((count - 1))); do
    fname=$(jq -r --argjson i "$i" '.knowledgeItems[$i].name' "$FILE")
    content=$(jq -r --argjson i "$i" '.knowledgeItems[$i].content' "$FILE")
    content_length=${#content}
    sanitized=$(echo "$fname" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//')
    b64=$(echo "$content" | base64)
    case "$fname" in
      *.md)   ctype="text/markdown" ;;
      *.txt)  ctype="text/plain" ;;
      *.pdf)  ctype="application/pdf" ;;
      *.json) ctype="application/json" ;;
      *)      ctype="application/octet-stream" ;;
    esac
    body=$(jq -nc \
      --arg name "$sanitized" \
      --arg displayName "$fname" \
      --arg fileName "$fname" \
      --arg fileContent "$b64" \
      --arg contentType "$ctype" \
      '{
        properties: {
          dataConnectorType: "KnowledgeFile",
          dataSource: $name,
          extendedProperties: {
            displayName: $displayName,
            fileName: $fileName,
            fileContent: $fileContent,
            contentType: $contentType
          }
        }
      }')
    arm_put_connector "$sanitized" "$body"
    # KnowledgeFile connectors need 15s between PUTs to avoid 500s
    [[ $i -lt $((count - 1)) ]] && sleep 15
  done
fi

# 4a-3. synthesizedKnowledge — tar.gz upload to WorkspaceMemory (data-plane)
synth_dir=$(jq -r '.synthesizedKnowledgeDir // empty' "$FILE")
if [[ -n "$synth_dir" && -d "$synth_dir" ]]; then
  sk_count=$(find "$synth_dir" -type f | wc -l | tr -d ' ')
  if [[ "$sk_count" -gt 0 ]]; then
    if [[ "$DP_TOKEN_AVAILABLE" == "true" ]]; then
      echo "synthesizedKnowledge: ${sk_count} file(s)"
      tarball=$(mktemp -t synth.XXXXXX.tar.gz)
      tar -czf "$tarball" -C "$synth_dir" .
      token=$(_dp_token) || { echo "    FAILED — token"; rm -f "$tarball"; }
      if [[ -n "$token" ]]; then
        echo "  data-plane POST WorkspaceMemory/synthesized-knowledge (${sk_count} files)"
        if curl -sS -f -X POST "${AGENT_ENDPOINT}/api/v1/WorkspaceMemory/synthesized-knowledge" \
             -H "Authorization: Bearer ${token}" \
             -H "Content-Type: application/gzip" \
             --data-binary "@${tarball}" >/dev/null 2>&1; then
          echo "    ok"
        else
          echo "    FAILED"
        fi
        rm -f "$tarball"
      fi
    else
      echo "synthesizedKnowledge: ${sk_count} file(s) — ⚠ skipped (no data-plane token)"
      DP_SKIPPED_ITEMS+=("synthesizedKnowledge (${sk_count} files)")
    fi
  fi
fi

# 4b. plugins.marketplaces (data-plane v2)
count=$(jq '.plugins.marketplaces // [] | length' "$FILE")
if [[ "$count" -gt 0 ]]; then
  if [[ "$DP_TOKEN_AVAILABLE" == "true" ]]; then
    echo "plugins.marketplaces: ${count}"
    url="${AGENT_ENDPOINT}/api/v2/plugins/marketplaces"
    for i in $(seq 0 $((count - 1))); do
      body=$(jq -c --argjson i "$i" '{ metadata: { name: .plugins.marketplaces[$i].name }, spec: .plugins.marketplaces[$i].spec }' "$FILE")
      name=$(jq -r --argjson i "$i" '.plugins.marketplaces[$i].name' "$FILE")
      dataplane_post_json "marketplaces/${name}" "$url" "$body"
    done
  else
    echo "plugins.marketplaces: ${count} — ⚠ skipped (no data-plane token)"
    DP_SKIPPED_ITEMS+=("plugins.marketplaces (${count} items)")
  fi
fi

# 4c. plugins.installations (data-plane v2)
count=$(jq '.plugins.installations // [] | length' "$FILE")
if [[ "$count" -gt 0 ]]; then
  if [[ "$DP_TOKEN_AVAILABLE" == "true" ]]; then
    echo "plugins.installations: ${count}"
    url="${AGENT_ENDPOINT}/api/v2/plugins/installations"
    for i in $(seq 0 $((count - 1))); do
      body=$(jq -c --argjson i "$i" '{ metadata: { name: .plugins.installations[$i].name }, spec: .plugins.installations[$i].spec }' "$FILE")
      name=$(jq -r --argjson i "$i" '.plugins.installations[$i].name' "$FILE")
      dataplane_post_json "installations/${name}" "$url" "$body"
    done
  else
    echo "plugins.installations: ${count} — ⚠ skipped (no data-plane token)"
    DP_SKIPPED_ITEMS+=("plugins.installations (${count} items)")
  fi
fi

# 4d. hooks — data-plane only (no ARM sub-resource)
count=$(jq '(.hooks // []) | length' "$FILE")
if [[ "$count" -gt 0 ]]; then
  if [[ "$DP_TOKEN_AVAILABLE" == "true" ]]; then
    _process_extended "hooks" "hooks"
  else
    echo "hooks: ${count} — ⚠ skipped (no data-plane token)"
    for i in $(seq 0 $((count - 1))); do
      hname=$(jq -r --argjson i "$i" '.hooks[$i].name' "$FILE")
      DP_SKIPPED_ITEMS+=("hook/${hname}")
    done
  fi
fi

# 4e. commonPrompts — data-plane PUT
count=$(jq '(.commonPrompts // []) | length' "$FILE")
if [[ "$count" -gt 0 ]]; then
  if [[ "$DP_TOKEN_AVAILABLE" == "true" ]]; then
    _process_extended "commonPrompts" "commonprompts"
  else
    echo "commonPrompts: ${count} — ⚠ skipped (no data-plane token)"
    for i in $(seq 0 $((count - 1))); do
      cpname=$(jq -r --argjson i "$i" '.commonPrompts[$i].name' "$FILE")
      DP_SKIPPED_ITEMS+=("commonPrompt/${cpname}")
    done
  fi
fi

# 4f. pluginConfigs — data-plane only
count=$(jq '(.pluginConfigs // []) | length' "$FILE")
if [[ "$count" -gt 0 ]]; then
  if [[ "$DP_TOKEN_AVAILABLE" == "true" ]]; then
    _process_extended "pluginConfigs" "plugins"
  else
    echo "pluginConfigs: ${count} — ⚠ skipped (no data-plane token)"
    DP_SKIPPED_ITEMS+=("pluginConfigs (${count} items)")
  fi
fi

# 4f-2. toolPermissions — data-plane PUT /api/v2/agent/settings/global
# Body: { permissions: { allow: [...], ask: [...], deny: [...] } }
# Requires If-Match header (optimistic concurrency) — GET first to get etag.
# If no global-settings doc exists yet (bootstrap), use If-Match: *
tp_has=$(jq 'has("toolPermissions") and (.toolPermissions | length > 0)' "$FILE")
if [[ "$tp_has" == "true" ]]; then
  if [[ "$DP_TOKEN_AVAILABLE" == "true" ]]; then
    echo "toolPermissions: configuring"
    TOKEN=$(_dp_token)
    # GET current to capture etag
    tp_resp=$(curl -sS -D- -o /tmp/tp_body.json "${AGENT_ENDPOINT}/api/v2/agent/settings/global" \
      -H "Authorization: Bearer ${TOKEN}" 2>/dev/null)
    tp_etag=$(echo "$tp_resp" | grep -i '^etag:' | tr -d '\r' | awk '{print $2}' || true)
    if [[ -z "$tp_etag" ]]; then
      tp_etag="*"  # bootstrap: no doc exists yet
    fi
    # Build body
    tp_body=$(jq -c '{permissions: .toolPermissions}' "$FILE")
    tp_result=$(curl -sS -w "\n%{http_code}" -X PUT "${AGENT_ENDPOINT}/api/v2/agent/settings/global" \
      -H "Authorization: Bearer ${TOKEN}" \
      -H "Content-Type: application/json" \
      -H "If-Match: ${tp_etag}" \
      --data "$tp_body" 2>&1)
    tp_code=$(echo "$tp_result" | tail -1)
    if [[ "$tp_code" =~ ^2 ]]; then
      echo "  ok toolPermissions"
    else
      echo "  FAILED — PUT settings/global (HTTP ${tp_code})"
    fi
    rm -f /tmp/tp_body.json
  else
    echo "toolPermissions — ⚠ skipped (no data-plane token)"
    DP_SKIPPED_ITEMS+=("toolPermissions")
  fi
fi

# 4f-3. githubDomains — data-plane PUT /api/v2/github/domains/{domain}
# Supports authType: Pat (github.com only) and GitHubApp (BYO App for GHE)
# Each entry: { metadata: { name: "github.com" }, spec: { authType, pat?, clientId?, privateKeySecretUri?, keyVaultManagedIdentityId? } }
count=$(jq '.githubDomains // [] | length' "$FILE")
if [[ "$count" -gt 0 ]]; then
  if [[ "$DP_TOKEN_AVAILABLE" == "true" ]]; then
    echo "githubDomains: ${count}"
    for i in $(seq 0 $((count - 1))); do
      domain=$(jq -r --argjson i "$i" '.githubDomains[$i].metadata.name // .githubDomains[$i].name' "$FILE")
      spec=$(jq -c --argjson i "$i" '.githubDomains[$i].spec // .githubDomains[$i]' "$FILE")
      # Resolve env vars in spec (secrets like clientId, privateKeySecretUri)
      auth_type=$(echo "$spec" | jq -r '.authType // "Pat"')
      # Encode domain for URL: github.com → github_com (dots to underscores)
      domain_encoded=$(echo "$domain" | tr '.' '_')
      TOKEN=$(_dp_token)
      ghd_result=$(curl -sS -w "\n%{http_code}" -X PUT \
        "${AGENT_ENDPOINT}/api/v2/github/domains/${domain_encoded}" \
        -H "Authorization: Bearer ${TOKEN}" \
        -H "Content-Type: application/json" \
        --data "$spec" 2>&1)
      ghd_code=$(echo "$ghd_result" | tail -1)
      if [[ "$ghd_code" =~ ^2 ]]; then
        echo "  ok githubDomains/${domain} (${auth_type})"
      else
        echo "  FAILED — PUT github/domains/${domain_encoded} (HTTP ${ghd_code})"
        echo "    $(echo "$ghd_result" | sed '$d' | head -2)"
      fi
    done
  else
    echo "githubDomains: ${count} — ⚠ skipped (no data-plane token)"
    for i in $(seq 0 $((count - 1))); do
      gd=$(jq -r --argjson i "$i" '.githubDomains[$i].metadata.name // .githubDomains[$i].name' "$FILE")
      DP_SKIPPED_ITEMS+=("githubDomain/${gd}")
    done
  fi
fi

# 4f-3b. BYO App repos — push repos that use GitHubApp auth directly (no OAuth needed)
# These were identified in step 2 above. The githubDomains PUT above already configured
# the BYO App auth, so the agent can access repos using the app's installation token.
if [[ ${#byoapp_repos[@]} -gt 0 && "$DP_TOKEN_AVAILABLE" == "true" ]]; then
  echo "byoapp repos: ${#byoapp_repos[@]}"
  TOKEN=$(_dp_token)
  repo_count=$(jq '.repos // [] | length' "$FILE")
  for rname in "${byoapp_repos[@]}"; do
    rurl=$(jq -r --arg n "$rname" '[.repos[] | select(.name == $n)][0].spec.url' "$FILE")
    rdesc=$(jq -r --arg n "$rname" '[.repos[] | select(.name == $n)][0].spec.description // ""' "$FILE")
    rtype_in=$(jq -r --arg n "$rname" '[.repos[] | select(.name == $n)][0].spec.type // "github"' "$FILE")
    case "$(printf %s "$rtype_in" | tr "[:upper:]" "[:lower:]")" in
      ado|azuredevops|azure-devops) rtype="AzureDevOps" ;;
      *)                            rtype="GitHub" ;;
    esac
    # Normalize short "org/repo" to full URL
    if [[ "$rurl" != http* && "$rurl" == */* ]]; then
      rurl="https://github.com/${rurl}"
    fi
    rbody=$(jq -nc --arg n "$rname" --arg u "$rurl" --arg t "$rtype" --arg d "$rdesc" '{
      name: $n,
      type: "CodeRepo",
      properties: ({ url: $u, type: $t } + (if $d == "" then {} else { description: $d } end))
    }')
    if curl -sS -f -X PUT "${AGENT_ENDPOINT}/api/v2/repos/$(printf %s "$rname" | jq -sRr @uri)" \
         -H "Authorization: Bearer ${TOKEN}" \
         -H "Content-Type: application/json" \
         --data "$rbody" >/dev/null 2>&1; then
      echo "  ok repo/${rname} (${rurl}) [BYO App]"
    else
      echo "  FAILED — PUT /api/v2/repos/${rname} (try the portal Repos blade)"
    fi
  done
fi

# 4f-4. connectorV2 — data-plane multi-step setup via /api/v2/connectorV2
# Each entry: { metadata: { name }, spec: { apiName, displayName, connectionName?,
#   parameterValueSet?: { name, values }, requireApprovalTools?: [...] } }
# Flow: 1) PUT connection  2) list consent links  3) print consent URL  4) PUT mcpserver config
count=$(jq '.connectorV2 // [] | length' "$FILE")
if [[ "$count" -gt 0 ]]; then
  if [[ "$DP_TOKEN_AVAILABLE" == "true" ]]; then
    echo "connectorV2: ${count}"
    for i in $(seq 0 $((count - 1))); do
      cv2_name=$(jq -r --argjson i "$i" '.connectorV2[$i].metadata.name // .connectorV2[$i].name' "$FILE")
      cv2_spec=$(jq -c --argjson i "$i" '.connectorV2[$i].spec // .connectorV2[$i]' "$FILE")
      cv2_api=$(echo "$cv2_spec" | jq -r '.apiName')
      cv2_display=$(echo "$cv2_spec" | jq -r '.displayName // .apiName')
      cv2_conn=$(echo "$cv2_spec" | jq -r '.connectionName // .apiName | ascii_downcase')
      cv2_pvs=$(echo "$cv2_spec" | jq -c '.parameterValueSet // null')
      cv2_pv=$(echo "$cv2_spec" | jq -c '.parameterValues // null')
      cv2_rat=$(echo "$cv2_spec" | jq -c '.requireApprovalTools // null')

      TOKEN=$(_dp_token)

      # Step 1: Create the connection
      conn_body=$(jq -nc --arg dn "$cv2_display" --arg cn "$cv2_api" \
        --argjson pvs "$cv2_pvs" --argjson pv "$cv2_pv" \
        '{displayName: $dn, connectorName: $cn} + (if $pvs != null then {parameterValueSet: $pvs} else {} end) + (if $pv != null then {parameterValues: $pv} else {} end)')
      conn_result=$(curl -sS -w "\n%{http_code}" -X PUT \
        "${AGENT_ENDPOINT}/api/v2/connectorV2/connections/${cv2_conn}" \
        -H "Authorization: Bearer ${TOKEN}" \
        -H "Content-Type: application/json" \
        --data "$conn_body" 2>&1)
      conn_code=$(echo "$conn_result" | tail -1)
      if [[ "$conn_code" =~ ^2 ]]; then
        echo "  ok connectorV2/connection/${cv2_conn}"
      else
        echo "  WARN — PUT connection/${cv2_conn} (HTTP ${conn_code}) — may need OAuth consent in portal"
      fi

      # Step 2: Create MCP server config (links connection to MCP tools)
      mcp_body=$(jq -nc --arg desc "$cv2_display" --arg cn "$cv2_conn" --arg api "$cv2_api" \
        --argjson rat "$cv2_rat" \
        '{properties: {description: $desc, connectors: [{name: $api, connectionName: $cn}]}} + (if $rat != null then {runtimeMcpConfiguration: {requireApprovalTools: $rat}} else {} end)')
      TOKEN=$(_dp_token)
      mcp_result=$(curl -sS -w "\n%{http_code}" -X PUT \
        "${AGENT_ENDPOINT}/api/v2/connectorV2/mcpservers/${cv2_conn}" \
        -H "Authorization: Bearer ${TOKEN}" \
        -H "Content-Type: application/json" \
        --data "$mcp_body" 2>&1)
      mcp_code=$(echo "$mcp_result" | tail -1)
      if [[ "$mcp_code" =~ ^2 ]]; then
        echo "  ok connectorV2/mcpserver/${cv2_conn}"
      else
        echo "  FAILED — PUT mcpservers/${cv2_conn} (HTTP ${mcp_code})"
        echo "    $(echo "$mcp_result" | sed '$d' | head -2)"
      fi

      # Step 3: Print consent link if connection needs OAuth
      conn_status=$(echo "$conn_result" | sed '$d' | jq -r '.properties.overallStatus // "Unknown"' 2>/dev/null)
      if [[ "$conn_status" == "Error" || "$conn_status" == "Unauthenticated" ]]; then
        echo "  ⚠ Connection ${cv2_conn} needs OAuth consent. Complete in the portal:"
        echo "    https://sre.azure.com → Connectors → ${cv2_display} → Authorize"
      fi
    done
  else
    echo "connectorV2: ${count} — ⚠ skipped (no data-plane token)"
    for i in $(seq 0 $((count - 1))); do
      cn=$(jq -r --argjson i "$i" '.connectorV2[$i].metadata.name // .connectorV2[$i].name' "$FILE")
      DP_SKIPPED_ITEMS+=("connectorV2/${cn}")
    done
  fi
fi

# 4g. httpTriggers — data-plane only
count=$(jq '.httpTriggers // [] | length' "$FILE")
HTTP_TRIGGER_URL=""
if [[ "$count" -gt 0 ]]; then
  if [[ "$DP_TOKEN_AVAILABLE" == "true" ]]; then
    echo "httpTriggers: ${count}"
    TOKEN=$(_dp_token)
    EXISTING_TRIGGERS=$(curl -sS "${AGENT_ENDPOINT}/api/v1/httpTriggers" \
      -H "Authorization: Bearer ${TOKEN}" 2>/dev/null || echo '[]')
    for i in $(seq 0 $((count - 1))); do
      name=$(jq -r --argjson i "$i" '.httpTriggers[$i].name' "$FILE")
      spec=$(jq -c --argjson i "$i" '.httpTriggers[$i].spec // .httpTriggers[$i]' "$FILE")
      body=$(jq -n --arg name "$name" --argjson spec "$spec" '{name: $name} + $spec')
      existing_id=$(echo "$EXISTING_TRIGGERS" | jq -r --arg n "$name" '[.[] | select(.name == $n)] | first | .id // empty')
      if [[ -n "$existing_id" ]]; then
        existing_url="${AGENT_ENDPOINT}/api/v1/httptriggers/trigger/${existing_id}"
        echo "  httpTrigger/${name}: ${existing_url}"
        [[ -z "$HTTP_TRIGGER_URL" ]] && HTTP_TRIGGER_URL="$existing_url"
      else
        resp=$(curl -sS -w "\n%{http_code}" -X POST "${AGENT_ENDPOINT}/api/v1/httptriggers/create" \
          -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" -d "$body" 2>&1)
        http_code=$(echo "$resp" | tail -1)
        if [[ "$http_code" =~ ^2 ]]; then
          trigger_url=$(echo "$resp" | sed '$d' | jq -r '.triggerUrl // "created"')
          echo "  httpTrigger/${name}: ${trigger_url}"
          [[ -z "$HTTP_TRIGGER_URL" ]] && HTTP_TRIGGER_URL="$trigger_url"
        else
          echo "  httpTrigger/${name}: FAILED (HTTP ${http_code})"
        fi
      fi
    done
  else
    echo "httpTriggers: ${count} — ⚠ skipped (no data-plane token)"
    for i in $(seq 0 $((count - 1))); do
      hname=$(jq -r --argjson i "$i" '.httpTriggers[$i].name' "$FILE")
      DP_SKIPPED_ITEMS+=("httpTrigger/${hname}")
    done
  fi
fi

# 4h. MCP connectors — ARM PUT (native properties, no data-plane token needed)
count=$(jq '.connectors // [] | length' "$FILE")
if [[ "$count" -gt 0 ]]; then
  echo "connectors: ${count} (ARM)"
  for i in $(seq 0 $((count - 1))); do
    cname=$(jq -r --argjson i "$i" '.connectors[$i].name' "$FILE")
    ctype=$(jq -r --argjson i "$i" '.connectors[$i].properties.dataConnectorType' "$FILE")
    body=$(jq -c --argjson i "$i" '{properties: .connectors[$i].properties}' "$FILE")
    arm_put_connector "$cname" "$body"
  done
fi

# 4i-1. skills — data-plane PUT
# Route: PUT /api/v2/extendedAgent/skills/{name}
# Body: { name, type: "Skill", tags: [], properties: { name, description, tools, skillContent, additionalFiles } }
count=$(jq '.skills // [] | length' "$FILE")
if [[ "$count" -gt 0 ]]; then
  if [[ "$DP_TOKEN_AVAILABLE" == "true" ]]; then
    echo "skills: ${count}"
    for i in $(seq 0 $((count - 1))); do
      name=$(jq -r --argjson i "$i" '.skills[$i].metadata.name' "$FILE")
      desc=$(jq -r --argjson i "$i" '.skills[$i].metadata.description // ""' "$FILE")
      skill_tools=$(jq -c --argjson i "$i" '.skills[$i].metadata.spec.tools // []' "$FILE")
      skill_content=$(jq -r --argjson i "$i" '.skills[$i].skillContent // ""' "$FILE")
      additional_files=$(jq -c --argjson i "$i" '.skills[$i].additionalFiles // []' "$FILE")
      props=$(jq -nc --arg n "$name" --arg d "$desc" --argjson t "$skill_tools" \
        --arg c "$skill_content" --argjson af "$additional_files" \
        '{name:$n, description:$d, tools:$t, skillContent:$c, additionalFiles:$af}')
      dataplane_put_extended "skills" "$name" "Skill" "[]" "$props"
    done
  else
    echo "skills: ${count} — ⚠ skipped (no data-plane token)"
    for i in $(seq 0 $((count - 1))); do
      sname=$(jq -r --argjson i "$i" '.skills[$i].metadata.name' "$FILE")
      DP_SKIPPED_ITEMS+=("skill/${sname}")
    done
  fi
fi

# 4i-2. subagents — data-plane PUT
# Route: PUT /api/v2/extendedAgent/agents/{name}
# Body: { name, type: "ExtendedAgent", tags: [], properties: { instructions, handoffDescription, tools, ... } }
count=$(jq '.subagents // [] | length' "$FILE")
if [[ "$count" -gt 0 ]]; then
  if [[ "$DP_TOKEN_AVAILABLE" == "true" ]]; then
    echo "subagents: ${count}"
    for i in $(seq 0 $((count - 1))); do
      name=$(jq -r --argjson i "$i" '.subagents[$i].metadata.name' "$FILE")
      props=$(jq -c --argjson i "$i" '.subagents[$i].spec' "$FILE")
      dataplane_put_extended "agents" "$name" "ExtendedAgent" "[]" "$props"
    done
  else
    echo "subagents: ${count} — ⚠ skipped (no data-plane token)"
    for i in $(seq 0 $((count - 1))); do
      saname=$(jq -r --argjson i "$i" '.subagents[$i].metadata.name' "$FILE")
      DP_SKIPPED_ITEMS+=("subagent/${saname}")
    done
  fi
fi

# 4i-3. tools — data-plane PUT
# Route: PUT /api/v2/extendedAgent/tools/{name}
# Body: { name, type: "Tool", tags: [], properties: { ... tool spec } }
count=$(jq '.tools // [] | length' "$FILE")
if [[ "$count" -gt 0 ]]; then
  if [[ "$DP_TOKEN_AVAILABLE" == "true" ]]; then
    echo "tools: ${count}"
    for i in $(seq 0 $((count - 1))); do
      name=$(jq -r --argjson i "$i" '.tools[$i].metadata.name' "$FILE")
      props=$(jq -c --argjson i "$i" '.tools[$i].spec' "$FILE")
      dataplane_put_extended "tools" "$name" "Tool" "[]" "$props"
    done
  else
    echo "tools: ${count} — ⚠ skipped (no data-plane token)"
    for i in $(seq 0 $((count - 1))); do
      tname=$(jq -r --argjson i "$i" '.tools[$i].metadata.name' "$FILE")
      DP_SKIPPED_ITEMS+=("tool/${tname}")
    done
  fi
fi

# 4i. Webhook bridge Logic App — auto-deploy if httpTriggers exist and enableWebhookBridge is set
#     Solves the chicken-and-egg: trigger URL is only known after httpTrigger creation above.
if [[ -n "$HTTP_TRIGGER_URL" ]]; then
  # Check if agent.json has enableWebhookBridge=true
  AGENT_JSON_DIR=$(dirname "$FILE")
  # The FILE is extras.json — look for agent.json in the original config dir
  # deploy.sh passes INPUT as an env var if available
  WH_ENABLED="false"
  for candidate in "${INPUT}/agent.json" "${AGENT_JSON_DIR}/../agent.json" "${AGENT_JSON_DIR}/agent.json"; do
    if [[ -f "$candidate" ]]; then
      WH_ENABLED=$(jq -r '.toggles.enableWebhookBridge // false' "$candidate" 2>/dev/null)
      break
    fi
  done

  if [[ "$WH_ENABLED" == "true" ]]; then
    # Check if Logic App already exists
    EXISTING_LA=$(az resource list -g "$RG" --resource-type Microsoft.Logic/workflows --query "[?name=='${AGENT}-webhook-bridge'].name" -o tsv 2>/dev/null)
    if [[ -n "$EXISTING_LA" ]]; then
      WH_CALLBACK=$(az rest --method POST \
        --url "/subscriptions/${SUB}/resourceGroups/${RG}/providers/Microsoft.Logic/workflows/${AGENT}-webhook-bridge/triggers/incoming_webhook/listCallbackUrl?api-version=2019-05-01" \
        --query value -o tsv 2>/dev/null)
      echo
      echo "webhook-bridge: already exists"
      echo "  Callback URL: ${WH_CALLBACK}"
    else
      echo
      echo "── Deploying webhook bridge Logic App ──"
      echo "  Trigger URL: ${HTTP_TRIGGER_URL}"
      SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
      LA_RESULT=$(az deployment group create \
        --resource-group "$RG" \
        --template-file "${SCRIPT_PATH}/logic-app-bridge.bicep" \
        --parameters agentName="$AGENT" location="$(az group show -n "$RG" --query location -o tsv)" triggerUrl="$HTTP_TRIGGER_URL" \
        --output json 2>&1)
      LA_STATE=$(echo "$LA_RESULT" | jq -r '.properties.provisioningState // "?"' 2>/dev/null)
      if [[ "$LA_STATE" == "Succeeded" ]]; then
        WH_CALLBACK=$(echo "$LA_RESULT" | jq -r '.properties.outputs.logicAppCallbackUrl.value // empty')
        echo "  ✅ Webhook bridge deployed"
        echo "  Callback URL: ${WH_CALLBACK}"
      else
        echo "  ❌ Webhook bridge deployment failed"
        echo "$LA_RESULT" | head -10
      fi
    fi
  fi
fi

# ---------------------------------------------------------------------------
# 5. Post-deploy auth wiring (data-plane). All optional — driven by env vars
#    so secrets never sit in JSON. Requires data-plane token.
# ---------------------------------------------------------------------------

if [[ "$DP_TOKEN_AVAILABLE" == "true" ]]; then

# Reusable: get a data-plane bearer (already defined above for multipart helper)

# 5a. GitHub auth
#   - GITHUB_PAT set  → install PAT silently (no browser)
#   - GITHUB_PAT unset → print OAuth login URL at the end (browser sign-in, no secret in env)
if [[ -n "${GITHUB_PAT:-}" ]]; then
  echo "GitHub auth: installing PAT (no browser needed)"
  TOKEN=$(_dp_token)
  if curl -sS -f -X PUT "${AGENT_ENDPOINT}/api/v2/github/domains/github.com" \
       -H "Authorization: Bearer ${TOKEN}" \
       -H "Content-Type: application/json" \
       --data "{\"AuthType\":\"Pat\",\"Pat\":\"${GITHUB_PAT}\"}" >/dev/null; then
    echo "  ok"
  else
    echo "  FAILED — PUT /api/v2/github/domains/github.com"
  fi
elif [[ ${#oauth_repos[@]} -gt 0 ]]; then
  echo "GitHub auth: will use OAuth (browser sign-in) — see URL below"
fi

# 5b. Azure DevOps PAT
if [[ -n "${ADO_PAT:-}" && -n "${ADO_ORG:-}" ]]; then
  echo "post_deploy: ADO PAT detected — wiring up for ${ADO_ORG}"
  TOKEN=$(_dp_token)
  if curl -sS -f -X POST "${AGENT_ENDPOINT}/api/v1/AzureDevOps/auth/pat?organization=${ADO_ORG}" \
       -H "Authorization: Bearer ${TOKEN}" \
       -H "Content-Type: application/json" \
       --data "{\"accessToken\":\"${ADO_PAT}\"}" >/dev/null; then
    echo "  ok"
  else
    echo "  FAILED — POST /api/v1/AzureDevOps/auth/pat"
  fi
fi

# 5c. Azure DevOps via AAD (uses your `az login` token, no PAT needed)
if [[ "${ADO_USE_AAD:-0}" == "1" && -n "${ADO_ORG:-}" ]]; then
  echo "post_deploy: wiring ADO via your AAD token for ${ADO_ORG}"
  AAD_TOKEN=$(az account get-access-token --resource 499b84ac-1321-427f-aa17-267ca6975798 --query accessToken -o tsv 2>/dev/null)
  TOKEN=$(_dp_token)
  if curl -sS -f -X POST "${AGENT_ENDPOINT}/api/v1/AzureDevOps/aadauth/complete?organization=${ADO_ORG}" \
       -H "Authorization: Bearer ${TOKEN}" \
       -H "Content-Type: application/json" \
       --data "{\"aadAccessToken\":\"${AAD_TOKEN}\"}" >/dev/null; then
    echo "  ok"
  else
    echo "  FAILED — POST /api/v1/AzureDevOps/aadauth/complete"
  fi
fi

# 5d. Azure DevOps via Managed Identity
if [[ "${ADO_USE_MI:-0}" == "1" && -n "${ADO_ORG:-}" ]]; then
  echo "post_deploy: wiring ADO via agent MI for ${ADO_ORG}"
  TOKEN=$(_dp_token)
  if curl -sS -f -X POST "${AGENT_ENDPOINT}/api/v1/AzureDevOps/auth/mi?organization=${ADO_ORG}" \
       -H "Authorization: Bearer ${TOKEN}" >/dev/null; then
    echo "  ok"
  else
    echo "  FAILED — POST /api/v1/AzureDevOps/auth/mi"
  fi
fi

echo

# ---------------------------------------------------------------------------
# GitHub: OAuth sign-in + repo wiring.
# Three-state flow:
#   - No repos requested              → skip
#   - Repos requested, OAuth NOT done → print sign-in URL, instruct re-run
#   - Repos requested, OAuth DONE     → PUT repos
# NOTE: The old GitHubOAuth connector type was deprecated in platform build
#   26.4.216.0 (April 2026). Auth is now stored via /api/v2/github/domains.
#   We no longer PUT /api/v2/extendedAgent/connectors/github.
# ---------------------------------------------------------------------------
if [[ ${#oauth_repos[@]} -gt 0 ]]; then
  TOKEN=$(_dp_token 2>/dev/null || true)
  # Check if OAuth is configured via domains endpoint
  GH_STATUS=$(curl -sS -H "Authorization: Bearer ${TOKEN}" \
    "${AGENT_ENDPOINT}/api/v2/github/domains" 2>/dev/null || echo '{}')
  if echo "$GH_STATUS" | jq empty 2>/dev/null; then
    GH_CONFIGURED=$(echo "$GH_STATUS" | jq -r 'if (.values // []) | length > 0 then "true" else "false" end')
  else
    GH_CONFIGURED="false"
  fi

  if [[ "$GH_CONFIGURED" == "true" || -n "${GITHUB_PAT:-}" ]]; then
    # ── OAuth (or PAT) is in place — wire repos ──
    echo "── Wiring GitHub repos ──"

    # If GITHUB_PAT is provided, store it via the domains API so the agent
    # can use it for GitHub API calls (replaces deprecated connector PUT).
    if [[ -n "${GITHUB_PAT:-}" && "$GH_CONFIGURED" != "true" ]]; then
      if curl -sS -f -X PUT "${AGENT_ENDPOINT}/api/v2/github/domains/github_com" \
           -H "Authorization: Bearer ${TOKEN}" \
           -H "Content-Type: application/json" \
           --data "{\"AuthType\":\"Pat\",\"Pat\":\"${GITHUB_PAT}\"}" >/dev/null; then
        echo "  ok github/domains/github_com (PAT)"
      else
        echo "  FAILED — PUT /api/v2/github/domains/github_com"
      fi
    fi

    # Attach each repo via the v2 repos dataplane (CodeRepoApiController).
    # Route: PUT /api/v2/repos/{name}
    # Body : { name, type:"CodeRepo", properties:{ url, type:"GitHub"|"AzureDevOps", description? } }
    count=$(jq '.repos // [] | length' "$FILE")
    for i in $(seq 0 $((count - 1))); do
      rname=$(jq -r --argjson i "$i" '.repos[$i].name' "$FILE")
      rurl=$(jq -r  --argjson i "$i" '.repos[$i].spec.url' "$FILE")
      # Normalize short "org/repo" to full URL (API requires valid URL format)
      if [[ "$rurl" != http* && "$rurl" == */* ]]; then
        rurl="https://github.com/${rurl}"
      fi
      # Map our spec.type ("github"/"ado") to the View enum ("GitHub"/"AzureDevOps").
      rtype_in=$(jq -r --argjson i "$i" '.repos[$i].spec.type // "github"' "$FILE")
      case "$(printf %s "$rtype_in" | tr "[:upper:]" "[:lower:]")" in
        ado|azuredevops|azure-devops) rtype="AzureDevOps" ;;
        *)                            rtype="GitHub" ;;
      esac
      rdesc=$(jq -r --argjson i "$i" '.repos[$i].spec.description // ""' "$FILE")
      rbody=$(jq -nc --arg n "$rname" --arg u "$rurl" --arg t "$rtype" --arg d "$rdesc" '{
        name: $n,
        type: "CodeRepo",
        properties: ({ url: $u, type: $t } + (if $d == "" then {} else { description: $d } end))
      }')
      if curl -sS -f -X PUT "${AGENT_ENDPOINT}/api/v2/repos/$(printf %s "$rname" | jq -sRr @uri)" \
           -H "Authorization: Bearer ${TOKEN}" \
           -H "Content-Type: application/json" \
           --data "$rbody" >/dev/null; then
        echo "  ok repo/${rname} (${rurl})"
      else
        echo "  FAILED — PUT /api/v2/repos/${rname} (try the portal Repos blade)"
      fi
    done
    echo
  else
    # ── OAuth not done — print sign-in URL ──
    echo "── GitHub OAuth sign-in required ──"
    echo "Repos waiting: ${oauth_repos[*]}"
    OAUTH_URL=""
    if [[ -n "$TOKEN" ]]; then
      _gh_config=$(curl -sS -f -H "Authorization: Bearer ${TOKEN}" \
        "${AGENT_ENDPOINT}/api/v2/github/oauth/config" 2>/dev/null || echo '{}')
      if echo "$_gh_config" | jq empty 2>/dev/null; then
        OAUTH_URL=$(echo "$_gh_config" | jq -r '.oAuthUrl // .OAuthUrl // empty')
      fi
    fi
    if [[ -n "${OAUTH_URL:-}" ]]; then
      echo "  1. Open this URL in a browser:"
      echo "     ${OAUTH_URL}"
      echo "  2. Sign in to GitHub and approve the SRE Agent app."
      echo
      echo "  Waiting for GitHub authorization (Ctrl-C to skip)..."
      auth_ok=false
      for attempt in $(seq 1 24); do
        sleep 10
        TOKEN=$(_dp_token 2>/dev/null || true)
        # Poll domains endpoint — non-empty means OAuth callback was received
        _poll=$(curl -sS -H "Authorization: Bearer ${TOKEN}" \
          "${AGENT_ENDPOINT}/api/v2/github/domains" 2>/dev/null || echo '{}')
        _has_domain=$(echo "$_poll" | jq -r 'if (.values // []) | length > 0 then "true" else "false" end' 2>/dev/null)
        if [[ "$_has_domain" == "true" ]]; then
          echo "  GitHub authorized!"
          auth_ok=true
          break
        fi
        printf "  ... waiting (%d/240s)\r" $((attempt * 10))
      done
      echo

      if [[ "$auth_ok" == "true" ]]; then
        # OAuth token stored by platform callback — wire repos
        echo "── Wiring GitHub repos ──"
        TOKEN=$(_dp_token)
        count=$(jq '.repos // [] | length' "$FILE")
        for i in $(seq 0 $((count - 1))); do
          rname=$(jq -r --argjson i "$i" '.repos[$i].name' "$FILE")
          rurl=$(jq -r --argjson i "$i" '.repos[$i].spec.url' "$FILE")
          # Normalize short "org/repo" to full URL (API requires valid URL format)
          if [[ "$rurl" != http* && "$rurl" == */* ]]; then
            rurl="https://github.com/${rurl}"
          fi
          rtype_in=$(jq -r --argjson i "$i" '.repos[$i].spec.type // "github"' "$FILE")
          case "$(printf %s "$rtype_in" | tr "[:upper:]" "[:lower:]")" in ado*) rtype="AzureDevOps" ;; *) rtype="GitHub" ;; esac
          rbody=$(jq -nc --arg n "$rname" --arg u "$rurl" --arg t "$rtype" '{name:$n,type:"CodeRepo",properties:{url:$u,type:$t}}')
          curl -sS -f -X PUT "${AGENT_ENDPOINT}/api/v2/repos/$(printf %s "$rname" | jq -sRr @uri)" \
            -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" --data "$rbody" >/dev/null && \
            echo "  ok repo/${rname}" || echo "  FAILED repo/${rname}"
        done
      else
        echo "  Timed out. Re-run apply-extras after authorizing."
        echo "  Headless alternative: export GITHUB_PAT=ghp_xxx && re-run"
      fi
    else
      echo "  Could not fetch OAuth URL from ${AGENT_ENDPOINT}/api/v2/github/oauth/config."
      echo "  Fallback: Azure portal → agent → Repos → 'Authorize' next to each repo."
    fi
    echo
  fi
fi

if [[ -z "${ADO_PAT:-}" && "${ADO_USE_AAD:-0}" != "1" && "${ADO_USE_MI:-0}" != "1" ]]; then
  echo "Optional Azure DevOps auth (only needed if you have ADO repos / connectors):"
  echo "  PAT:  export ADO_ORG=https://dev.azure.com/<org> ADO_PAT=<pat> && re-run"
  echo "  AAD:  export ADO_ORG=https://dev.azure.com/<org> ADO_USE_AAD=1 && re-run"
  echo "  MI:   export ADO_ORG=https://dev.azure.com/<org> ADO_USE_MI=1  && re-run"
  echo
fi

fi  # end DP_TOKEN_AVAILABLE block

# ---------------------------------------------------------------------------
# Summary of skipped items (data-plane token unavailable)
# ---------------------------------------------------------------------------
if [[ ${#DP_SKIPPED_ITEMS[@]} -gt 0 ]]; then
  echo ""
  echo "══════════════════════════════════════════════════════════════"
  echo "  ⚠ ${#DP_SKIPPED_ITEMS[@]} item(s) skipped (no data-plane token)"
  echo "  These require audience https://azuresre.dev which is not"
  echo "  available in this environment (Cloud Shell MSI)."
  echo ""
  echo "  To apply the remaining items:"
  echo "    1. From a compliant machine: az login && re-run this script"
  echo "    2. Or configure in the portal: https://sre.azure.com"
  echo ""
  echo "  Skipped:"
  for item in "${DP_SKIPPED_ITEMS[@]}"; do
    echo "    - ${item}"
  done
  echo "══════════════════════════════════════════════════════════════"
fi

echo ""
echo "── Your agent ──"
echo "  Open agent:    https://sre.azure.com/#/agent/${SUB}/${RG}/${AGENT}"
echo "  Resource group: https://portal.azure.com/#@/resource/subscriptions/${SUB}/resourceGroups/${RG}/overview"
echo "  Data plane:    ${AGENT_ENDPOINT}"
echo
echo "Done."
