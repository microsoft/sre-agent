#!/bin/bash
# ============================================================
# Break VM Script — Simulate performance issues and drift
# Usage:
#   bash scripts/break-vm.sh cpu      — CPU stress on app VM
#   bash scripts/break-vm.sh memory   — Memory pressure on app VM
#   bash scripts/break-vm.sh drift    — Introduce compliance drift
#   bash scripts/break-vm.sh all      — Both CPU and drift
# ============================================================

set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCENARIO="${1:-help}"

RESOURCE_GROUP=$(azd env get-value RESOURCE_GROUP_NAME 2>/dev/null || echo "")
if [[ -z "$RESOURCE_GROUP" ]]; then
  ENV_NAME=$(azd env get-value AZURE_ENV_NAME 2>/dev/null || echo "vm-perf-demo")
  RESOURCE_GROUP="rg-${ENV_NAME}"
fi

VM_APP="vm-sap-app-01"
VM_DB="vm-sap-db-01"

case "$SCENARIO" in
  cpu)
    echo -e "${YELLOW}Triggering CPU stress on ${VM_APP}...${NC}"
    echo -e "This will run a CPU stress test for 10 minutes."
    echo ""

    az vm run-command invoke \
      --resource-group "$RESOURCE_GROUP" \
      --name "$VM_APP" \
      --command-id RunShellScript \
      --scripts "
        apt-get update -qq && apt-get install -y -qq stress-ng > /dev/null 2>&1
        nohup stress-ng --cpu 2 --timeout 600 > /dev/null 2>&1 &
        echo 'CPU stress started (2 workers, 10 min timeout)'
      " \
      --output table

    echo -e "\n${GREEN}✓ CPU stress test running on ${VM_APP}${NC}"
    echo -e "Azure Monitor alert should fire in ~3-5 minutes."
    echo -e "SRE Agent will pick up the alert and investigate."
    ;;

  memory)
    echo -e "${YELLOW}Triggering memory pressure on ${VM_APP}...${NC}"

    az vm run-command invoke \
      --resource-group "$RESOURCE_GROUP" \
      --name "$VM_APP" \
      --command-id RunShellScript \
      --scripts "
        apt-get update -qq && apt-get install -y -qq stress-ng > /dev/null 2>&1
        nohup stress-ng --vm 2 --vm-bytes 80% --timeout 600 > /dev/null 2>&1 &
        echo 'Memory stress started (80% target, 10 min timeout)'
      " \
      --output table

    echo -e "\n${GREEN}✓ Memory stress running on ${VM_APP}${NC}"
    ;;

  drift)
    echo -e "${YELLOW}Introducing compliance drift...${NC}"
    echo ""

    # Drift 1: Remove required tags from app VM
    echo -e "  [1/3] Removing required tags from ${VM_APP}..."
    az tag update --resource-id "$(az vm show -g "$RESOURCE_GROUP" -n "$VM_APP" --query id -o tsv)" \
      --operation delete \
      --tags environment cost-center compliance-required \
      --output none 2>/dev/null || true
    echo -e "${GREEN}  ✓ Tags removed from ${VM_APP}${NC}"

    # Drift 2: Add insecure NSG rule (SSH from anywhere)
    NSG_NAME=$(az network nsg list -g "$RESOURCE_GROUP" --query "[0].name" -o tsv 2>/dev/null)
    if [[ -n "$NSG_NAME" ]]; then
      echo -e "  [2/3] Opening SSH to 0.0.0.0/0 on ${NSG_NAME}..."
      az network nsg rule create \
        --resource-group "$RESOURCE_GROUP" \
        --nsg-name "$NSG_NAME" \
        --name "AllowSSH-FromAnywhere-INSECURE" \
        --priority 110 \
        --direction Inbound \
        --access Allow \
        --protocol Tcp \
        --source-address-prefixes "*" \
        --destination-port-ranges 22 \
        --output none 2>/dev/null
      echo -e "${GREEN}  ✓ Insecure SSH rule added to ${NSG_NAME}${NC}"
    fi

    # Drift 3: Disable boot diagnostics on DB VM
    echo -e "  [3/3] Disabling boot diagnostics on ${VM_DB}..."
    az vm boot-diagnostics disable \
      --resource-group "$RESOURCE_GROUP" \
      --name "$VM_DB" \
      --output none 2>/dev/null || true
    echo -e "${GREEN}  ✓ Boot diagnostics disabled on ${VM_DB}${NC}"

    echo -e "\n${GREEN}✓ Compliance drift introduced!${NC}"
    echo -e "Run a compliance scan to detect:"
    echo -e "  srectl thread new --message 'Run a compliance drift scan'"
    ;;

  all)
    echo -e "${BLUE}Running all break scenarios...${NC}\n"
    bash "$0" cpu
    echo ""
    bash "$0" drift
    ;;

  help|*)
    echo "Usage: bash scripts/break-vm.sh <scenario>"
    echo ""
    echo "Scenarios:"
    echo "  cpu      - CPU stress test on app VM (triggers alert)"
    echo "  memory   - Memory pressure on app VM (triggers alert)"
    echo "  drift    - Introduce compliance drift (tags, NSG, diagnostics)"
    echo "  all      - Run both cpu and drift scenarios"
    ;;
esac
