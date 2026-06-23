# Zava Learning — Incident Report Template & Deliverable Skeleton

The canonical structure for the post-incident deliverable and its three packaged formats
(report, executive deck, email/Teams). Reporting skills retrieve this with `SearchMemory`
(memory name `zava-report-template`) and fill each section from the matching skill's output.
Apply the `zava-brand` standard for all styling. Omit a section only when it has no content;
never reorder.

## Canonical report structure (Markdown deliverable)

1. **Header** — `ZAVA Learning · Site Reliability · Incident Report · <UTC date>`,
   incident id / PagerDuty number, severity, report status (Draft / Final).
2. **Executive summary** — 3–5 bullets a VP can read in 30s: what broke (symptom), who/how
   many were impacted, how long, root cause in one line, current status. No jargon.
3. **Incident overview** — table: Symptom · Severity · Services affected (`learner-portal`,
   `course-api`, `assessment-api`) · Customer impact · Detected at · Mitigated at · Resolved
   at · Total duration.
4. **Timeline** — table (UTC time · event · source/evidence) from detection → mitigation →
   durable fix. Owned by the `rca-analysis` skill.
5. **Root cause analysis** — narrative + an explicit, rendered **5-Whys ladder** (numbered
   Why 1 → … → Why 5/latent cause, each rung evidence-backed) + contributing factors; trigger
   vs. latent cause clearly separated. Never collapse the ladder to a one-line summary. Owned by
   `rca-analysis`. **The ladder is MANDATORY and must be rendered, not described:** the Root Cause
   section of every deliverable (Markdown and the packaged HTML) MUST contain a labeled subsection
   headed **`5 Whys`** (e.g. `### 5 Whys` / `<h3>5 Whys</h3>`) followed by exactly five numbered
   rungs, each on its own line beginning `Why 1:` … `Why 5:` (Why 5 = the latent cause). A report
   whose Root Cause section has no `5 Whys` heading, or fewer than five `Why N:` rungs, is incomplete
   and must NOT be finalized.
6. **Before / After** — metric comparison table (`metric · before · after · delta · target`)
   plus the rendered before/after charts. Owned by `evidence-before-after`.
7. **Remediation** — (a) live mitigation taken (NSG rule, revision rollback/restart),
   (b) durable fix: GitHub PR link, (c) ServiceNow Change Request number. Owned by
   `pr-delivery` + `servicenow-change-management`.
8. **Recommendations & next steps** — table (action · type [preventive/detective/process] ·
   owner · priority · target date · status). Owned by `recommendations-next-steps`.
9. **Artifacts & links** — a table listing **every** artifact created during the incident, each
   with a working link, so the reader can reach all of them from one place:
   | Artifact | Link |
   |---|---|
   | Incident report (HTML) | `[Open the HTML report](<download-link>)` — the attachment download link from `ExecutePythonCode` |
   | Durable-fix pull request | `[PR #<n>](<github-pr-url>)` |
   | ServiceNow Change Request | `[<CR number>](<servicenow-cr-url>)` |
   | PagerDuty incident | `[Incident #<n>](<pagerduty-incident-url>)` |
   | Evidence charts / deck (if produced) | `[Download the deck](<download-link>)` |
   **Every Link cell MUST be a clickable markdown hyperlink `[label](url)`** — never a bare URL, a
   naked id/number, or a relative path; only `[label](url)` renders clickable in the thread. Include
   the HTML report link explicitly — never omit it. Use the actual attachment download link the
   runtime returns, verbatim.
10. **Appendix** — KQL/queries used, raw evidence, links. Collapsible / last.

## Executive deck order (16:9, one idea per slide)

1. Title — symptom + severity + date + ZAVA wordmark.
2. Executive summary (the 3–5 bullets).
3. Customer impact (the one chart that shows the blast radius / recovery).
4. Timeline (compact horizontal timeline).
5. Root cause (one diagram or 5-Whys ladder; symptom → cause).
6. Before / After (side-by-side charts with deltas).
7. What we did (mitigation → PR → Change Request).
8. Recommendations & next steps (owners + dates).
9. Closing — status + contacts + confidentiality footer.

## Email / Teams summary (deliverable-only)

- **Email (HTML, `zava-brand` email layout):** subject
  `[ZAVA SRE] <symptom> — <SEVx> — <Resolved|Mitigated|Investigating>`; sections: Summary,
  Impact, Root cause (1–2 lines), What we did, Recommended actions (checklist), links to the
  full report / PR / CR / PagerDuty.
- **Teams (Adaptive Card JSON, `zava-brand` card layout):** FactSet (Severity, Status,
  Duration, Users impacted), one-line root cause, top 3 next steps, OpenUrl buttons.

## Quality bar (every deliverable must pass)
- Title and any alert reference are **symptom-only** — root cause never leaks into a heading.
- The Root Cause section renders a **`5 Whys`** subsection with five numbered `Why 1:`…`Why 5:`
  rungs — never just a narrative or a one-line trigger/latent summary.
- Every claimed recovery is backed by a post-fix number in Before/After.
- All visuals are really rendered, brand-colored, and labeled.
- No secrets/PII. Confidentiality footer present.
