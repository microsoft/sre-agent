#!/usr/bin/env bash
set -euo pipefail

lab_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
original_path="$PATH"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/sre-agent-bash-tests.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT
mkdir -p "$test_root/bin"
export TEST_CALLS="$test_root/calls.log"
export TEST_CAPTURE="$test_root/parameters.json"
passed=0

pass() {
  passed=$((passed + 1))
  printf 'PASS %s\n' "$1"
}

assert_fails_without_calls() {
  local name="$1"
  local expected="$2"
  shift 2
  : >"$TEST_CALLS"
  if "$@" >"$test_root/output.log" 2>&1; then
    printf 'FAIL %s: command unexpectedly succeeded\n' "$name" >&2
    exit 1
  fi
  grep -q "$expected" "$test_root/output.log" || {
    printf 'FAIL %s: expected error not found\n' "$name" >&2
    cat "$test_root/output.log" >&2
    exit 1
  }
  [[ ! -s "$TEST_CALLS" ]] || {
    printf 'FAIL %s: invalid input reached an external command\n' "$name" >&2
    exit 1
  }
  pass "$name"
}

cat >"$test_root/bin/az" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf 'az %s\n' "$*" >>"$TEST_CALLS"
parameter_file=''
while [[ $# -gt 0 ]]; do
  if [[ "$1" == '--parameters' ]]; then
    parameter_file="${2#@}"
    break
  fi
  shift
done
[[ -n "$parameter_file" && -f "$parameter_file" ]]
cp "$parameter_file" "$TEST_CAPTURE"
printf '%s\n' '{"properties":{"provisioningState":"Succeeded","outputs":{"result":{"value":"ok"}}}}'
MOCK

cat >"$test_root/bin/azd" <<'MOCK'
#!/usr/bin/env bash
printf 'azd %s\n' "$*" >>"$TEST_CALLS"
exit 99
MOCK
chmod +x "$test_root/bin/az" "$test_root/bin/azd"
export PATH="$test_root/bin:$original_path"

for script in \
  "$lab_root/agent-setup/apply-permissions.sh" \
  "$lab_root/scripts/internal/lab-environment.sh" \
  "$lab_root/scripts/deploy-agent.sh" \
  "$lab_root/scripts/deploy-use-cases.sh" \
  "$lab_root/scripts/fault.sh"; do
  bash -n "$script"
done
pass 'all Bash scripts parse'

# shellcheck source=../scripts/internal/lab-environment.sh
source "$lab_root/scripts/internal/lab-environment.sh"
parameters='{"recipients":["one@example.test"],"enabled":false,"severity":2}'
outputs="$(invoke_lab_deployment '11111111-1111-1111-1111-111111111111' 'lab-rg' 'offline-test' "$lab_root/fault.bicep" "$parameters")"
jq -e '.result.value == "ok"' <<<"$outputs" >/dev/null
jq -e '.parameters.recipients.value == ["one@example.test"] and .parameters.enabled.value == false and .parameters.severity.value == 2' "$TEST_CAPTURE" >/dev/null
parameter_path="$(awk '{ for (i=1; i<=NF; i++) if ($i == "--parameters") print $(i+1) }' "$TEST_CALLS" | sed 's/^@//')"
[[ -n "$parameter_path" && ! -e "$parameter_path" ]]
pass 'deployment parameters preserve JSON types and temporary file is removed'

assert_fails_without_calls 'invalid repository URL fails before Azure calls' 'Supply https://github.com' \
  "$lab_root/scripts/deploy-use-cases.sh" \
  --github-repository-url 'https://example.test/owner/repo' \
  --email-recipient 'person@example.test' \
  --email-connector-name 'email'

assert_fails_without_calls 'incident enable requires explicit connection confirmation' 'confirm-connections-ready' \
  "$lab_root/scripts/deploy-use-cases.sh" \
  --github-repository-url 'https://github.com/example/repo' \
  --email-recipient 'person@example.test' \
  --email-connector-name 'email' \
  --enable-incidents

assert_fails_without_calls 'invalid email fails before Azure calls' 'plain email address' \
  "$lab_root/scripts/deploy-use-cases.sh" \
  --github-repository-url 'https://github.com/example/repo' \
  --email-recipient 'Display Name <person@example.test>' \
  --email-connector-name 'email'

assert_fails_without_calls 'invalid fault action fails before Azure calls' 'Usage:' \
  "$lab_root/scripts/fault.sh" remove

assert_fails_without_calls 'invalid permission resource ID fails before Azure calls' 'ResourceId must' \
  "$lab_root/agent-setup/apply-permissions.sh" \
  --subscription-id '11111111-1111-1111-1111-111111111111' \
  --resource-id '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/lab-rg/providers/Microsoft.App/agents/lab-agent?x=1'

cat >"$test_root/bin/az" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf 'az %s\n' "$*" >>"$TEST_CALLS"
if [[ "$1" == 'rest' ]]; then
  printf '%s\n' '{"id":"/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/lab-rg/providers/Microsoft.App/agents/lab-agent","properties":{"actionConfiguration":{"mode":"Review"},"agentEndpoint":"https://agent.example.test"}}'
else
  printf '%s\n' 'test-secret-token'
fi
MOCK
cat >"$test_root/bin/curl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf 'curl %s\n' "$*" >>"$TEST_CALLS"
[[ "$*" != *'test-secret-token'* ]] || exit 91
config="$(cat)"
[[ "$config" == *'Authorization: Bearer test-secret-token'* ]] || exit 92
body_file=''
header_file=''
url=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output) body_file="$2"; shift 2 ;;
    --dump-header) header_file="$2"; shift 2 ;;
    http*) url="$1"; shift ;;
    *) shift ;;
  esac
done
: >"$header_file"
if [[ "$url" == */api/v1/Feature/status/enableV2AgentLoop ]]; then
  printf '%s' '{"enabled":true}' >"$body_file"
elif [[ "$url" == */api/v2/agent/settings/global ]]; then
  cp "$TEST_PERMISSIONS" "$body_file"
else
  exit 93
fi
printf '200'
MOCK
chmod +x "$test_root/bin/az" "$test_root/bin/curl"
export TEST_PERMISSIONS="$lab_root/agent-setup/permissions.json"
: >"$TEST_CALLS"
"$lab_root/agent-setup/apply-permissions.sh" \
  --subscription-id '11111111-1111-1111-1111-111111111111' \
  --resource-id '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/lab-rg/providers/Microsoft.App/agents/lab-agent' \
  >"$test_root/output.log"
[[ "$(grep -c '^curl ' "$TEST_CALLS")" -eq 2 ]]
! grep -q 'test-secret-token' "$TEST_CALLS"
grep -q 'already match' "$test_root/output.log"
pass 'authenticated HTTP keeps bearer token out of process arguments'

printf '\nRESULT: %d passed; 0 failed.\n' "$passed"
