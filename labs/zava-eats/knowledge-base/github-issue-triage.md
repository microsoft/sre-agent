# Grubify App Issue Triage Runbook

Triage incoming customer issues for the Grubify food ordering application. Focus on issues with **[Customer Issue]** in the title — these are user-reported problems. Classify them, add labels, and post a triage comment.

---

## Step 1: Get Open Issues

Fetch all open issues from the repo. Focus on issues that have **[Customer Issue]** in the title and are unassigned/unlabeled. Skip issues that don't have the [Customer Issue] prefix (those are internal agent-created reports).

---

## Step 2: Handle Each Issue Based on Current State

For each open issue, check its current state:

### Case A: Already triaged (bot comment + labels exist, no updates since)
→ **Skip it** — already handled.

### Case B: Has labels but NO bot comment
This happens when another subagent (incident-handler or code-analyzer) created the issue with labels already applied. The issue is valid and already categorized.

**Post an acknowledgment comment:**
```
🤖 **Grubify SRE Agent Bot**

This issue has been reviewed. Labels are already applied and the team is looking into it.

Issue summary: [brief summary from issue body]
Current labels: [list existing labels]

🔍 Status: **Under investigation by the team**
```

→ Do NOT change existing labels — they were set by the creating agent.

### Case C: Has a bot comment but labels were removed or changed
→ **Re-triage** — classify again following Step 3 below.

### Case D: No labels, no bot comment (new untriaged issue)
→ **Triage it** — continue to Step 3.

---

## Step 3: Classify the Issue

Read the title and description. Pick ONE category:

| Category | What it looks like |
|----------|-------------------|
| **Bug** | "Error", "500", "crash", "not working", "broken", "OOM", "memory leak" |
| **Performance** | "slow", "timeout", "high CPU", "high memory", "latency" |
| **Feature Request** | "Would be nice to have...", "Please add...", suggestions |
| **Question** | "How do I...", "Where can I find...", configuration help |

---

## Step 4: Handle Bugs

### Pick a sub-category:

| Type | Examples |
|------|----------|
| **API Bug** | Cart API errors, order failures, menu not loading, 500 errors |
| **Frontend Bug** | UI broken, page not rendering, CORS errors, failed to load |
| **Infrastructure** | Container restarts, OOM kills, deployment failures, scaling issues |
| **Memory Leak** | Memory growing over time, cart accumulating without cleanup |

### Check if user provided enough info:

**Need at minimum:**
- What happened (error message or behavior)
- Steps to reproduce
- Which endpoint or page was affected

### If info is missing:

**Post comment:**
```
🤖 **Grubify SRE Agent Bot**

Thanks for reporting this issue with Grubify. To investigate, we need:
- [list what's missing]

⚠️ Status: **Waiting for info from user**
```

**Add labels:** `needs-more-info` + sub-category label

### If info is complete:

**Post comment:**
```
🤖 **Grubify SRE Agent Bot**

Thanks for the details. This bug report is ready for investigation.

Issue summary: [brief summary]
Affected component: [API / Frontend / Infrastructure]
Severity: [Critical / High / Medium / Low]

✅ Status: **Ready for investigation**
```

**Add labels:** `bug` + sub-category label + severity label

**Sub-category labels:**
- `api-bug`
- `frontend-bug`
- `infrastructure`
- `memory-leak`

---

## Step 5: Handle Performance Issues

**Post comment:**
```
🤖 **Grubify SRE Agent Bot**

Performance issue identified.

Affected area: [API response time / Memory usage / CPU / Scaling]
Recommended investigation: [Check metrics / Review logs / Load test]

🔧 Status: **Performance investigation needed**
```

**Add labels:** `performance` + relevant sub-category

---

## Step 6: Handle Feature Requests

**Post comment:**
```
🤖 **Grubify SRE Agent Bot**

Thanks for the suggestion for Grubify!

[If feature exists: explain how to use it]
[If new: "This is a great idea. We'll consider it for future development."]

💡 Status: **Feature request**
```

**Add labels:** `enhancement`, `feature-request`

---

## Step 7: Handle Questions

**Post comment:**
```
🤖 **Grubify SRE Agent Bot**

[Answer the question based on the grubify-architecture knowledge base document]

📖 Status: **Question answered**
```

**Add labels:** `question`, `answered`

---

## Labels Cheat Sheet

| Situation | Labels to Add |
|-----------|---------------|
| Bug, need more info | `needs-more-info` + sub-category |
| Bug, ready to investigate | `bug` + sub-category + severity |
| Performance issue | `performance` + sub-category |
| Feature request | `enhancement`, `feature-request` |
| Question | `question`, `answered` |

**Severity labels:**
- `critical` — App completely down, all users affected
- `high` — Major feature broken, many users affected
- `medium` — Feature partially broken, workaround exists
- `low` — Minor issue, cosmetic, edge case

---

## Comment Template

Always start with: `🤖 **Grubify SRE Agent Bot**`

Always end with a status line:
- `⚠️ Status: **Waiting for info from user**`
- `✅ Status: **Ready for investigation**`
- `🔧 Status: **Performance investigation needed**`
- `💡 Status: **Feature request**`
- `📖 Status: **Question answered**`
