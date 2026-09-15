# Onboarding lab base agent

Creates the base Azure SRE Agent used by `labs/onboardinglab`:

- Review mode with Low access
- Agent deployment into the resource group created by the onboarding workload
- Read-only managed-resource access to that same resource group
- Checkout Application Insights connector
- Azure Monitor incident platform
- Attendee-owned `ticketingapp-source` GitHub repository containing the complete ticketing app azd project
- `onboardinglab-architecture.md` and `onboardinglab-incident-runbook.md` knowledge sources
- Office 365 Outlook managed connector with runtime access and interactive OAuth consent
- `onboardinglab-safety` common prompt
- `evidence-checklist` Stop hook
- Global tool policy with agent and notification writes set to ask for approval
- Guarded `sre-agent-self-configure` administrative skill

Files under `data/` are uploaded automatically as Knowledge Sources by the shared deployer. Users do not need to upload them manually in the portal.

The self-configuration skill can inspect and generate agent configuration. Its Azure CLI write tool remains governed by Review mode and limits changes to the current agent. Workflow investigation skills, custom agents, response plans, and scheduled tasks are installed separately from the onboarding lab workflow template.