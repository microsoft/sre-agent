# Onboarding lab base agent

Creates the base Azure SRE Agent used by `labs/onboardinglab`:

- Review mode with Low access
- Agent deployment into the resource group created by the onboarding workload
- Read-only managed-resource access to that same resource group
- Checkout Application Insights connector
- Azure Monitor incident platform
- `onboardinglab-architecture.md` and `onboardinglab-incident-runbook.md` knowledge sources
- `onboardinglab-safety` common prompt
- `evidence-checklist` Stop hook
- Global tool policy with agent configuration writes set to ask for approval
- Guarded `sre-agent-self-configure` administrative skill
- `onboarding-lab-guide` for the learner progression
- `onboarding-health-check` for a visible read-only health assessment

Files under `data/` are uploaded automatically as Knowledge Sources by the shared deployer. Users do not need to upload them manually in the portal.

The self-configuration skill can inspect and draft agent configuration. Actual
persistence requires a supported identity and normal approval. If that path is
unavailable, the learner uses the documented local helper or Skill Builder,
then verifies the saved artifact in a fresh conversation.

GitHub repository and Outlook connector templates live under `optional/`, outside
the reusable base configuration. The standard lab setup helper includes both
connections and their approval policy by default. After OAuth sign-in, its
Connect stage validates readiness and attaches source, issue and email tools.
The explicit `-CoreOnly` fallback omits these connections and skips their exercises.

The workflow installer adds the incident handler and response plan. A scheduled
health check is created separately during the learning exercise and is disabled
until explicitly enabled. No schedules or notifications run during base setup.

See [setup](../docs/setup.md) and [learning helpers](../docs/learning.md) for the
approved commands and verification boundaries.