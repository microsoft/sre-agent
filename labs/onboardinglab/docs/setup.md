# Set up or resume the lab

Run these commands from `labs/onboardinglab` in PowerShell 7. On macOS, start
`pwsh` after running the macOS prerequisite script. The local coding assistant
can follow the same stages after checking your environment and approvals.

## New environment

Confirm the subscription, region, resource owner and cleanup plan. You need
permission to create resources and assign the recipe's roles. Preflight checks
advertised capabilities; it cannot guarantee deployment capacity.

```powershell
$Subscription = 'YOUR-SUBSCRIPTION-ID'
$Location = 'swedencentral'
$Environment = 'YOUR-UNIQUE-ENVIRONMENT'
$AgentName = 'YOUR-UNIQUE-AGENT'

azd env new $Environment --subscription $Subscription --location $Location -C .\ticketingapp-source
.\scripts\preflight.ps1 -Subscription $Subscription -Location $Location
```

If preflight fails, resolve the reported issue before provisioning. Complete
`az login` and `azd auth login` through their normal sign-in flows if needed.
Provider registration and new role assignments require the subscription owner's
approval; the preflight does not perform them.

Deploy the workload after reviewing its billable resources:

```powershell
azd provision -C .\ticketingapp-source
azd deploy -C .\ticketingapp-source
```

At this point the agent setup hook reports that it was not selected. Verify a
successful reservation before proceeding.

## Preview and apply the agent configuration

```powershell
.\scripts\setup.ps1 -AgentName $AgentName -Stage Preview
```

Review the generated configuration beneath
`ticketingapp-source/.azure/<environment>/<agent>/`. The core recipe contains
workload telemetry, knowledge, the lab guide, self-configuration guidance, the
read-only health-check skill and safety controls. It does not require a GitHub
fork or Outlook sign-in.

After approving the target and changes:

```powershell
.\scripts\setup.ps1 -AgentName $AgentName -Stage Apply
```

The helper calls the existing shared generator/deployer and workflow installer.
It creates no schedule and sends no notifications.

For later workload deployments, you can opt into the same agent setup stage:

```powershell
azd -C .\ticketingapp-source env set ONBOARDING_AGENT_NAME $AgentName
azd -C .\ticketingapp-source env set ONBOARDING_CONFIGURE_AGENT true
azd up -C .\ticketingapp-source
```

Setting the flag selects the post-deploy operation. Approve its cloud effects
before running azd. With an existing agent, the hook verifies the base configuration
without overwriting its workflow or learner artifacts.

The hook uses the core setup selection. If you selected optional connections,
leave this flag false and run the helper with those same explicit options after
deploying the workload. A mismatched selection fails without overwriting it.

To deploy only the workload again:

```powershell
azd -C .\ticketingapp-source env set ONBOARDING_CONFIGURE_AGENT false
```

## Existing or partially configured environment

Select the intended azd environment and inspect its values first:

```powershell
azd env list -C .\ticketingapp-source
azd env get-values -C .\ticketingapp-source
.\scripts\setup.ps1 -AgentName $AgentName -Stage Verify
```

If this helper has not generated configuration for that agent, run Preview
first. It will not overwrite a configuration directory it does not own.
Changed generation options stop rather than silently replace an existing selection.

For an existing live agent, Apply verifies it and does not automatically replace
configuration. If verification finds missing components or unexpected changes,
inspect the exact differences with the local assistant before applying a repair.
Do not use a force flag simply to make verification pass.

After confirming that the intended core recipe is safe to reapply, the existing
deployer can apply that reviewed directory. Reapplying shared global configuration
can affect other learners, so coordinate that operation with the facilitator.

If the base agent is healthy but workflow installation was interrupted, inspect
the existing `alert-investigator` and `alert-investigation` definitions before
running the same installer:

```powershell
.\scripts\install-workflow-template.ps1 `
  -Subscription $Subscription -AgentName $AgentName `
  -Template .\workflow-templates\incidentinvestigation-workflowtemplate.yaml
```

The installer writes those named lab definitions. Do not rerun it over edited
shared definitions without reviewing the replacement. Unrelated learner names
are not pruned.

## Optional code access and follow-ups

Select optional extensions during the initial Preview and repeat the same options
for Apply and Verify. A later change to that selection requires reviewing the
existing generated directory; it is not silently regenerated.

For example, add code access and an Outlook connection to a new agent:

```powershell
$Repository = 'https://github.com/YOUR-USER/YOUR-REPOSITORY'
.\scripts\setup.ps1 -AgentName $AgentName -Stage Preview `
  -GitHubRepositoryUrl $Repository -EnableEmail
```

Add `-EnableGitHubIssues` only if issue follow-ups are wanted. It adds the
appropriate approval policy; it does not enable GitHub Issues on the repository
or create an issue. The repository must be accessible and its Issues feature
must be enabled for that extension.

Apply with the same options. Complete GitHub and Outlook consent only through
their trusted UI. The generated configuration must never contain access tokens
or passwords. Missing selected consent can block that extension's verification.

After consent, select the corresponding workflow capability explicitly:

```powershell
.\scripts\install-workflow-template.ps1 `
  -Subscription $Subscription -AgentName $AgentName `
  -Template .\workflow-templates\incidentinvestigation-workflowtemplate.yaml `
  -EnableSourceCode -GitHubRepository $Repository
```

For approved issue follow-ups, also pass `-EnableGitHubIssues`. For email, pass
`-EnableEmail -EmailRecipients 'APPROVED-RECIPIENT@example.com'` only after
reviewing that destination. Setup consent does not authorize a later send.

The installer validates the selected connections before attaching their tools.
The Bash installer exposes the equivalent kebab-case flags for existing manual
Bash workflows.

## Verify the outcome

Get the saved links:

```powershell
azd -C .\ticketingapp-source env get-value SERVICE_CHECKOUT_ENDPOINT_URL
azd -C .\ticketingapp-source env get-value SRE_AGENT_URL
```

Confirm successful checkout and fresh workload request/dependency telemetry.
Check the agent's managed resource group, Low access, Review mode and installed
skills. Verify that the incident route points to the intended read-only handler.

Base verification does not demonstrate learner-skill persistence, fresh-thread
reuse or an actual scheduled execution. Complete those checkpoints in the README.
