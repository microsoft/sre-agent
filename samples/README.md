# SRE Agent Samples

This directory contains end-to-end samples to help you get started with Azure SRE Agent.

## Folder Structure

```
samples/
├── bicep-deployment/          # Infrastructure as Code templates for deploying SRE Agents
│   ├── bicep/
│   ├── examples/
│   └── scripts/
└── incident-automation/       # End-to-end incident automation guide with Octopets sample app
    ├── 00-configure-sre-agent.md
    ├── 01-octopets-memleak-sample.md
    ├── sample-apps/
    │   └── octopets-setup.md
    ├── subagents/
    │   └── pd-azure-resource-error-handler.yaml
    └── images/
```

## Available Samples

### 1. Bicep Deployment
Infrastructure as Code templates for deploying Azure SRE Agents with advanced configuration options.

[View Deployment Guide →](./bicep-deployment/deployment-guide.md)

### 2. Incident Automation
Complete guide for setting up automated incident response with Azure SRE Agent, including a sample Octopets application to test incident detection, diagnosis, and mitigation.

**Get Started:**
1. Deploy the sample app: [octopets-setup.md](./incident-automation/sample-apps/octopets-setup.md)
2. Configure SRE Agent: [00-configure-sre-agent.md](./incident-automation/00-configure-sre-agent.md)
3. Test incident automation: [01-octopets-memleak-sample.md](./incident-automation/01-octopets-memleak-sample.md)
4. Review subagent example: [pd-azure-resource-error-handler.yaml](./incident-automation/subagents/pd-azure-resource-error-handler.yaml)

## Contributing

We welcome community contributions! If you have samples that would help others use SRE Agent, please feel free to contribute.

## Support

For issues specific to these samples, please open a GitHub issue in this repository. 
