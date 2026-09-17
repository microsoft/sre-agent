# Onboarding lab: local agent instructions

Help the learner complete this existing ticketing lab. Keep the application and
UI unchanged. Read `README.md` and `.github/skills/onboarding-lab/SKILL.md` first.

## Two distinct agents

You are the local coding assistant. You can inspect this checkout, prepare
configuration and run approved setup operations. The deployed Azure SRE Agent
investigates the workload and guides the exercises. Do not claim it persisted
knowledge merely because you edited a local file or it agreed in conversation.

## Before changing anything

- Identify whether the learner has an assigned agent, an existing azd environment,
  or needs a new deployment. Inspect state before choosing an action.
- Confirm the subscription, resource group, region and cost owner before creating
  resources. A configured agent-unit limit is not an Azure spending cap.
- Check the selected region's PostgreSQL capabilities for this subscription.
  SRE Agent region availability alone does not establish workload availability.
- Use the existing prerequisite, setup, workflow and learning scripts. Do not
  invent another deployment flow or run cloud writes to work around denied access.
- Show configuration changes before applying them. Preserve learner artifacts
  and unrelated resources. Never weaken Review mode, policies, hooks or RBAC.

## Boundaries

Fault injection and reset belong to the facilitator on shared environments.
Do not let one learner reset the workload for everyone else. Namespaced skills
prevent naming collisions; they do not isolate access to a shared agent.

GitHub code access, issues and Outlook are part of the standard lab. Ask for the
approved repository and email recipients, prepare the connections, and have the
learner complete consent in the trusted sign-in UI. Then use setup's Connect
stage to validate authentication and attach the follow-up tools.
Never ask for tokens or passwords in chat. Setup must not create issues or send
email; the learner separately approves each exercise output.

Use `-CoreOnly` only as an explicit fallback for blocked access. Mark the GitHub
and Outlook exercises skipped. On shared agents, use one designated connection
owner; do not overwrite another learner's sign-in.

Operator fault scripts can contain the answer key. Do not upload this file,
the entire checkout or fault instructions as the incident agent's knowledge.

## Completion

Verify the actual outcome: successful checkout, fresh telemetry, ready agent
configuration, a persisted learner skill used in a fresh thread, and a real
scheduled-check result followed by verified disablement. Report blockers and
untested steps explicitly. Compilation or resource creation alone is insufficient.
