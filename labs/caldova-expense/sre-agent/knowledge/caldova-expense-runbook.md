# Caldova Expense — Hybrid On-Premises Architecture & SRE Runbook

## 1. Service Overview
- **Service Name:** Caldova Expense (`expense.internal.caldovagroup.com`)
- **Business Function:** Employee expense report submission, manager approval, and automated journal voucher posting to SAP FI.
- **Hosting Model:** On-premises Windows Server 2022/2025 (`win-caldova-exp01`, private IP `10.50.1.10/24`) onboarded to **Azure Arc** (`Microsoft.HybridCompute/machines`) in resource group `rg-hybrid-connectivity` (`eastus2`).
- **Inbound Security Posture:** Zero inbound internet ports. Management, monitoring, and ZIP deployments operate over outbound HTTPS `443` via Azure Arc (`azcmagent`) and Azure Monitor Agent (`AzureMonitorWindowsAgent`).

## 2. Application & Data Topology
- **Web Tier:** IIS 10 site `CaldovaExpense` (`:8080`), Application Pool `CaldovaExpensePool` (`.NET 8` in-process via `AspNetCoreModuleV2`, physical path `C:\inetpub\caldova-expense`).
- **Database Tier:** Local SQL Server 2022 (`localhost,1433` or `localhost\SQLEXPRESS`), database `CaldovaExpenseDb`, table `dbo.ExpenseReports`, stored procedure `dbo.usp_SubmitExpenseReport`.
  - **Authentication:** Windows Integrated Security (`IIS APPPOOL\CaldovaExpensePool`) — no SQL passwords exist in `appsettings.json` or `web.config`.
- **Upstream ERP Dependency:** SAP FI OData Journal Entry gateway (`https://sap-fi.internal.caldovagroup.com:8443/sap/opu/odata/sap/API_JOURNALENTRY`, private IP `10.42.1.25:8443` reachable across the East US 2 Hub VNet `vnet-hub-eus2` `10.40.0.0/16` S2S IPsec VPN).
  - Expense submissions `>= $500` or with `syncSap=true`, and manager approvals (`POST /api/expenses/{id}/approve`), synchronously post a voucher to SAP FI.

## 3. Telemetry Tables in `law-caldova-central`
Always correlate across all five Log Analytics tables before concluding root cause:

| Table | What It Captures | Key Filter / Columns |
|---|---|---|
| `Heartbeat` | Azure Arc / AMA connectivity liveness | `Computer has "caldova"` or `_ResourceId has "win-caldova-exp01"` |
| `W3CIISLog` | IIS HTTP requests, status codes, latency | `csUriStem`, `csMethod`, `scStatus`, `scSubStatus`, `scWin32Status`, `timeTaken` (ms) |
| `Event` | Windows Application & System Event Logs | `Source == "CaldovaExpense"`, `EventID`, `EventLevelName`, `RenderedDescription` |
| `Perf` | Windows OS, IIS, and SQL Server counters | `ObjectName`, `CounterName`, `CounterValue` (`% Processor Time`, `Available MBytes`, `Lock Wait Time (ms)`) |
| `CaldovaExpenseApp_CL` | Structured app trace & request completion logs | `RawData` (`corr=...`, `status=...`, `durationMs=...`) |

> **Error-rate counting rule:** In `CaldovaExpenseApp_CL`, count only lines matching `RawData has "HttpRequest" and RawData has "Request "` when computing request failure rate, because a single failed request also logs a separate `SapFiSync` or `SqlTimeout`/`SqlError` diagnostic record with the same `corr=` ID.

## 4. Known Event IDs (`Source == "CaldovaExpense"`) & Failure Signatures

| Event ID | Category | HTTP Status | Root Cause & Diagnostic Signature |
|---|---|---|---|
| `1001` | Info | `201` | Normal expense submission persisted to `CaldovaExpenseDb`. |
| `4001` | ChaosControl | N/A | Lab chaos state toggled on `win-caldova-exp01`. |
| `5001` | `SqlTimeout` | `500` (`timeTaken >= 4000ms`) | SQL command/lock timeout (`SqlError=-2` or `1222`) querying `dbo.ExpenseReports`. Check SQL `Lock Wait Time (ms)` in `Perf`. |
| `5002` | `SapFiSync` | `502 Bad Gateway` (`timeTaken ~2200ms`) | Upstream SAP FI endpoint (`10.42.1.25:8443`) unreachable (`SocketException 10060`). Note: `GET /api/expenses` continues returning `200` and host CPU/SQL remain healthy! |
| `5003` | `SqlError` | `500` / `503` | SQL database login/catalog access failure (e.g., `SqlError=4060` or `18456` for `IIS APPPOOL\CaldovaExpensePool`). Both `GET` and `POST` fail immediately (`timeTaken < 200ms`). |
| `5004` | `ChaosCpu` | `200` (elevated latency) | Worker pool CPU saturation (`% Processor Time > 80%` in `Perf`). |
| `5005` / WAS | IIS AppPool Down | `503 Service Unavailable` | `CaldovaExpensePool` stopped in IIS. `W3CIISLog` or HTTP.sys returns `503` while no new `CaldovaExpenseApp_CL` lines are written because the .NET worker process is not running. |

## 5. Investigation Workflow
1. **Confirm Host & Arc Liveness:** Query `Heartbeat` and `Perf` (`% Processor Time`, `Available MBytes`) for `win-caldova-exp01` to determine whether the Windows Server itself is healthy or resource-starved.
2. **Quantify User Impact in IIS:** Query `W3CIISLog` over the affected window grouped by `bin(TimeGenerated, 1m)`, `csMethod`, `csUriStem`, and `scStatus`, plus p95 `timeTaken`.
3. **Pinpoint Exact Exception:** Query `Event` (`Source == "CaldovaExpense"` or `EventLevelName in ("Error", "Warning")`) and `CaldovaExpenseApp_CL` to extract `EventID`, `SqlError`, upstream IP/port, and `corr=` correlation IDs.
4. **Distinguish Tier:**
   - `502` on `POST /api/expenses` + `EventID 5002` + healthy `GET /api/expenses` + normal CPU/SQL -> **Upstream SAP FI / S2S VPN path (`10.42.1.25:8443`)**, NOT an IIS or SQL Server outage.
   - `500` + `EventID 5001` + `timeTaken > 4000ms` -> **SQL Server blocking/query timeout** on `CaldovaExpenseDb`.
   - `500` + `EventID 5003` (`SqlError 4060/18456`) -> **SQL Integrated Auth / database permission regression** for `IIS APPPOOL\CaldovaExpensePool`.
   - `503` + `EventID 5005` / `WAS` event + zero `CaldovaExpenseApp_CL` entries -> **IIS Application Pool `CaldovaExpensePool` stopped**.
5. **Safe Remediation (via Azure Arc Run Command):**
   - Inspect status remotely: `.\azure\invoke-arc-chaos.ps1 -SubscriptionId <SUB> -Mode status`
   - Restore healthy service: `.\azure\invoke-arc-chaos.ps1 -SubscriptionId <SUB> -Mode reset` (or restart `CaldovaExpensePool` via `az connectedmachine run-command`).
