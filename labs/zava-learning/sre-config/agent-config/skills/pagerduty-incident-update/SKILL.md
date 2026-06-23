---
metadata:
  api_version: azuresre.ai/v2
  kind: Skill
name: pagerduty-incident-update
description: Use to keep the triggering PagerDuty incident in sync with the investigation and to close it out — acknowledge on engagement, mark the incident Mitigated the moment the live fix lands, post a concise symptom-only status/summary note (diagnosis, mitigation, links to the PR / Change Request), and resolve the incident only after the RCA and summary report are complete and recovery is verified. This is the PagerDuty communication and closure layer for a Zava Learning incident.
tools:
  - GetPagerDutyIncidentById
  - AcknowledgePagerDutyIncident
  - AddNoteToPagerDutyIncident
  - ResolvePagerDutyIncident
  - SearchMemory
---

## Zava Learning — PagerDuty Incident Update & Closure

Keep the PagerDuty incident that triggered this investigation current, and close it out cleanly.
Resource Group: `@@RG@@`. Services: `learner-portal`, `course-api`, `assessment-api`. Operate on
the PagerDuty incident id from the triggering event (confirm details with
`GetPagerDutyIncidentById` if needed). Capture the incident's `html_url` from the
`GetPagerDutyIncidentById` response — that is the operator-facing PagerDuty link the
`zava-reporting` Artifacts & links section surfaces as `[Incident #<n>](<html_url>)`. The bare
incident key (e.g. `Q1LXN8LVWLS9L6`) is NOT clickable — always pass the `html_url`.

## Acknowledge on engagement
As soon as you start working the incident, call `AcknowledgePagerDutyIncident` so responders see it
is owned and stop escalating. This must be a REAL tool call that returns success — do not write
"acknowledged" unless `AcknowledgePagerDutyIncident` actually executed in this thread. If that tool
is not available, this skill is not loaded: load `pagerduty-incident-update` and retry before doing
anything else.

## Mark MITIGATED immediately after the live fix
The moment the live mitigation is applied and the symptom clears (endpoint returns 200), post a
plain-text note with **`Status: Mitigated`** via `AddNoteToPagerDutyIncident`, summarising the live
fix in one or two lines. This marks the incident as mitigated for on-call while the incident stays
**acknowledged** — do NOT resolve here. The lifecycle is always: mitigate → mark Mitigated →
RCA + summary → resolve. (If `zava-reporting` or a triage skill swapped the active toolset and the
PagerDuty tools are gone, reload `pagerduty-incident-update` first.)

## Post the status / summary note
Use `AddNoteToPagerDutyIncident` to add a concise, factual note. **PagerDuty notes are PLAIN TEXT
only** — they do not render HTML or markdown, and they have a practical length cap. Never paste the
`zava-reporting` HTML email, the deck, or the Teams Adaptive Card into a note; those rich
deliverables go through their own channels. Instead post a short text summary and **link out** to
the rich artifacts. Keep it **symptom-only** — never put the root cause in a heading or opening line
(the alert is symptom-only by design). Pull the agreed summary from the completed `rca-analysis`
(and `zava-reporting`) via `SearchMemory`; do not re-derive it. Post (plain text):
- **Symptom & impact:** one line on what users experienced and the blast radius.
- **What we found / did:** the confirmed diagnosis and the live mitigation applied, in plain text.
- **Links:** the GitHub pull request (durable fix), the ServiceNow Change Request, and the full
  report/deck location if available.
- **Status:** Mitigated / Monitoring / Resolved.

Add interim notes at meaningful transitions (mitigation applied, recovery confirmed) rather than a
single dump at the end.

## Resolve — only after mitigation, RCA, and the summary report are all complete
Call `ResolvePagerDutyIncident` to close the incident **only once the incident is already MITIGATED,
recovery is proven, AND the RCA + summary report exist**: the public endpoint returns 200 on `/` and
`/api/quiz/*`, the underlying Azure Monitor alert has auto-mitigated, `evidence-before-after` confirms
the metric/state returned to healthy, and the RCA narrative and Zava report have been produced. Never
resolve straight after the live fix — that step only marks the incident Mitigated; resolution comes
after the RCA and summary. Before resolving, ensure a final note records the resolution and references
the PR and Change Request. Do not resolve on a hunch or while the alert is still firing.

## Rules
- Symptom-only language in every note title/opening — root cause goes in the body, never a heading.
- No secrets, credentials, or PII in notes. Apply the `zava-redaction` standard
  (`SearchMemory("zava-redaction")`) and mask anything sensitive as `[REDACTED:<CLASS>]` before
  posting — never paste a Key Vault secret value, connection string, or token into a note.
- Don't resolve before recovery is verified; if recovery is partial or unconfirmed, leave it
  acknowledged with a Monitoring note and say why.
- Blameless: describe systems and conditions, not individuals.

## Verification
The PagerDuty incident is acknowledged on engagement, marked **Mitigated** the moment the live fix
lands (a `Status: Mitigated` note), carries a concise symptom-only summary note with links to the PR
and Change Request, and is **resolved only after** the RCA and the Zava report are complete and
recovery is verified — i.e. the lifecycle ran mitigate → mark Mitigated → RCA + summary → resolve.
