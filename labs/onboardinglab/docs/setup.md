# Set up or resume the lab

Run these commands from `labs/onboardinglab` in PowerShell 7. On macOS, start
`pwsh` after running the macOS prerequisite script. The local coding assistant
can follow the same stages after checking your environment and approvals.

> [!TIP]
> This page covers the **manual** path, which uses `azd` and local tooling. If you would
> rather have an agent stand the lab up for you from Azure Cloud Shell with nothing installed
> locally, use [agent-driven setup](../README.md#agent-driven-setup) instead. That path does
> not use `azd` at all.

The standard lab includes GitHub code access and issue follow-ups, plus Outlook
email. The facilitator selects an approved repository and recipients during
preparation. Participants complete OAuth sign-in through the trusted connection
UI; they do not paste credentials into chat or edit connector files.

Preparation and sign-in are separate. Setup creates the connection configuration;
`Connect` validates authentication and attaches the follow-up tools. It sends no
email and creates no issues.

## New environment

Confirm the subscription, region, resource owner and cleanup plan. You need
permission to create resources and assign the recipe's roles. Preflight checks
advertised capabilities; it cannot guarantee deployment capacity.

```powershell
$Subscription = 'YOUR-SUBSCRIPTION-ID'
$Location = 'swedencentral'
$Environment = 'YOUR-UNIQUE-ENVIRONMENT'
$AgentName = 'YOUR-UNIQUE-AGENT'
$Repository = 'https://github.com/YOUR-USER/YOUR-LAB-REPOSITORY'
$EmailRecipients = 'APPROVED-RECIPIENT@example.com'

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
.\scripts\setup.ps1 -AgentName $AgentName -Stage Preview -GitHubRepositoryUrl $Repository
```

Review the generated configuration beneath
`ticketingapp-source/.azure/<environment>/<agent>/`. The base recipe contains
workload telemetry, knowledge, the lab guide, self-configuration guidance, the
read-only health-check skill and safety controls. Standard setup adds the selected
GitHub repository, Outlook connection and approval policies for follow-ups.
Use a repository you can access and create issues in, with its Issues feature
enabled. An existing approved repository is sufficient; a new fork is not required.

After approving the target and changes:

```powershell
.\scripts\setup.ps1 -AgentName $AgentName -Stage Apply -GitHubRepositoryUrl $Repository
```

The helper calls the existing shared generator/deployer and installs the
investigation workflow. When deployment prints the GitHub OAuth link, complete
sign-in and consent through that UI. The deployer waits up to four minutes.
It creates no schedule, issues or email.

If sign-in times out, setup remains incomplete. After authenticating, have the
local assistant or facilitator inspect and finish the pending repository
connection before verifying again; do not blindly rerun configuration over drift.

## Sign in and activate the connected exercises

Open the agent's Code access page and verify `ticketingapp-source` points to the
approved repository. Under **Build + setup > Extensions > Connectors**, complete
the Office 365 Outlook sign-in. Keep passwords and tokens out of chat and script
arguments. A blocked consent requires help from the connection or tenant owner.

Once both connections are authenticated, review the intended repository and
email recipients, then activate the follow-up workflow:

```powershell
.\scripts\setup.ps1 -AgentName $AgentName -Stage Connect `
  -GitHubRepositoryUrl $Repository -EmailRecipients $EmailRecipients
```

The installer checks GitHub and Outlook readiness before attaching their tools,
then reads back the selected tool and skill sets. An unauthenticated connector
stops this stage. Setup consent does not authorize a later issue creation or send.

On shared agents, use one designated connection owner. Do not replace another
participant's GitHub or Outlook sign-in. Use isolated agents when each attendee
needs to authenticate with their own account.

## Use the azd setup hook

For later workload deployments, you can opt into the same agent setup stage:

```powershell
azd -C .\ticketingapp-source env set ONBOARDING_AGENT_NAME $AgentName
azd -C .\ticketingapp-source env set ONBOARDING_GITHUB_REPOSITORY_URL $Repository
azd -C .\ticketingapp-source env set ONBOARDING_CONFIGURE_AGENT true
azd up -C .\ticketingapp-source
```

Setting the flag selects the post-deploy operation. Approve its cloud effects
before running azd. With an existing agent, the hook verifies the base configuration
without overwriting its workflow or learner artifacts.

The hook uses the standard GitHub/Outlook selection and the saved repository URL.
After sign-in, run Connect separately with approved recipients. The hook never
activates follow-up writes or sends messages automatically.

To deploy only the workload again:

```powershell
azd -C .\ticketingapp-source env set ONBOARDING_CONFIGURE_AGENT false
```

## Existing or partially configured environment

Select the intended azd environment and inspect its values first:

```powershell
azd env list -C .\ticketingapp-source
azd env get-values -C .\ticketingapp-source
.\scripts\setup.ps1 -AgentName $AgentName -Stage Verify -GitHubRepositoryUrl $Repository
```

If this helper has not generated configuration for that agent, run Preview
first. It will not overwrite a configuration directory it does not own.
Changed generation options stop rather than silently replace an existing selection.

For an existing live agent, Apply verifies it and does not automatically replace
configuration. If verification finds missing components or unexpected changes,
inspect the exact differences with the local assistant before applying a repair.
Do not use a force flag simply to make verification pass.

After confirming that the intended recipe is safe to reapply, the existing
deployer can apply that reviewed directory. Reapplying shared global configuration
can affect other learners, so coordinate that operation with the facilitator.

If the base agent is healthy but connected workflow installation was interrupted,
inspect the existing `alert-investigator` and `alert-investigation` definitions
before rerunning Connect:

```powershell
.\scripts\setup.ps1 -AgentName $AgentName -Stage Connect `
  -GitHubRepositoryUrl $Repository -EmailRecipients $EmailRecipients
```

The installer writes those named lab definitions. Do not rerun it over edited
shared definitions without reviewing the replacement. Unrelated learner names
are not pruned.

## Core-only fallback

When a participant cannot obtain approved GitHub/Outlook access, explicitly choose
the reduced fallback for a new setup:

```powershell
.\scripts\setup.ps1 -AgentName $AgentName -Stage Preview -CoreOnly
.\scripts\setup.ps1 -AgentName $AgentName -Stage Apply -CoreOnly
.\scripts\setup.ps1 -AgentName $AgentName -Stage Verify -CoreOnly
```

Do not combine this switch with integration options or run Connect. For an azd
hook, set `ONBOARDING_CORE_ONLY=true`; otherwise the standard path is used.
Repeat the same selection on later runs. Changing an existing selection stops
for review and never silently removes connections.

Mark the GitHub and Outlook exercises as skipped. Core-only is a contingency,
not completion of the full lab. The low-level workflow installers still support
explicit capability flags for facilitator-controlled recovery.

## Verify the outcome

Get the saved links:

```powershell
azd -C .\ticketingapp-source env get-value SERVICE_CHECKOUT_ENDPOINT_URL
azd -C .\ticketingapp-source env get-value SRE_AGENT_URL
```

Confirm successful checkout and fresh workload request/dependency telemetry.
Check the agent's managed resource group, Low access, Review mode and installed
skills. Verify that the incident route points to the intended handler and that
GitHub/Outlook tools are attached only after authenticated connection validation.
Azure investigation remains read-only; issue and email writes require approval.

Base verification does not demonstrate learner-skill persistence, fresh-thread
reuse or an actual scheduled execution. Complete those checkpoints in the README.
