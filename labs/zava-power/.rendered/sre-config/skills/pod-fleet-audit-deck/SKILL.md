---
metadata:
  api_version: azuresre.ai/v2
  kind: Skill
name: pod-fleet-audit-deck
description: |
  Generate ONE polished executive PowerPoint deck summarizing pod-level
  health across all 5 PowerGrid Container Apps over a configurable
  lookback window (default 48h). Read-only. NEVER creates SNOW tickets.
  NEVER calls remediation tools. Used by the daily "PowerGrid Fleet
  Audit Deck" scheduled task.
---

# Pod Fleet Audit Deck

## 0. Output contract (must satisfy ALL)

- Exactly ONE `.pptx` file attached to the agent thread.
- Filename: `powergrid-fleet-audit-<UTC-yyyyMMdd-HHmm>.pptx`.
- Slide size: 16:9 widescreen, 13.333 in x 7.5 in (NOT 4:3).
- Final assistant message: 1-paragraph executive summary + link to the
  attachment + 4 KPI tiles (Findings / Categories / Auto-fixable /
  Fleet status emoji). Total <= 80 words.
- NEVER emit more than one deck per run.
- NEVER emit Markdown instead of a deck.

---

## 1. Inputs

| Param | Default | Notes |
|---|---|---|
| `window_hours` | `48` | lookback in hours |
| `services` | `["ca-powergrid-outage","ca-powergrid-meter","ca-powergrid-grid","ca-powergrid-notify","ca-powergrid-portal"]` | MUST use the ca-powergrid-* short names because that's what `ContainerAppName_s` contains in this workspace. |
| `friendly_names` | mapping below | shown on slides |
| `resource_group` | `rg-powergrid` | |
| `subscription` | `e964602f-6afc-4cc7-ba6b-3a796008e254` | |
| `workspace_id` | `1b8e5f73-805d-4efe-9a29-2489e255f607` | law-powergrid customerId |

Friendly-name map (use `friendly` anywhere a service appears in user-visible text):

| ContainerAppName_s | friendly |
|---|---|
| ca-powergrid-outage | outage-api |
| ca-powergrid-meter  | meter-api |
| ca-powergrid-grid   | grid-status-api |
| ca-powergrid-notify | notification-svc |
| ca-powergrid-portal | portal-web |

---

## 2. Step 1 - fetch data (5 queries, run via Log Analytics REST or the agent's KQL tool)

> Do NOT skip Step 1. No drafting allowed until all 5 results are in memory.
> Token audience for direct REST: `https://api.loganalytics.io/.default`.
> Endpoint: `https://api.loganalytics.io/v1/workspaces/{workspace_id}/query`.

`{{services_kql}}` below = the 5 names above as a Kusto string list, e.g.
`'ca-powergrid-outage','ca-powergrid-meter','ca-powergrid-grid','ca-powergrid-notify','ca-powergrid-portal'`.

### Q1 - Failure events per service (the headline signal)
```kusto
let _start = ago({{window_hours}}h);
let _failure_reasons = dynamic([
  "ReplicaUnhealthy","ContainerBackOff","AssigningReplicaFailed",
  "ScaledObjectCheckFailed","Error","OOMKilled","BackOff",
  "CrashLoopBackOff","Killing","Unhealthy"
]);
ContainerAppSystemLogs_CL
| where TimeGenerated >= _start
| where ContainerAppName_s in ({{services_kql}})
| where Reason_s in (_failure_reasons)
| summarize n = count() by ContainerAppName_s, Reason_s
| order by n desc
```

### Q2 - Failure events binned for the heat map (1-hour bins)
```kusto
let _start = ago({{window_hours}}h);
let _failure_reasons = dynamic([
  "ReplicaUnhealthy","ContainerBackOff","AssigningReplicaFailed",
  "ScaledObjectCheckFailed","Error","OOMKilled","Killing","Unhealthy"
]);
ContainerAppSystemLogs_CL
| where TimeGenerated >= _start
| where ContainerAppName_s in ({{services_kql}})
| where Reason_s in (_failure_reasons)
| summarize n = count() by ContainerAppName_s, bin(TimeGenerated, 1h)
| order by TimeGenerated asc
```

### Q3 - Probe failures (console log scan)
```kusto
let _start = ago({{window_hours}}h);
ContainerAppConsoleLogs_CL
| where TimeGenerated >= _start
| where ContainerAppName_s in ({{services_kql}})
| where Log_s matches regex @"(?i)(probe|liveness|readiness|unhealthy)"
| summarize probe_failures = count() by ContainerAppName_s
```

### Q4 - Sample evidence (first + most-recent failure log line per service)
```kusto
let _start = ago({{window_hours}}h);
ContainerAppSystemLogs_CL
| where TimeGenerated >= _start
| where ContainerAppName_s in ({{services_kql}})
| where Reason_s in ("ReplicaUnhealthy","ContainerBackOff","Error","AssigningReplicaFailed")
| summarize
    first_seen = min(TimeGenerated),
    last_seen  = max(TimeGenerated),
    sample_msg = take_any(Log_s)
  by ContainerAppName_s, Reason_s
| order by ContainerAppName_s asc, Reason_s asc
```

### Q5 - Replica state (per service, current; NOT KQL - `az` calls)
For each `ContainerAppName_s`:
```
az containerapp show -n <name> -g rg-powergrid \
  --query "{min:properties.template.scale.minReplicas, max:properties.template.scale.maxReplicas, status:properties.runningStatus}" \
  -o json
```

> Do NOT filter App Insights `AppRequests` by `AppRoleName` - it is
> empty/`unknown_service` on this workspace and will silently return zero
> results. Skip traffic metrics; the system logs above already tell the
> story.

---

## 3. Step 2 - classification

For each service, pick exactly ONE category using its Q1 totals (highest match wins):

| Category | Rule |
|---|---|
| `crash-loop` | `ContainerBackOff >= 50` OR `BackOff >= 20` OR `CrashLoopBackOff >= 5` |
| `oom` | `OOMKilled >= 1` |
| `probe-misconfig` | `Q3 probe_failures >= 100` AND `ReplicaUnhealthy >= 50` |
| `scaling-flap` | `ScaledObjectCheckFailed >= 50` OR `AssigningReplicaFailed >= 10` |
| `unhealthy-replicas` | `ReplicaUnhealthy >= 50` (catch-all if no above category) |
| `errors-only` | `Error >= 10` (and no above) |
| `healthy` | total failure events == 0 |

Track per-service: `{service, friendly, category, total_events, top_reason, top_reason_count, evidence_first, evidence_last, sample_msg, recommendation}`.

---

## 4. Step 3 - build the deck (HARD layout rules)

> Most reported pain in v1 was overflow + cluttered look. Fix it by
> following these rules verbatim. Do NOT improvise sizes.

### 4.1 Global setup

```python
from pptx import Presentation
from pptx.util import Inches, Pt, Emu
from pptx.dml.color import RGBColor
from pptx.enum.shapes import MSO_SHAPE
from pptx.enum.text import PP_ALIGN, MSO_ANCHOR, MSO_AUTO_SIZE

prs = Presentation()
prs.slide_width  = Inches(13.333)
prs.slide_height = Inches(7.5)
BLANK = prs.slide_layouts[6]   # blank layout - we draw everything ourselves
```

### 4.2 Brand tokens (MUST be used everywhere - no other colors)

| Token | RGB | When |
|---|---|---|
| `BRAND` | `0x0078D4` | titles, accent bars |
| `INK` | `0x1F2937` | body text |
| `MUTED` | `0x6B7280` | sub-labels, footers |
| `BG_LIGHT` | `0xF3F4F6` | KPI cards, table header band |
| `OK` | `0x10B981` | healthy / green pills |
| `WARN` | `0xF59E0B` | scaling-flap, errors-only |
| `BAD` | `0xEF4444` | crash-loop, oom, probe-misconfig, unhealthy-replicas |

### 4.3 Type scale (no other sizes)

| Role | Font | Size | Weight |
|---|---|---|---|
| Slide title | Calibri | 28pt | bold |
| Section header | Calibri | 18pt | bold |
| Body bullet | Calibri | 14pt | regular |
| Table cell | Calibri | 12pt | regular |
| KPI big number | Calibri | 36pt | bold |
| KPI label | Calibri | 11pt | regular |
| Footer | Calibri | 9pt | regular |

### 4.4 Anti-overflow rules (MANDATORY)

For EVERY text frame you create:
```python
tf = shape.text_frame
tf.word_wrap = True
tf.auto_size = MSO_AUTO_SIZE.NONE   # NEVER let pptx auto-grow boxes
tf.margin_left = tf.margin_right = Inches(0.1)
tf.margin_top  = tf.margin_bottom = Inches(0.05)
```

Truncate before writing. NEVER paste a string longer than the limits below - if it's longer, cut and append `...`:

| Field | Char limit |
|---|---|
| Slide title | 60 |
| Section header | 50 |
| Bullet line | 90 |
| Table cell | 32 |
| KPI big number | 5 (e.g. "1,473") |
| KPI label | 18 |
| Code/`az` line | 80 (then break to a 2nd line) |
| Sample log evidence | 110 (one line, monospace, then `...`) |

Bullet lists: max 5 bullets per text box. If you have more, drop the lowest-priority ones (don't shrink font).

### 4.5 Page grid (in inches; everything snaps to this)

| Region | Left | Top | Width | Height |
|---|---|---|---|---|
| Title bar | 0.5 | 0.3 | 12.333 | 0.7 |
| Accent rule under title | 0.5 | 1.05 | 12.333 | 0.04 |
| Content area | 0.5 | 1.25 | 12.333 | 5.7 |
| Footer | 0.5 | 7.05 | 12.333 | 0.3 |

Always draw the title bar + accent rule + footer using a helper function so every slide looks identical.

Footer text: `PowerGrid Fleet Audit | <window>h window | Generated <UTC ts> | Slide N of M`

---

## 5. Slide-by-slide spec (FIXED - do not invent extra slides)

### Slide 1 - Title (cover)
- BRAND background bar across the top 1.5 inch
- Title (white, 44pt bold): `PowerGrid Fleet Health Audit`
- Subtitle (white, 20pt): `Last <window>h | <UTC date range>`
- Bottom-right small text (MUTED, 10pt): `Zava Power Limited | Confidential`

### Slide 2 - Executive Summary
- Title: `Executive Summary`
- One sentence (16pt, INK): e.g. `4 of 5 services experienced pod failures in the last 48h; grid-status-api is the largest contributor with 687 events.`
- Below: a row of 4 KPI cards, equally spaced, each card 2.7"w x 1.6"h, BG_LIGHT fill, 0.02" border in BRAND, anchored top:3.0", lefts at 0.5 / 3.5 / 6.5 / 9.5
  - Card 1: total failure events (number + label `Failure events`)
  - Card 2: services affected (e.g. `4 / 5`, label `Services affected`)
  - Card 3: distinct categories triggered (label `Categories`)
  - Card 4: fleet status (one big colored emoji + label `Fleet status`). Use OK/WARN/BAD color band per rule:
    - green if 0 services in non-healthy
    - amber if 1-2 non-healthy
    - red if >=3 non-healthy

### Slide 3 - Cluster Snapshot (table)
- Title: `Cluster Snapshot`
- Table 6 cols x 6 rows (header + 5 services), pinned at left=0.5", top=1.4", width=12.333", row_height=0.55"
  - Cols: `Service` (3.0") | `Status` (1.4") | `Replicas (active/min/max)` (2.5") | `Top failure reason` (2.5") | `Events (48h)` (1.5") | `Category` (1.4")
  - Header row: BRAND fill, white bold text
  - Body rows: alternate white / BG_LIGHT
  - `Status` cell: colored pill (rounded rect inside cell) using OK/WARN/BAD per category
  - `Events (48h)` right-aligned

### Slide 4 - Failure Heat Map
- Title: `Failure Frequency - last <window>h (1-hour bins)`
- Render Q2 result with matplotlib:
  ```python
  fig, ax = plt.subplots(figsize=(12.0, 4.0), dpi=150)
  # rows = services in fixed order, cols = hour bins
  im = ax.imshow(matrix, aspect='auto', cmap='Reds')
  ax.set_yticks(range(len(services))); ax.set_yticklabels(friendly_names)
  ax.set_xticks(every Nth bin); ax.set_xticklabels(HH:MM rotation=0)
  ax.set_title('Pod failure events per hour'); fig.colorbar(im, ax=ax, label='events')
  fig.tight_layout(); fig.savefig(buf, format='png', bbox_inches='tight')
  ```
- Insert PNG anchored left=0.5", top=1.4", width=12.333", height=5.5"
- Below the chart, one-line caption (MUTED, 12pt) explaining the color scale

### Slides 5..N - One per non-healthy finding (max 5)
> If more than 5 non-healthy findings, group the lowest-event ones into a single "Other" slide.

Layout - 4 quadrants, each in a fixed BG_LIGHT rounded-rect tile:

```
+----------------------------------------------------------+
| Title:  <friendly>  |  <category>          [colored pill]|
+--------------------------+-------------------------------+
| ISSUE                    | MITIGATION                    |
| (1.4" tall)              | (1.4" tall)                   |
| - 1-line root cause      | `<exact az command, <=80ch>`  |
| - Top reason: <name>x<n> | OR "engineering required"     |
| - First seen: <UTC>      |                               |
| - Last seen:  <UTC>      |                               |
+--------------------------+-------------------------------+
| IMPACT                   | RECOMMENDATION                |
| (1.4" tall)              | (1.4" tall)                   |
| - Repeat count: <n>      | - Bullet 1 (<=90 ch)          |
| - Operator-min saved: <n>| - Bullet 2                    |
|   (assume 12 min/event)  | - Bullet 3                    |
+--------------------------+-------------------------------+
```

Tile dimensions: each 6.0"w x 2.7"h, gap 0.16". Lefts: 0.5 / 6.66. Tops: 1.4 / 4.26.

Section header (`ISSUE` / `MITIGATION` / `IMPACT` / `RECOMMENDATION`):
- 11pt bold, MUTED color, ALL CAPS
- Anchored top of its tile, left-padded 0.15"

Body inside each tile:
- 14pt INK bullets, max 4 lines

Color pill in title-bar (right side): rounded rect, BAD/WARN/OK per category. Width = enough for category label + 0.4" padding.

### Slide N+1 - Recommendations Roll-up
- Title: `Prevention Recommendations (prioritized)`
- Table 4 cols x (1 + N findings rows), max 6 rows total
  - Cols: `Priority` (1.0") | `Service` (2.5") | `Action` (7.5") | `Owner hint` (1.3")
  - Priority cell: colored pill `P1` (BAD), `P2` (WARN), `P3` (OK)
  - Action text wraps to max 2 lines (<=180 chars total)

Priority rule:
- `P1` if category in `{crash-loop, oom, probe-misconfig}`
- `P2` if category in `{unhealthy-replicas, scaling-flap}`
- `P3` everything else

### Slide N+2 - Audit ROI
- Title: `Audit ROI`
- Left half (5.5"w): bullet list (16pt INK, max 5 bullets)
  - `Findings detected: <n>`
  - `Auto-remediable: <n>`
  - `Estimated operator-minutes saved: <n>` (assume 12 min/finding)
  - `Time to insight: ~10s` (vs human triage)
  - `Coverage: 5/5 services audited`
- Right half (5.5"w): a small horizontal bar chart of "events by category" (matplotlib, 6.0x4.0 in, dpi=150, BRAND-colored bars)

### Slide N+3 - Appendix (KQL)
- Title: `Appendix - KQL Queries`
- 3 columns of code text (10pt monospace `Consolas`, INK), one per Q1/Q2/Q3, each in its own BG_LIGHT rounded rect
- Code lines wrap at 60 chars (use a hard wrapper in Python before inserting)

---

## 6. Step 4 - attach + summary message

1. Save as `/tmp/powergrid-fleet-audit-<yyyyMMdd-HHmm>.pptx`.
2. Attach via the runtime's standard thread-attachment mechanism. If
   attachment fails, base64-encode and emit as
   `data:application/vnd.openxmlformats-officedocument.presentationml.presentation;base64,<...>`.
3. Final assistant message (<= 80 words):

```
**PowerGrid Fleet Audit - last <window>h**

Fleet status: <emoji> <verdict> | <N> findings | <M> auto-fixable | ~<X> operator-min saved

[powergrid-fleet-audit-<ts>.pptx](<attachment URL>)

Top finding: <friendly> (<category>) - <top_reason>x<count>.
```

---

## 7. Failure handling

- Single KQL fails -> render its slide with `data unavailable` footer band; continue. Never abort the whole deck.
- python-pptx pip-install fails -> emit a Markdown deck-equivalent labeled `Fallback: pptx unavailable`.
- Empty fleet (no events) -> 2-slide deck (Title + "No activity in window - fleet is healthy").

---

## 8. Anti-patterns (do NOT do these)

- Use `requests` / `cloud_RoleName` (App Insights tables) - `AppRoleName` is empty on this workspace.
- Use reason names like `Started`, `BackOff`, `CrashLoopBackOff` as the primary failure filter - they're not what ACA emits. Use the list in section 2 Q1.
- Auto-grow text frames (`MSO_AUTO_SIZE.TEXT_TO_FIT_SHAPE`) - produces uneven slides.
- Multiple charts per finding slide - use the 4-quadrant layout only.
- Add new colors beyond the 7 brand tokens.
- Add slides not listed in section 5.
- Create SNOW tickets, call remediation tools, or run any Phase 1-4 of `utility-ops-agent`.
