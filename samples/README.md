# SRE Agent Samples

This directory contains end-to-end samples to help you get started with Azure SRE Agent.

## Folder Structure

```
samples/
├── bicep-deployment/          # Infrastructure as Code templates for deploying SRE Agents
│   ├── bicep/
│   ├── examples/
│   └── scripts/
├── automation/                # Automation samples with configuration guides and sample apps
│   ├── configuration/
│   │   └── 00-configure-sre-agent.md
│   ├── samples/
│   │   ├── 01-incident-automation-sample.md
│   │   └── 02-scheduled-health-check-sample.md
│   ├── sample-apps/
│   │   └── octopets-setup.md
│   ├── subagents/
│   │   ├── pd-azure-resource-error-handler.yaml
│   │   └── health-check-agent.yaml
│   └── images/
└── hands-on-lab/              # Complete hands-on lab with 3 personas (azd up)
    ├── azure.yaml
    ├── infra/                 # Bicep templates
    ├── scripts/               # Post-provision, break-app, sample issues
    ├── sre-config/            # Subagent YAML specs
    ├── knowledge-base/        # Runbooks and incident templates
    └── lab/                   # Skillable lab instructions
```

## Available Samples

### 1. Bicep Deployment
Infrastructure as Code templates for deploying Azure SRE Agents with advanced configuration options.

[View Deployment Guide →](./bicep-deployment/deployment-guide.md)

### 2. Incident Automation
Complete guide for setting up automated incident response with Azure SRE Agent, including a sample Octopets application to test incident detection, diagnosis, and mitigation.

**Get Started:**
1. Deploy the sample app: [octopets-setup.md](./automation/sample-apps/octopets-setup.md)
2. Configure SRE Agent: [00-configure-sre-agent.md](./automation/configuration/00-configure-sre-agent.md)
3. Test incident automation: [01-octopets-memleak-sample.md](./automation/samples/01-incident-automation-sample.md)
4. Review subagent example: [pd-azure-resource-error-handler.yaml](./automation/subagents/pd-azure-resource-error-handler.yaml)

### 3. Hands-On Lab (Grubify)
Complete hands-on lab deployable with a single `azd up` command. Covers 3 personas:

| Persona | What You'll See |
|---------|----------------|
| **IT Operations** | Autonomous incident detection, log analysis, KB-driven investigation, remediation |
| **Developer** | Source code root cause analysis with file:line references, structured GitHub issues |
| **Workflow Automation** | Automated issue triage via scheduled tasks, label + comment on customer issues |

**Get Started:**
1. Read the [hands-on-lab README](./hands-on-lab/README.md)
2. Run `azd up` in the `hands-on-lab/` directory
3. Follow the [Skillable instructions](./hands-on-lab/lab/skillable-instructions.md) or use standalone

## Contributing

We welcome community contributions! If you have samples that would help others use SRE Agent, please feel free to contribute.

## Support

For issues specific to these samples, please open a GitHub issue in this repository. 
