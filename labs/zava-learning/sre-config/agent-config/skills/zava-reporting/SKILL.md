---
metadata:
  api_version: azuresre.ai/v2
  kind: Skill
name: zava-reporting
description: Use to package a completed Zava Learning incident analysis for the audience. First present a branded in-thread executive summary (markdown with the before/after visuals inline), then produce the downloadable deliverables — a PowerPoint deck, an HTML email, and a Teams notification — using the Zava corporate template. The calling agent may narrow this to a subset (e.g. only the HTML report). Produces content and artifacts; it does not send them. Assembles the output of rca-analysis, evidence-before-after, recommendations-next-steps, and pr-delivery.
tools:
  - SearchMemory
  - ExecutePythonCode
  - PlotBarChart
  - PlotPieChart
---

## Zava Learning — Executive Reporting & Packaging

Assemble the final, branded incident deliverables. This is the packaging layer: it consumes the
RCA (`rca-analysis`), before/after evidence (`evidence-before-after`), recommendations
(`recommendations-next-steps`), and the PR / Change Request (`pr-delivery`,
`servicenow-change-management`), and renders them in the Zava house style.

**Deliverable-only:** produce the artifacts and content; do **not** auto-send. Hand the email
body and Teams card to the operator to send. **Scope:** by default produce all three deliverables;
if the calling agent asks for a subset (e.g. only the HTML report), produce only those and skip the
rest.

## Always load the standard first
Retrieve `zava-brand` (style) and `zava-report-template` (structure, deck order, email/Teams
formats) with `SearchMemory` and apply them exactly. Reuse the visual evidence already produced by
`evidence-before-after` — whether that is a before/after path diagram or comparison charts — rather
than re-rendering it.

## Present the in-thread executive summary FIRST
The incident thread renders **markdown + inline images**, not raw HTML — so do not paste the HTML
email into the thread. Instead, write the executive summary directly in the thread as brand-styled
**markdown** so the operator sees the full story in place:
- Use markdown structure: a symptom-only title line, then **Summary**, **Customer impact**,
  **Timeline** (compact table), **Root cause** (the rendered 5-Whys ladder from `rca-analysis`),
  **What we did**, **Before/After**, **Recommendations**, and an **Artifacts & links** section
  (see below). Apply the `zava-brand` tone and severity labels.
- **Show the visuals inline.** The `Plot*` tools post their image straight into the thread — reuse
  the `evidence-before-after` charts (or call `PlotBarChart` / `PlotPieChart` for a summary visual)
  so they render inline next to the narrative. For a connectivity/config fault, include the
  before→after path diagram as a fenced code block (ASCII) directly in the markdown.
- Keep every heading symptom-only; the root cause appears in the body, never in a title.

This in-thread summary is the primary, human-readable deliverable. The packaged artifacts below are
the takeaways the operator distributes outside the thread — produce all of them by default, or only
the subset the calling agent requests.

## Redact before emitting (mandatory)
Sensitive data must never reach the operator. Retrieve the scrubber with
`SearchMemory("zava-redaction")` and run its `redact()` function over the final HTML/markdown and any
deck text **before** writing the file or posting the text. Apply the same masking to the in-thread
markdown summary before posting. Never paste a Key Vault secret value, connection string, token, or
learner PII into the thread or any artifact.

## Write the report so it actually persists as a download
The downloadable artifacts (the HTML report, and a `.pptx` only if asked) are written into THIS
thread's files directory — `tmp/ThreadFiles/<threadId>/` — and the runtime persists them to blob
storage so the operator can download them. The single most common defect is a link that 404s because
the file was not actually on disk when persistence ran. The reliable recipe:
1. **Create the directory FIRST:** `mkdir -p tmp/ThreadFiles/<threadId>/` before writing anything.
2. **Write the file into that directory, then confirm it is really on disk and non-empty** (e.g.
   `ls -l` shows a non-zero byte count). Never announce a file you have not verified exists.
3. **Surface the link** as `/api/files/tmp/ThreadFiles/<threadId>/<filename>` — this `/api/files/...`
   path IS the correct, working download URL once the file has persisted. Use the real thread id and
   the real filename, rendered as a clickable markdown hyperlink `[label](url)`.

Build the file however is simplest — the `ExecutePythonCode` tool or terminal Python both work. What
matters is that the file genuinely lands in `tmp/ThreadFiles/<threadId>/` and is **verified on disk**
before you share its link. If you are not certain the file persisted, re-write it and re-share before
finishing — a re-save reliably fixes a link that did not take the first time.

Render every artifact link as `[label](url)` (e.g.
`[Open the HTML report](/api/files/tmp/ThreadFiles/<threadId>/<file>)`) — never a bare URL or plain
text, because only `[label](url)` is clickable in the thread.

## Artifacts & links (always include, as a bulleted list — NOT a table)
Close the in-thread executive summary with an **Artifacts & links** section that lists **every**
artifact created, each as its own bullet with a clickable link, so nothing is buried and the operator
never has to ask for the links a second time. **Present them as a markdown bulleted list, one artifact
per line — do NOT put links inside a markdown table.** The thread UI renders links inside table cells
as plain (non-clickable) text; only inline/bulleted `[label](url)` links are clickable. Use exactly
this shape:

- **Incident report (HTML):** `[Open the HTML report](/api/files/tmp/ThreadFiles/<threadId>/<file>)`
- **Durable-fix PR:** `[PR #<n>](<github-pr-url>)`
- **ServiceNow CR:** `[<CR number>](<servicenow-cr-link>)` — use the clickable `link` returned by the CreateServiceNowChangeRequest tool
- **PagerDuty incident:** `[Incident #<n>](<pagerduty-incident-url>)`
- **Deck / charts (if produced):** `[Download the deck](<download-link>)`

**Every bullet MUST be a clickable markdown hyperlink `[label](url)`** — never a bare URL, a naked
id/number, or plain text, and never wrapped in a table. The PagerDuty, ServiceNow CR, and GitHub PR
URLs come from those skills (the ServiceNow CR link is returned directly by its tool); the HTML report
(and deck) link is `/api/files/tmp/ThreadFiles/<threadId>/<file>` — correct once the file is verified
on disk. If a real URL/link is not available for an artifact, omit that bullet rather than emitting a
non-clickable placeholder.
The HTML report download link is **mandatory** — never omit it. If the report file did not persist
(its link 404s), re-write it into `tmp/ThreadFiles/<threadId>/` and confirm it is on disk, then include
the `/api/files/...` link as a markdown hyperlink.

## Then produce the downloadable deliverables
1. **Executive deck (.pptx)** — build with `ExecutePythonCode` + `python-pptx` following the
   canonical deck order: Title → Exec summary → Customer impact → Timeline → Root cause →
   Before/After → What we did → Recommendations → Closing. Apply Zava Indigo title bars, the
   ZAVA wordmark, brand colors, and the confidentiality footer. Embed the real visual evidence
   from `evidence-before-after` (the before/after diagram or charts), adding `PlotBarChart` /
   `PlotPieChart` only for summary visuals. Emit the `.pptx` as a downloadable artifact.
2. **Email (HTML)** — the `zava-report-template` email layout: subject
   `[ZAVA SRE] <symptom> — <SEVx> — <status>`; Summary, Impact, Root cause (1–2 lines), What we
   did, Recommended actions checklist, and links to the full report / PR / CR / PagerDuty. Write the
   HTML into `tmp/ThreadFiles/<threadId>/` and verify it is on disk so it persists as a downloadable.
3. **Teams notification (Adaptive Card JSON)** — FactSet (Severity, Status, Duration, Users
   impacted), one-line root cause, top 3 next steps, OpenUrl buttons for PR, ServiceNow CR, and
   PagerDuty incident.

If the calling agent restricts the deliverables (e.g. "only the HTML report"), produce just that
subset — the in-thread summary above is always produced.

## Quality bar (must pass before handing off)
- Titles and alert references are **symptom-only** — no root cause in any heading.
- The in-thread executive summary is rendered as markdown with the before/after visuals inline.
- All visuals really rendered, brand-colored, labeled; every recovery claim backed by a
  Before/After number.
- Consistent severity, duration, and impact figures across every deliverable produced.
- No secrets or PII; apply the `zava-redaction` scrub (`SearchMemory("zava-redaction")` →
  `redact()`) to every deliverable and the in-thread summary; confidentiality footer present on the
  deck and email.
- File-creation self-audit: the HTML report (and any deck) was written into
  `tmp/ThreadFiles/<threadId>/` and **verified on disk** (non-zero bytes) before its link was shared;
  the Artifacts & links section is a **bulleted list (never a table)** and EVERY bullet is a clickable
  `[label](url)` — the HTML report (`/api/files/tmp/ThreadFiles/<threadId>/<file>`), the PR, the
  ServiceNow CR link, and the PagerDuty `html_url` — with no bare id/number and no plain-text
  placeholder.

## Verification
An in-thread branded markdown executive summary with the before/after visuals shown inline, plus the
requested on-brand deliverables (by default the .pptx deck + HTML email + Teams card JSON, or the
subset the calling agent asked for) produced as artifacts/content, all consistent with each other
and the source skills, ready for the operator to distribute.
