# Incident Report Template — Transient Alert Check Flow

## Summary
<!-- One-paragraph description: what happened, whether the alert was transient or persistent, and final outcome. -->

**Alert Rule**: [Azure Monitor alert rule name]
**Severity**: [Sev0-4]
**Resource**: [Affected Azure resource ID]
**Fired At**: [UTC timestamp]
**Transient Check Result**: [TRANSIENT — self-resolved / PERSISTENT — still firing after 15 min]
**Status**: [Closed-Transient / Investigating / Resolved / Mitigated]
**ServiceNow Ticket**: [INC number, if created]

---

## Transient Check Details

| Step | Time (UTC) | Result |
|---|---|---|
| Alert fired | HH:MM | Monitor condition: Fired |
| 15-min timer started | HH:MM | Observation window opened |
| 15-min timer completed | HH:MM | Re-checked alert state |
| Alert state at check | HH:MM | [Fired / Resolved] |
| Decision | HH:MM | [Closed as transient / Escalated to investigation] |

---

## Investigation (only for persistent alerts)

### Evidence

#### Azure Monitor Metrics
<!-- CPU, memory, request rate, error rate charts for the affected resource. -->

#### Application Insights
<!-- Exceptions, failed requests, dependency failures in the alert window. -->

#### Log Analytics
<!-- Correlated error logs, performance counters. -->

#### Activity Log
<!-- Recent deployments, config changes, scaling events. -->

---

### Root Cause

<!-- Technical explanation of why the alert is persistent. -->

**Category**: [Database / Network / Deployment / Configuration / Code Bug / Capacity]

---

### Remediation

#### Recommended Actions
1. [Specific action with exact command]
2. [Verification step]

#### ServiceNow Ticket Details
- **Ticket ID**: [INC number]
- **Urgency**: [1-High / 2-Medium / 3-Low]
- **Impact**: [1-High / 2-Medium / 3-Low]
- **Assignment Group**: [Team name]
- **Description**: [Summary of analysis included in ticket]
