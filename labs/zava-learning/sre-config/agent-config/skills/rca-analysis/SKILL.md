---
metadata:
  api_version: azuresre.ai/v2
  kind: Skill
name: rca-analysis
description: Use to produce the root-cause analysis narrative for a resolved or mitigated Zava Learning incident — the incident timeline, the trigger vs. latent root cause (5-Whys), contributing factors, and how to present them. Defines the RCA section format; its output is used in the before/after, recommendations, and reporting deliverables.
tools:
  - SearchMemory
  - GetActivityLogsSummary
  - GetChangeHistory
  - QueryAppInsightsByResourceId
  - QueryLogAnalyticsByResourceId
  - RunAzCliReadCommands
  - ExecutePythonCode
---

## Zava Learning — Root Cause Analysis

Produce the analytical heart of the incident report: a defensible, evidence-backed RCA in the
house format. Resource Group: `@@RG@@`. Services: `learner-portal`, `course-api`,
`assessment-api`. Retrieve `zava-brand` and `zava-report-template` with `SearchMemory` and
follow the Root cause + Timeline sections of the template.

## Gather evidence first (never assert without it)
- **Timeline:** reconstruct detection → mitigation → durable fix from `GetActivityLogsSummary`,
  `GetChangeHistory`, and the relevant App Insights / Log Analytics queries
  (`QueryAppInsightsByResourceId`, `QueryLogAnalyticsByResourceId`) filtered by the affected
  `cloud_RoleName`. Every timeline row cites a source.
- Align the symptom onset to the nearest config/revision/deployment change.

## Structure the RCA
1. **What happened** — the symptom and customer impact in plain language (no cause in the title).
2. **Timeline** — UTC table: time · event · evidence/source.
3. **5-Whys (MANDATORY, render the ladder)** — write an explicit, numbered Why-ladder, not a
   one-line summary. Start from the student-visible symptom and ask "why?" repeatedly until you
   reach the latent root cause — typically five steps:
   - **Why 1:** students saw <symptom> → because <immediate technical effect>
   - **Why 2:** <effect> → because <misbehaving component/config>
   - **Why 3:** <component> misbehaved → because <the change/state that caused it>
   - **Why 4:** that change happened → because <how it got introduced / trigger>
   - **Why 5 (latent root cause):** it was possible/undetected → because <missing guardrail or gap>

   Each rung cites its evidence. Then state the **trigger** (what set it off now) separately from
   the **latent cause** (the condition that made it possible) — the latent cause is Why 5. Render
   this ladder in the RCA section; never collapse it to a single trigger/latent two-liner.
4. **Contributing factors** — gaps in detection, guardrails, or process that widened impact.
5. **Why it was hard / easy to detect** — informs the detective recommendations.

## Presentation rules
- Symptom-only headings; the root cause appears in the body, never in a title.
- The 5-Whys ladder is ALWAYS rendered under a literal **`5 Whys`** heading (`### 5 Whys` /
  `<h3>5 Whys</h3>`) inside the Root Cause section, with five numbered rungs each on its own line
  (`Why 1:` … `Why 5:`). A request-path Mermaid diagram may accompany it but never replaces it.
- Distinguish facts (with evidence) from hypotheses (label clearly).
- Keep it blameless: systems and conditions, not individuals.

## Outputs
This skill produces, for the wider investigation: the **fault class** (connectivity/config/RBAC vs.
performance/availability — so `evidence-before-after` picks the right visual), the confirmed
before/after time windows and affected metrics or config state (used by `evidence-before-after`),
the unresolved detection/guardrail gaps (used
by `recommendations-next-steps`), and the finished RCA section (used by `zava-reporting`). Record
them clearly so the agent can use them in whichever skill it runs next.

## Verification
The RCA names a specific, evidence-backed root cause; an explicit numbered 5-Whys ladder is
rendered (symptom → … → latent cause), not a single trigger/latent two-liner; trigger and latent
cause are separated; every timeline entry is sourced; the section matches `zava-report-template`.
