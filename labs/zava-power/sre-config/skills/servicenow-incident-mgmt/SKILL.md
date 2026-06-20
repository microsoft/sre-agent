---
metadata:
  api_version: azuresre.ai/v2
  kind: Skill
name: servicenow-incident-mgmt
description: Manage ServiceNow incident lifecycle: create incidents, add work notes for audit trail, and resolve tickets. Use this skill whenever an investigation needs to be documented in ServiceNow. Follows the PowerGrid incident report template for field mapping and priority classification.
tools:
  - CreateServiceNowIncident
  - UpdateServiceNowWorkNotes
  - ResolveServiceNowIncident
  - LookupServiceNowIncident
  - UploadChartToServiceNow
---

# ServiceNow Incident Management

## Overview
This skill manages the full ServiceNow incident lifecycle for PowerGrid services.
Use it to create, update, and resolve incidents with a complete audit trail.

## When to Use
- An investigation has been triggered (by alert or manually)
- You need to document findings during an investigation
- A remediation has been completed and needs to be recorded
- An incident needs to be resolved with root cause and fix details
- You need to attach a metrics chart to an incident

## Workflow

### Creating an Incident
1. Use CreateServiceNowIncident with:
   - short_description: "[PowerGrid] <service>: <brief symptom>"
   - description: Alert details, affected service, initial observations
   - urgency: 1 (Critical), 2 (High), 3 (Medium), 4 (Low)
   - impact: 1 (High), 2 (Medium), 3 (Low)
   - category: "Software"
2. Save the returned incident number (INC00XXXXX) for subsequent updates
3. Include the incident URL in work notes: https://{{SN_INSTANCE}}.service-now.com/incident.do?sysparm_query=number=<INC_NUMBER>

### Adding Work Notes (Audit Trail)
Use UpdateServiceNowWorkNotes at each investigation phase. Each note
should be a concrete observation from your investigation — not a
template phrase. Suggested phases:
- "Investigating: <what query / what tool>..."
- "Finding: <specific exception/log/metric with file:line if applicable>"
- "Correlation: <build/commit/revision tied to onset>"
- "Remediation: <what action was taken>"
- "Validation: <which probe passed, which metric returned to baseline>"

### Resolving an Incident
Use ResolveServiceNowIncident with:
- incident_id: The INC number from creation
- resolution_notes: Root cause + what was done + permanent fix status

### Looking Up Existing Incidents
Use LookupServiceNowIncident to:
- Check if a related incident already exists before creating a duplicate
- Search by short description or keywords to find existing tickets
Note: Native ServiceNow tools now accept INC numbers directly — no sys_id translation needed.

### Attaching a Metrics Chart
Use UploadChartToServiceNow to generate a chart and (a) attach it to the
incident AND (b) get an inline image you can render in the SRE Agent
thread:
1. Pass the incident number and a KQL query that returns time-series data
2. The tool runs the query, plots with matplotlib, uploads the PNG to
   SNOW (Attachments tab), AND returns:
   - `snow_attachments_url` — link to the SNOW incident's attachments
   - `markdown` — a ready-to-paste `![title](data:image/png;base64,...)`
     string that renders the chart inline in the SRE Agent thread
3. Use a descriptive chart_title (e.g. "Disk Usage During Incident" or
   "Request Latency Spike")
4. **MANDATORY**: include the returned `markdown` field VERBATIM in your
   next assistant reply so the chart is visible in the thread. Then add
   a work note referencing the SNOW attachment:
   `UpdateServiceNowWorkNotes("Metrics chart attached — see Attachments
   tab. Inline preview rendered in SRE Agent thread.")`
Example KQL: requests | where timestamp > ago(30m) | summarize avg(duration), count() by bin(timestamp, 1m)

# ServiceNow Incident Report Template

## Purpose
Use this template when filing or updating ServiceNow incidents for the PowerGrid utility portal. The SRE Agent should populate these fields during investigation and include them in the incident report.

---

## ServiceNow Fields

| Field | Value / Guidance |
|-------|------------------|
| **Short description** | `[PowerGrid] <service-name>: <brief symptom>` — e.g., `[PowerGrid] outage-api: HTTP 503 on all endpoints` |
| **Description** | Detailed description including affected service, symptoms, error codes, and initial findings |
| **Category** | `Software` |
| **Subcategory** | `Application` or `Container Platform` |
| **Priority** | P1 (Critical) / P2 (High) / P3 (Medium) / P4 (Low) — see priority matrix below |
| **Impact** | 1-High / 2-Medium / 3-Low |
| **Urgency** | 1-High / 2-Medium / 3-Low |
| **Assignment group** | `PowerGrid-SRE` |
| **Assigned to** | Auto-assigned or on-call engineer |
| **Configuration item** | `{{AZ_APP_PREFIX}}-<service>` (e.g., `{{AZ_APP_PREFIX}}-outage`) |
| **Business service** | `PowerGrid Utility Portal` |

---

## Priority Matrix

| Impact \ Urgency | High | Medium | Low |
|-------------------|------|--------|-----|
| **High** (all users affected) | P1 — Critical | P2 — High | P3 — Medium |
| **Medium** (partial users) | P2 — High | P3 — Medium | P4 — Low |
| **Low** (minimal impact) | P3 — Medium | P4 — Low | P4 — Low |

---

## Incident Report Body Template

Use the following markdown structure for the incident description and work notes:

```markdown
# Incident Report: <short description>

- **Incident ID:** <ServiceNow INC number>
- **Service:** <container-app-name> (rg: <resource-group>)
- **Environment:** Production / Staging / Development
- **Severity:** P1 / P2 / P3 / P4
- **Status:** Investigating / Identified / Mitigated / Resolved

---

## Summary

<2-3 sentences: what happened, what was observed, who is affected.>

Example: "The outage-api service ({{AZ_APP_PREFIX}}-outage) began returning HTTP 503 errors
on all endpoints at approximately 14:30 UTC. All outage reporting and lookup functionality
is unavailable. Customer-facing portal shows error messages for outage-related features."

---

## Impact

- **User Impact:** <description of user-facing impact>
- **Services Affected:** <list of affected services>
- **Estimated Users Affected:** <count or percentage>
- **Revenue Impact:** <if applicable>

---

## Timeline (UTC)

| Time (UTC) | Event |
|------------|-------|
| HH:MM | First anomaly detected (alert fired / user report) |
| HH:MM | Investigation started |
| HH:MM | Root cause identified |
| HH:MM | Remediation applied |
| HH:MM | Service restored / Incident resolved |

---

## Root Cause

<Technical explanation of what caused the incident. **Must include the
actual code-level cause**, not a paraphrase. Quote the offending
function and the exact source lines (≤5 lines, with file path and
line numbers) from the diagnosis skill's `code_cause` block. State
the mechanism in plain English: WHICH function, WHAT it does, WHY it
produces the observed symptom, by HOW MUCH (latency added, % of
requests affected, etc.). If the cause is a config/env delta, also
include `config_delta` showing old → new value and the deploy
artifact line that introduced it.>

Required shape (fill from the diagnosis skill's `code_cause` block —
do NOT invent values, do NOT paraphrase):

"<file path>:<line range> — `<function name>` (commit <sha>, build
#<n>) <one-line description of the change>:

```<lang>
<verbatim ≤5 lines of source from that location>
```

<Plain-English mechanism: WHICH function/line/constant, WHAT it does
or what input triggers it, WHY it produces the observed symptom, by
HOW MUCH (latency added, % requests affected, exception rate, etc.).
WHY tests/health checks didn't catch it, if known.>"

---

## Evidence

### Logs
<Paste relevant log excerpts or KQL query results>

### Metrics
| Metric | Before Incident | During Incident | After Fix |
|--------|----------------|-----------------|-----------|
| Error Rate | 0% | 100% | 0% |
| Response Time | 150ms | N/A (503) | 145ms |
| Restart Count | 0 | 0 | 0 |

### KQL Queries Used
<Include the KQL queries used during investigation for reproducibility>

---

## Resolution

<What was done to fix the issue. Include the exact commands or API
calls run, the new revision name produced (if any), and the UTC time
the service returned to healthy state. Be specific — paste the
command, don't describe it.>

---

## Prevention

### Immediate Actions
- [ ] <Action item 1 — e.g., add deployment validation to prevent FORCE_ERROR in production>
- [ ] <Action item 2 — e.g., add pre-deployment health check gate>

### Long-Term Improvements
- [ ] <Improvement 1 — e.g., implement deployment approval workflow>
- [ ] <Improvement 2 — e.g., add canary deployment with automatic rollback>
- [ ] <Improvement 3 — e.g., enhance monitoring to detect this class of issue faster>

### Monitoring Gaps Identified
- [ ] <Gap 1 — e.g., no alert for FORCE_ERROR env var presence>
- [ ] <Gap 2 — e.g., alert threshold too high, delayed detection>
```

---

## Labels / Tags for Classification

| Condition | ServiceNow Category | Tags |
|-----------|---------------------|------|
| HTTP 5xx errors | Application Failure | `http-5xx`, `service-unavailable` |
| OOM / Memory leak | Resource Exhaustion | `oom`, `memory-leak` |
| High latency | Performance Degradation | `latency`, `slow-response` |
| Crash loop | Application Crash | `crash-loop`, `startup-failure` |
| Bad deployment | Change-Related | `deployment`, `rollback` |

---

## Post-Incident Review Checklist

After the incident is resolved, ensure:
- [ ] Incident report is complete with all sections filled
- [ ] Timeline is accurate with UTC timestamps
- [ ] Root cause is clearly identified and documented
- [ ] Resolution steps are documented with exact commands
- [ ] Prevention actions are created as follow-up tasks
- [ ] Monitoring gaps are identified and ticketed
- [ ] Stakeholders are notified of resolution
- [ ] Knowledge base is updated if new failure mode discovered
