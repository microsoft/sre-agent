#!/bin/bash

# Azure SRE Agent Interactive Deployment Script
# This script deploys an SRE Agent with configurable subscription, resource groups, and target assignments

set -e

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
TEMPLATE_FILE="$PROJECT_ROOT/bicep/minimal-sre-agent.bicep"
PARAMETERS_FILE="$PROJECT_ROOT/examples/minimal-sre-agent.parameters.json"
DEFAULT_CONFIG_FILE="$PROJECT_ROOT/examples/sre-agent.config"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to load configuration from file
load_config() {
    local config_file="$1"
    
    if [[ ! -f "$config_file" ]]; then
        echo -e "${RED}Configuration file '$config_file' not found!${NC}"
        echo -e "${BLUE}Creating a template configuration file...${NC}"
        create_config_template "$config_file"
        echo -e "${GREEN}Template created at '$config_file'. Please edit it and run the script again.${NC}"
        exit 1
    fi
    
    echo -e "${BLUE}Loading configuration from '$config_file'...${NC}"
    
    # Source the config file
    source "$config_file"
    
    # Validate required parameters
    if [[ -z "$SUBSCRIPTION_ID" || -z "$RESOURCE_GROUP" || -z "$AGENT_NAME" ]]; then
        echo -e "${RED}Error: Missing required configuration in '$config_file'${NC}"
        echo -e "${BLUE}Required: SUBSCRIPTION_ID, RESOURCE_GROUP, AGENT_NAME${NC}"
        exit 1
    fi
    
    echo -e "${GREEN}Configuration loaded successfully.${NC}"
}

# Function to create configuration template
create_config_template() {
    local config_file="$1"
    
    # Get current Azure info if available
    local current_sub_id=""
    if az account show &>/dev/null; then
        current_sub_id=$(az account show --query 'id' -o tsv)
    fi
    
    cat > "$config_file" << EOF
# Azure SRE Agent Configuration File
# This file contains the configuration for deploying an SRE Agent
# You can modify these values and use them with: ./deploy.sh --config

# Required Configuration
SUBSCRIPTION_ID="${current_sub_id:-"your-subscription-id-here"}"
RESOURCE_GROUP="rg-sre-agent"
AGENT_NAME="sre-agent-\$(date +%Y%m%d)"

# Basic Configuration
LOCATION="eastus2"                    # swedencentral, uksouth, eastus2, australiaeast
ACCESS_LEVEL="High"                   # High, Low

# Target Resource Groups (comma-separated, can be empty)
TARGET_RGS=""
# Example: TARGET_RGS="rg-prod-web,rg-prod-data,rg-staging"

# Target Subscriptions (comma-separated, optional - matches TARGET_RGS order)
TARGET_SUBS=""
# Example: TARGET_SUBS="sub1-id,sub1-id,sub2-id"

# Optional: Existing Managed Identity (leave empty to create new)
EXISTING_IDENTITY=""
# Example: EXISTING_IDENTITY="/subscriptions/xxx/resourceGroups/xxx/providers/Microsoft.ManagedIdentity/userAssignedIdentities/xxx"

# Deployment Options
CONFIRM_DEPLOYMENT=true              # Set to false to skip confirmation prompt
VERBOSE_OUTPUT=false                 # Set to true for detailed output
EOF
}

# Function to display usage
usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Modes:"
    echo "  Interactive Mode (default):  $0"
    echo "  Config File Mode:           $0 --config [CONFIG_FILE]"
    echo "  Command Line Mode:          $0 --no-interactive [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -i, --interactive                        Run in interactive mode (default)"
    echo "  -c, --config CONFIG_FILE                 Use configuration file (default: sre-agent.config)"
    echo "  --no-interactive                         Disable interactive mode"
    echo "  --create-config CONFIG_FILE              Create a configuration file template"
    echo "  -s, --subscription-id SUBSCRIPTION_ID    Target subscription ID"
    echo "  -r, --resource-group RESOURCE_GROUP      Resource group where SRE Agent will be deployed"
    echo "  -n, --agent-name AGENT_NAME             Name of the SRE Agent"
    echo "  -l, --location LOCATION                  Azure region (eastus2, swedencentral, uksouth, australiaeast)"
    echo "  -a, --access-level ACCESS_LEVEL          Access level (High, Low)"
    echo "  -t, --target-rgs \"RG1,RG2,RG3\"           Comma-separated list of target resource groups"
    echo "  -u, --target-subs \"SUB1,SUB2,SUB3\"       Comma-separated list of target subscriptions (optional)"
    echo "  -e, --existing-identity IDENTITY_ID      Existing managed identity resource ID (optional)"
    echo "  -y, --yes                                Skip confirmation prompts"
    echo "  -v, --verbose                            Verbose output"
    echo "  -h, --help                               Display this help message"
    echo ""
    echo "Examples:"
    echo ""
    echo "  Interactive Mode (guided setup):"
    echo "    $0"
    echo ""
    echo "  Config File Mode (edit sre-agent.config first):"
    echo "    $0 --config"
    echo "    $0 --config my-custom.config"
    echo ""
    echo "  Create Config Template:"
    echo "    $0 --create-config my-config.config"
    echo ""
    echo "  Command Line Mode:"
    echo "    $0 --no-interactive \\"
    echo "       -s \"12345678-1234-1234-1234-123456789012\" \\"
    echo "       -r \"rg-sre-agent\" \\"
    echo "       -n \"my-sre-agent\" \\"
    echo "       -t \"rg-prod-web,rg-prod-data\""
}

# Function to get current Azure account info
get_azure_info() {
    echo -e "${BLUE}Getting current Azure account information...${NC}"
    
    # Check if user is logged in
    if ! az account show &>/dev/null; then
        echo -e "${RED}You are not logged in to Azure. Please run 'az login' first.${NC}"
        exit 1
    fi
    
    # Get current subscription info
    CURRENT_SUB_INFO=$(az account show --query '{id:id, name:name}' -o tsv)
    CURRENT_SUB_ID=$(echo "$CURRENT_SUB_INFO" | cut -f1)
    CURRENT_SUB_NAME=$(echo "$CURRENT_SUB_INFO" | cut -f2)
    
    echo -e "${GREEN}Current Azure subscription:${NC}"
    echo -e "  ID: ${YELLOW}$CURRENT_SUB_ID${NC}"
    echo -e "  Name: ${YELLOW}$CURRENT_SUB_NAME${NC}"
}

# Function to prompt for input with default value
prompt_with_default() {
    local prompt="$1"
    local default="$2"
    local var_name="$3"
    
    if [[ -n "$default" ]]; then
        echo -e -n "${BLUE}$prompt${NC} [${YELLOW}$default${NC}]: "
    else
        echo -e -n "${BLUE}$prompt${NC}: "
    fi
    
    read -r input
    if [[ -z "$input" && -n "$default" ]]; then
        input="$default"
    fi
    
    eval "$var_name='$input'"
}

# Function to validate subscription ID format
validate_subscription_id() {
    local sub_id="$1"
    if [[ ! "$sub_id" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
        echo -e "${RED}Invalid subscription ID format. Please use the format: 12345678-1234-1234-1234-123456789012${NC}"
        return 1
    fi
    return 0
}

# Function to validate Azure region
validate_location() {
    local location="$1"
    local valid_locations=("swedencentral" "uksouth" "eastus2" "australiaeast")
    
    for valid_loc in "${valid_locations[@]}"; do
        if [[ "$location" == "$valid_loc" ]]; then
            return 0
        fi
    done
    
    echo -e "${RED}Invalid location. Valid options are: ${valid_locations[*]}${NC}"
    return 1
}

# Function to run interactive mode
interactive_mode() {
    echo -e "${GREEN}=== Azure SRE Agent Interactive Deployment ===${NC}"
    echo ""
    
    # Get Azure info
    get_azure_info
    echo ""
    
    # Get subscription ID
    while true; do
        prompt_with_default "Enter subscription ID" "$CURRENT_SUB_ID" "SUBSCRIPTION_ID"
        if validate_subscription_id "$SUBSCRIPTION_ID"; then
            break
        fi
    done
    
    # Get resource group name
    while true; do
        prompt_with_default "Enter resource group name for SRE Agent deployment" "rg-sre-agent" "RESOURCE_GROUP"
        if [[ -n "$RESOURCE_GROUP" ]]; then
            break
        fi
        echo -e "${RED}Resource group name cannot be empty${NC}"
    done
    
    # Get agent name
    while true; do
        prompt_with_default "Enter SRE Agent name" "sre-agent-$(date +%Y%m%d)" "AGENT_NAME"
        if [[ -n "$AGENT_NAME" ]]; then
            break
        fi
        echo -e "${RED}Agent name cannot be empty${NC}"
    done
    
    # Get location
    while true; do
        prompt_with_default "Enter Azure region (swedencentral, uksouth, eastus2, australiaeast)" "eastus2" "LOCATION"
        if validate_location "$LOCATION"; then
            break
        fi
    done
    
    # Get access level
    while true; do
        prompt_with_default "Enter access level (High, Low)" "High" "ACCESS_LEVEL"
        if [[ "$ACCESS_LEVEL" =~ ^(High|Low)$ ]]; then
            break
        fi
        echo -e "${RED}Access level must be 'High' or 'Low'${NC}"
    done
    
    # Get target resource groups
    echo ""
    echo -e "${BLUE}Target Resource Groups Configuration:${NC}"
    echo -e "Enter the resource groups that the SRE Agent should manage."
    echo -e "You can enter multiple resource groups separated by commas."
    echo -e "Leave empty if you only want the agent to manage its own resource group."
    prompt_with_default "Enter target resource groups (comma-separated)" "" "TARGET_RGS"
    
    # Get target subscriptions (optional)
    if [[ -n "$TARGET_RGS" ]]; then
        echo ""
        echo -e "${BLUE}Target Subscriptions Configuration (Optional):${NC}"
        echo -e "If your target resource groups are in different subscriptions,"
        echo -e "enter subscription IDs in the same order as resource groups."
        echo -e "Leave empty to use the deployment subscription for all resource groups."
        prompt_with_default "Enter target subscriptions (comma-separated)" "" "TARGET_SUBS"
    fi
    
    # Get existing managed identity (optional)
    echo ""
    echo -e "${BLUE}Managed Identity Configuration (Optional):${NC}"
    echo -e "You can use an existing managed identity instead of creating a new one."
    prompt_with_default "Enter existing managed identity resource ID (optional)" "" "EXISTING_IDENTITY"
    
    # Display configuration summary
    echo ""
    echo -e "${GREEN}=== Deployment Configuration Summary ===${NC}"
    echo -e "Subscription ID: ${YELLOW}$SUBSCRIPTION_ID${NC}"
    echo -e "Resource Group: ${YELLOW}$RESOURCE_GROUP${NC}"
    echo -e "Agent Name: ${YELLOW}$AGENT_NAME${NC}"
    echo -e "Location: ${YELLOW}$LOCATION${NC}"
    echo -e "Access Level: ${YELLOW}$ACCESS_LEVEL${NC}"
    echo -e "Target Resource Groups: ${YELLOW}${TARGET_RGS:-"None (deployment RG only)"}${NC}"
    echo -e "Target Subscriptions: ${YELLOW}${TARGET_SUBS:-"Use deployment subscription"}${NC}"
    echo -e "Existing Identity: ${YELLOW}${EXISTING_IDENTITY:-"Create new identity"}${NC}"
    
    # Confirm deployment
    if [[ "$CONFIRM_DEPLOYMENT" != "false" ]]; then
        echo ""
        echo -e -n "${BLUE}Proceed with deployment? (y/N):${NC} "
        read -r confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            echo -e "${YELLOW}Deployment cancelled.${NC}"
            exit 0
        fi
    fi
}

# Default to interactive mode
INTERACTIVE_MODE=true
CONFIG_MODE=false
CONFIG_FILE=""
VERBOSE_OUTPUT=false
CONFIRM_DEPLOYMENT=true

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -i|--interactive)
            INTERACTIVE_MODE=true
            CONFIG_MODE=false
            shift
            ;;
        -c|--config)
            CONFIG_MODE=true
            INTERACTIVE_MODE=false
            if [[ -n "$2" && "$2" != -* ]]; then
                CONFIG_FILE="$2"
                shift 2
            else
                CONFIG_FILE="$DEFAULT_CONFIG_FILE"
                shift
            fi
            ;;
        --no-interactive)
            INTERACTIVE_MODE=false
            CONFIG_MODE=false
            shift
            ;;
        --create-config)
            if [[ -n "$2" && "$2" != -* ]]; then
                create_config_template "$2"
                echo -e "${GREEN}Configuration template created at '$2'${NC}"
                echo -e "${BLUE}Edit the file and then run: $0 --config $2${NC}"
            else
                create_config_template "$DEFAULT_CONFIG_FILE"
                echo -e "${GREEN}Configuration template created at '$DEFAULT_CONFIG_FILE'${NC}"
                echo -e "${BLUE}Edit the file and then run: $0 --config${NC}"
            fi
            exit 0
            ;;
        -s|--subscription-id)
            SUBSCRIPTION_ID="$2"
            INTERACTIVE_MODE=false
            CONFIG_MODE=false
            shift 2
            ;;
        -r|--resource-group)
            RESOURCE_GROUP="$2"
            INTERACTIVE_MODE=false
            CONFIG_MODE=false
            shift 2
            ;;
        -n|--agent-name)
            AGENT_NAME="$2"
            INTERACTIVE_MODE=false
            CONFIG_MODE=false
            shift 2
            ;;
        -l|--location)
            LOCATION="$2"
            INTERACTIVE_MODE=false
            CONFIG_MODE=false
            shift 2
            ;;
        -a|--access-level)
            ACCESS_LEVEL="$2"
            INTERACTIVE_MODE=false
            CONFIG_MODE=false
            shift 2
            ;;
        -t|--target-rgs)
            TARGET_RGS="$2"
            INTERACTIVE_MODE=false
            CONFIG_MODE=false
            shift 2
            ;;
        -u|--target-subs)
            TARGET_SUBS="$2"
            INTERACTIVE_MODE=false
            CONFIG_MODE=false
            shift 2
            ;;
        -e|--existing-identity)
            EXISTING_IDENTITY="$2"
            INTERACTIVE_MODE=false
            CONFIG_MODE=false
            shift 2
            ;;
        -y|--yes)
            CONFIRM_DEPLOYMENT=false
            shift
            ;;
        -v|--verbose)
            VERBOSE_OUTPUT=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option $1"
            usage
            exit 1
            ;;
    esac
done

# Determine execution mode and load configuration
if [[ "$CONFIG_MODE" == "true" ]]; then
    # Config file mode
    load_config "$CONFIG_FILE"
    
    # Evaluate any variables in the config (like date commands)
    AGENT_NAME=$(eval echo "$AGENT_NAME")
    
    echo -e "${GREEN}=== Config File Mode ===${NC}"
    echo -e "Using configuration from: ${YELLOW}$CONFIG_FILE${NC}"
    echo ""
    echo -e "${GREEN}=== Configuration Summary ===${NC}"
    echo -e "Subscription ID: ${YELLOW}$SUBSCRIPTION_ID${NC}"
    echo -e "Resource Group: ${YELLOW}$RESOURCE_GROUP${NC}"
    echo -e "Agent Name: ${YELLOW}$AGENT_NAME${NC}"
    echo -e "Location: ${YELLOW}$LOCATION${NC}"
    echo -e "Access Level: ${YELLOW}$ACCESS_LEVEL${NC}"
    echo -e "Target Resource Groups: ${YELLOW}${TARGET_RGS:-"None"}${NC}"
    echo -e "Target Subscriptions: ${YELLOW}${TARGET_SUBS:-"Use deployment subscription"}${NC}"
    echo -e "Existing Identity: ${YELLOW}${EXISTING_IDENTITY:-"Create new identity"}${NC}"
    
    # Confirm deployment if required
    if [[ "$CONFIRM_DEPLOYMENT" != "false" ]]; then
        echo ""
        echo -e -n "${BLUE}Proceed with deployment? (y/N):${NC} "
        read -r confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            echo -e "${YELLOW}Deployment cancelled.${NC}"
            exit 0
        fi
    fi
    
elif [[ "$INTERACTIVE_MODE" == "true" ]]; then
    # Interactive mode
    interactive_mode
    
else
    # Command line mode - validate required parameters
    if [[ -z "$SUBSCRIPTION_ID" || -z "$RESOURCE_GROUP" || -z "$AGENT_NAME" ]]; then
        echo -e "${RED}Error: Missing required parameters for command line mode${NC}"
        usage
        exit 1
    fi
fi

# Set defaults for command line mode
LOCATION=${LOCATION:-"eastus2"}
ACCESS_LEVEL=${ACCESS_LEVEL:-"High"}
MODE=${MODE:-"Review"}
EXISTING_IDENTITY=${EXISTING_IDENTITY:-""}

# Process target resource groups
if [[ -n "$TARGET_RGS" ]]; then
    IFS=',' read -ra RG_ARRAY <<< "$TARGET_RGS"
    TARGET_RGS_JSON="["
    for i in "${!RG_ARRAY[@]}"; do
        if [[ $i -gt 0 ]]; then
            TARGET_RGS_JSON+=","
        fi
        TARGET_RGS_JSON+="\"${RG_ARRAY[$i]}\""
    done
    TARGET_RGS_JSON+="]"
else
    TARGET_RGS_JSON="[]"
fi

# Process target subscriptions
if [[ -n "$TARGET_SUBS" ]]; then
    IFS=',' read -ra SUB_ARRAY <<< "$TARGET_SUBS"
    TARGET_SUBS_JSON="["
    for i in "${!SUB_ARRAY[@]}"; do
        if [[ $i -gt 0 ]]; then
            TARGET_SUBS_JSON+=","
        fi
        TARGET_SUBS_JSON+="\"${SUB_ARRAY[$i]}\""
    done
    TARGET_SUBS_JSON+="]"
else
    TARGET_SUBS_JSON="[]"
fi

echo ""
echo -e "${GREEN}=== Starting SRE Agent Deployment ===${NC}"
echo -e "Subscription: ${YELLOW}$SUBSCRIPTION_ID${NC}"
echo -e "Resource Group: ${YELLOW}$RESOURCE_GROUP${NC}"
echo -e "Agent Name: ${YELLOW}$AGENT_NAME${NC}"
echo -e "Location: ${YELLOW}$LOCATION${NC}"
echo -e "Access Level: ${YELLOW}$ACCESS_LEVEL${NC}"
echo -e "Target Resource Groups: ${YELLOW}$TARGET_RGS_JSON${NC}"
echo -e "Target Subscriptions: ${YELLOW}$TARGET_SUBS_JSON${NC}"

# Create resource group if it doesn't exist
echo ""
echo -e "${BLUE}Creating resource group if it doesn't exist...${NC}"
if az group create --name "$RESOURCE_GROUP" --location "$LOCATION" --subscription "$SUBSCRIPTION_ID" &>/dev/null; then
    echo -e "${GREEN}✓ Resource group '$RESOURCE_GROUP' ready${NC}"
else
    echo -e "${YELLOW}⚠ Resource group may already exist or creation failed${NC}"
fi

# Deploy the Bicep template
echo ""
echo -e "${BLUE}Deploying SRE Agent...${NC}"
echo -e "${YELLOW}This may take several minutes...${NC}"

DEPLOYMENT_NAME="sre-agent-deployment-$(date +%Y%m%d%H%M%S)"

# Set deployment output based on verbose mode
if [[ "$VERBOSE_OUTPUT" == "true" ]]; then
    DEPLOYMENT_OUTPUT="json"
    QUERY_OUTPUT="--query 'properties.outputs'"
else
    DEPLOYMENT_OUTPUT="table"
    QUERY_OUTPUT="--query 'properties.outputs' --output table"
fi

if az deployment sub create \
    --name "$DEPLOYMENT_NAME" \
    --subscription "$SUBSCRIPTION_ID" \
    --location "$LOCATION" \
    --template-file "$TEMPLATE_FILE" \
    --parameters \
        agentName="$AGENT_NAME" \
        subscriptionId="$SUBSCRIPTION_ID" \
        deploymentResourceGroupName="$RESOURCE_GROUP" \
        location="$LOCATION" \
        existingManagedIdentityId="$EXISTING_IDENTITY" \
        accessLevel="$ACCESS_LEVEL" \
        targetResourceGroups="$TARGET_RGS_JSON" \
        targetSubscriptions="$TARGET_SUBS_JSON" \
    $QUERY_OUTPUT; then
    
    echo ""
    echo -e "${GREEN}🎉 SRE Agent deployment completed successfully!${NC}"
    echo ""
    echo -e "${BLUE}Next steps:${NC}"
    echo -e "1. Visit the Azure portal to configure your SRE Agent"
    echo -e "2. Set up workflows and monitoring rules"
    echo -e "3. Test the agent in Review mode before switching to Autonomous"
    echo ""
    echo -e "${BLUE}Useful commands:${NC}"
    echo -e "• View deployment: ${YELLOW}az deployment sub show --name '$DEPLOYMENT_NAME' --subscription '$SUBSCRIPTION_ID'${NC}"
    echo -e "• View agent: ${YELLOW}az resource show --resource-group '$RESOURCE_GROUP' --name '$AGENT_NAME' --resource-type 'Microsoft.App/agents'${NC}"
    
else
    echo ""
    echo -e "${RED}❌ SRE Agent deployment failed!${NC}"
    echo ""
    echo -e "${BLUE}Troubleshooting steps:${NC}"
    echo -e "1. Check if you have the required permissions"
    echo -e "2. Verify the subscription ID and resource group name"
    echo -e "3. Ensure the SRE Agent resource provider is registered"
    echo -e "4. View deployment details: ${YELLOW}az deployment sub show --name '$DEPLOYMENT_NAME' --subscription '$SUBSCRIPTION_ID'${NC}"
    exit 1
fi
