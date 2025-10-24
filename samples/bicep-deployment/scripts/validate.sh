#!/bin/bash
# Validate Bicep Templates
# This script validates all Bicep templates in the project

set -e

# Get script directory and project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
BICEP_DIR="$PROJECT_ROOT/bicep"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}🔍 Validating Bicep Templates${NC}"
echo "================================="

# Check if Bicep CLI is available
if ! command -v az bicep &> /dev/null; then
    echo -e "${RED}❌ Bicep CLI not found. Installing...${NC}"
    az bicep install
fi

echo -e "${BLUE}📁 Bicep templates directory: $BICEP_DIR${NC}"
echo ""

# Validate main template
echo -e "${YELLOW}Validating main template...${NC}"
az bicep build --file "$BICEP_DIR/minimal-sre-agent.bicep"
echo -e "${GREEN}✅ minimal-sre-agent.bicep - Valid${NC}"

# Validate resource module
echo -e "${YELLOW}Validating resource module...${NC}"
az bicep build --file "$BICEP_DIR/sre-agent-resources.bicep"
echo -e "${GREEN}✅ sre-agent-resources.bicep - Valid${NC}"

# Validate role assignment modules
echo -e "${YELLOW}Validating role assignment modules...${NC}"
az bicep build --file "$BICEP_DIR/role-assignments-minimal.bicep"
echo -e "${GREEN}✅ role-assignments-minimal.bicep - Valid${NC}"

az bicep build --file "$BICEP_DIR/role-assignments-target.bicep"
echo -e "${GREEN}✅ role-assignments-target.bicep - Valid${NC}"

echo ""
echo -e "${GREEN}🎉 All templates validated successfully!${NC}"

# Optional: Run What-If analysis if parameters provided
if [[ -f "$PROJECT_ROOT/examples/minimal-sre-agent.parameters.json" ]]; then
    echo ""
    echo -e "${BLUE}💡 To run What-If analysis, use:${NC}"
    echo -e "${YELLOW}   az deployment sub what-if \\${NC}"
    echo -e "${YELLOW}     --location eastus2 \\${NC}"
    echo -e "${YELLOW}     --template-file $BICEP_DIR/minimal-sre-agent.bicep \\${NC}"
    echo -e "${YELLOW}     --parameters @$PROJECT_ROOT/examples/minimal-sre-agent.parameters.json${NC}"
fi

echo ""
echo -e "${GREEN}✅ Validation complete!${NC}"
