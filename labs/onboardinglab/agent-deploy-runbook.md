# Onboarding Lab - agent deployment runbook

This runbook is for the final Azure SRE Agent. The bootstrap has already created the agent,
its action identity, and the lab resource group, and has granted the action identity temporary
Owner on that resource group.

## Locate the repository

Find the local workspace directory that contains this exact repository path:
`labs/onboardinglab/agent-deploy-runbook.md`. Code Access can still be preparing the local
`sre-agent` clone when the chat becomes available. If the path is not present yet, keep the
operator informed, wait, and retry periodically. Do not report deployment failure and do not
clone a second copy of the repository.

Change to the discovered `sre-agent` repository root before continuing.

## Run the deployment

Use the workspace terminal to launch the repository-owned deployment script once:

```bash
bash labs/onboardinglab/scripts/deploy-agent.sh \
  <AGENT_IDENTITY_CLIENT_ID> \
  <SUBSCRIPTION> \
  <LAB_RG> \
  <LOCATION> \
  <NAME_PREFIX> \
  <AGENT_NAME> \
  <AGENT_IDENTITY_NAME> \
  <WORKLOAD_OPTION>
```

Use the exact values from the deployment request. Do not invent or substitute values.

The first operation signs Azure CLI in with the existing user-assigned action identity:

```bash
az login --identity --client-id <AGENT_IDENTITY_CLIENT_ID>
```

The script then owns the full workflow:

- validates the identity, subscription, regional capabilities, tools, and disk space
- acquires both ARM and SRE Agent data-plane tokens
- deploys the Bicep-authored infrastructure from its compiled ARM artifact
- monitors Azure deployment state and reports progress
- packages and publishes the checkout application through asynchronous OneDeploy
- monitors the existing OneDeploy operation without submitting duplicate uploads
- generates and applies skills, knowledge, hooks, prompts, and tool policy
- verifies the agent, permanent RBAC, alert, database-fault state, application, checkout path,
  and telemetry
- writes the verified ARM completion marker used by external finalization

Keep the operator informed with the status lines emitted by the script. Do not duplicate its
individual commands in separate Azure CLI tool calls. If the terminal or thread is interrupted,
run the same script command again; it detects active or completed deployments and resumes safely.

Do not install dependencies, create another SRE Agent or managed identity, enable the database
fault, modify resources outside `LAB_RG`, remove temporary Owner, or lower the agent's access.
The external bootstrap finalizer performs and verifies that final boundary.

When the script prints `External finalization is safe`, report:

- the checkout URL
- the full agent portal URL
- that workload deployment, configuration, checkout, and telemetry verification succeeded
- that the operator can now run `bootstrap-agent.ps1 -Finalize`
