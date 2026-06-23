---
metadata:
  api_version: azuresre.ai/v2
  kind: Skill
name: recommendations-next-steps
description: Use to produce the forward-looking recommendations and next steps for a Zava Learning incident — prioritized preventive, detective, and process actions with owners, target dates, and the risk of inaction. Its output is used in the zava-reporting deliverables.
tools:
  - SearchMemory
  - SearchIncidentKnowledge
  - microsoft-learn_microsoft_docs_search
  - ExecutePythonCode
---

## Zava Learning — Recommendations & Next Steps

Turn the RCA into a concrete, accountable action plan. Retrieve `zava-brand` and
`zava-report-template` with `SearchMemory`; follow the Recommendations section. Use
`SearchIncidentKnowledge` for related past incidents and `microsoft-learn_microsoft_docs_search`
to ground recommendations in Azure best practice.

## Derive actions from the RCA
Map each contributing factor and detection gap to an action. Classify every action:
- **Preventive** — stops recurrence (e.g. an NSG priority guardrail in IaC, a CI check for
  synchronous work on the request path, an autoscale floor so an API can't reach zero replicas).
- **Detective** — catches it sooner (a targeted alert/metric, a synthetic probe on
  `/api/quiz/*`, a dashboard).
- **Process** — runbook, ownership, review, or deployment-policy change.

## Present as an accountable table
Columns: `action · type · owner · priority (P1/P2/P3) · target date · risk if not done · status`.
- Priority by likelihood × impact of recurrence.
- Owners are roles/teams, not named individuals.
- Every recommendation is specific and testable — no "improve monitoring".
- Separate **immediate** next steps (this week) from **longer-term** hardening.

## Rules
- Recommend only what the evidence supports; don't pad the list.
- Note where a recommendation is already partially done (e.g. mitigation applied, guardrail PR
  open) and what remains.

## Verification
A prioritized, owned, dated action table where each row traces to an RCA finding, immediate vs.
long-term separated, ready for `zava-reporting`.
