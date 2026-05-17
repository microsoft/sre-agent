#!/usr/bin/env sh
# Zava Unlimited meta-sim — POSIX wrapper around sim.ps1
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
if ! command -v pwsh >/dev/null 2>&1; then
    echo "ERROR: pwsh (PowerShell 7+) required. https://aka.ms/powershell" >&2
    exit 1
fi
exec pwsh -NoProfile -File "$DIR/sim.ps1" "$@"
