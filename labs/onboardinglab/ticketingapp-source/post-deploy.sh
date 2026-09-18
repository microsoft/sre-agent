#!/usr/bin/env bash
set -euo pipefail
project="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
setup="$project/../scripts/setup.ps1"
if [[ ! -f "$setup" ]]; then
  if [[ "${ONBOARDING_CONFIGURE_AGENT:-false}" == true ]]; then
    echo 'Agent setup requires the full onboarding lab checkout.' >&2
    exit 1
  fi
  echo 'Standalone workload deployed. Use the full onboarding lab checkout to configure an agent.'
elif command -v pwsh >/dev/null 2>&1; then
  pwsh -NoProfile -File "$setup" -FromAzdHook
elif [[ "${ONBOARDING_CONFIGURE_AGENT:-false}" == true ]]; then
  echo 'Agent setup requires PowerShell 7. Run the lab prerequisites first.' >&2
  exit 1
else
  echo 'Workload deployed. Install PowerShell 7 before selecting optional agent setup.'
fi
