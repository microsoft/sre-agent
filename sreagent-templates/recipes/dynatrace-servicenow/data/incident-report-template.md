# Incident Report Template

## Summary
<!-- One-paragraph description: what happened, when, and business impact. -->

**Incident ID**: [ServiceNow / Azure Monitor Alert ID]
**Severity**: [P1 / P2 / Sev0-4]
**Duration**: [Start time] - [End time] ([total duration])
**Status**: [Resolved / Mitigated / Ongoing]

---

## Impact

- **Users Affected**: [Number or percentage]
- **Services Affected**: [List endpoints/services]
- **Data Loss**: [Yes/No]
- **SLA Impact**: [Uptime SLA breached?]

---

## Timeline

| Time (UTC) | Event |
|---|---|
| HH:MM | Alert triggered |
| HH:MM | SRE Agent investigation started |
| HH:MM | Root cause identified |
| HH:MM | Remediation executed (with approval) |
| HH:MM | Service restored |
| HH:MM | Verification confirmed recovery |
| HH:MM | Incident closed |

---

## Evidence

### Azure Monitor
<!-- Distributed traces, error rates, service flow showing the failure path. -->

### App Insights / Log Analytics
<!-- KQL queries, request metrics, dependency failures. -->

### Activity Log
<!-- Recent deployments, config changes, scaling events from Azure Activity Log. -->

### GitHub
<!-- Recent commits/PRs around the failure time. -->

---

## Root Cause

<!-- Technical explanation of why the incident occurred. -->

**Category**: [Database / Network / Deployment / Configuration / Code Bug / Capacity]

---

## Remediation

### Actions Taken by SRE Agent
1. [Automated action with hook approval reference]
2. [Verification step]

### Follow-Up Actions
| Action | Owner | Due Date | Status |
|---|---|---|---|
| [Fix description] | [Team] | [Date] | [Open/Done] |

---

## Compliance Check

<!-- Was the deployment that caused this incident compliant? -->
- Deployment method: [CI/CD Pipeline / Portal / CLI]
- Compliance status: [COMPLIANT / NON-COMPLIANT]
- Caller identity: [Service Principal / User Principal]
- Image labels verified: [Yes/No]
