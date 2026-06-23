# AGENTS.md — conventions for the Zava Learning lab

Guidance for humans and agents extending this lab. The overriding principle:

## 1. Symptom-only alerts — never spoon-feed the diagnosis

Alerts describe what a **student or operator observes**, never the **cause**. The whole point of the
lab is that the SRE Agent diagnoses root cause from telemetry and live configuration.

- ✅ `Zava-quiz-launch-failing`, `Zava-portal-5xx-elevated`, `Zava-quiz-responses-slow`
- ❌ `nsg-deny-rule-blocking-traffic`, `appgw-probe-misconfigured`, `assessment-api-scaled-to-zero`

The same symptom (`Zava-quiz-launch-failing`) is reachable from **multiple** causes (NSG priority
inversion, App Gateway probe, an API at zero replicas). Routing is by **symptom**, not cause.

Likewise, the NSG fault rule is named plausibly (`legacy-cross-subnet-deny`), not
`the-bug` — the agent must recognise the **priority inversion**, not string-match a label.

## 2. Skill descriptions are the discovery key

Incident filters route to the **default agent**, which picks a skill by **description match**. Keep
skill descriptions concrete about the **symptom surface** they own (e.g. "students cannot reach the
platform / actions fail at the network/edge layer") — but do not enumerate alert names as the cause.

## 3. Diagnose from telemetry, hop by hop

The request path is `App Gateway → NSG → Container Apps ingress/LB → APIs`. Any hop can produce the
same symptom. A runbook should trace the path and use the built-in network skills
(`network_connectivity_troubleshoot`, `application_gateway_troubleshoot`, `load_balancer_troubleshoot`,
`network_topology_mapper`) to go deep — never assume the cause.

## 4. No committed secrets

PagerDuty and ServiceNow credentials are **parameters or environment variables**. Custom tools read
`SERVICENOW_URL/USER/PASS` from the environment. Never hardcode a key, URL, or password in Bicep,
YAML, or Python. `simulator/config.json` is generated locally and must not be committed with tokens.

## 5. Remediation boundary

Permitted autonomous actions: delete an NSG rule that blocks the apps subnet; correct an App Gateway
probe; restart/scale a Container App; roll back a revision. Out of scope (human approval): VNet/IAM
changes, SKU/tier changes, destructive data operations.

## 6. Code & change management

IaC or application root causes → the **`pr-delivery`** skill opens the **GitHub PR** (via
`ExecutePythonCode` + GitHub API; there is no native GitHub-PR tool) and the
**`servicenow-change-management`** skill raises a **ServiceNow Change Request** referencing the PR
with the RCA attached. Post-incident, the reporting skills (`rca-analysis`,
`evidence-before-after`, `recommendations-next-steps`, `zava-reporting`) produce the branded
deliverables. The custom agent selects and sequences whichever skills the situation needs — skills
declare their scope; they do not call each other. Incident lifecycle (ack/notes/resolve) happens in
**PagerDuty**.

## Adding a new scenario

1. Add `chaos/break-<x>.ps1` + `chaos/fix-<x>.ps1` (idempotent; discover the resource by name/tag).
2. Add an entry to `SCENARIOS` in `simulator/demo.py` (symptom title, break/fix scripts, symptom alert,
   probe path, agent).
3. If a new symptom alert is needed, add it to `infra/modules/alerts.bicep` with a **symptom-only** name.
4. Extend the relevant skill runbook in `sre-config/agent-config/skills/<name>/SKILL.md` if the
   new surface needs guidance — add tools to its `tools:` frontmatter list. Skills are applied
   (with their tools) by `scripts/configure-agent.mjs` via `srectl skill apply`.
