#!/usr/bin/env bash
# Checks and installs everything the Caldova Retail Ops lab needs and signs you in.
# Safe to run more than once.
# Usage: bash <(curl -fsSL https://raw.githubusercontent.com/microsoft/sre-agent/main/labs/caldova-retail-ops/setup.sh)
set -uo pipefail

ok()   { printf '  \033[32m✔\033[0m %s\n' "$1"; }
doing(){ printf '  \033[33m→\033[0m %s\n' "$1"; }
fail() { printf '\n\033[31m✖ %s\033[0m\n' "$1"; [ $# -gt 1 ] && printf '  %s\n' "$2"; exit 1; }
step() { printf '\n\033[1m[%s] %s\033[0m\n' "$1" "$2"; }

OS="$(uname -s)"

step 1/5 "Package manager"
if [ "$OS" = "Darwin" ]; then
  for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    [ -x "$b" ] && eval "$("$b" shellenv)" && break
  done
  if ! command -v brew >/dev/null; then
    doing "Installing Homebrew (asks for your Mac password)"
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" \
      || fail "Homebrew install failed." "See https://brew.sh"
    for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do
      [ -x "$b" ] && eval "$("$b" shellenv)" && break
    done
  fi
  ok "Homebrew $(brew --version | head -1 | awk '{print $2}')"
  export HOMEBREW_NO_ENV_HINTS=1
  install_pkg() { brew install "$@"; }
else
  command -v apt-get >/dev/null || fail "This script supports macOS and Debian/Ubuntu Linux." "Install the tools listed in the README manually."
  ok "apt"
  install_pkg() { :; }
fi

step 2/5 "Tools"
need_tool() { # name, check command, mac install, linux install
  if eval "$2" >/dev/null 2>&1; then ok "$1"; return; fi
  doing "Installing $1"
  if [ "$OS" = "Darwin" ]; then eval "$3"; else eval "$4"; fi
  hash -r
  eval "$2" >/dev/null 2>&1 || fail "$1 is still not available." "Open a new terminal and run the setup command again."
  ok "$1"
}
need_tool "Git" "git --version" \
  "brew install git" \
  "sudo apt-get update && sudo apt-get install -y git"
need_tool "Azure CLI" "az version" \
  "brew install azure-cli" \
  "curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash"
need_tool "Azure Developer CLI" "azd version" \
  "brew install azd" \
  "curl -fsSL https://aka.ms/install-azd.sh | bash"
need_tool "GitHub CLI" "gh --version" \
  "brew install gh" \
  "sudo apt-get install -y gh"
has_dotnet8() { dotnet --list-sdks 2>/dev/null | awk -F. '$1>=8{f=1} END{exit !f}'; }
if has_dotnet8; then
  ok ".NET SDK $(dotnet --version)"
else
  doing "Installing .NET SDK (macOS asks for your password)"
  if [ "$OS" = "Darwin" ]; then
    brew install --cask dotnet-sdk || fail ".NET SDK install failed." "Install it from https://dotnet.microsoft.com/download and run the setup command again."
  else
    curl -fsSL https://dot.net/v1/dotnet-install.sh | bash -s -- --channel 8.0 \
      && export PATH="$HOME/.dotnet:$PATH"
  fi
  hash -r; has_dotnet8 || fail ".NET SDK 8 or later is still not available." "Open a new terminal and run the setup command again."
  ok ".NET SDK $(dotnet --version)"
fi

step 3/5 "Git identity and GitHub sign-in"
if [ -z "$(git config --global user.name)" ]; then
  read -rp "  Your name for Git commits: " gname; git config --global user.name "$gname"
fi
if [ -z "$(git config --global user.email)" ]; then
  read -rp "  Your email for Git commits: " gmail; git config --global user.email "$gmail"
fi
ok "Git identity: $(git config --global user.name) <$(git config --global user.email)>"
if ! gh auth status -h github.com >/dev/null 2>&1; then
  doing "Signing in to GitHub (opens your browser)"
  gh auth login -h github.com -p https --git-protocol https --web || fail "GitHub sign-in failed."
fi
ok "GitHub: $(gh api user --jq .login 2>/dev/null)"

step 4/5 "Azure sign-in"
if ! az account get-access-token --output none >/dev/null 2>&1; then
  doing "Signing in to Azure CLI (opens your browser)"
  az login --output none || fail "Azure CLI sign-in failed."
fi
ok "Azure CLI signed in"
if ! azd auth token --output json >/dev/null 2>&1; then
  doing "Signing in to Azure Developer CLI (opens your browser)"
  azd auth login || fail "azd sign-in failed."
  azd auth token --output json >/dev/null 2>&1 || fail "azd sign-in did not produce a valid token."
fi
ok "Azure Developer CLI signed in"

step 5/5 "Subscription"
current="$(az account show --query "join('', [name, ' (', id, ')'])" -o tsv)"
read -rp "  Use subscription $current? [Y/n] " yn
if [[ "$yn" =~ ^[Nn] ]]; then
  read -rp "  Subscription name or ID: " pick
  az account set --subscription "$pick" || fail "Could not select subscription '$pick'." "List yours with: az account list -o table"
fi
SUB_ID="$(az account show --query id -o tsv)"
ok "Subscription: $(az account show --query name -o tsv) ($SUB_ID)"

PERM_URL="https://management.azure.com/subscriptions/$SUB_ID/providers/Microsoft.Authorization/permissions?api-version=2022-04-01"
can_create="$(az rest --method get --url "$PERM_URL" --query "length(value[?contains(actions, '*')])" -o tsv 2>/dev/null)"
can_rbac="$(az rest --method get --url "$PERM_URL" \
  --query "length(value[?(contains(actions, '*') && length(notActions) == \`0\`) || contains(actions, 'Microsoft.Authorization/*')])" -o tsv 2>/dev/null)"
if [ "${can_create:-0}" -gt 0 ] && [ "${can_rbac:-0}" -gt 0 ]; then
  ok "Permissions: can create resources and role assignments"
else
  fail "Your account can't create both resources and role assignments in this subscription." \
       "You need Owner, or Contributor + User Access Administrator. Ask a subscription owner, or pick another subscription."
fi

state="$(az provider show -n Microsoft.App --query registrationState -o tsv 2>/dev/null)"
if [ "$state" != "Registered" ]; then
  doing "Registering the Microsoft.App resource provider (1-2 minutes)"
  az provider register --namespace Microsoft.App --wait || fail "Provider registration failed."
fi
ok "Microsoft.App resource provider registered"

printf '\n\033[32m\033[1mAll prerequisites are ready.\033[0m Continue with step 2 in the lab README.\n\n'
