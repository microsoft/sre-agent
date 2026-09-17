# Facilitate the onboarding lab

Use the existing ticketing application. The lesson teaches evidence gathering,
skill creation and reuse. App styling is not an exercise.

## Prepare the participant environment

Choose who owns the subscription, costs, expiry and cleanup. Confirm capacity
for the selected PostgreSQL SKU and region before provisioning. Record the
approved resource group and agent for each participant or group.

Prefer isolated agents. If participants share an agent, assign learner-specific
artifact names and coordinate configuration changes. Namespaces do not prevent
participants with administrator access from editing each other's configuration.

Provide these items before the exercise:

- Application and agent links.
- Whether the participant may provision or only use an assigned environment.
- The facilitator who controls workload fault injection and recovery.
- The supported machine prerequisites or an assigned-environment alternative.
- Where to find the README and the local-agent setup instructions.

Keep GitHub and Outlook optional. Complete any selected consent flow before
demonstrating external follow-ups. Do not use attendee preparation as approval
to send email or create issues.

## Readiness checks

Use the published commands from a clean checkout. Record every intervention
that the instructions do not explain.

| Check | Evidence |
| --- | --- |
| Workload | A successful reservation, not only a healthy service endpoint |
| Telemetry | Fresh checkout requests and PostgreSQL dependencies in the workload source |
| Agent | Correct managed resource group, Review mode and configured tools |
| Guidance | Lab-guide and health-check skills are present with the expected content |
| Incident route | The lab alert matches the intended read-only response plan |
| Learning | The selected save path can create a learner skill and read it back |
| Schedule | A read-only handler and a supported enable/disable path are available |

An unavailable runtime save path is acceptable only when the lesson clearly
demonstrates the authorized local-assistant or portal handoff. A skill-creation
failure must not turn into a request for broad permissions during the session.

## Lead the lesson

Have participants open **New chat** in their assigned SRE Agent and use the
README's startup prompt naming `onboarding-lab-guide`. No slash command is needed.
Verify that the guide gives a starting-point check and one next action with a
completion checkpoint. A generic welcome is not evidence that the guide loaded.
If the skill is missing, repair setup before continuing; do not ask participants
to discover a command that the lab never registered.

Keep the coaching chat separate from the incident investigation. The guide is
lab-aware by design; the incident handler's selected skills exclude it. Do not
feed the lesson or fault instructions to the investigator. Resource naming and
shared operational context can still reveal the sample, so do not describe
the exercise as a blind evaluation.

Start with the learner's question: what does the agent know about this workload,
what evidence can it query, and what remains unknown?

Let participants inspect the current environment before triggering a fault.
Keep the explanation of the fault mechanism in operator materials. Do not give
them a diagnosis to paste into the incident thread.

For a shared workload, run fault injection once and tell participants which
incident to examine. Capture the baseline and affected UTC intervals. Wait for
the actual Azure alert and its routed agent thread; a successful fault command
does not prove incident dispatch.

Use `scripts/fault.ps1 reset` on Windows or `scripts/fault.sh reset` on macOS to
recover. These helpers preserve the fault rule and set it to Allow. Verify fresh
successful reservations and PostgreSQL dependencies afterward. Wait for the
Azure alert's monitor condition to become Resolved before another rehearsal.

Do not rely on the model making an error for the teaching exercise. Ask each
learner to add an operational requirement, such as including the evidence
interval and both request and dependency results before declaring recovery.
They should save it, inspect the saved content, then use it in a fresh thread.

For scheduled checks, inspect an actual run and its result. A task waiting for
approval has not completed. Disable every exercise schedule and verify its state
before participants leave.

## What participants should explain

- Which evidence supported the diagnosis and what contradicted it.
- How their saved skill changed the new conversation's behavior.
- Which customer-specific facts and connections would replace the sample's.
- Which identity performed setup and skill writes, and which actions needed approval.
- What the scheduled check proved and where its result was recorded.

## Rehearsal and recording

Have a first-time user follow the README without hidden commands. Test the
published Windows and macOS paths on those platforms before claiming support.
Local syntax and mock tests alone do not prove cloud or cross-platform behavior.

Record a walkthrough only after the flow passes. Show setup entry, environment
discovery, evidence-backed investigation, a saved skill, fresh-thread reuse and
the scheduled result. Do not show credentials, participant data or OAuth tokens.

If capacity or access blocks deployment, use an already approved environment.
If none is available, state that hands-on provisioning is blocked. A recording
can explain the flow but does not count as the participant completing it.

## Leave the environment deliberately

Stop traffic generators and disable exercise schedules. Verify that the fault
is reset and the application works. Export learner artifacts before cleanup.

If the environment remains available, record its owner and expiry; it remains
billable. Before `azd down`, show the exact selected subscription and resource
group and obtain approval. Never delete a resource group merely because its
name resembles the lab.
