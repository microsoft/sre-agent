#!/usr/bin/env bash
# tests/lib/test-helpers.sh — Shared helpers for recipe dry-run tests.
# Source this from each test-dry-run-<recipe>.sh script.

PASS=0; FAIL=0; TOTAL=0
REPORT="${REPORT:-/tmp/test-dry-run-report.txt}"

log()  { echo "$1" | tee -a "$REPORT"; }
pass() { PASS=$((PASS+1)); TOTAL=$((TOTAL+1)); log "  ✅ $1"; }
fail() { FAIL=$((FAIL+1)); TOTAL=$((TOTAL+1)); log "  ❌ $1"; }
assert_eq() { if [[ "$2" == "$3" ]]; then pass "$1: $2"; else fail "$1: got '$2', expected '$3'"; fi; }
assert_gt() { if [[ "$2" -gt "$3" ]]; then pass "$1: $2"; else fail "$1: got '$2', expected > $3"; fi; }
assert_nonempty() { if [[ -n "$2" && "$2" != "null" ]]; then pass "$1"; else fail "$1: empty"; fi; }

count_yaml() { ls "$1"/*.yaml 2>/dev/null | wc -l | tr -d ' '; }

# ── Validate config directory structure and content ──
validate_config_dir() {
  local OUT="$1"
  local exp_skills="$2" exp_subagents="$3" exp_hooks="$4" exp_prompts="$5"
  local exp_sched="$6" exp_filters="$7" exp_platforms="$8" exp_httptrig="$9"

  log "── validate config dir ──"

  assert_eq "skills" "$(count_yaml "$OUT/config/skills")" "$exp_skills"

  # Skill content: YAML has name, tools, skillContent ref → .md exists
  for sf in "$OUT/config/skills/"*.yaml; do
    [[ -f "$sf" ]] || continue
    local sname=$(python3 -c "import yaml,sys; d=yaml.safe_load(open(sys.argv[1])); print(d.get('metadata',{}).get('name',''))" "$sf" 2>/dev/null)
    assert_nonempty "skill $(basename $sf .yaml) name" "$sname"
    local stools=$(python3 -c "import yaml,sys; d=yaml.safe_load(open(sys.argv[1])); print(len(d.get('metadata',{}).get('spec',{}).get('tools',[])))" "$sf" 2>/dev/null)
    assert_gt "skill $sname tools" "${stools:-0}" 0
    local scref=$(python3 -c "import yaml,sys; d=yaml.safe_load(open(sys.argv[1])); print(d.get('skillContent',''))" "$sf" 2>/dev/null)
    assert_nonempty "skill $sname skillContent ref" "$scref"
    if [[ -n "$scref" ]]; then
      local md_file="$OUT/config/$scref"
      # Some recipes use "skills/name.md", others use just "name.md" (resolved relative to skills/)
      [[ ! -f "$md_file" && -f "$OUT/config/skills/$scref" ]] && md_file="$OUT/config/skills/$scref"
      if [[ -f "$md_file" ]]; then
        assert_gt "skill $sname .md size" "$(wc -c < "$md_file" | tr -d ' ')" 10
      else
        fail "skill $sname .md missing: $OUT/config/$scref"
      fi
    fi
  done

  assert_eq "subagents" "$(count_yaml "$OUT/config/subagents")" "$exp_subagents"
  for sf in "$OUT/config/subagents/"*.yaml; do
    [[ -f "$sf" ]] || continue
    local saname=$(python3 -c "import yaml,sys; d=yaml.safe_load(open(sys.argv[1])); print(d.get('metadata',{}).get('name',''))" "$sf" 2>/dev/null)
    assert_nonempty "subagent $(basename $sf .yaml) name" "$saname"
  done

  assert_eq "hooks" "$(count_yaml "$OUT/config/hooks")" "$exp_hooks"
  assert_eq "prompts" "$(count_yaml "$OUT/config/common-prompts")" "$exp_prompts"
  assert_eq "scheduled-tasks" "$(count_yaml "$OUT/automations/scheduled-tasks")" "$exp_sched"
  assert_eq "incident-filters" "$(count_yaml "$OUT/automations/incident-filters")" "$exp_filters"
  assert_eq "incident-platforms" "$(count_yaml "$OUT/automations/incident-platforms")" "$exp_platforms"
  assert_eq "http-triggers" "$(count_yaml "$OUT/automations/http-triggers")" "$exp_httptrig"

  # No unreplaced placeholders (exclude ${{ which is GitHub Actions syntax)
  local leftover=$(grep -r '{{' "$OUT/" 2>/dev/null | grep -v '\${{' | grep -vc '^$' 2>/dev/null || echo 0)
  assert_eq "no {{placeholders}}" "$leftover" "0"

  # connectors.json exists
  assert_nonempty "connectors.json" "$(cat "$OUT/connectors.json" 2>/dev/null | head -1)"
}

# ── Validate assembled parameters.json content (RP minimums) ──
validate_assembled_content() {
  local OUT="$1"
  log "── validate assembled content ──"
  local TMPOUT=$(mktemp -d)/assembled
  bash bicep/assemble-agent.sh "$OUT" --output "$TMPOUT" > /dev/null 2>&1
  local PARAMS="${TMPOUT}.parameters.json"
  if [[ ! -f "$PARAMS" ]]; then fail "assemble: no parameters.json"; return; fi

  # Skills: skillContent must be >50 chars (RP rejects shorter)
  local skill_ct=$(jq '.parameters.skills.value | length' "$PARAMS")
  if [[ "$skill_ct" -gt 0 ]]; then
    for i in $(seq 0 $((skill_ct - 1))); do
      local sname=$(jq -r --argjson i "$i" '.parameters.skills.value[$i].metadata.name' "$PARAMS")
      local sclen=$(jq --argjson i "$i" '.parameters.skills.value[$i].skillContent | length' "$PARAMS")
      if [[ "$sclen" -gt 50 ]]; then pass "skill $sname content: ${sclen} chars"
      else fail "skill $sname content: ${sclen} chars (<50 — RP will reject)"; fi
    done
  fi

  # Subagents: instructions must be >50 chars
  local sa_ct=$(jq '.parameters.subagents.value | length' "$PARAMS")
  if [[ "$sa_ct" -gt 0 ]]; then
    for i in $(seq 0 $((sa_ct - 1))); do
      local saname=$(jq -r --argjson i "$i" '.parameters.subagents.value[$i].metadata.name' "$PARAMS")
      local salen=$(jq --argjson i "$i" '.parameters.subagents.value[$i].spec.instructions | length' "$PARAMS")
      if [[ "$salen" -gt 50 ]]; then pass "subagent $saname instructions: ${salen} chars"
      else fail "subagent $saname instructions: ${salen} chars (<50 — RP will reject)"; fi
    done
  fi
}

# ── Validate Bicep dry-run ──
validate_bicep_dryrun() {
  local OUT="$1"
  log "── deploy.sh --dry-run (Bicep) ──"
  ./bin/deploy.sh "$OUT" --dry-run > /tmp/dryrun-bicep.log 2>&1
  if [[ $? -eq 0 ]]; then pass "deploy.sh --dry-run"; else fail "deploy.sh --dry-run (exit $?)"; fi

  # Compile Bicep to catch syntax/type errors (BCP*)
  if command -v az &>/dev/null; then
    az bicep build --file bicep/main.bicep --stdout > /dev/null 2>/tmp/dryrun-bicep-build.log
    if [[ $? -eq 0 ]]; then pass "az bicep build"; else fail "az bicep build (see /tmp/dryrun-bicep-build.log)"; fi
  fi
}

# ── Validate Terraform dry-run ──
validate_tf_dryrun() {
  local OUT="$1" exp_skills="$2" exp_subagents="$3" exp_prompts="$4"
  log "── deploy-tf.sh --dry-run (Terraform) ──"
  ./bin/deploy-tf.sh "$OUT" --dry-run > /tmp/dryrun-tf.log 2>&1
  if [[ $? -eq 0 ]]; then pass "deploy-tf.sh --dry-run"; else fail "deploy-tf.sh --dry-run (exit $?)"; fi

  local TFVARS="terraform/terraform.tfvars.json"
  if [[ -f "$TFVARS" ]]; then
    assert_eq "tfvars skills" "$(jq '.skills | length' "$TFVARS")" "$exp_skills"
    assert_eq "tfvars subagents" "$(jq '.subagents | length' "$TFVARS")" "$exp_subagents"
    assert_eq "tfvars prompts" "$(jq '.common_prompts | length' "$TFVARS")" "$exp_prompts"
    if [[ "$(jq '.skills | length' "$TFVARS")" -gt 0 ]]; then
      assert_eq "tfvars skill[0] has name" "$(jq '.skills[0].spec.name | length > 0' "$TFVARS")" "true"
      assert_eq "tfvars skill[0] has skillContent" "$(jq '.skills[0].spec.skillContent | length > 0' "$TFVARS")" "true"
      assert_eq "tfvars skill[0] has tools" "$(jq '.skills[0].spec.tools | length > 0' "$TFVARS")" "true"
    fi
    if [[ "$(jq '.subagents | length' "$TFVARS")" -gt 0 ]]; then
      assert_eq "tfvars subagent[0] has instructions" "$(jq '.subagents[0].spec.instructions | length > 0' "$TFVARS")" "true"
      assert_eq "tfvars subagent[0] has handoffs" "$(jq '.subagents[0].spec | has("handoffs")' "$TFVARS")" "true"
    fi
  else
    fail "terraform.tfvars.json not found"
  fi

  # Validate TF syntax
  if command -v terraform &>/dev/null; then
    pushd terraform > /dev/null
    terraform init -backend=false -input=false > /dev/null 2>&1
    terraform validate -no-color > /tmp/dryrun-tf-validate.log 2>&1
    if [[ $? -eq 0 ]]; then pass "terraform validate"; else fail "terraform validate (see /tmp/dryrun-tf-validate.log)"; fi
    popd > /dev/null
  fi
}

# ── Validate PS New-Agent dry-run ──
validate_ps_newagent() {
  local RECIPE="$1" SET_ARGS="$2"
  local PS_OUT="/tmp/dryrun-ps-${RECIPE}"
  log "── New-Agent.ps1 (PowerShell) ──"
  rm -rf "$PS_OUT"
  local PS_SET_HASH=""
  # Convert --set k=v pairs to PS hashtable format
  local IFS_OLD="$IFS"; IFS=';'
  PS_SET_HASH="@{agentName='dry-ps-${RECIPE}'; resourceGroup='rg-dry-ps'; location='swedencentral'; targetRGs='rg-fake'"
  for s in $SET_ARGS; do
    [[ -z "$s" ]] && continue
    local k="${s%%=*}" v="${s#*=}"
    PS_SET_HASH="${PS_SET_HASH}; ${k}='${v}'"
  done
  PS_SET_HASH="${PS_SET_HASH}}"
  IFS="$IFS_OLD"

  pwsh -NoProfile -Command "
    & './bin/ps/New-Agent.ps1' -Recipe '$RECIPE' -NonInteractive -Set ${PS_SET_HASH} -Output '$PS_OUT'
  " > /tmp/dryrun-ps-new.log 2>&1
  if [[ -f "$PS_OUT/agent.json" ]]; then pass "PS New-Agent.ps1"; else fail "PS New-Agent.ps1 (no agent.json)"; fi
}

# ── Validate azd-style (new-agent + assemble — same as preprovision hook) ──
validate_azd_dryrun() {
  local OUT="$1"
  log "── azd-style assemble ──"
  local TMPOUT=$(mktemp -d)/assembled
  bash bicep/assemble-agent.sh "$OUT" --output "$TMPOUT" > /tmp/dryrun-azd.log 2>&1
  if [[ -f "${TMPOUT}.parameters.json" ]]; then
    local psize=$(wc -c < "${TMPOUT}.parameters.json" | tr -d ' ')
    assert_gt "azd params.json size" "$psize" 100
  else
    fail "azd assemble: no parameters.json"
  fi
  if [[ -f "${TMPOUT}.extras.json" ]]; then
    local esize=$(wc -c < "${TMPOUT}.extras.json" | tr -d ' ')
    assert_gt "azd extras.json size" "$esize" 10
  else
    fail "azd assemble: no extras.json"
  fi
}

# ── Print summary and exit ──
print_summary() {
  local recipe="$1"
  log ""
  log "═══════════════════════════════════════════════════════"
  log "  ${recipe}: $PASS passed, $FAIL failed (of $TOTAL)"
  log "═══════════════════════════════════════════════════════"
  [[ $FAIL -eq 0 ]] && return 0 || return 1
}
