#!/usr/bin/env sh
# Top-level lab launcher (POSIX wrapper around lab.ps1).
# Requires pwsh 7+ — same prereq as the labs themselves.
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
if ! command -v pwsh >/dev/null 2>&1; then
    echo "ERROR: pwsh (PowerShell 7+) required. https://aka.ms/powershell" >&2
    exit 1
fi
exec pwsh -NoProfile -File "$DIR/lab.ps1" "$@"
