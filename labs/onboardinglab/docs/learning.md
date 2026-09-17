# Save a lesson and run a scheduled check

The supported exercise has two separate outcomes: a saved skill used in a new
conversation, and a real scheduled run followed by disablement. A local file,
generated JSON or a successful API request does not prove both outcomes.

## Save the learner's skill

Ask the agent to draft a short, tool-free skill. Use a learner-specific name such
as `onboarding-learned-alex`. Keep the content limited to the chosen operational
rule, without credentials, additional tools or global policy changes.

Review it before saving. Use the deployed agent's self-configuration capability
only if it can read the target and obtain normal approval. If it cannot, stop
that path. Do not grant broader access merely to finish the exercise.

The authorized learner can use **Build + setup > Extensions > Skill Builder**
to save the reviewed content. Reopen the saved skill and compare its name and
content with the draft. Start a new conversation and explicitly ask the agent
to use that skill without pasting the text again.

An authorized local assistant can also use the helper below. It requires an
isolated learner-owned agent or an exclusive facilitator configuration window.
The extension service does not enforce conditional creates, so the helper's
read/compare/write checks are best-effort rather than atomic. Use Skill Builder
with the facilitator if other participants may be editing the same objects.

## Preview with the local helper

Run PowerShell 7 from `labs/onboardinglab`. Save the reviewed skill as a UTF-8
Markdown file without YAML frontmatter, outside the repository if it contains
environment-specific details.

```powershell
$AgentId = azd -C .\ticketingapp-source env get-value SRE_AGENT_RESOURCE_ID
$SkillName = 'onboarding-learned-alex'

.\scripts\learning.ps1 -Action Skill -AgentResourceId $AgentId `
  -Name $SkillName -MarkdownPath 'C:\lab-artifacts\recovery-check.md' `
  -Description 'Require checkout and PostgreSQL evidence before declaring recovery.'
```

On macOS use the actual local Markdown path. The preview reads the exact agent
and displays the target, payload and plan hash. It performs no configuration
writes. Existing names are rejected rather than overwritten.

After reviewing the plan and confirming exclusive access, repeat the exact
preview command with:

```powershell
-Apply -ApprovePlan 'THE-REVIEWED-PLAN-SHA256' -ExclusiveAccess
```

The flag confirms the operating boundary; it grants no permissions and provides
no server-side lock. Changed content or target requires a new preview and approval.

The helper rejects existing names, authorization failures and ambiguous writes without retrying.
It reads back the object after a successful write. A race, missing read-back or
unknown outcome requires reconciliation of the exact object before another attempt.

## Prepare the read-only scheduled check

Have the agent explain `onboarding-health-check`. The scheduled handler must
query only the workload's Application Insights resource, produce a visible
result, and have no write, notification or delegation tools.

The local helper can preview a disabled task and its dedicated handler:

```powershell
$AppInsightsId = azd -C .\ticketingapp-source env get-value APPLICATION_INSIGHTS_ID
$TaskName = 'onboarding-health-alex'
$StartUtc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
$EndUtc = [DateTime]::UtcNow.AddMinutes(15).ToString("yyyy-MM-ddTHH:mm:ssZ")

.\scripts\learning.ps1 -Action Schedule -AgentResourceId $AgentId `
  -Name $TaskName -AppInsightsResourceId $AppInsightsId `
  -StartUtc $StartUtc -EndUtc $EndUtc
```

Choose the window when ready to perform the exercise. The helper accepts an
explicit 5-30-minute UTC window and a five-minute cron cadence. It sets
`maxExecutions` to one and records the window in the service's start/end fields.
It creates a paused task named `$TaskName` and a handler named `$TaskName-reader`.
Neither is created by a preview.

Inspect the displayed handler and task. The handler contains only the read-only
telemetry query tool. It must not call another agent to remediate a problem.
The UTC window is also included in the instructions. Verify the saved
`startTime`, `endTime`, `maxExecutions: 1` and `status: Paused` before enabling it.

Use Automation and the agent builder if the local helper is unavailable. Keep the task paused
until its target, handler, tool list, schedule, timezone and cost ownership are
confirmed. An authorized facilitator should perform this configuration on a
shared environment.

For an isolated agent or an exclusive configuration window, repeat the Schedule
preview with the reviewed hash and apply flags. A failure between handler and task creation is
partial completion: inspect both names before deciding how to recover. The helper
does not automatically delete the handler or overwrite an existing task.

## Observe a run and disable the task

Confirm healthy traffic exists in the evidence interval. The check itself does
not create traffic. Enable the task only for the approved exercise window.

For an API-created task, preview Enable:

```powershell
.\scripts\learning.ps1 -Action Enable -AgentResourceId $AgentId -Name $TaskName
```

Review the current state, then repeat with the approval and exclusive-access
flags. Enable runs in the foreground and pauses the task at the window's end.
The service also receives the end time and single-execution limit. Keep the
terminal open and verify the final state; do not rely only on the model's instructions.

In Automation, inspect a real scheduled execution and its evidence summary.
A task created but never triggered has not met the checkpoint. A run waiting
for approval or missing telemetry must be reported as such.

Pause the task in Automation after the exercise and read its state back.
For a helper-created task, the explicit recovery command is:

```powershell
.\scripts\learning.ps1 -Action Disable -AgentResourceId $AgentId -Name $TaskName
```

This also previews by default. Apply requires a newly reviewed hash and exclusive
access. If that path is blocked, pause it through Automation and confirm the
state. Do not leave a schedule active while debugging the helper.

## Completion record

Record the saved skill name, the fresh conversation that used it, the scheduled
run and result, and the final disabled state. Identify whether the remote agent,
local assistant or learner performed each configuration write.

The helper has offline transport and lifecycle tests. The facilitator must still
verify identity permissions, actual execution and the supported participant
platforms before offering this path at the event.
