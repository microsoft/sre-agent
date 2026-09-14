# Field Level Up: SRE Agent Hands-On Lab

## Scenarios and expected outcomes

| Scenario | Expected outcome |
| --- | --- |
| **Database Connectivity Incident (primary)** | An Azure Monitor alert routes to a commander that loads all three lab skills, delegates read-only RCA to application, PostgreSQL, and network specialists, and reconciles evidence. The attendee resets the fault and verifies recovery, then explicitly requests and separately approves a GitHub issue and an email. |
| **Proactive Service Health (optional)** | A manually invoked, paused read-only task returns evidence-backed findings in its own thread. Memory persistence and a Live Report remain available as separate, explicitly reviewed manual steps—not automatic outputs. |

The single [attendee walkthrough](../README.md) contains setup commands, prompts, readiness checks, and cleanup. Clone the public repository, then begin in VS Code with **File → Open Folder → sre-agent → labs → field-level-up** and open a PowerShell 7 terminal there. It does not assume the terminal starts at the repository root. There is one attendee-owned path, not a facilitator-provisioned fallback track.

> **Validation status:** all seven templates compile; 21 application tests, 66 deployment-script tests and 28 template/binding checks pass locally. The CLI tool remains approval-gated and policy setup requires V2. Provisioning, connector writes, alert routing, effective approval behavior, recovery, and cleanup still require an Azure rehearsal before workshop delivery. Agent extension schemas are unavailable to the compiler.

## Three independent setup parts

| Part | Entry point | Boundary and expected result |
| --- | --- | --- |
| **1. Sample application** | `azd up` using [azure.yaml](../azure.yaml) and [main.bicep](../main.bicep) | Creates the lab resource group, checkout App Service, private PostgreSQL/networking, identities, and telemetry; deploys bundled app source. **No SRE Agent or incident use cases.** Successful checkout is the baseline gate. |
| **2. New SRE Agent** | [deploy-agent.ps1](../scripts/deploy-agent.ps1) | Creates a new agent in that lab group; applies a common prompt, knowledge, telemetry/Azure Monitor integration, Stop evidence-checklist hook, and global permission policy. The hook is not an approval boundary. GitHub and email authentication are interactive prerequisites, not automated consent. |
| **3. Use cases** | [deploy-use-cases.ps1](../scripts/deploy-use-cases.ps1) | Takes `GitHubRepositoryUrl`, `EmailRecipients`, and `EmailConnectorName`; installs skills, subagents, response plan, alert, and paused task. First deploy with incidents disabled; enable only after manual checks with `EnableIncidents` and `ConfirmConnectionsReady`. No issue or email is sent by deployment. |

An Azure subscription with resource-creation/role-assignment permissions, a supported region, an authorized issue-write repository, and an authenticated email sender are prerequisites. No existing agent, Docker image, or database password is required. The sample uses elevated PostgreSQL administrator access for its managed identity and fixed `SELECT 1` query; use no real data and do not treat it as a production access model.

### Manual readiness is a gate, not a deployment side effect

- Verify fresh checkout request/dependency telemetry, resource-read access, Azure Monitor scanning, actual `Task` delegation, all three specialists, and all three skills. Inspect the response plan's exact alert title, Application Insights resource, Sev1/Sev2 matching, commander, and Review mode. Alert polling—not an action-group webhook—drives the integration.
- Configure GitHub integration that supports **issue creation/update** in the intended repository. A source-only connector or indexed repository is insufficient. Interactively authenticate the email connector, verify its exact name and sending account, and approve the intended recipient audience. Never ask the model to collect credentials; enter secrets only in the trusted connection/sign-in UI.
- Keep the agent and incident execution in **Review**. Inspect global, subagent, and relevant thread policy allows and active hook scopes/results before activation. Global `ask` is not absolute: scoped allows and user-hook `allow` results can bypass it, and Autonomous mode can bypass review. Prompts/hooks do not replace policy inspection.
- Do not allowlist `RunAzCliReadCommands`: its classifier is not a safe read-only boundary. CLI, connector, and delegation calls may request approval even during a read-only investigation. Do not promise unattended reads or grant broad persistent allows to remove friction.
- `ConfirmConnectionsReady` records the attendee's confirmation; it does not authenticate connectors or test every safety path. The activation script checks global policy and ARM Review mode without repairing mismatches; manual inspection remains required.

## Scenario 1: Database Connectivity Incident

A single outbound NSG rule blocks TCP 5432 from the App Service integration subnet to the private PostgreSQL subnet. Checkout fails while the web server remains healthy. Telemetry records the failures, the enabled Azure Monitor alert fires, and the incident response plan selects `database-incident-commander`.

1. **Inject:** the attendee runs the fault helper and generates traffic. The helper owns only `PostgreSqlFaultInjection`; it does not redeploy setup or use-case configuration.
2. **Load skills:** the commander loads `azure-monitor-rca`, `github-issue-followup`, and `email-incident-followup`. Loading a follow-up skill is not permission to publish.
3. **Delegate read-only RCA:** actual `Task` calls target `application-investigator` for impact/dependency evidence, `postgresql-investigator` for database health versus reachability, and `network-investigator` for DNS/routes/NSG path evidence. Independent investigations can run in parallel; missing capability must be reported rather than impersonated.
4. **Reconcile:** present timestamped evidence, uncertainty, the exact blocking rule when supported, and a narrow reversible mitigation. Review any read/delegation prompts; do not approve agent-driven resource changes. An alert alone does not prove the cause.
5. **Reset and validate:** the attendee runs the reset helper, restoring the same rule to Allow, and generates new checkouts. Verify repeated successes, fresh telemetry, and current alert state; missing data is not recovery and alert resolution may lag.
6. **GitHub follow-up:** explicitly request a draft, inspect the exact repository/operation/title/body and duplicate check, then separately approve the final issue create/update. Confirm the returned issue URL/ID in the thread.
7. **Email follow-up:** explicitly request another draft, inspect connector/sender/recipients/subject/body, then separately approve sending. Include the issue URL only if verified. Confirm the message receipt/status; provider acceptance is not proof of delivery. GitHub approval does not authorize email.

**Success evidence:** routed incident; actual activation of all three skills and results from all three specialists; evidence-backed RCA; operator reset and measured recovery; independently reviewed GitHub and email outcomes. If routing or either integration is unavailable, report the incomplete outcome—manual chat and drafts are not equivalent completion. Correlation markers, searches, and thread receipts support best-effort duplicate prevention, not exactly-once delivery. Reconcile unknown write outcomes before any retry or renewed approval.

## Scenario 2: Proactive Service Health (optional)

The provisioned `checkout-daily-health-report` selects `service-health-analyst`, uses **read-only** mode, and remains **Paused**. Manually run it once and inspect its execution thread. It returns findings, evidence links, missing data, risks, and recommended follow-up; a fresh lab does not have a seven-day baseline.

The task does **not** persist memory, create/update a Live Report, remediate, publish GitHub issues, or send email. Its name does not imply a report association. Keep the recurring schedule paused during the lab.

**Optional separate manual steps:** outside that task, use an interactive Review session to request/review saving a verified incident summary to memory and read it back. Separately use Live Report authoring to review/publish a health view from session telemetry and explicitly supplied findings. Use memory only after its existence is confirmed; label missing history. If unavailable, retain thread findings rather than claim persistence or report creation. Neither step establishes automatic task-to-memory or task-to-report updates.

## Reuse, reruns, and lifecycle

- **Reusable package:** [the plugin manifest](../use-cases/plugin/.plugin/plugin.json) exposes three generic installable skills. It is not a published marketplace offering. Skills contain workflow guidance, not credentials or infrastructure. [The companion template](../use-cases/main.bicep) supplies environment bindings, subagents, alert, response plan, and task; Part 2 supplies common prompts, knowledge, hooks, permissions, and agent configuration. Plugin installation alone does not provision these.
- **Reruns reapply lab-owned settings:** Part 3 can overwrite edited lab subagent/task settings and returns the task to Paused. Omitting `EnableIncidents` sets `enableIncidents=false`, which can disable an already enabled alert/plan. Part 2 refuses to overwrite differing nonempty global permissions; resolve those manually. Use only the dedicated fault/reset helper for the incident toggle.
- **Cleanup:** `azd down` deletes the lab resource group, **including the agent and resources added later by Parts 2 and 3**. Verify completion; partial cleanup can leave charges. GitHub issues, sent email, and external account consent are not deleted by Azure resource-group cleanup. Review those artifacts/consents separately.

## Session target

Allow roughly 30 minutes for the introduction and Part 1 deployment, then 60 minutes for agent/connector setup, disabled use-case inspection and activation, the primary incident, optional health work if time permits, and cleanup. This is an unmeasured session target, not a deployment or OAuth timing guarantee. Do not omit readiness or separate write approvals to fit the clock.

**Core message:** SRE Agent coordinates evidence-backed specialist investigation; humans review external writes separately. Repeatable health analysis, memory, and Live Reports are distinct capabilities with distinct execution and persistence boundaries.
