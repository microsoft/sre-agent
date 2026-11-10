# SRE Agent + on-prem VM telemetry lab

This lab runs a fault-injectable ASP.NET Core application and a tiny load generator in Docker on an Ubuntu VM hosted by Hyper-V. The Ubuntu VM is connected to Azure Arc. Azure Monitor Agent sends host telemetry, Syslog, and `/var/log/sre-lab/app.log` to Log Analytics. Azure SRE Agent investigates the simulated outage using telemetry only.

## Architecture

Windows + Hyper-V -> Ubuntu VM -> Docker (`app`, `loadgen`) -> Azure Arc/AMA -> DCRs -> Log Analytics -> SRE Agent

## Prerequisites

- Windows 11 Pro/Enterprise with Hyper-V, or another local hypervisor
- Ubuntu 22.04/24.04 x64 VM with outbound HTTPS
- About 2 vCPU, 4 GB RAM, and 30 GB disk for the lab VM
- Azure subscription and permissions to create resources, role assignments, and an SRE Agent
- Azure CLI on the admin workstation
- PowerShell 7 recommended for the Azure script

## 1. Prepare the Ubuntu VM

Copy this repository to the VM, then run:

```bash
cd sre-agent-onprem-lab
./scripts/setup-host.sh
```

Sign out and back in so Docker group membership applies. Start and test the workload:

```bash
./scripts/start-lab.sh
./scripts/test-lab.sh
docker compose logs -f loadgen
```

The healthy load generator should receive HTTP 200 every five seconds. The control endpoint is published only on `127.0.0.1:8080`.

## 2. Onboard the VM to Azure Arc

Register the required providers if needed:

```powershell
$sub = "YOUR-SUBSCRIPTION-ID"
az account set --subscription $sub
@("Microsoft.HybridCompute","Microsoft.GuestConfiguration","Microsoft.HybridConnectivity","Microsoft.AzureArcData") | ForEach-Object { az provider register --namespace $_ }
az group create -n rg-sre-onprem-lab -l eastus
```

In Azure portal, open **Azure Arc > Infrastructure > Machines > Onboard/Create > Onboard existing machines**, choose **Add a single server**, and generate a Linux onboarding script for:

- Resource group: `rg-sre-onprem-lab`
- Region: `eastus` (or your chosen supported region)
- Connectivity: public endpoint

Copy that generated script to Ubuntu and execute it with `sudo`. Verify:

```bash
sudo azcmagent show
sudo azcmagent check
```

Continue only when `Agent Status` is `Connected`.

## 3. Deploy Log Analytics and collection rules

From PowerShell on the admin workstation:

```powershell
cd azure
./deploy-monitoring.ps1 -SubscriptionId "YOUR-SUBSCRIPTION-ID"
```

The script creates:

- `law-sre-onprem-lab`
- `SreLabApp_CL`
- Azure Monitor Agent extension on the Arc machine
- Host DCR for performance counters and Syslog
- App DCR for `/var/log/sre-lab/app.log`
- DCR associations to `sre-onprem-01`

Wait 5-15 minutes. On Ubuntu, generate a Syslog probe:

```bash
logger -p user.error -t sre-lab "sre-lab pipeline test"
```

Use the KQL files under `queries/` to confirm Heartbeat, Syslog, and application telemetry.

## 4. Create and configure SRE Agent

Create an SRE Agent in the current SRE Agent portal experience. Keep its resource group separate, for example `rg-sre-agent`.

Add `rg-sre-onprem-lab` as a managed resource at Reader level. Add `law-sre-onprem-lab` as a Log Analytics telemetry source/connector if that option is present. Confirm the agent can discover `Heartbeat`, `Perf`, `Syslog`, and `SreLabApp_CL`.

## 5. Run the investigation

On Ubuntu:

```bash
./scripts/fault.sh status
./scripts/fault.sh http500
```

Wait about five minutes for ingestion, then ask SRE Agent:

> The application running on the Arc-enabled server sre-onprem-01 appears to be unhealthy. Investigate what happened and when it started.

A useful investigation should find the first HTTP 500, identify the `upstream dependency unavailable` message, and use Heartbeat/CPU/memory/Syslog to rule out a host-level failure.

Recover the application:

```bash
./scripts/fault.sh reset
```

## 6. Interpret the logs correctly

Every failed request writes two ERROR records: an exception line and a request-completion line containing `status=500`. Count only request-completion records when calculating request failure rate. `queries/error-rate.kql` applies this filter.

The upstream dependency is simulated by application state. This version demonstrates telemetry-driven investigation, not verification of a real dependency outage.

## Cleanup

Stop local containers:

```bash
./scripts/stop-lab.sh
```

Delete Azure lab resources after reviewing the command:

```powershell
./azure/cleanup.ps1 -SubscriptionId "YOUR-SUBSCRIPTION-ID" -WhatIf
./azure/cleanup.ps1 -SubscriptionId "YOUR-SUBSCRIPTION-ID" -Confirm
```

Delete the separately created SRE Agent resource group when no longer needed. If you intend to reuse the VM, disconnect the Arc agent cleanly before cloning or restoring older checkpoints.

## Troubleshooting

- `hello-world` pull fails: verify outbound HTTPS and access to Docker/Microsoft registries.
- Arc onboarding fails: run `sudo azcmagent check`; validate DNS, proxy, TLS inspection, and required endpoints.
- Heartbeat exists but tables are empty: confirm DCR associations and wait for the rule to reach AMA.
- Syslog probe is missing: ensure the probe was generated after DCR rollout and appears in `/var/log/syslog`.
- `SreLabApp_CL` empty: check `ls -l /var/log/sre-lab/app.log`, AMA service status, DCR association, and allow up to 15 minutes for the first rows.
