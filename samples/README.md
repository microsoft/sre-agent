# SRE Agent Samples

This directory contains community-contributed samples and deployment templates for the Azure SRE Agent.

## Available Samples

### [Bicep Deployment](./bicep-deployment/)

A comprehensive Bicep-based Infrastructure as Code (IaC) solution for deploying Azure SRE Agents with advanced configuration options.

**Features:**
- 🎯 **Subscription Targeting**: Deploy SRE Agents to specific Azure subscriptions
- 🏗️ **Custom Resource Groups**: Deploy to any resource group with flexible naming
- 🔐 **Multi-Resource Group Access**: Grant SRE Agent permissions across multiple resource groups
- 🌐 **Cross-Subscription Support**: Target resource groups across different subscriptions
- 🤖 **Interactive Deployment**: User-friendly deployment scripts with CLI and config file support
- 📋 **Role Assignment Management**: Automated permission setup with high/low access levels

**What's Included:**
- Complete Bicep templates for SRE Agent deployment
- Role assignment templates for security configuration
- Interactive deployment scripts with CLI interface
- Configuration examples and parameter files
- Comprehensive documentation and troubleshooting guides

**Quick Start:**
```bash
cd bicep-deployment
chmod +x scripts/deploy.sh
./scripts/deploy.sh
```

## Contributing

We welcome community contributions! If you have samples, templates, or tools that would help others deploy and manage SRE Agents, please feel free to contribute.

### Guidelines for New Samples
- Include comprehensive documentation
- Provide example configurations
- Follow Azure best practices
- Include proper error handling
- Test thoroughly before submitting

## Support

For issues specific to these samples or SREAgent, please open a GitHub issue in this repository. 
