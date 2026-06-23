---
metadata:
  api_version: azuresre.ai/v2
  kind: Skill
name: rbac-audit
description: Use when an operator or a scheduled task requests a periodic RBAC / least-privilege audit of the Zava Learning resource group — enumerate the real role assignments effective on the group, correlate each identity against actual Activity-Log usage to find standing access that is never used, flag over-privileged and directly-assigned (versus group-governed) identities and stale troubleshooting access, and recommend least-privilege corrections. Read-only; produces findings for a report.
tools:
  - RunAzCliReadCommands
  - GetAzCliHelp
  - SearchMemory
  - ExecutePythonCode
  - microsoft-learn_microsoft_docs_search
---

## Zava Learning — RBAC / Least-Privilege & Access-Usage Audit

Resource Group: `@@RG@@`. **Read-only audit — never create, modify, or remove a role assignment.**
This is a weekly governance review of *who can do what here, and whether they actually use it*. The
goal is real least-privilege hygiene: surface over-privileged identities, direct (ungoverned)
assignments, and **standing access that has gone unused** so a human can clean it up.

### Identity naming policy (governance reports name their subjects)
The principals under audit (their display name / UPN / objectId and role) are the **subject** of this
report — show them; an RBAC finding that hides the identity is useless. This is NOT the learner-PII
the redaction standard protects. Still apply `SearchMemory("zava-redaction")` `redact()` to strip any
**secrets, tokens, credentials, or learner/customer PII** that happen to appear, and never print
secret values — but DO name the admins, service principals, and groups being audited.

**Where the names come from (do NOT call Microsoft Graph):** take the identity name from the
`principalName` field that `az role assignment list` already returns, plus `principalType`. Do **not**
run `az ad user/group/sp list|show` or `az rest https://graph.microsoft.com/...` to resolve names or
look up guest/enabled status — the SRE Agent's managed identity has **no Graph directory-read
permission**, so those calls fail with `Insufficient privileges` AND are gated as `PendingAuthorization`,
which would stall this unattended weekly run. If a `principalName` is blank, identify that principal by
its `principalId` (objectId) + `principalType` and note "display name unavailable (directory lookup not
permitted)". A UPN containing `#EXT#` (when present in `principalName`) still indicates a guest.

### 1. Enumerate the real assignments effective on the RG
- All assignments scoped at or above the RG (this includes subscription/management-group inheritance —
  most access here is inherited):
  `az role assignment list --scope /subscriptions/<sub>/resourceGroups/@@RG@@ --include-inherited -o json`.
- For each: capture `principalName`, `principalType` (User / Group / ServicePrincipal), `roleDefinitionName`,
  `scope`, `description`, and `createdOn` where present. These fields are sufficient — everything you
  need to name and classify a principal is already in this output; no follow-up directory calls.

### 2. Correlate against ACTUAL usage (the key step, BEST-EFFORT)
Standing access that is never exercised is the prime cleanup target. Pull who has actually operated in
this RG and join it to the assignment list:
- The `-g` server-side filter on the activity log is unreliable here — query **subscription-wide** and
  filter client-side on `resourceGroupName == @@RG@@`. Use a **bounded, valid** query (the API rejects
  oversized requests with HTTP 400 "Bad Request"): a window of **30 days** and **`--max-events 1000`**,
  e.g. `az monitor activity-log list --start-time <UTC now-30d> --end-time <UTC now> --max-events 1000 -o json`.
  If that still 400s, halve the window (e.g. 7-14 days) and/or add `--query "[].{c:caller,r:resourceGroupName,t:eventTimestamp}"`.
  Then keep events where `resourceGroupName` is the RG; aggregate distinct `caller` values (these are
  UPNs or principal objectIds) with their last-seen timestamp.
- A principal that **holds a privileged role but appears as no caller in the window** is
  *standing-but-unused access* → recommend removal / down-scoping. (Activity Log is control-plane,
  ~90-day retention; state the window you actually used and note data-plane-only usage may not appear.)
- **Usage correlation is best-effort and MUST NOT block the report.** If the activity-log query keeps
  failing or returns nothing, do **not** retry indefinitely — after at most two adjusted attempts, record
  "usage data unavailable (control-plane query limit / retention)" against the affected identities and
  **continue** to the findings table and the branded deck using the assignment, scope, identity-type,
  and `createdOn`/`description` signals alone. Finishing the audit with a clear caveat is required;
  stalling on usage correlation is a failure.
- Do **not** attempt Entra sign-in logs or any other Microsoft Graph query (e.g.
  `az rest https://graph.microsoft.com/...auditLogs/signIns`) — the agent identity is not permitted and
  the call would stall on approval / fail. Base usage purely on the Activity Log window above.

### 3. Flag findings with impact-based severity (see `zava-audit-report` model)
- **SEV1** — Owner / User Access Administrator / Contributor held **directly by a User** (not via a
  group), especially with **no usage in the lookback window**; any privileged role on a **guest**
  (`#EXT#` in `principalName`) or orphaned principal; a clearly **temporary / break-glass** grant still present (telltale
  `description` like "temp", "break-glass", "INC-####", "troubleshooting", or an old `createdOn`).
- **SEV2** — an identity assigned **broader scope than needed** (privileged role at subscription/MG
  scope when only this RG is used), or a privileged role with **stale usage** (used long ago, not
  recently); a direct privileged grant that should be **group-governed and PIM-eligible**.
- **SEV3** — non-privileged direct assignment that should be group-governed; duplicate / redundant
  assignments; a standing role that should be converted to a **PIM eligible (just-in-time)** assignment.

### 4. Recognise legitimate platform identities (avoid false positives)
This subscription carries first-party security & governance service principals — **do not flag them as
risky**; acknowledge them as expected. These include Microsoft Defender for Cloud, Azure Policy /
remediation, AzSecPack, Wiz (`Wiz*`), Illumio, Connected Machine / Arc, Backup / Recovery Services,
and the SRE Agent's own managed identity and the platform's user-assigned identity (AcrPull, Key Vault
Secrets User, Network Contributor for the agent). Note them in an "expected platform identities"
appendix rather than the findings table. Focus the findings on **human users** and **non-platform**
principals.

### 5. Produce the findings + recommendations
One row per finding:
`Identity (type) · Role · Scope (direct/inherited) · Governance (direct/group) · Last used · Finding · Severity · Recommendation`.
Sort SEV1 → SEV3. Recommendations should be concrete least-privilege moves: remove unused standing
access; replace a direct user grant with **membership in a governed group**; convert standing
privileged grants to **PIM eligible (JIT)**; down-scope from subscription to the specific RG/resource;
remove stale break-glass access. Also produce a posture summary (Healthy / Needs attention / At risk,
counts by severity, # of identities with privileged-but-unused access, the single most important
action). Cite Azure least-privilege / PIM guidance via `microsoft-learn_microsoft_docs_search`.

### 6. Hand off to the branded report
This skill does not remediate. Pass the posture summary, the findings rows (each with its severity),
and the recommendations to the `zava-audit-report` skill, which renders the single branded,
downloadable PowerPoint deck and returns its download link. Surface that link to the operator.
