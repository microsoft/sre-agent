# Caldova Expense — Hybrid On-Premises IIS + SQL Server + Azure Arc SRE Agent Lab

This lab implements the **Caldova Expense** hybrid enterprise scenario described in [onprem-caldova-expense.md](./onprem-caldova-expense.md): a `.NET 8` expense-reimbursement web application hosted on an **on-premises Windows Server 2022/2025** (`IIS 10` + local `SQL Server 2022` with Windows Integrated Auth) onboarded to **Azure Arc** over outbound HTTPS `443` — with **zero inbound firewall ports** and **no CI/CD runner** on the server.

From Azure, scripts provision **Log Analytics (`law-caldova-central`)**, **Data Collection Rules (DCRs)**, **Azure Monitor Agent (`AMAWindows`)**, and an **Azure SRE Agent** pre-wired to investigate hybrid incidents across IIS W3C logs, Windows Event Logs, OS/IIS/SQL performance counters, and structured application logs — while app updates and fault injections run remotely via `az connectedmachine run-command`.

## Topology

```text
                                      Azure (East US 2)

  +-----------------------------------------------------------------------------------+
  | rg-caldova-sre-agent                                                              |
  |   +---------------------------------------------------------------------------+   |
  |   | Azure SRE Agent (sre-caldova-expense)                                     |   |
  |   | - Connectors: Log Analytics (law-caldova-central) + Azure Monitor         |   |
  |   | - Knowledge : caldova-expense-runbook.md                                  |   |
  |   | - Managed RG: rg-hybrid-connectivity                                      |   |
  |   +-------------------------------------+-------------------------------------+   |
  +-----------------------------------------|-----------------------------------------+
                                            | KQL + ARM / Arc insights
                                            v
  +-----------------------------------------------------------------------------------+
  | rg-hybrid-connectivity                                                            |
  |   +-------------------------------+     +-------------------------------------+   |
  |   | law-caldova-central           |     | Azure Arc (HybridCompute)           |   |
  |   | - Heartbeat                   |     | - Machine: win-caldova-exp01        |   |
  |   | - W3CIISLog (IIS 10)          |     | - Extension: AMAWindows             |   |
  |   | - Event (CaldovaExpense)      |     | - DCRs: Win Telemetry + App Log     |   |
  |   | - Perf (OS / IIS / SQL)       |     | - Remote ZIP & Chaos: Run Command   |   |
  |   | - CaldovaExpenseApp_CL        |     +------------------+------------------+   |
  |   +---------------+---------------+                        ^                      |
  +-------------------|----------------------------------------|----------------------+
                      ^                                        |
                      | Outbound HTTPS 443 (AMA ingestion)     | Outbound HTTPS 443 (azcmagent)
                      +--------------------+-------------------+
                                           |
                       (Optional S2S IPsec VPN: 10.50.1.0/24 <-> 10.40.0.0/16 Hub
                        for live SAP FI 10.42.1.25:8443 traffic; NOT required for Arc/AMA)
                                           |
                              On-Premises Lab (`10.50.1.0/24`)

  +-----------------------------------------------------------------------------------+
  | Non-Azure Windows Server 2022/2025: win-caldova-exp01 (10.50.1.10)                |
  | FQDN: expense.internal.caldovagroup.com  |  Inbound ports: NONE required          |
  |                                                                                   |
  |   +-----------------------------------+     +---------------------------------+   |
  |   | IIS 10 (:8080)                    |     | SQL Server 2022 Express/Dev     |   |
  |   | Site   : CaldovaExpense           | --> | DB   : CaldovaExpenseDb         |   |
  |   | AppPool: CaldovaExpensePool       |     | Auth : Windows Integrated       |   |
  |   | Path   : C:\inetpub\caldova-...   |     |        [IIS APPPOOL\Caldova...] |   |
  |   +-----------------------------------+     +---------------------------------+   |
  |   +---------------------------------------------------------------------------+   |
  |   | Agents & Local Telemetry                                                  |   |
  |   | - Azure Connected Machine Agent (azcmagent)                               |   |
  |   | - Azure Monitor Agent (AMAWindows — auto-pushed from Azure)               |   |
  |   | - W3C Logs + Event Log ('CaldovaExpense') + C:\ProgramData\...\app.log    |   |
  |   +---------------------------------------------------------------------------+   |
  +-----------------------------------------------------------------------------------+
```

---

## Directory Structure

```text
caldova-expense/
|-- README.md                                  # End-to-end setup & investigation guide
|-- onprem-expense.md                          # onprem environment summary
|-- app/                                       # Caldova Expense (.NET 8 ASP.NET Core web app)
|   |-- CaldovaExpense.csproj
|   |-- Program.cs
|   |-- appsettings.json                       # Zero secrets — Windows Integrated SQL Auth
|   `-- web.config                             # IIS AspNetCoreModuleV2 configuration
|-- sql/
|   `-- init-caldova-expense.sql               # Idempotent DB schema, stored proc, seed data & AppPool login
|-- scripts/
|   `-- build-package.ps1                      # Builds app/ and packages CaldovaExpense.zip
|-- onprem/                                    # Run on your non-Azure Windows Server
|   |-- 1-setup-windows-host.ps1               # IIS 10 + W3C fields + .NET 8 Hosting Bundle + SQL Express
|   |-- 2-setup-database.ps1                   # Creates CaldovaExpenseDb & grants AppPool Integrated Auth
|   |-- 3-deploy-caldova-expense.ps1           # Unzips CaldovaExpense.zip -> IIS (:8080) + baseline traffic
|   |-- 4-connect-azure-arc.ps1                # Installs azcmagent & connects to rg-hybrid-connectivity
|   |-- setup-onprem-all.ps1                   # Single-command wrapper for Steps 1–4
|   |-- start-traffic-generator.ps1            # Scheduled Task generating steady baseline requests
|   `-- set-chaos.ps1                          # Local fault injection / reset CLI
|-- azure/                                     # Run from Azure admin workstation or Cloud Shell
|   |-- 1-setup-azure-and-sre-agent.ps1        # Creates LAW, DCE, DCRs, AND deploys the Azure SRE Agent
|   |-- 2-attach-arc-monitoring.ps1            # Pushes AMAWindows + DCR associations once Arc is Connected
|   |-- create-arc-onboarding-sp.ps1           # Creates a scoped Arc onboarding Service Principal
|   |-- push-zip-via-arc.ps1                   # Pushes fresh CaldovaExpense.zip remotely over Arc Run Command
|   |-- invoke-arc-chaos.ps1                   # Triggers/resets chaos modes remotely over Arc Run Command
|   `-- cleanup-azure.ps1                      # Removes SRE Agent & lab monitoring resources (-WhatIf supported)
|-- sre-agent/
|   `-- knowledge/
|       `-- caldova-expense-runbook.md         # Runbook uploaded to SRE Agent Knowledge Memory
`-- queries/                                   # KQL verification queries for law-caldova-central
    |-- 1-arc-heartbeat-and-perf.kql
    |-- 2-iis-w3c-errors-and-latency.kql
    |-- 3-windows-event-logs.kql
    `-- 4-app-structured-logs.kql
```

---

## Prerequisites

### Azure Operator Workstation
- **Azure subscription** with `Owner` or `Contributor` + `User Access Administrator` permissions (needed to assign RBAC roles to the SRE Agent's Managed Identities).
- **Azure CLI (`az`)** signed in (`az login`).
  - Tip: Sign in with `az login --scope "https://azuresre.dev/.default"` if you also want `1-setup-azure-and-sre-agent.ps1` to automatically upload `caldova-expense-runbook.md` to the SRE Agent data-plane Knowledge Memory (otherwise you can upload it with one click in the SRE Agent portal).
- **.NET 8 SDK** + **PowerShell 7+** (or Windows PowerShell 5.1) to build `CaldovaExpense.zip`.

### On-Premises Lab Machine
- **1× non-Azure machine or VM** (Hyper-V, Proxmox, VMware, or physical server — *do not use an Azure VM*, because `azcmagent` detects Azure IMDS).
- **Sizing:** `4 vCPU`, `8 GB RAM`, `80–100 GB SSD`, **Windows Server 2022 or 2025**.
- **Network:** Private subnet `10.50.1.0/24` (`10.50.1.10`), outbound HTTPS (`443`) to internet/Azure Arc & Azure Monitor endpoints. Zero inbound ports required.

---

## Phase 1 — Build Package & Prepare Azure + SRE Agent (Azure Operator)

You can run Phase 1 **before** or **after** you set up the Windows Server. Running it first prepares `rg-hybrid-connectivity`, `law-caldova-central`, the Data Collection Rules, the **Azure SRE Agent**, and an optional onboarding Service Principal for use with `CaldovaExpense.zip`.

### 1. Build `CaldovaExpense.zip`

```powershell
.\scripts\build-package.ps1
```

This publishes [CaldovaExpense.csproj](./app/CaldovaExpense.csproj) (`Release`) and produces `.\CaldovaExpense.zip` (with `sql\init-caldova-expense.sql` bundled inside `_deploy\`).

### 2. Provision Azure Monitoring + Azure SRE Agent

```powershell
$subId = "66a7fcba-dac3-46d8-b509-202f305618c8"   # Replace with your target subscription ID

.\azure\1-setup-azure-and-sre-agent.ps1 `
  -SubscriptionId $subId `
  -HybridResourceGroup "rg-hybrid-connectivity" `
  -WorkspaceName "law-caldova-central" `
  -Location "eastus2" `
  -AgentResourceGroup "rg-caldova-sre-agent" `
  -AgentName "sre-caldova-expense"
```

> **Region tip:** If Azure SRE Agent uses a different supported region on your subscription (for example `swedencentral`) while your hybrid resources stay in `eastus2`, pass `-Location "eastus2" -AgentLocation "swedencentral"`.

What `1-setup-azure-and-sre-agent.ps1` creates:
- **Resource Groups:** `rg-hybrid-connectivity` and `rg-caldova-sre-agent`
- **Log Analytics:** `law-caldova-central` + custom table `CaldovaExpenseApp_CL`
- **Data Collection Endpoint & Rules:**
  - `dce-caldova-central`
  - `dcr-caldova-win-telemetry` (`Perf` counters for OS/IIS/SQL, `Event` logs for `CaldovaExpense` + System/App, and `W3CIISLog` for IIS 10)
  - `dcr-caldova-expense-applog` (`C:\ProgramData\CaldovaExpense\logs\app.log` -> `CaldovaExpenseApp_CL`)
- **Azure SRE Agent (`sre-caldova-expense`):**
  - User-Assigned + System-Assigned Managed Identity and Application Insights
  - `Reader`, `Monitoring Reader`, and `Log Analytics Reader` on `rg-hybrid-connectivity` (plus `SRE Agent Administrator` for you)
  - Pre-wired **`log-analytics`** connector (`law-caldova-central`) and **`azure-monitor`** connector
  - Uploads [caldova-expense-runbook.md](./sre-agent/knowledge/caldova-expense-runbook.md) into SRE Agent Knowledge Memory (when a `https://azuresre.dev/.default` token is available)
- **Arc Extension & DCR Attachment:** Automatically runs `2-attach-arc-monitoring.ps1` if `win-caldova-exp01` is already onboarded!

### 3. (Optional) Generate Scoped Arc Onboarding Credentials

If you do not have interactive permissions on the Azure subscription, an Azure administrator can generate a least-privilege Service Principal scoped strictly to `Azure Connected Machine Onboarding` on `rg-hybrid-connectivity`:

```powershell
.\azure\create-arc-onboarding-sp.ps1 -SubscriptionId $subId
```

Copy `CaldovaExpense.zip` and the `onprem\` folder (or repo) to the Windows Server, and securely transfer the printed `4-connect-azure-arc.ps1` command.

---

## Phase 2 — On-Premises Windows Server Setup

Copy `CaldovaExpense.zip`, `onprem\`, and `sql\` onto `win-caldova-exp01` (`10.50.1.10`) and open an **Administrator PowerShell** prompt.

### Option A: Step-by-Step (4 Clear Commands)

```powershell
# 1. Enable IIS 10 + W3C Extended Logging + .NET 8 Hosting Bundle + SQL Server 2022 Express
.\onprem\1-setup-windows-host.ps1

# 2. Create CaldovaExpenseDb, seed reports, and grant Windows Integrated Auth to IIS APPPOOL\CaldovaExpensePool
.\onprem\2-setup-database.ps1

# 3. Extract CaldovaExpense.zip -> C:\inetpub\caldova-expense (:8080), register EventLog source, & start baseline traffic
.\onprem\3-deploy-caldova-expense.ps1 -ZipPath .\CaldovaExpense.zip

# 4. Install azcmagent and onboard win-caldova-exp01 to Azure Arc (outbound 443 only)
.\onprem\4-connect-azure-arc.ps1 `
  -SubscriptionId "66a7fcba-dac3-46d8-b509-202f305618c8" `
  -ResourceGroup "rg-hybrid-connectivity" `
  -Location "eastus2" `
  -MachineName "win-caldova-exp01" `
  -UseDeviceCode
```
*(Or pass `-TenantId`, `-ServicePrincipalId`, and `-ServicePrincipalSecret` from `create-arc-onboarding-sp.ps1` instead of `-UseDeviceCode`.)*

### Option B: Single-Command All-in-One Setup

```powershell
.\onprem\setup-onprem-all.ps1 `
  -ZipPath .\CaldovaExpense.zip `
  -SubscriptionId "66a7fcba-dac3-46d8-b509-202f305618c8" `
  -UseDeviceCode
```

Verify locally on `win-caldova-exp01`:
```powershell
Invoke-RestMethod http://localhost:8080/api/health
Invoke-RestMethod http://localhost:8080/api/expenses
& "$env:ProgramW6432\AzureConnectedMachineAgent\azcmagent.exe" show
```

---

## Phase 3 — Attach Azure Monitor Agent & Verify Telemetry (Azure Operator)

Once you confirm `azcmagent show` reports `Agent Status: Connected`, run:

```powershell
.\azure\2-attach-arc-monitoring.ps1 -SubscriptionId $subId
```

*(If `win-caldova-exp01` was already connected before you ran `1-setup-azure-and-sre-agent.ps1`, this step already ran automatically!)*

Wait **5–10 minutes** for `AzureMonitorWindowsAgent` (`AMAWindows`) to download the Data Collection Rules and ship initial records, then run the KQL queries in [queries/](./queries) against `law-caldova-central`:
1. [1-arc-heartbeat-and-perf.kql](./queries/1-arc-heartbeat-and-perf.kql) — Confirms Arc `Heartbeat` and OS/IIS/SQL `Perf` counters.
2. [2-iis-w3c-errors-and-latency.kql](./queries/2-iis-w3c-errors-and-latency.kql) — Confirms `W3CIISLog` baseline `200` / `201` requests from the scheduled baseline traffic task.
3. [3-windows-event-logs.kql](./queries/3-windows-event-logs.kql) — Confirms `Event` records from `Source == "CaldovaExpense"`.
4. [4-app-structured-logs.kql](./queries/4-app-structured-logs.kql) — Confirms structured traces in `CaldovaExpenseApp_CL`.

---

## Phase 4 — Remote Operations & SRE Agent Incident Walkthroughs

Because `win-caldova-exp01` is Arc-enabled, you never need CI/CD agents, WinRM, or RDP to push code updates or run chaos drills.

### Remote App Updates via Azure Arc (`push-zip-via-arc.ps1`)
Whenever you modify [Program.cs](./app/Program.cs), push a fresh `CaldovaExpense.zip` straight to `C:\inetpub\caldova-expense` over outbound `443`:

```powershell
.\azure\push-zip-via-arc.ps1 -SubscriptionId $subId
```

### Inject Faults Remotely & Investigate with Azure SRE Agent

Trigger any of the built-in chaos scenarios from your Azure workstation:

| Scenario Mode | Command | What Breaks & Expected SRE Agent Finding |
|---|---|---|
| **1. Upstream SAP FI Outage** | `.\azure\invoke-arc-chaos.ps1 -SubscriptionId $subId -Mode sap-unavailable` | `POST /api/expenses` returns **HTTP `502`** (`timeTaken ~2200ms`), Windows Event ID **`5002`** (`SocketException 10060` to `10.42.1.25:8443`), while `GET /api/expenses`, SQL Server, and host CPU remain completely healthy — proving an upstream ERP / S2S VPN issue rather than a server outage. |
| **2. SQL Server Lock / Query Timeout** | `.\azure\invoke-arc-chaos.ps1 -SubscriptionId $subId -Mode sql-lock` | Both `GET` and `POST /api/expenses` fail with **HTTP `500`** after `~4000ms+` (`SqlError=-2` timeout on `dbo.ExpenseReports`), Event ID **`5001`**, while Arc `Heartbeat` stays up. |
| **3. SQL Integrated Auth Regression** | `.\azure\invoke-arc-chaos.ps1 -SubscriptionId $subId -Mode db-auth-broken` | Immediate **HTTP `500` / `503`** (`timeTaken < 200ms`), Event ID **`5003`** (`SqlError=4060` / login denied for `IIS APPPOOL\CaldovaExpensePool`). |
| **4. Worker Pool CPU Saturation** | `.\azure\invoke-arc-chaos.ps1 -SubscriptionId $subId -Mode cpu-pressure` | `% Processor Time` spikes to `85–95%` in `Perf`, Event ID **`5004`** logged. |
| **5. IIS Application Pool Stopped** | `.\azure\invoke-arc-chaos.ps1 -SubscriptionId $subId -Mode apppool-stop` | IIS returns kernel-mode **HTTP `503 Service Unavailable`**, Event ID **`5005`**, and `CaldovaExpenseApp_CL` stops logging new app lines because `w3wp.exe` is stopped. |

#### Sample SRE Agent Investigation Prompt
1. Inject a fault (for example `sap-unavailable` or `sql-lock`), wait **~5 minutes** for Log Analytics ingestion, and open [Azure SRE Agent](https://sre.azure.com).
2. Select **`sre-caldova-expense`** and ask:
   > Users report errors submitting expense reports on the on-premises Caldova Expense portal (`win-caldova-exp01`). Investigate `law-caldova-central` across IIS logs, Windows Event Logs, performance counters, and application logs to determine when the issue started, which endpoints are impacted, and whether the root cause is the Windows host, IIS, local SQL Server, or an upstream dependency.
3. Reset the environment back to healthy baseline from Azure:
   ```powershell
   .\azure\invoke-arc-chaos.ps1 -SubscriptionId $subId -Mode reset
   ```

---

## Cleanup

Preview or remove Azure SRE Agent and monitoring resources when finished:

```powershell
# Dry-run preview
.\azure\cleanup-azure.ps1 -SubscriptionId $subId -WhatIf

# Delete rg-caldova-sre-agent and remove Caldova DCRs/DCE (preserves rg-hybrid-connectivity)
.\azure\cleanup-azure.ps1 -SubscriptionId $subId -Confirm:$false
```

On the on-premises Windows Server (if retiring the VM):
```powershell
.\onprem\start-traffic-generator.ps1 -Stop
& "$env:ProgramW6432\AzureConnectedMachineAgent\azcmagent.exe" disconnect --use-device-code
```

---

## Troubleshooting

- **`azcmagent connect` fails with `HCRP403` / Azure VM error:** Ensure `win-caldova-exp01` runs on non-Azure hardware/hypervisor (Hyper-V, Proxmox, VMware). Azure VMs expose Azure IMDS (`169.254.169.254`) which blocks Arc onboarding unless Arc VM guest evaluation mode is explicitly configured.
- **`Heartbeat` appears in `law-caldova-central`, but `W3CIISLog` is empty:** IIS buffers W3C logs in `HTTP.sys` for up to 60 seconds under low traffic. Keep `CaldovaExpense-BaselineTraffic` running (`.\onprem\start-traffic-generator.ps1`) or run `netsh http flush logbuffer` on `win-caldova-exp01`.
- **`CaldovaExpenseApp_CL` takes longer than `Event` / `Perf` on first run:** Custom text log tables + DCE associations (`configurationAccessEndpoint`) can take **10–15 minutes** on initial provisioning before the first rows appear.
- **Knowledge file not auto-uploaded during `1-setup-azure-and-sre-agent.ps1`:** Either run `az login --scope "https://azuresre.dev/.default"` and re-run `1-setup-azure-and-sre-agent.ps1`, or open `sre-caldova-expense` in [https://sre.azure.com](https://sre.azure.com) and upload `sre-agent\knowledge\caldova-expense-runbook.md` under **Knowledge**.
