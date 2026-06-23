---
metadata:
  api_version: azuresre.ai/v2
  kind: Skill
name: zava-audit-report
description: Use to package a completed Zava Learning weekly governance audit (NSG / network security, RBAC / least-privilege, or cloud cost) into a single branded, downloadable PowerPoint deck in the Zava house style. The calling audit agent passes its findings (a list of rows with severity) and a short posture summary; this skill renders the deck, applies redaction, and returns the attachment download link. Produces the artifact; it does not send it.
tools:
  - SearchMemory
  - ExecutePythonCode
  - PlotBarChart
  - PlotPieChart
---

## Zava Learning — Branded Weekly Audit Report (PowerPoint)

This is the packaging layer for the **proactive weekly audits**. It is NOT for incidents — there is
no PagerDuty, no 5-Whys, no before/after recovery. It turns the calling agent's audit findings into
one downloadable, executive-ready `.pptx` deck in the Zava house style.

The three audit agents that call this skill are `zava-nsg-auditor`, `zava-rbac-auditor`, and
`zava-cost-analyst`. Each hands you: the audit type, a 3–5 bullet posture summary, the findings rows
(each with an impact-based severity SEV1/SEV2/SEV3), and a prioritized recommendations list.

## Always load the standard first
Retrieve `zava-brand` (palette, typography, layout, footer) and `zava-audit-report` (the audit deck
order and the per-type table columns) with `SearchMemory` and apply them **exactly**. The deck order
is: Title → Posture summary → Findings at a glance (chart) → Findings detail (table) → Trend/context
(optional) → Recommendations & next steps → Closing.

## Redact before emitting (mandatory)
Sensitive data must never reach the deck. Retrieve the scrubber with
`SearchMemory("zava-redaction")` and run its `redact()` function over every slide's text (titles,
bullets, and every table cell) **before** writing the file. Resource names, NSG/rule names, role
names, scopes, and resource IDs are NOT secret — keep them; they are needed for the narrative. Never
place a Key Vault secret value, connection string, token, or learner PII on a slide.

## Write the deck so it actually persists as a download
The `.pptx` is written into THIS thread's files directory — `tmp/ThreadFiles/<threadId>/` — and the
runtime persists it to blob storage so the operator can download it. The single most common defect is
a link that 404s because the file was not actually on disk when persistence ran. The reliable recipe:
1. **Create the directory FIRST:** `mkdir -p tmp/ThreadFiles/<threadId>/` before writing the deck.
2. **Write the `.pptx` into that directory, then confirm it is really on disk and non-empty** (e.g.
   `ls -l` shows a non-zero byte count). Never announce a deck you have not verified exists.
3. **Surface the link** as `/api/files/tmp/ThreadFiles/<threadId>/<file>.pptx` — this `/api/files/...`
   path IS the correct, working download URL once the file has persisted.

Build the deck however is simplest (the `ExecutePythonCode` tool or terminal Python both work) — what
matters is that the `.pptx` genuinely lands in `tmp/ThreadFiles/<threadId>/` and is **verified on
disk** before you share its link. If you are not certain it persisted, re-write it and re-share before
finishing — a re-save reliably fixes a link that did not take the first time.

Surface the link as a clickable markdown hyperlink to the operator (and as the audit notification
body) — render it as `[Download the deck](/api/files/tmp/ThreadFiles/<threadId>/<file>.pptx)`, never a
bare URL or plain text, because only `[label](url)` is clickable in the thread.

## Deck builder reference (python-pptx)
Build the deck with `python-pptx`. The sandbox has it preinstalled; if an import fails, the very
first lines of `main` may `import subprocess, sys; subprocess.run([sys.executable, "-m", "pip",
"install", "--quiet", "python-pptx"])` defensively, then `from pptx import Presentation`. Use the
brand palette as RGB: Indigo `4B2E83`, Teal `00A39A`, Slate `2E3440`, Mist `F4F4F8`, Success
`2E8B57`, Warning `E8A317`, Critical `C0392B`.

Follow this structure inside `def main()` (adapt the inputs to the calling agent's data):

```python
def main():
    # 0. inline redact() from zava-redaction (paste its deterministic function here)
    # 1. import / ensure python-pptx
    from pptx import Presentation
    from pptx.util import Inches, Pt
    from pptx.dml.color import RGBColor
    from pptx.enum.text import PP_ALIGN
    import datetime, os

    INDIGO = RGBColor(0x4B,0x2E,0x83); TEAL = RGBColor(0x00,0xA3,0x9A)
    SLATE  = RGBColor(0x2E,0x34,0x40); MIST = RGBColor(0xF4,0xF4,0xF8)
    WHITE  = RGBColor(0xFF,0xFF,0xFF)
    SEVCOL = {"SEV1": RGBColor(0xC0,0x39,0x2B), "SEV2": RGBColor(0xE8,0xA3,0x17),
              "SEV3": RGBColor(0x2E,0x34,0x40)}

    AUDIT_TYPE = "Network Security Group"        # <- set per caller: NSG / RBAC / Cost
    RG = "<resource group>"
    today = datetime.datetime.utcnow().strftime("%Y-%m-%d")
    posture = ["...3-5 executive bullets..."]    # <- from caller
    findings = [ {} ]                            # <- from caller (rows w/ 'severity')
    recs = [ {} ]                                # <- from caller
    counts = {"SEV1":0,"SEV2":0,"SEV3":0}
    for f in findings: counts[f["severity"]] = counts.get(f["severity"],0)+1

    prs = Presentation(); prs.slide_width = Inches(13.333); prs.slide_height = Inches(7.5)
    blank = prs.slide_layouts[6]
    SW, SH = prs.slide_width, prs.slide_height

    def title_bar(slide, text):
        bar = slide.shapes.add_shape(1, 0, 0, SW, Inches(1.05))
        bar.fill.solid(); bar.fill.fore_color.rgb = INDIGO; bar.line.fill.background()
        p = bar.text_frame.paragraphs[0]; p.text = redact(text)
        r = p.runs[0]; r.font.size = Pt(30); r.font.bold = True; r.font.color.rgb = WHITE
        r.font.name = "Segoe UI Semibold"
        wm = slide.shapes.add_textbox(SW - Inches(3.1), Inches(0.18), Inches(3.0), Inches(0.6))
        wp = wm.text_frame.paragraphs[0]; wp.alignment = PP_ALIGN.RIGHT
        wr = wp.add_run(); wr.text = "ZAVA Learning"
        wr.font.size = Pt(16); wr.font.bold = True; wr.font.color.rgb = WHITE

    def footer(slide):
        fb = slide.shapes.add_textbox(Inches(0.4), SH - Inches(0.45), SW - Inches(0.8), Inches(0.35))
        fr = fb.text_frame.paragraphs[0].add_run()
        fr.text = "Confidential — Internal Use Only · Generated by the Zava SRE Agent"
        fr.font.size = Pt(9); fr.font.color.rgb = SLATE

    # Slide 1: Title — Slide 2: Posture summary (bullets) — Slide 3: chart image (saved by
    # PlotBarChart of severity counts, add_picture) — Slide 4+: findings table (header row Indigo,
    # zebra Mist, severity cell colored via SEVCOL) — Slide: Recommendations table —
    # Slide: Closing (posture statement + read-only assurance + footer). title_bar + footer on every
    # content slide; apply redact() to EVERY string before placing it.

    out = os.path.join(os.getcwd(), f"zava-{AUDIT_TYPE.lower().split()[0]}-audit-{today}.pptx")
    prs.save(out)
    return out
```

Render the "Findings at a glance" chart by calling `PlotBarChart` (severity counts, or for cost the
top spend drivers) so it posts inline AND save the image to embed it on slide 3 with
`slide.shapes.add_picture`. Keep one idea per slide and ≤ ~8 table rows per slide (continue on a new
slide titled "<Audit Type> findings (cont.)").

## Quality bar (must pass before handing off)
- Deck order matches `zava-audit-report`; title is the audit type only (posture review, not an
  incident); Indigo title bars + ZAVA wordmark + confidentiality footer on every slide.
- The findings-by-severity (or cost-driver) chart is really rendered, brand-colored, labeled.
- Findings sorted SEV1 → SEV3; every row has a concrete recommended fix; counts consistent across the
  posture summary, the chart, and the table.
- `zava-redaction` `redact()` applied to every slide string; no secret/PII anywhere.
- The `.pptx` was written into `tmp/ThreadFiles/<threadId>/` and **verified on disk** (non-zero bytes)
  before its link was shared, so it genuinely persisted. SELF-AUDIT: the deck file exists on disk and
  its `/api/files/tmp/ThreadFiles/<threadId>/<file>.pptx` link was surfaced as a clickable
  `[Download the deck](url)`. If you are not certain it persisted, re-write the deck, re-verify it on
  disk, and re-surface the link before handing off.

## Verification
A single branded, downloadable `.pptx` weekly-audit deck in the Zava house style, following the
`zava-audit-report` order, with a real attachment download link returned to the operator, consistent
with the calling agent's findings and posture summary.
