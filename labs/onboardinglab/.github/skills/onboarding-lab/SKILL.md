---
name: onboarding-lab
description: Set up, resume, inspect or operate the Azure SRE Agent onboarding lab in this checkout. Use when a learner asks for help preparing the lab, understanding a setup failure, or saving their reviewed learner artifact.
---

# Help with the onboarding lab

Read the lab's `README.md` from `labs/onboardinglab`. Work from that directory
so relative paths and its local instructions resolve correctly.

## Find the learner's starting point

1. For an assigned agent, ask for its portal link or exact resource ID. Inspect
   only that environment. Do not deploy or overwrite it.
2. For an existing local setup, read `azd env list` and the selected environment's
   values from `ticketingapp-source`. Check the subscription and resource group
   before executing any stage.
3. For a new environment, explain which resources are billable, confirm the target
   and responsible owner, and run the documented preflight before deployment.
4. If access, quota or prerequisites are missing, name the failed check and its
   remedy. Offer the facilitator's assigned environment when one is available.
   Never invent an assigned environment or grant yourself access.

## Prepare and resume

Use the documented setup scripts and azd lifecycle. Inspect their help and
parameters before calling them. Do not turn README examples into a separate
collection of unverified REST writes.

Run prerequisite checks before installing anything. Obtain approval for missing
tools, Azure resources and role assignments. Reuse existing sign-ins; let the
learner complete an expired sign-in through the provider's normal UI.

The standard lab includes GitHub and Outlook. Obtain the approved repository
and email recipients during preparation. Let the learner complete OAuth in the
connection UI, then run setup's Connect stage. Do not ask for credentials in
chat or treat consent as permission to create an issue or send email.
Use `-CoreOnly` only when explicitly choosing the reduced fallback.

After a failure, inspect the named deployment and the stage's read-back output.
Reconcile an unknown write result before retrying. Preserve the existing app,
agent, skills, knowledge and existing connections. Do not use a force flag to
silence unexpected drift.

Verify checkout and workload telemetry before allowing a fault scenario.
Check agent configuration separately from workload provisioning.

## Help the learner teach the agent

Have the deployed agent draft a small, workload-specific skill. A useful example
requires fresh successful checkout and PostgreSQL dependency evidence before
declaring recovery. Keep it tool-free and give it a learner-specific name.

Show the proposed content and exact agent target before saving. Prefer the
deployed agent's supported, approved self-configuration path. If that path fails
authorization, stop it; use the documented local learning helper or Skill Builder
only after explaining that an authorized operator will perform the write.

Do not claim the deployed agent saved a skill when the local assistant performed
the operation. Read the saved content back, then have the learner invoke it in a
new conversation without pasting the content again.

## Facilitate safely

Only the facilitator injects or resets faults on shared workloads. Inspect a
fault command's target before running it. Run the documented reset helper instead
of inventing a different recovery action.

Do not enable scheduled activity as part of ordinary setup. For the scheduling
exercise, show the target, schedule and read-only handler before enabling it.
Observe a real scheduled execution, disable it afterward and verify the state.
If a run is waiting for approval, report it as waiting, not complete.

At handoff, list the app and agent URLs, remaining blockers, learner artifacts,
enabled schedules, and the resource owner. Teardown requires explicit approval.
