---
metadata:
  api_version: azuresre.ai/v2
  kind: Skill
name: nsg-audit
description: Use when an operator or a scheduled task requests a periodic Network Security Group (NSG) and connectivity-path audit of the Zava Learning resource group — enumerate every NSG and its rules, trace the full path (NSGs, UDRs / route tables, Private Endpoints, DNS, and any firewall), flag overly-permissive, shadowed, unused, or orphaned rules, and recommend least-exposure corrections. Read-only; produces findings for a report.
tools:
  - RunAzCliReadCommands
  - GetAzCliHelp
  - SearchMemory
  - ExecutePythonCode
  - microsoft-learn_microsoft_docs_search
---

## Zava Learning — Network Security Group (NSG) & Connectivity-Path Audit

Resource Group: `@@RG@@`. **Read-only audit — never create, modify, or delete an NSG, rule, route, or
firewall.** This is a weekly posture review of the lab's network exposure and the integrity of its
connectivity paths, not an incident response.

### 1. Enumerate the network surface
- List every NSG: `az network nsg list -g @@RG@@`.
- For each NSG, list its security rules (custom + default):
  `az network nsg rule list -g @@RG@@ --nsg-name <nsg> --include-default`.
- Map each NSG to what it protects (`az network nsg show -g @@RG@@ -n <nsg>
  --query "{subnets:subnets[].id, nics:networkInterfaces[].id}"`). **An NSG attached to no subnet and
  no NIC is orphaned** — itself a finding.

### 2. Evaluate every inbound (and risky outbound) rule
Flag, with an impact-based severity (see the `zava-audit-report` severity model):
- **SEV1** — any inbound `Allow` from `*` / `Internet` / `0.0.0.0/0` to a **management port**
  (22 SSH, 3389 RDP); a blanket `Allow *:* *` (any source, any port, any protocol); or a rule whose
  `description` marks it **temporary / break-glass** ("temp", "troubleshooting", "INC-####") that is
  still present.
- **SEV2** — inbound `Allow` from a broad source (large CIDR / `Internet`) to a **data or admin port**
  (e.g. 5432 Postgres, 6379 Redis, 1433, 27017, 8080-808x app-management ports) where the source
  should be a known subnet / Application Gateway only.
- **SEV3** — **shadowed** rules (a higher-priority rule fully masks a lower one so it can never match),
  **unused / legacy** rules (deny or allow referencing a decommissioned CIDR/subnet), **overlapping /
  duplicate** rules, priority inversions, and **orphaned NSGs** (attached to nothing).
Distinguish the lab's *intended* exposure (the Application Gateway public lane ports 8081-8087 reaching
the lane apps; the AppGw subnet allowing Internet inbound on 80/443 + those lane ports) from genuinely
risky exposure — flag only what a real reviewer would. The lane data ports (Postgres, the reporting-VM
subnet) should be reachable only from inside the VNet; the reporting VM has no public path and needs no
inbound Internet at all.

### 3. Trace the full connectivity path (not just NSGs)
A real network audit follows the whole path. Enumerate and assess each layer, and flag misconfigurations:
- **UDRs / route tables** — `az network route-table list -g @@RG@@` and `az network route-table route
  list`. Flag routes that **bypass a firewall / NVA** (e.g. `0.0.0.0/0 -> Internet` where an appliance
  is expected), black-hole routes (`nextHopType=None`), routes to decommissioned next hops, and route
  tables not associated with any subnet.
- **Private Endpoints & Private DNS** — `az network private-endpoint list -g @@RG@@`; for data services
  (Postgres, Key Vault, Storage) check whether access is via Private Endpoint or left on a **public
  endpoint**, and whether the matching **Private DNS zone** + VNet link exist
  (`az network private-dns zone list`, `... link vnet list`). Flag a data service exposed publicly when
  a Private Endpoint is expected, or a Private Endpoint with a **missing/dangling DNS zone link** (which
  silently breaks name resolution).
- **DNS** — confirm Private DNS zones resolve to the Private Endpoint NICs and have a VNet link; flag
  orphaned zones or links to deleted VNets.
- **Firewall / NVA** — if an Azure Firewall or other NVA is present (`az network firewall list -g @@RG@@`),
  check that subnet UDRs actually force egress through it and review overly-permissive network/application
  rules; if none is present, note that egress is direct and whether that is acceptable for the lab.
Where a control reference helps, cite Azure network-security guidance via
`microsoft-learn_microsoft_docs_search` (deny-by-default, just-in-time access, hub-spoke segmentation,
Private Link, forced tunneling).

### 4. Produce the findings table
For every finding output a row: `Layer (NSG/UDR/PE/DNS/FW) · Resource · Rule/Route · Source → Dest:Port ·
Finding · Severity · Recommended fix`. Sort SEV1 → SEV3. Also produce a short posture summary
(Healthy / Needs attention / At risk, counts by severity, the single most important action) and a
prioritized recommendations list.

### 5. Hand off to the branded report
This skill does not remediate. Pass the posture summary, the findings rows (each with its severity),
and the recommendations to the `zava-audit-report` skill, which renders the single branded,
downloadable PowerPoint deck and returns its download link. Surface that link to the operator.
