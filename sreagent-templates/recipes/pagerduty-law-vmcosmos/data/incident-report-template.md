# Incident Report Template

## Summary
<!-- One-paragraph description of the incident: what happened, when, and the business impact. -->

**Incident ID**: [PagerDuty Incident ID]
**Severity**: [P1 / P2 / P3]
**Duration**: [Start time] — [End time] ([total duration])
**Status**: [Resolved / Mitigated / Ongoing]

---

## Impact

- **Users Affected**: [Number or percentage of impacted users]
- **Services Affected**: [List of impacted services/endpoints]
- **Data Loss**: [Yes/No — describe if applicable]
- **SLA Impact**: [Uptime SLA breached? Which SLOs were violated?]

---

## Timeline

| Time (UTC) | Event |
|------------|-------|
| HH:MM | Alert triggered — [description] |
| HH:MM | Investigation started |
| HH:MM | Root cause identified |
| HH:MM | Mitigation applied |
| HH:MM | Service restored |
| HH:MM | Incident closed |

---

## Evidence

### Metrics
<!-- Paste or link to relevant metric charts (CPU, memory, error rates, latency). -->

### Logs
<!-- Key log entries or KQL query results that helped identify the root cause. -->

### Activity Log
<!-- Relevant Azure activity log entries (deployments, config changes, scaling events). -->

---

## Root Cause

<!-- Detailed technical explanation of why the incident occurred. -->

**Category**: [Deployment / Configuration / Infrastructure / Code Bug / External Dependency / Capacity]

---

## Remediation

### Immediate Actions Taken
1. [Action taken to restore service]
2. [Action taken to mitigate impact]

### Follow-Up Actions
| Action | Owner | Due Date | Status |
|--------|-------|----------|--------|
| [Fix description] | [Team/Person] | [Date] | [Open/Done] |

---

## Prevention

### What Went Well
- [Things that helped during the response]

### What Could Be Improved
- [Gaps in monitoring, runbooks, or processes]

### Action Items
- [ ] [Preventive measure 1]
- [ ] [Preventive measure 2]
- [ ] [Update monitoring/alerts]
- [ ] [Update runbooks]
