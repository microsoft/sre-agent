---
metadata:
  api_version: azuresre.ai/v2
  kind: Skill
name: cost-analysis
description: Use when an operator or a scheduled task requests a periodic cloud-cost / spend audit of the Zava Learning resource group — identify the top cost drivers, week-over-week trend, idle or oversized resources, and concrete savings opportunities. Read-only; produces findings for a report.
tools:
  - RunAzCliReadCommands
  - GetAzCliHelp
  - SearchMemory
  - ExecutePythonCode
  - microsoft-learn_microsoft_docs_search
---

## Zava Learning — Cloud Cost Analysis

Resource Group: `@@RG@@`. **Read-only audit — never resize, deallocate, or delete a resource.**
This is a weekly spend posture review. Recommend optimisations for a human to apply; change nothing.

### 1. Pull actual spend (preferred path)
Use Cost Management for real billed amounts, scoped to the RG:
- This week vs. last week by resource:
  `az costmanagement query --type ActualCost --timeframe Custom --time-period from=<start> to=<end>
   --scope "/subscriptions/<sub>/resourceGroups/@@RG@@"
   --dataset-grouping name=ResourceId type=Dimension --dataset-aggregation totalCost.name=Cost totalCost.function=Sum`
  (run it for the current 7-day window and the prior 7-day window, then diff per ResourceId).
- Or month-to-date by service: same query grouped by `ServiceName`.
If `az costmanagement` is missing or returns an auth error (the agent identity lacks **Cost
Management Reader**), FALL BACK to `az consumption usage list --start-date <d> --end-date <d>`
filtered to the RG. **Record which data source you used** so the report is honest about provenance.

### 2. If billing data is unavailable, estimate from inventory
As a last resort (no Cost Management and no consumption access), build an estimate:
- Inventory the RG: `az resource list -g @@RG@@ --query "[].{name:name,type:type,sku:sku}"`.
- Note the cost-bearing resources (PostgreSQL Flexible Server SKU, the reporting VM SKU + managed
  disks, Container Apps environments + per-app replicas/scale, Application Gateway tier + capacity
  units, Log Analytics ingestion, Key Vault, ACR SKU, public IPs).
- Use `microsoft-learn_microsoft_docs_search` / known Azure retail pricing to produce a *rough,
  clearly-labelled estimate*, not a billed figure. State the assumption explicitly.

### 3. Find waste and right-sizing opportunities (read-only signals)
- **Idle/oversized:** VMs that are deallocated yet still incurring disk cost; disks not attached to
  any VM (`az disk list -g @@RG@@ --query "[?managedBy==null]"`); over-provisioned VM/DB SKUs vs.
  observed CPU/memory; Container Apps with high min-replicas but low traffic.
- **Orphaned:** unattached public IPs, empty App Gateway backend pools, unused NICs, old ACR images.
- **Trend:** any ResourceId whose week-over-week cost rose sharply — flag it with the Δ%.

### 4. Produce the findings table
For each driver/opportunity output a row: `Resource (type) · This week $ · Last week $ · Δ% ·
Finding · Severity · Recommendation`. Severity is impact-based: a sharp WoW spike or a clearly idle/
oversized paid resource is SEV2; smaller tidy-ups are SEV3. Sort by this-week spend (and severity).
Also produce a posture summary (total RG spend this week, WoW delta, the single biggest saving) and a
prioritized recommendations list with rough monthly savings where you can estimate them.

### 5. Hand off to the branded report
This skill does not remediate. Pass the posture summary, the findings rows (each with its severity),
the spend numbers, and the recommendations to the `zava-audit-report` skill, which renders the single
branded, downloadable PowerPoint deck (top cost drivers chart + findings table) and returns its
download link. Surface that link to the operator.
