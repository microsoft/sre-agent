#!/bin/bash
# =============================================================================
# Post-Start Script — runs each time the container starts.
# =============================================================================

echo ""
echo "========================================"
echo "  Azure SRE Agent Lab"
echo "========================================"
echo "  Docs: https://aka.ms/sreagent/lab"
echo "========================================"
echo ""

# Check Azure login status
if az account show &>/dev/null; then
    ACCOUNT=$(az account show --query 'name' -o tsv)
    echo "Azure: Logged in ($ACCOUNT)"
else
    echo "Azure: Not logged in. Run 'az login --use-device-code' to authenticate."
fi
echo ""
