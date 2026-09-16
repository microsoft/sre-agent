#!/usr/bin/env bash

ONBOARDING_PREREQS_SOURCED=false
if [[ -n "${ZSH_VERSION:-}" ]]; then
  [[ "${ZSH_EVAL_CONTEXT:-}" == *:file ]] && ONBOARDING_PREREQS_SOURCED=true
elif [[ -n "${BASH_VERSION:-}" ]]; then
  [[ "${BASH_SOURCE[0]}" != "$0" ]] && ONBOARDING_PREREQS_SOURCED=true
fi

ONBOARDING_CHECK_ONLY=false
ONBOARDING_MISSING=0

ensure_homebrew() {
  if command -v brew >/dev/null 2>&1; then
    return 0
  fi

  echo "  [missing] Homebrew"
  if [[ "$ONBOARDING_CHECK_ONLY" == true ]]; then
    ONBOARDING_MISSING=$((ONBOARDING_MISSING + 1))
    return 0
  fi

  echo "  [install] Homebrew"
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || return 1

  if [[ -x /opt/homebrew/bin/brew ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  elif [[ -x /usr/local/bin/brew ]]; then
    eval "$(/usr/local/bin/brew shellenv)"
  else
    echo "Homebrew was installed but is not available in PATH." >&2
    return 1
  fi
}

ensure_formula() {
  local name="$1"
  local command_name="$2"
  local formula="$3"

  if command -v "$command_name" >/dev/null 2>&1; then
    echo "  [ok] $name"
    return 0
  fi

  echo "  [missing] $name"
  if [[ "$ONBOARDING_CHECK_ONLY" == true ]]; then
    ONBOARDING_MISSING=$((ONBOARDING_MISSING + 1))
    return 0
  fi

  ensure_homebrew || return 1
  echo "  [install] $name"
  brew install "$formula"
}

node_is_supported() {
  local node_major
  command -v node >/dev/null 2>&1 || return 1
  node_major="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null)" || return 1
  [[ "$node_major" -ge 22 ]]
}

load_nvm() {
  if command -v nvm >/dev/null 2>&1; then
    return 0
  fi

  local nvm_dir="${NVM_DIR:-$HOME/.nvm}"
  if [[ ! -s "$nvm_dir/nvm.sh" ]]; then
    return 1
  fi

  export NVM_DIR="$nvm_dir"
  # shellcheck disable=SC1090
  . "$NVM_DIR/nvm.sh"
  command -v nvm >/dev/null 2>&1
}

ensure_node() {
  if node_is_supported; then
    echo "  [ok] Node.js $(node --version)"
    return 0
  fi

  if command -v node >/dev/null 2>&1; then
    echo "  [outdated] Node.js $(node --version); version 22 or later is required"
  else
    echo "  [missing] Node.js 22 or later"
  fi

  if [[ "$ONBOARDING_CHECK_ONLY" == true ]]; then
    ONBOARDING_MISSING=$((ONBOARDING_MISSING + 1))
    return 0
  fi

  if load_nvm; then
    echo "  [install] Node.js 22 with NVM"
    nvm install 22 || return 1
    nvm alias default 22 || return 1
    nvm use 22 || return 1
    local nvm_node
    nvm_node="$(nvm which 22)" || return 1
    export PATH="${nvm_node%/node}:$PATH"
    hash -r
    echo "  [active] Node.js $(node --version) ($(command -v node))"
    return 0
  fi

  ensure_homebrew || return 1
  if brew list --versions node >/dev/null 2>&1; then
    echo "  [upgrade] Node.js"
    brew upgrade node || return 1
  else
    echo "  [install] Node.js"
    brew install node || return 1
  fi

  brew link --overwrite node || return 1
  export PATH="$(brew --prefix node)/bin:$PATH"
  hash -r
}

ensure_python() {
  local python_home

  if ! command -v python3 >/dev/null 2>&1; then
    echo "  [missing] Python 3"
    if [[ "$ONBOARDING_CHECK_ONLY" == true ]]; then
      ONBOARDING_MISSING=$((ONBOARDING_MISSING + 1))
      return 0
    fi
    ensure_homebrew || return 1
    echo "  [install] Python 3"
    brew install python || return 1
    export PATH="$(brew --prefix python)/bin:$PATH"
    hash -r
  fi

  echo "  [ok] $(python3 --version 2>&1)"
  if python3 -c 'import yaml' >/dev/null 2>&1; then
    echo "  [ok] PyYAML"
    return 0
  fi

  echo "  [missing] PyYAML"
  if [[ "$ONBOARDING_CHECK_ONLY" == true ]]; then
    ONBOARDING_MISSING=$((ONBOARDING_MISSING + 1))
    return 0
  fi

  echo "  [install] PyYAML"
  if python3 -m pip install --user pyyaml >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
    echo "  [ok] PyYAML"
    return 0
  fi

  python_home="${XDG_CACHE_HOME:-${HOME:-$PWD/.cache}/.cache}/sre-agent/onboarding-python"
  echo "  [isolate] Creating Python environment at $python_home"
  python3 -m venv --clear "$python_home" || return 1
  "$python_home/bin/python3" -m pip install pyyaml >/dev/null || return 1
  export PATH="$python_home/bin:$PATH"
  hash -r
  python3 -c 'import yaml' >/dev/null 2>&1 || return 1
  echo "  [active] Python $(python3 --version 2>&1) with PyYAML ($(command -v python3))"
}

restore_app_dependencies() {
  if [[ ! -f "./ticketingapp-source/app/package-lock.json" ]]; then
    echo "Run this script from the labs/onboardinglab directory." >&2
    return 1
  fi

  if [[ "$ONBOARDING_CHECK_ONLY" == true ]]; then
    echo "  [check skipped] App dependency restore"
    return 0
  fi

  echo "  [verify] Restoring locked app dependencies"
  if ! npm ci --prefix ./ticketingapp-source/app --ignore-scripts --no-audit --no-fund; then
    echo "Unable to restore app dependencies from $(npm config get registry)." >&2
    echo "Check network or VPN access, then rerun source ./scripts/prereqs.sh." >&2
    return 1
  fi
  echo "  [ok] App dependencies restored"
}

onboarding_prereqs_main() {
  if [[ "$ONBOARDING_PREREQS_SOURCED" != true ]]; then
    echo "Source this script so Node.js and npm settings remain active:" >&2
    echo "  source ./scripts/prereqs.sh" >&2
    return 2
  fi

  if [[ "${1:-}" == "--check" ]]; then
    ONBOARDING_CHECK_ONLY=true
  elif [[ $# -gt 0 ]]; then
    echo "Usage: source ./scripts/prereqs.sh [--check]" >&2
    return 2
  fi

  if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "This script supports macOS. On Windows, run . .\\scripts\\prereqs.ps1." >&2
    return 1
  fi

  echo
  echo "============================================="
  echo "  Onboarding Lab - Prerequisite Setup"
  echo "============================================="
  echo
  echo "Platform: macOS"
  echo

  ensure_formula "Azure CLI" az azure-cli || return 1
  ensure_formula "Azure Developer CLI" azd azd || return 1
  ensure_formula "curl" curl curl || return 1
  ensure_formula "jq" jq jq || return 1
  ensure_python || return 1
  ensure_node || return 1

  if [[ "$ONBOARDING_CHECK_ONLY" == true ]]; then
    if command -v npm >/dev/null 2>&1; then
      echo "  [ok] npm registry $(npm config get registry)"
    else
      ONBOARDING_MISSING=$((ONBOARDING_MISSING + 1))
    fi

    if (( ONBOARDING_MISSING > 0 )); then
      echo
      echo "$ONBOARDING_MISSING prerequisite(s) need installation, activation, or configuration."
      return 1
    fi
  else
    for command_name in az azd curl jq python3 node npm; do
      if ! command -v "$command_name" >/dev/null 2>&1; then
        echo "Required command is still unavailable: $command_name" >&2
        return 1
      fi
    done

    if ! node_is_supported; then
      echo "Node.js validation failed: $(command -v node) reports $(node --version)." >&2
      return 1
    fi

    echo "  [ok] npm registry $(npm config get registry)"
  fi

  restore_app_dependencies || return 1

  echo
  echo "All local prerequisites are installed and active in this terminal."
  echo "  Python: $(python3 --version 2>&1) with PyYAML ($(command -v python3))"
  echo "  Node.js: $(node --version) ($(command -v node))"
  echo "  npm registry: $(npm config get registry)"
  if [[ "$ONBOARDING_CHECK_ONLY" != true ]]; then
    echo "  App dependencies: restored"
  fi
}

onboarding_prereqs_main "$@"
ONBOARDING_PREREQS_STATUS=$?

if [[ "$ONBOARDING_PREREQS_SOURCED" == true ]]; then
  return "$ONBOARDING_PREREQS_STATUS"
else
  exit "$ONBOARDING_PREREQS_STATUS"
fi