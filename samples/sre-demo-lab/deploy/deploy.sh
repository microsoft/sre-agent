#!/bin/bash
# =============================================================================
# SRE Agent Demo Lab - Deployment Script (Bash)
# =============================================================================
# Deploys all required Azure resources for demonstrating SRE Agent
# troubleshooting capabilities.
# =============================================================================

set -e

# =============================================================================
# Default Values
# =============================================================================
LOCATION="eastus"
RESOURCE_GROUP_NAME="infra-sre-demo-rg"
BASE_NAME="sre-demo"
VM_COUNT=2
ALERT_EMAIL=""

# =============================================================================
# Parse Arguments
# =============================================================================
usage() {
    echo "Usage: $0 --subscription <subscription-id> [options]"
    echo ""
    echo "Required:"
    echo "  --subscription    Azure subscription ID"
    echo ""
    echo "Options:"
    echo "  --location        Azure region (default: eastus)"
    echo "  --resource-group  Resource group name (default: infra-sre-demo-rg)"
    echo "  --base-name       Base name for resources (default: sre-demo)"
    echo "  --vm-count        Number of VMs to deploy (default: 2)"
    echo "  --alert-email     Email for alert notifications"
    echo "  --help            Show this help message"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --subscription)
            SUBSCRIPTION_ID="$2"
            shift 2
            ;;
        --location)
            LOCATION="$2"
            shift 2
            ;;
        --resource-group)
            RESOURCE_GROUP_NAME="$2"
            shift 2
            ;;
        --base-name)
            BASE_NAME="$2"
            shift 2
            ;;
        --vm-count)
            VM_COUNT="$2"
            shift 2
            ;;
        --alert-email)
            ALERT_EMAIL="$2"
            shift 2
            ;;
        --help)
            usage
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

if [ -z "$SUBSCRIPTION_ID" ]; then
    echo "Error: --subscription is required"
    usage
fi

# =============================================================================
# Helper Functions
# =============================================================================
print_step() {
    echo ""
    echo "========================================"
    echo "$1"
    echo "========================================"
}

print_success() {
    echo "✓ $1"
}

print_info() {
    echo "ℹ $1"
}

# =============================================================================
# Pre-flight Checks
# =============================================================================
print_step "Step 1: Pre-flight checks"

# Check Azure CLI
if ! command -v az &> /dev/null; then
    echo "Error: Azure CLI is not installed"
    exit 1
fi
print_success "Azure CLI is installed"

# Check logged in
if ! az account show &> /dev/null; then
    echo "Error: Not logged in to Azure CLI. Please run 'az login' first."
    exit 1
fi
print_success "Logged in to Azure CLI"

# Set subscription
print_info "Setting subscription to: $SUBSCRIPTION_ID"
az account set --subscription "$SUBSCRIPTION_ID"
print_success "Subscription set successfully"

# =============================================================================
# Generate SSH Key
# =============================================================================
print_step "Step 2: Generate SSH key pair"

SSH_KEY_PATH="$HOME/.ssh/sre-demo-key"
if [ ! -f "$SSH_KEY_PATH" ]; then
    print_info "Generating new SSH key pair..."
    ssh-keygen -t rsa -b 4096 -f "$SSH_KEY_PATH" -N "" -q
    print_success "SSH key generated at: $SSH_KEY_PATH"
else
    print_success "Using existing SSH key: $SSH_KEY_PATH"
fi

SSH_PUBLIC_KEY=$(cat "$SSH_KEY_PATH.pub")

# =============================================================================
# Create Resource Group
# =============================================================================
print_step "Step 3: Create Resource Group"

if az group exists --name "$RESOURCE_GROUP_NAME" | grep -q "true"; then
    print_info "Resource group '$RESOURCE_GROUP_NAME' already exists"
else
    az group create --name "$RESOURCE_GROUP_NAME" --location "$LOCATION" --output none
    print_success "Created resource group: $RESOURCE_GROUP_NAME in $LOCATION"
fi

# =============================================================================
# Deploy Bicep Template
# =============================================================================
print_step "Step 4: Deploy infrastructure (this may take 10-15 minutes)"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_FILE="$SCRIPT_DIR/main.bicep"
DEPLOYMENT_NAME="sre-demo-deployment-$(date +%Y%m%d%H%M%S)"

print_info "Starting deployment: $DEPLOYMENT_NAME"

DEPLOYMENT_OUTPUT=$(az deployment group create \
    --name "$DEPLOYMENT_NAME" \
    --resource-group "$RESOURCE_GROUP_NAME" \
    --template-file "$TEMPLATE_FILE" \
    --parameters \
        location="$LOCATION" \
        baseName="$BASE_NAME" \
        sshPublicKey="$SSH_PUBLIC_KEY" \
        vmCount="$VM_COUNT" \
        alertEmail="$ALERT_EMAIL" \
    --output json)

if [ $? -ne 0 ]; then
    echo "Error: Deployment failed. Check the Azure portal for details."
    exit 1
fi

print_success "Deployment completed successfully"

# Extract outputs
LOG_ANALYTICS_NAME=$(echo "$DEPLOYMENT_OUTPUT" | jq -r '.properties.outputs.logAnalyticsWorkspaceName.value')
VM_NAMES=$(echo "$DEPLOYMENT_OUTPUT" | jq -r '.properties.outputs.vmNames.value[]')
RSV_NAME=$(echo "$DEPLOYMENT_OUTPUT" | jq -r '.properties.outputs.rsvName.value')

# =============================================================================
# Configure VM Backup Protection
# =============================================================================
print_step "Step 5: Configure VM Backup Protection"

for VM_NAME in $VM_NAMES; do
    print_info "Enabling backup for VM: $VM_NAME"
    
    az backup protection enable-for-vm \
        --resource-group "$RESOURCE_GROUP_NAME" \
        --vault-name "$RSV_NAME" \
        --vm "$VM_NAME" \
        --policy-name "DemoBackupPolicy" \
        --output none 2>/dev/null || true
    
    print_success "Backup configured for: $VM_NAME"
done

# =============================================================================
# Trigger Initial Backup
# =============================================================================
print_step "Step 6: Trigger initial backup jobs"

for VM_NAME in $VM_NAMES; do
    print_info "Starting backup for: $VM_NAME"
    
    CONTAINER_NAME="IaasVMContainer;iaasvmcontainerv2;$RESOURCE_GROUP_NAME;$VM_NAME"
    ITEM_NAME="VM;iaasvmcontainerv2;$RESOURCE_GROUP_NAME;$VM_NAME"
    
    az backup protection backup-now \
        --resource-group "$RESOURCE_GROUP_NAME" \
        --vault-name "$RSV_NAME" \
        --container-name "$CONTAINER_NAME" \
        --item-name "$ITEM_NAME" \
        --backup-management-type AzureIaasVM \
        --output none 2>/dev/null || true
    
    print_success "Backup job started for: $VM_NAME"
done

# =============================================================================
# Summary
# =============================================================================
print_step "Deployment Complete!"

echo ""
echo "Resources Created:"
echo "  • Resource Group: $RESOURCE_GROUP_NAME"
echo "  • Log Analytics: $LOG_ANALYTICS_NAME"
echo "  • VMs: $VM_NAMES"
echo "  • Recovery Vault: $RSV_NAME"

echo ""
echo "Next Steps:"
echo "  1. Wait 5-10 minutes for Azure Monitor Agent to start collecting metrics"
echo "  2. Run './scenarios/generate-problems.sh' to create troubleshooting scenarios"
echo "  3. Use SRE Agent to detect and troubleshoot the issues"

echo ""
echo "SSH Access:"
for VM_NAME in $VM_NAMES; do
    PUBLIC_IP=$(az vm show -g "$RESOURCE_GROUP_NAME" -n "$VM_NAME" -d --query publicIps -o tsv)
    echo "  ssh -i $SSH_KEY_PATH azureuser@$PUBLIC_IP"
done

echo ""
