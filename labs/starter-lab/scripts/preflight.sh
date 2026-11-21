#!/usr/bin/env bash
# Check the optional GitHub fork before provisioning Azure resources.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/.."

RECREATE=false
case "${1:-}" in
  "") ;;
  --recreate-fork) RECREATE=true ;;
  *) echo "Usage: bash scripts/preflight.sh [--recreate-fork]" >&2; exit 1 ;;
esac

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

lowercase() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

# azd does not export custom environment values to every standalone invocation.
if [ -z "${GITHUB_USER:-}" ]; then
  if ! GITHUB_USER="$(azd env get-value GITHUB_USER 2>&1)"; then
    case "$GITHUB_USER" in
      *"ERROR: key not found in environment values: 'GITHUB_USER'"*) GITHUB_USER="" ;;
      *) fail "Could not read GITHUB_USER from azd: $GITHUB_USER" ;;
    esac
  fi
fi
if [ -z "$GITHUB_USER" ]; then
  if [ -t 0 ]; then
    echo "Optional GitHub integration enables source analysis and issue triage."
    read -r -p "GitHub username (Enter to skip): " GITHUB_USER
  fi
  if [ -z "$GITHUB_USER" ]; then
    if [ "$RECREATE" = true ]; then
      fail "Set GITHUB_USER before requesting fork recreation."
    fi
    echo "GitHub integration skipped. Add it later with bash scripts/setup-github.sh <username>."
    exit 0
  fi
fi

[[ "$GITHUB_USER" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]*$ ]] || fail "Invalid GitHub username."
[[ "$(lowercase "$GITHUB_USER")" != dm-chelupati ]] || fail "Use your own GitHub account, not dm-chelupati."

command -v gh >/dev/null 2>&1 || fail "Install GitHub CLI (https://cli.github.com), then run gh auth login."
gh auth status --hostname github.com || fail "Run gh auth login --hostname github.com and retry."
AUTH_USER="$(gh api --hostname github.com user --jq .login)"
[[ "$(lowercase "$AUTH_USER")" = "$(lowercase "$GITHUB_USER")" ]] || fail "GitHub CLI is signed in as $AUTH_USER, not $GITHUB_USER. Switch accounts with gh auth switch."
GITHUB_USER="$AUTH_USER"
REPO="$GITHUB_USER/grubify"
UPSTREAM="dm-chelupati/grubify"

# Listing owned repositories distinguishes absence from API/authentication errors.
EXISTING="$(gh api --hostname github.com --paginate 'user/repos?affiliation=owner&per_page=100' \
  --jq '.[] | select((.name | ascii_downcase) == "grubify") | .full_name')"

verify_fork() {
  local parent
  parent="$(gh repo view "github.com/$REPO" --json isFork,parent \
    --jq 'if .isFork then (.parent.owner.login + "/" + .parent.name) else "" end')"
  [[ "$(lowercase "$parent")" = "$UPSTREAM" ]] || fail "$REPO is not a fork of $UPSTREAM. It will not be modified or deleted."
}

if [ -n "$EXISTING" ]; then
  verify_fork
  ACTION=keep
  if [ "$RECREATE" = true ]; then
    ACTION=recreate
  elif [ -t 0 ]; then
    read -r -p "Fork $REPO exists. Keep or recreate? [keep]: " ACTION
    ACTION="${ACTION:-keep}"
  fi
  case "$ACTION" in
    keep) echo "Using existing fork: https://github.com/$REPO" ;;
    recreate)
      echo "WARNING: This permanently deletes $REPO, including its issues, pull requests, and changes."
      echo "GitHub CLI needs repository deletion permission (gh auth refresh --hostname github.com -s delete_repo)."
      [ -t 0 ] || fail "Fork recreation requires an interactive terminal for confirmation."
      read -r -p "Type $REPO to confirm deletion: " CONFIRM
      [ "$CONFIRM" = "$REPO" ] || fail "Confirmation did not match; nothing was deleted."
      if DELETE_OUTPUT="$(gh repo delete "github.com/$REPO" --yes 2>&1)"; then
        [ -z "$DELETE_OUTPUT" ] || printf '%s\n' "$DELETE_OUTPUT"
      else
        printf '%s\n' "$DELETE_OUTPUT" >&2
        [[ "$DELETE_OUTPUT" == *"delete_repo"* ]] || fail "Could not delete $REPO; recreation stopped."
        read -r -p "Request delete_repo permission with GitHub CLI and retry deletion? [y/N]: " REFRESH
        [[ "$REFRESH" = y || "$REFRESH" = Y || "$REFRESH" = yes ]] || fail "Permission request declined; nothing was deleted."
        gh auth refresh --hostname github.com -s delete_repo || fail "Could not obtain deletion permission; nothing was deleted."
        gh repo delete "github.com/$REPO" --yes
      fi
      EXISTING=""
      ;;
    *) fail "Choose keep or recreate; nothing was deleted." ;;
  esac
else
  echo "Missing fork: https://github.com/$REPO"
  [ -t 0 ] || fail "Fork https://github.com/$UPSTREAM/fork into $GITHUB_USER, then retry."
  read -r -p "Fork $UPSTREAM into your account now? [y/N]: " CREATE
  [[ "$CREATE" = y || "$CREATE" = Y || "$CREATE" = yes ]] || fail "Fork required for GitHub integration. Create it and retry, or unset GITHUB_USER for the core-only lab."
fi

if [ -z "$EXISTING" ]; then
  gh repo fork "github.com/$UPSTREAM" --clone=false
  verify_fork
fi

# Forks disable issues by default; both GitHub lab scenarios need them.
gh repo edit "github.com/$REPO" --enable-issues
azd env set GITHUB_USER "$GITHUB_USER"
echo "GitHub preflight complete: https://github.com/$REPO (issues enabled)."
