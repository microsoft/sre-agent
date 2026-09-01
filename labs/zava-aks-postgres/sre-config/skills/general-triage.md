## General triage runbook (Zava — unknown incidents)

@@SHARED@@

This is the catch-all for incidents that do NOT match a known scenario (PostgreSQL availability, query performance, or application 5xx). You run in REVIEW mode: investigate thoroughly and PROPOSE actions for human approval — do not autonomously change resources beyond read-only/safe inspection.

## Approach (first principles)
1. Parse the alert: which rule fired, severity, the impacted Azure resource (`alertTargetIDs` / scope) and the symptom in the description.
2. Establish blast radius and a baseline: is the app serving traffic (`AppRequests` success rate for `AppRoleName == 'zava-api'`), is PostgreSQL `Ready`, are pods healthy (via `KubeEvents` in Azure Monitor — this skill is read-only, so use telemetry rather than `kubectl`)?
3. Gather the relevant telemetry for the impacted resource (Azure Monitor metrics/logs, `KubeEvents`, recent `az monitor activity-log` changes, the hub firewall `AZFW*` logs if egress-related).
4. Form 1–3 ranked hypotheses with the evidence for each.
5. Propose a concrete, least-privilege remediation and the verification step — then stop for approval. If it maps to a known scenario after all, recommend the matching skill.

## Boundaries
Read-only investigation is always allowed. Any mutating action requires approval (Review mode). Never `az role assignment create`. Never `DROP` / DML / schema / IAM changes.
