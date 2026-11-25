# Caldova On-Premises Lab Setup (`Caldova Expense` — Simple ZIP + Azure Arc Edition)

**Short answer:** Yes — keep it dead simple! On the Windows Server you only need **IIS + SQL Server + Azure Arc** (no Azure DevOps agent, no CI/CD runner, no inbound firewall ports). We deploy the `CaldovaExpense.zip` package once with PowerShell `Expand-Archive` (and any future updates or chaos toggles run remotely via **`az connectedmachine run-command`** over Azure Arc's outbound `443` channel).

> **Only real constraint:** Host it on any non-Azure machine (physical server, Hyper-V, Proxmox, or VMware lab box) so Azure Arc sees genuine non-Azure hardware. Do **not** install K3s/OpenPLC/SAP on this box.

---

## 1. Host & OS Sizing
- **Machine:** 1× non-Azure server or local lab VM (`4 vCPU`, `8 GB RAM`, `80–100 GB SSD`)
- **OS:** Windows Server 2022 or Windows Server 2025 (Standard or Datacenter)
- **Suggested Hostname / FQDN:** `win-caldova-exp01` (`expense.internal.caldovagroup.com`)
- **Suggested Private Subnet:** **`10.50.1.0/24`** (Gateway `10.50.1.1`, Windows Server `10.50.1.10`)
  - *Why `10.50.1.0/24`?* Azure East US 2 uses `10.40.0.0/13` (`10.40/16` Hub + `10.42–10.47/16` Spokes), so `10.50.1.0/24` avoids any CIDR overlap.
- **Inbound Security:** Zero public inbound ports needed (`3389` RDP, `1433` SQL, `5985` WinRM stay closed to the internet).

---

## 2. Core Stack on the Windows Server (IIS + SQL Server + ZIP Deploy)

### A. IIS 10 + .NET Hosting Bundle
```powershell
Install-WindowsFeature -Name Web-Server, Web-WebServer, Web-Common-Http, `
  Web-Default-Doc, Web-Http-Errors, Web-Static-Content, Web-Http-Logging, `
  Web-Request-Monitor, Web-Http-Tracing, Web-Stat-Compression, `
  Web-Security, Web-Filtering, Web-Windows-Auth, `
  Web-App-Dev, Web-Net-Ext45, Web-Asp-Net45, Web-Mgmt-Console, Web-Scripting-Tools `
  -IncludeManagementTools
```
- Install the **.NET 8 Windows Hosting Bundle** (`.NET Framework 4.8` is already built into WS2022/2025).
- Keep **IIS W3C Extended Logging** enabled (`C:\inetpub\logs\LogFiles\W3SVC*`) with `time-taken`, `sc-status`, `cs-uri-stem`.

### B. SQL Server (Local Default Instance)
- **Edition:** **SQL Server 2022 Express** or **Developer Edition** (both free for lab/demo).
- **Database:** `CaldovaExpenseDb` on default instance (`localhost,1433`).
- **Auth:** Grant Windows Integrated Auth (`db_datareader`, `db_datawriter`, `EXECUTE`) to **`IIS APPPOOL\CaldovaExpensePool`** — zero passwords in `web.config` / `appsettings.json`.

### C. Simple One-Command ZIP Deploy (No DevOps Agent Needed)
Drop `CaldovaExpense.zip` onto the box (or pull from a release URL) and extract straight into IIS:
```powershell
New-Item -ItemType Directory -Force -Path C:\inetpub\caldova-expense | Out-Null
Expand-Archive -Path .\CaldovaExpense.zip -DestinationPath C:\inetpub\caldova-expense -Force

Import-Module WebAdministration
if (-not (Test-Path IIS:\AppPools\CaldovaExpensePool)) {
  New-WebAppPool -Name "CaldovaExpensePool"
}
New-Website -Name "CaldovaExpense" -Port 8080 `
  -PhysicalPath "C:\inetpub\caldova-expense" `
  -ApplicationPool "CaldovaExpensePool" -Force
```
*(Later updates or chaos injections don't need CI/CD either — we push a fresh ZIP anytime from Azure using `az connectedmachine run-command create` over Azure Arc!)*

---

## 3. Azure Arc Onboarding (Replaces CI/CD & Enables Monitoring)

1. **Azure Arc Connected Machine Agent (`azcmagent`)**
   - Subscription: `Private Test Sub SAZIZ` (`66a7fcba-dac3-46d8-b509-202f305618c8`)
   - Resource Group: **`rg-hybrid-connectivity`** | Region: **`eastus2`**
   - Needs only outbound HTTPS (`443`) to Azure Arc endpoints.
2. **Azure Monitor Agent (`AMA`)** *(auto-pushed from Azure once Arc is connected!)*
   - You do **not** even need to install AMA manually — once `azcmagent` shows **Connected**, we attach the `AMAWindows` extension + Data Collection Rule from Azure to stream Windows Event Logs (`CaldovaExpense`), IIS W3C logs, and SQL/CPU counters to `law-caldova-central`.

---

## 4. Network & DNS (Lab Router ↔ Azure East US 2)
- **Site-to-Site IPsec VPN (IKEv2):** Connect the lab router / OPNsense (`10.50.1.1`) to Azure Hub VNet **`vnet-hub-eus2` (`10.40.0.0/16`)** in `rg-hub-network` (`eastus2`) *if* you want live cross-network traffic (`Caldova Expense -> SAP FI / Azure Private Endpoints`). *(Note: Even before the VPN tunnel is up, Azure Arc + Log Analytics + Arc Run-Command ZIP deploys already work 100% over outbound HTTPS `443`!)*
- **Optional Private DNS:** Add `expense.internal.caldovagroup.com -> 10.50.1.10` once S2S VPN is up.

---

## 5. Minimal Setup Checklist (5 Steps Total)
- [ ] Spin up Windows Server 2022/2025 VM (`4 vCPU`, `8 GB RAM`, `10.50.1.10/24`) on non-Azure hardware
- [ ] Enable IIS + install `.NET 8 Hosting Bundle`
- [ ] Install SQL Server 2022 Express/Dev, create `CaldovaExpenseDb`, grant `IIS APPPOOL\CaldovaExpensePool` access
- [ ] Unzip `CaldovaExpense.zip` into `C:\inetpub\caldova-expense` on port `8080`/`443`
- [ ] Run `azcmagent connect` into `rg-hybrid-connectivity` (`eastus2`) — we handle AMA logs & future ZIP updates remotely via Arc!
