# SRE Agent Architecture — Zava Power Limited

## One Agent, Operations Focus

Zava Power Limited operates one SRE Agent dedicated to infrastructure operations:

- **sre-zavapower-ops** — Infrastructure operations, deployment validation, incident response

> IT helpdesk / ServiceNow ticket processing has been extracted into the standalone
> [`labs/zava-itsupport`](../../zava-itsupport/) lab.

---

## sre-zavapower-ops — Infrastructure Operations

### Trigger Routing

```
ADO Release Pipeline (BuildSucceeded)
  → deployment-validator agent
  → Proactively checks health after every deploy
  → Identifies which microservice was deployed
  → Picks the right diagnostic skill

ADO Build Pipeline (BuildFailed)
  → incident-handler agent
  → Reads build logs, finds compile/import errors
  → Creates fix PR in ADO

Azure Monitor Alert (title contains "disk")
  → vm-ops-agent
  → Investigates VM disk pressure
  → Uses disk-pressure-diagnosis skill

Azure Monitor Alert (all other alerts)
  → incident-handler agent
  → General investigation (latency, errors, load)
  → Uses appropriate diagnostic skill

Scheduled (every 30 min)
  → utility-ops-agent
  → Continuous anomaly detection across all services
```

### Agents (4)

| Agent | Purpose | Trigger |
|---|---|---|
| **deployment-validator** | Post-deploy health check. Reads pipeline run to identify which service was deployed, checks its health, picks the right diagnostic skill if unhealthy. | Release pipeline succeeds |
| **incident-handler** | General-purpose investigator. Handles Azure Monitor alerts (non-disk) and build pipeline failures. Reads logs, correlates with deployments, creates fix PRs. | Azure Monitor alerts + Build failures |
| **vm-ops-agent** | VM infrastructure specialist. Handles disk pressure, CPU spikes, memory issues on Azure VMs. Runs commands on VMs via az vm run-command. | Azure Monitor alerts (disk) |
| **utility-ops-agent** | Continuous anomaly detection. Proactively checks all service health endpoints, App Insights error rates, and Azure Monitor for active alerts. | Scheduled task (every 30 min) |

### Tools (4)

All ServiceNow REST API tools for incident lifecycle:

| Tool | Purpose |
|---|---|
| **CreateServiceNowIncident** | Creates INC ticket with short_description, urgency, impact |
| **UpdateServiceNowWorkNotes** | Adds [SRE Agent] work notes for audit trail |
| **ResolveServiceNowIncident** | Sets state=Resolved with resolution notes |
| **LookupServiceNowIncident** | Translates INC number to sys_id |

ServiceNow instance: https://dev268981.service-now.com

### Skills (7)

| Skill | Purpose | Used By |
|---|---|---|
| **outage-api-diagnosis** | Investigate Python/Flask crashes — tracebacks, NoneType errors, import failures | deployment-validator, incident-handler |
| **meter-api-diagnosis** | Investigate .NET OOM kills, memory leaks, GC pressure | deployment-validator, incident-handler |
| **grid-status-diagnosis** | Investigate Node.js latency — event loop blocking, CPU-bound operations | deployment-validator, incident-handler |
| **notification-svc-diagnosis** | Investigate Go crashes — missing config, wrong endpoints, CrashLoopBackOff | deployment-validator, incident-handler |
| **deployment-rollback** | Safely rollback ACA revisions — list revisions, activate previous, validate | deployment-validator, incident-handler |
| **disk-pressure-diagnosis** | Investigate VM disk space — find large files, classify cause, cleanup or expand | vm-ops-agent |
| **servicenow-incident-mgmt** | Full SNOW ticket lifecycle — create, document at each step, resolve | All agents |

### Incident Filters (2)

| Filter | Matches | Routes To |
|---|---|---|
| **vm-disk-alert** | Alert title contains "disk" | vm-ops-agent |
| **auto-investigate** | All other Azure Monitor alerts | incident-handler |

### Release Triggers (2)

| Trigger | Pipeline | Event | Routes To |
|---|---|---|---|
| **Post-Deploy Validation** | PowerGrid-Release (ID: 5) | BuildSucceeded | deployment-validator |
| **Build Failure Investigation** | PowerGrid-Build (ID: 4) | BuildFailed | incident-handler |

### Knowledge Base (2 docs)

| Document | Purpose |
|---|---|
| **powergrid-architecture.md** | System topology — all 5 services, endpoints, naming conventions, dependencies |
| **incident-report-template.md** | ServiceNow field mapping, priority matrix, required sections |

---

## Infrastructure

### Compute (3 types)

| Type | Resource | Service |
|---|---|---|
| **App Service** | app-powergrid-portal | React customer portal (Zava Power Electric branding) |
| **Container Apps** | ca-powergrid-outage | Python/Flask outage reporting API |
| **Container Apps** | ca-powergrid-meter | .NET 8 smart meter data API |
| **Container Apps** | ca-powergrid-grid | Node.js grid status API |
| **Container Apps** | ca-powergrid-notify | Go notification service |
| **Azure VM** | vm-powergrid-arc | Simulated on-prem grid management server |

### Observability

| Resource | Purpose |
|---|---|
| law-powergrid | Log Analytics workspace — container logs, VM metrics |
| ai-powergrid | Application Insights — request traces, exceptions, dependencies |
| grafana-powergrid | Managed Grafana — dashboards |
| alert-powergrid-http-5xx | Azure Monitor — fires on 5xx error spike |
| alert-powergrid-high-latency | Azure Monitor — fires on avg latency > 3s |

### CI/CD (ADO)

| Pipeline | Purpose |
|---|---|
| PowerGrid-Build (ID: 4) | Builds container images, runs tests. failure_scenario param injects demo bugs. |
| PowerGrid-Release (ID: 5) | Deploys images to ACA + App Service, validates health. |

### Identity

All service-to-service auth uses Managed Identity (no secrets):
- id-powergrid-sre: SRE Agent identity (Reader, Monitoring Reader, Log Analytics Reader, Website Contributor)
- id-powergrid-apps: Container Apps identity (AcrPull)
- App Service system MI: AcrPull
- VM system MI: Monitoring Contributor
