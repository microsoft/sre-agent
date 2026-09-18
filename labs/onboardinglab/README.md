# Azure SRE Agent onboarding lab

Investigate a failure in a ticketing application, teach the agent an operational
rule, and reuse that rule in a new conversation. Finish by observing a read-only
scheduled health check.

The application runs on App Service with PostgreSQL and Application Insights.
Reservations are simulated: each checkout connects to PostgreSQL, runs `SELECT 1`
and closes the connection. No tickets, payments or customer data are stored.

## Choose your starting point

| Your situation | Start here |
| --- | --- |
| The facilitator gave you an agent and application link | Open both links and [start the guided lesson](#start-the-guided-lesson). Do not deploy or reset shared resources. |
| You have a checkout and a local coding assistant | Open `labs/onboardinglab` as the working directory. Ask: **Help me set up or resume this lab. Check my environment and explain any approvals before changing anything.** |
| You want to run the commands yourself | Follow [Setup](#setup), then begin the same exercises. |
| You lack a subscription, permissions or required tools | Ask the facilitator for an assigned environment. A local assistant can explain the blocker but cannot grant access. |

The local assistant reads [AGENTS.md](AGENTS.md) and the
[onboarding-lab skill](.github/skills/onboarding-lab/SKILL.md). It uses the same
scripts as the manual setup. The deployed SRE Agent has a separate
`onboarding-lab-guide` skill for the exercises.

> [!IMPORTANT]
> This lab creates billable Azure resources. Confirm the subscription, resource
> owner and cleanup plan before deploying. An agent-unit limit is not a total
> Azure spending cap.

## What you should leave with

- An investigation supported by telemetry and resource evidence.
- A reviewed GitHub follow-up and Outlook summary with verifiable results.
- A skill you created, saved and used in a fresh conversation.
- The result of a read-only scheduled check, with the task disabled afterward.
- An explanation of what you would change for a customer's workload.

GitHub and Outlook are part of the standard lab. Setup prepares the connections;
participants finish sign-in through the trusted GitHub and Microsoft connection
UI. The facilitator provides an approved repository and email destination so
participants can see the investigation turn into useful follow-up work.

Never paste passwords or tokens into agent chat. If consent is blocked, use the
explicit [core-only fallback](docs/setup.md#core-only-fallback) and mark those
exercises as skipped.

## 1. Discover the environment

### Complete the prepared connections

For an assigned environment, open its GitHub Code access connection and Office
365 Outlook connector. Complete the requested sign-in, then ask the facilitator
or local assistant to run the setup helper's `Connect` stage with approved
destinations. This validates authentication and attaches the follow-up tools.
It does not create an issue or send an email.

On shared agents, the designated connection owner completes sign-in. Participants
must not replace each other's connected accounts. Setup details are in the
[sign-in instructions](docs/setup.md#sign-in-and-activate-the-connected-exercises).

### Start the guided lesson

Open the assigned **Azure SRE Agent**, choose **New chat**, and use the default
agent. Enter this in the chat box, not in a local terminal:

> Use onboarding-lab-guide to start the onboarding lab. Check my starting point
> and guide me through one step at a time. Keep investigation read-only and ask
> before any configuration change.

No slash command is required. [Skills load when relevant to the question](https://sre.azure.com/docs/concepts/skills);
naming `onboarding-lab-guide` makes the intended lesson explicit. This lab does
not register a custom slash command. Start in a normal chat rather than the
incident-specific `alert-investigator`, which has a different selected skill set.

The guide should identify the starting point, ask about missing setup information,
then give one next action and its completion checkpoint. It should not launch a
deployment, inject a fault, or save configuration just because you started the lesson.

The guide knows this is a training exercise. Keep that coaching conversation
separate from the incident thread. The `alert-investigator` workflow selects
its investigation skill without the lab-guide skill. Do not paste lesson or
fault-injection instructions into the investigator's prompt.

This is an evidence-based exercise, not a blind benchmark. Resource names and
tags can still reveal that the environment is a lab. Judge the diagnosis by its
telemetry and configuration evidence rather than apparent surprise at the fault.

If the guide is unavailable, ask the facilitator to verify that
`onboarding-lab-guide` is installed on this agent. Use Skill Builder to inspect
it. Do not try invented slash commands or treat a generic answer as proof that
the lab guide loaded.

To resume later, use the same startup prompt and describe your last completed
checkpoint. The guide should check saved artifacts before assuming earlier steps
succeeded.

### Map the workload

Continue in that chat:

> Map the ticketing request path, identify the evidence sources you can access,
> and explain what you cannot verify yet. Keep this read-only.

Compare its answer with the application's behavior. Select **Reserve tickets**
and confirm that the **Confirmed** count increases.

Ask the agent to locate that successful operation in workload telemetry.
Distinguish the app's telemetry from the agent's own operational telemetry.

**Checkpoint:** explain the app-to-database path, identify a business-operation
signal, and name one limitation in the available evidence.

## 2. Investigate an incident

The facilitator injects the controlled fault and identifies the incident for
the group. On a shared workload, participants must not inject or reset faults.
Operator commands are in the [facilitator guide](docs/facilitator.md).

Select **Reserve tickets** again. Observe whether checkout fails while the
service-health indicator stays available. The optional on-sale simulation
generates repeated requests and stops automatically; the facilitator controls
its use and stops it when enough evidence is available.

Open **Incidents** and select the lab's checkout-failure alert. The response plan
is `alert-investigation`. Allow for telemetry ingestion, alert evaluation and
the agent's next scan. The alert evaluates every minute over a five-minute window.

Ask:

> What evidence supports the cause, and what would contradict it? Separate
> observed facts from assumptions. Show the affected UTC interval and recommend
> a recovery action for the facilitator without changing resources.

Check the request failures, PostgreSQL dependency results and Azure configuration.
Do not accept a known runbook explanation as proof of the current fault.

The facilitator runs the reset helper. Confirm that new reservations succeed
and ask for fresh successful requests and dependencies after the reset.

**Checkpoint:** a diagnosis with cited evidence, explicit uncertainty and verified
recovery. Workload investigation remains read-only; the operator performs the reset.

### Turn the investigation into follow-up work

Use the approved repository and recipient supplied for your environment:

> Prepare a GitHub follow-up for this investigation in our approved repository.
> Include the impact, supporting evidence and next action. Check for an existing
> issue first, then show me the proposed destination and content before creating it.

Review the destination and a short, redacted summary. Approve creation only when
both are correct, then open the returned issue link.

> Draft an Outlook summary for the approved recipient with the diagnosis,
> recovery evidence and GitHub issue link. Show me the recipients and message,
> and wait for my approval before sending.

After approval, inspect the send receipt. Do not treat a draft as a sent message
or retry an unknown outcome blindly. Exclude credentials, raw logs and private
customer information from outbound content.

**Checkpoint:** an actual GitHub issue link and email receipt, or an explicit
blocked/skipped result. Authentication alone does not authorize either write.

## 3. Teach the agent a useful rule

Choose a requirement you would expect in a customer investigation. You do not
need to wait for the agent to make a mistake.

For example:

> Draft a short skill named onboarding-learned-MYNAME. Require fresh successful
> checkout requests and successful PostgreSQL dependencies after the reset
> before declaring recovery. Include the UTC evidence interval and any gaps.
> A healthy health endpoint alone is insufficient. Attach no tools, show me
> the content and exact target, and wait for approval before saving anything.

Replace `MYNAME` with an assigned lowercase learner identifier. Review the result and
change a detail so you understand the behavior you are saving.

Ask the agent to use `sre-agent-self-configure` to save the approved skill only
if that capability is available. It must show the change, use normal approval
and read the saved content back.

If the configured identity cannot save it, stop that path. Use the lab's
documented local learning helper or open **Build + setup > Extensions >
Skill Builder** and create the reviewed skill there. The local assistant or
authorized learner performs that write; do not claim the remote agent saved it.
Do not broaden permissions to get through the exercise.

**Checkpoint:** the new named skill exists and its saved content matches your
approved rule. Agreement in chat or a local Markdown file is not enough.

## 4. Prove reuse in a new conversation

Start a new agent conversation and ask:

> Use onboarding-learned-MYNAME. The health endpoint is healthy. Can we declare
> that ticket reservations have recovered?

Do not paste the skill text again. The agent should use the saved rule to
request or inspect fresh checkout and dependency evidence. If it lacks that
evidence, it should say so.

Ask it to identify the skill it used, then inspect the tool trace or loaded
skill content where available.

**Checkpoint:** the saved rule changes the answer in a fresh context. This proves
explicit skill reuse, not an automatic change to every future investigation.

## 5. Run a read-only scheduled check

Ask the agent to explain the installed `onboarding-health-check` skill. Review
which workload and UTC interval it will inspect, what a healthy result requires,
and how it reports missing telemetry.

Use the [learning helper instructions](docs/learning.md) to prepare a named
scheduled check. Inspect the schedule, timezone, read-only handler and approval
behavior before enabling it. Do not attach notification or remediation tools.

Open **Automation**, inspect an actual scheduled execution and review its
evidence summary. A manually submitted chat prompt is not a scheduled run.
If it is waiting for approval or blocked, report that state instead of calling
the exercise complete.

Disable the exercise task and verify that it is disabled.

**Checkpoint:** a real scheduled result and confirmed disablement. Even a
healthy run should give a visible summary.

## 6. Take the skill with you

Export your skill and explain:

- Which environment facts and evidence sources would change for a customer.
- Which identity performs configuration writes and who approves them.
- How you would test the skill against a new incident and missing evidence.

Real customer investigations should use maintained operational knowledge and
relevant connected application source. This lab keeps operator fault instructions
separate from the incident agent's evidence so the exercise requires investigation.

## Setup

### Prerequisites

Use Git, Azure CLI, Azure Developer CLI, PowerShell 7, Node.js 22 or later,
Python 3 with PyYAML, and jq. The scripts check the dependencies they use.
Windows and macOS prerequisite installers are provided; the shared setup and
learning helpers run in PowerShell 7 on either platform.

The Azure subscription must permit resource creation and role assignments.
The standard path also needs a GitHub account with access to the approved
repository and an account supported by the Office 365 Outlook connector.
Confirm a region that supports both SRE Agent and this subscription's PostgreSQL
16 / B1ms offering. Region availability does not guarantee quota or capacity.

From the repository root:

```powershell
Set-Location .\labs\onboardinglab
. .\scripts\prereqs.ps1 -Check
```

On macOS, from the lab directory:

```bash
source ./scripts/prereqs.sh --check
```

Remove the check-only option to install missing prerequisites after reviewing
the required changes. Complete Azure CLI and azd sign-in through their trusted UI.

### Prepare the approved environment

Choose a unique environment name and approved subscription:

```powershell
azd env new YOUR-ENVIRONMENT --subscription YOUR-SUBSCRIPTION --location swedencentral -C .\ticketingapp-source
pwsh -NoProfile -File .\scripts\preflight.ps1 -Subscription YOUR-SUBSCRIPTION -Location swedencentral
```

The preflight makes no changes. Fix any missing provider registration or regional
capability before proceeding; do not interpret an empty version list as a naming
collision.

Follow [setup and recovery](docs/setup.md) to enable the agent setup stage,
preview the changes and run `azd up`. Existing environments use the same stage
helpers. Review unexpected configuration drift instead of overwriting it.

### Verify before the exercises

Confirm all of the following:

- The application accepts a reservation and emits workload telemetry.
- The agent manages the correct resource group in Low access and Review mode.
- The lab-guide, self-configuration and health-check skills are installed.
- The incident workflow has the expected read-only tools and response plan.
- GitHub and Outlook are authenticated and their workflow tools are ready, or the core-only fallback is explicitly selected.
- The chosen learner skill-save path works with the available permissions.

Do not continue to fault injection when the baseline is broken.

## Troubleshooting

| Symptom | Action |
| --- | --- |
| Setup fails after creating some resources | Inspect the named deployment and failed stage. Resume through the setup helper after reconciling the existing state. |
| Python is installed but a prerequisite fails | Use the reported executable and error. A Windows Store alias is not proof of an installed interpreter. |
| Reservation fails before fault injection | Fix the baseline; this is not the intended incident. |
| Alert fires but no agent incident appears | Check Azure Monitor is connected, the alert is New/Fired and the lab response plan matches it. |
| Agent cannot save a skill | Keep permissions unchanged. Use the authorized local helper or Skill Builder and verify read-back. |
| No telemetry | Check the workload source and UTC interval. Missing data does not prove health or recovery. |
| Scheduled task has no completed run | Inspect its enabled state, trigger and approval status. Do not substitute a manual chat as proof. |
| GitHub or Outlook output is unavailable | Complete sign-in and Connect, or explicitly use core-only and mark the connected exercises skipped. Never bypass consent. |

## Cleanup

Export learner skills first. Stop the simulation, reset any fault and disable
exercise schedules. Verify the exact selected subscription and resource group.

After the resource owner approves deletion:

```powershell
azd down -C .\ticketingapp-source
```

Confirm that the intended resource group was removed. GitHub issues and sent
email are external artifacts and are not removed by azd. If the lab stays
deployed, keep a responsible owner and expiry; it remains billable.

## For facilitators and contributors

- [Facilitator guide](docs/facilitator.md)
- [Local-agent instructions](AGENTS.md)
- [Application and telemetry](ticketingapp-source/app/README.md)
- [Base-agent recipe](agent-recipe/README.md)

Run the app, workflow, setup and learning contracts before changing the exercise.
Offline tests validate configuration and error handling. Release readiness also
requires a live rehearsal of setup, investigation, learner-skill persistence,
fresh-thread reuse, a scheduled run and disablement on each supported host.
