#!/usr/bin/env bash
# install-prerequisites.sh — install all required tools for SRE Agent recipes.
#
# Usage:
#   ./bin/install-prerequisites.sh              # install missing tools
#   ./bin/install-prerequisites.sh --check      # check only, don't install
#   ./bin/install-prerequisites.sh --terraform  # also install Terraform
#   ./bin/install-prerequisites.sh --all        # install everything (incl. Terraform + azd)

set -euo pipefail

# ── Flags ──
CHECK_ONLY=""
INSTALL_TF=""
INSTALL_AZD=""
for arg in "$@"; do
  case "$arg" in
    --check)     CHECK_ONLY="true" ;;
    --terraform) INSTALL_TF="true" ;;
    --azd)       INSTALL_AZD="true" ;;
    --all)       INSTALL_TF="true"; INSTALL_AZD="true" ;;
    -h|--help)
      echo "Usage: install-prerequisites.sh [--check] [--terraform] [--azd] [--all]"
      echo "  --check      Check only, don't install"
      echo "  --terraform  Also install Terraform"
      echo "  --azd        Also install Azure Developer CLI (azd)"
      echo "  --all        Install everything"
      exit 0 ;;
  esac
done

# ── OS detection ──
OS="unknown"
if [[ "$OSTYPE" == "darwin"* ]]; then
  OS="macos"
elif [[ "$OSTYPE" == "linux"* ]]; then
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    OS="linux-$ID"
  else
    OS="linux"
  fi
fi

MISSING=()
INSTALLED=()
SKIPPED=()

ok()   { echo "  ✅ $1"; }
fail() { echo "  ❌ $1"; MISSING+=("$1"); }
info() { echo "  ℹ️  $1"; }

# ── Check functions ──
check_az() {
  if command -v az &>/dev/null; then
    ok "az CLI $(az version --query '\"azure-cli\"' -o tsv 2>/dev/null || echo '')"
  else
    fail "az CLI"
  fi
}

check_jq() {
  if command -v jq &>/dev/null; then
    ok "jq $(jq --version 2>/dev/null || echo '')"
  else
    fail "jq"
  fi
}

check_python() {
  local py=""
  if command -v python3 &>/dev/null; then
    py="python3"
  elif command -v python &>/dev/null; then
    py="python"
  fi

  if [[ -n "$py" ]]; then
    ok "$py $($py --version 2>&1 | head -1)"
    if "$py" -c "import yaml" 2>/dev/null; then
      ok "PyYAML"
    else
      fail "PyYAML (pip install pyyaml)"
    fi
  else
    fail "Python 3"
  fi
}

check_curl() {
  if command -v curl &>/dev/null; then
    ok "curl"
  else
    fail "curl"
  fi
}

check_terraform() {
  if command -v terraform &>/dev/null; then
    ok "terraform $(terraform version -json 2>/dev/null | jq -r '.terraform_version' 2>/dev/null || echo '')"
  else
    fail "terraform"
  fi
}

check_azd() {
  if command -v azd &>/dev/null; then
    ok "azd $(azd version 2>/dev/null || echo '')"
  else
    fail "azd"
  fi
}

# ── Install functions ──
install_brew_if_needed() {
  if ! command -v brew &>/dev/null; then
    echo "  Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  fi
}

install_az() {
  case "$OS" in
    macos)
      install_brew_if_needed
      brew install azure-cli
      ;;
    linux-ubuntu|linux-debian)
      curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
      ;;
    linux-rhel|linux-centos|linux-fedora)
      sudo rpm --import https://packages.microsoft.com/keys/microsoft.asc
      sudo dnf install -y azure-cli 2>/dev/null || sudo yum install -y azure-cli
      ;;
    *)
      echo "  Install manually: https://learn.microsoft.com/en-us/cli/azure/install-azure-cli"
      return 1 ;;
  esac
}

install_jq() {
  case "$OS" in
    macos)
      install_brew_if_needed
      brew install jq
      ;;
    linux-ubuntu|linux-debian)
      sudo apt-get update -qq && sudo apt-get install -y -qq jq
      ;;
    linux-rhel|linux-centos|linux-fedora)
      sudo dnf install -y jq 2>/dev/null || sudo yum install -y jq
      ;;
    *)
      echo "  Install manually: https://jqlang.github.io/jq/download/"
      return 1 ;;
  esac
}

install_python() {
  case "$OS" in
    macos)
      install_brew_if_needed
      brew install python3
      ;;
    linux-ubuntu|linux-debian)
      sudo apt-get update -qq && sudo apt-get install -y -qq python3 python3-pip
      ;;
    linux-rhel|linux-centos|linux-fedora)
      sudo dnf install -y python3 python3-pip 2>/dev/null || sudo yum install -y python3 python3-pip
      ;;
    *)
      echo "  Install manually: https://www.python.org/downloads/"
      return 1 ;;
  esac
}

install_pyyaml() {
  local py=$(command -v python3 || command -v python)
  "$py" -m pip install --user pyyaml 2>/dev/null || pip3 install pyyaml 2>/dev/null || pip install pyyaml
}

install_curl() {
  case "$OS" in
    linux-ubuntu|linux-debian)
      sudo apt-get update -qq && sudo apt-get install -y -qq curl ;;
    linux-rhel|linux-centos|linux-fedora)
      sudo dnf install -y curl 2>/dev/null || sudo yum install -y curl ;;
    *)
      echo "  curl should be pre-installed" ;;
  esac
}

install_terraform() {
  case "$OS" in
    macos)
      install_brew_if_needed
      brew tap hashicorp/tap && brew install hashicorp/tap/terraform
      ;;
    linux-ubuntu|linux-debian)
      curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp.gpg
      echo "deb [signed-by=/usr/share/keyrings/hashicorp.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
      sudo apt-get update -qq && sudo apt-get install -y -qq terraform
      ;;
    *)
      echo "  Install manually: https://developer.hashicorp.com/terraform/install"
      return 1 ;;
  esac
}

install_azd() {
  case "$OS" in
    macos)
      install_brew_if_needed
      brew tap azure/azd && brew install azd
      ;;
    linux*)
      curl -fsSL https://aka.ms/install-azd.sh | bash
      ;;
    *)
      echo "  Install manually: https://learn.microsoft.com/en-us/azure/developer/azure-developer-cli/install-azd"
      return 1 ;;
  esac
}

# ── Main ──
echo "═══════════════════════════════════════════════════"
echo "  SRE Agent — Prerequisites Check"
echo "  OS: $OS"
echo "═══════════════════════════════════════════════════"
echo

echo "── Required tools ──"
check_az
check_jq
check_python
check_curl
echo

if [[ -n "$INSTALL_TF" ]]; then
  echo "── Terraform (optional) ──"
  check_terraform
  echo
fi

if [[ -n "$INSTALL_AZD" ]]; then
  echo "── Azure Developer CLI (optional) ──"
  check_azd
  echo
fi

if [[ ${#MISSING[@]} -eq 0 ]]; then
  echo "All prerequisites installed! ✅"
  exit 0
fi

if [[ -n "$CHECK_ONLY" ]]; then
  echo "${#MISSING[@]} tool(s) missing."
  exit 1
fi

# ── Install missing ──
echo "── Installing ${#MISSING[@]} missing tool(s) ──"
echo

for tool in "${MISSING[@]}"; do
  case "$tool" in
    "az CLI")
      echo "  Installing az CLI..."
      if install_az; then INSTALLED+=("az CLI"); else SKIPPED+=("az CLI"); fi
      ;;
    "jq")
      echo "  Installing jq..."
      if install_jq; then INSTALLED+=("jq"); else SKIPPED+=("jq"); fi
      ;;
    "Python 3")
      echo "  Installing Python 3..."
      if install_python; then INSTALLED+=("Python 3"); else SKIPPED+=("Python 3"); fi
      ;;
    "PyYAML"*)
      echo "  Installing PyYAML..."
      if install_pyyaml; then INSTALLED+=("PyYAML"); else SKIPPED+=("PyYAML"); fi
      ;;
    "curl")
      echo "  Installing curl..."
      if install_curl; then INSTALLED+=("curl"); else SKIPPED+=("curl"); fi
      ;;
    "terraform")
      echo "  Installing Terraform..."
      if install_terraform; then INSTALLED+=("terraform"); else SKIPPED+=("terraform"); fi
      ;;
    "azd")
      echo "  Installing azd..."
      if install_azd; then INSTALLED+=("azd"); else SKIPPED+=("azd"); fi
      ;;
  esac
done

echo
echo "═══════════════════════════════════════════════════"
if [[ ${#INSTALLED[@]} -gt 0 ]]; then
  echo "  Installed: ${INSTALLED[*]}"
fi
if [[ ${#SKIPPED[@]} -gt 0 ]]; then
  echo "  ⚠ Could not install: ${SKIPPED[*]}"
  echo "    Install manually — see links above."
fi
echo "═══════════════════════════════════════════════════"

# ── Verify ──
echo
echo "── Verifying ──"
MISSING=()
check_az
check_jq
check_python
check_curl
[[ -n "$INSTALL_TF" ]] && check_terraform
[[ -n "$INSTALL_AZD" ]] && check_azd

if [[ ${#MISSING[@]} -eq 0 ]]; then
  echo
  echo "All prerequisites installed! ✅"
  echo "Next: ./bin/new-agent.sh --recipe azmon-lawappinsights"
else
  echo
  echo "${#MISSING[@]} tool(s) still missing — install manually."
  exit 1
fi
