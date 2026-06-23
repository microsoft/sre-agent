---
metadata:
  api_version: azuresre.ai/v2
  kind: Skill
name: pr-delivery
description: Use to deliver a durable Zava Learning fix as a GitHub pull request once an incident has been root-caused — for either an Infrastructure-as-Code change (Bicep under infra/) or an application code change (under src/). The single skill that creates pull requests; applies after live mitigation and root-cause confirmation. The resulting PR URL is what the ServiceNow Change Request references.
tools:
  - RunAzCliReadCommands
  - GetAzCliHelp
  - FindConnectedGitHubRepo
  - GetIaCForGitHub
  - ExecutePythonCode
  - SearchMemory
---

## Zava Learning — Pull Request Delivery (IaC + Code)

Single owner of GitHub pull-request creation for durable fixes. Repo: `@@REPO@@`
(hosts the app `src/` and the infrastructure `infra/`). This skill applies once an incident is
root-caused and the live mitigation is in place; the pull request it produces is later referenced
by the ServiceNow Change Request (`servicenow-change-management`).

There is no native GitHub pull-request tool — author the branch, commit, and open the PR with
`ExecutePythonCode` (GitHub REST API / `gh`) using `FindConnectedGitHubRepo` and
`GetIaCForGitHub` to locate the repo and IaC. Never commit secrets. Before opening the PR, retrieve
`SearchMemory("zava-redaction")` and run its `redact()` over the PR title, body, and commit message
(and never stage a credential or `.env`/`*.pem`/`git-credentials` file into the diff).

## When to use
- An incident is root-caused to a durable defect and the live mitigation is already applied.
- The fix belongs in version control: **IaC** (`infra/`, e.g. an NSG rule in
  `infra/modules/network.bicep`, or a value in `infra/main.parameters.json`) or
  **application code** (`src/`, e.g. a synchronous crypto regression in
  `src/assessment-api/server.js`).

## Decide the change class
- **Infrastructure (IaC):** the fix is a guardrail or config in Bicep / parameters. Make BOTH
  live Azure and the committed IaC reflect the corrected state so the next deploy keeps the fix.
- **Application code:** the fix is in `src/`. The live mitigation was a revision
  rollback/restart; the PR carries the actual code correction.

## Steps
1. Resolve the repo and IaC type (`FindConnectedGitHubRepo`, `GetIaCForGitHub`).
2. Branch from default: `fix/<symptom-slug>` (e.g. `fix/quiz-launch-nsg-priority`).
3. Apply the minimal, surgical change. Match existing style. Touch only what the root cause
   requires.
4. Commit with a conventional message: `fix(<area>): <symptom> — <root cause>` and a body that
   summarizes the RCA and links the PagerDuty incident.
5. Open the PR against `@@REPO@@`. PR body must include: symptom, root cause, the change,
   verification evidence (link the Before/After), and the PagerDuty incident number.
6. Capture the **PR URL** — the ServiceNow Change Request (`servicenow-change-management`)
   references it. Post the PR link back in the PagerDuty incident notes.

## Out of scope (human approval required)
- Merging the PR, force-pushes, history rewrites, changes outside the root-cause fix,
  VNet/subnet/IAM changes.

## Verification
The PR is open against the correct repo/branch with a complete RCA-backed description and a
linked Change Request; CI (if any) is green. Report the PR URL.
