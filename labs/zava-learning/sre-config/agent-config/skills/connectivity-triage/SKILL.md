---
metadata:
  api_version: azuresre.ai/v2
  kind: Skill
name: connectivity-triage
description: Use for any Zava Learning incident where students cannot reach the platform or actions fail at the network/edge layer — quiz launches failing, portal 5xx, requests timing out, or backends appearing unhealthy. Traces the full request path (Application Gateway -> NSG -> Container Apps internal load balancer -> APIs) from telemetry and Azure config, finds the broken hop, and remediates within the permitted-action boundary.
tools:
  - RunAzCliReadCommands
  - RunAzCliWriteCommands
  - GetAzCliHelp
  - SearchMemory
  - microsoft-learn_microsoft_docs_search
  - microsoft-learn_microsoft_docs_fetch
---

## Zava Learning — Connectivity / Edge Incident Runbook

Resource Group: `@@RG@@`. Public entry: Application Gateway -> learner-portal (Container App,
internal ingress) -> course-api / assessment-api (environment-internal). App Insights
`cloud_RoleName` values: `learner-portal`, `course-api`, `assessment-api`.

Diagnose root cause from telemetry and configuration, then remediate within the boundary below.
Do NOT guess the cause from the alert name — the alert is symptom-only by design.

## Trace the path, hop by hop
1. **Application Gateway** — backend health (`az network application-gateway show-backend-health`),
   probe path/host, HTTP settings. A probe pointed at a path the portal doesn't serve marks the
   backend unhealthy and yields 502s.
2. **NSG on the Container Apps subnet** — list effective rules. A higher-priority DENY can beat a
   lower-priority ALLOW (priority inversion) and silently block App Gateway -> apps.
3. **Container Apps internal load balancer / ingress** — revision health, replica counts.
4. **APIs** — are `course-api` / `assessment-api` answering and healthy?

Use the built-in network troubleshooting skills (network_connectivity_troubleshoot,
application_gateway_troubleshoot, load_balancer_troubleshoot, network_topology_mapper) to go deep
on any hop. Filter App Insights/LAW queries by the relevant `cloud_RoleName`.

## Permitted autonomous actions
- **Neutralize a blocking NSG rule with a non-destructive update**, not a delete: run
  `az network nsg rule update ... --access Allow` (or raise the DENY rule's `--priority` above the
  ALLOW). The write tool restricts `delete`/`remove`, and an `update` achieves the same effect — so
  never reach for `az network nsg rule delete`.
- Correct an Application Gateway probe path / HTTP settings back to a healthy configuration.
- Restart a Container Apps revision.

## Azure CLI usage (avoid avoidable command failures)
- **Do not pass `-o`/`--output` or `--query` to `RunAzCliReadCommands`.** The read tool already
  returns JSON — adding `-o json`, `-o table`, or a `--query` projection makes the command fail with
  a generic "Unknown error occurred." Run the plain command (e.g. `az network nsg rule list
  --nsg-name ... --include-default`) and pick out the fields you need from the JSON in your reasoning.
- If any read still returns "Unknown error occurred," just **retry the plain command once** — the
  first tool call in a session can fail transiently. Do not conclude the resource is broken.
- Always pass `--subscription` and prefer resource IDs to avoid ambiguity. Consult `GetAzCliHelp`
  before an unfamiliar write flag rather than guessing syntax.

## Incident communication (PagerDuty)
Record the request-path diagram and your diagnostic notes for the incident record. PagerDuty
acknowledgement, status/summary notes, and resolution are owned by the `pagerduty-incident-update`
skill.

## Code & change management
- For an Infrastructure-as-Code root cause, the infra lives under `infra/` in `@@REPO@@`
  (the NSG is defined in `infra/modules/network.bicep`). After the live mitigation, the durable
  fix is delivered as a GitHub pull request by the `pr-delivery` skill and recorded as a Change
  Request by `servicenow-change-management`.

## Out of scope (require human approval)
- VNet address-space changes, subnet deletion, IAM modifications, App Gateway SKU/tier changes.

## Verification
Re-check the hop you changed, confirm the public endpoint returns 200 on `/` and `/api/quiz/*`, and
confirm the alert auto-mitigated.
