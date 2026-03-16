# Fix It Before They Feel It: Higher Reliability with Proactive Mitigation

**Using Azure SRE Agent for Autonomous Performance Monitoring and Remediation**

---

## 📺 Watch the Demo

This content was presented at **.NET Day 2025**. Watch the full session to see Azure SRE Agent in action:

[![Watch on YouTube](https://img.shields.io/badge/YouTube-Watch%20Demo-red?style=for-the-badge&logo=youtube)](https://www.youtube.com/watch?v=Kx_6SB-mhgg)

🎬 **[Fix it before they feel it - .NET Day 2025](https://www.youtube.com/watch?v=Kx_6SB-mhgg)**

---

What if your infrastructure could detect performance issues and fix them automatically—before your users even notice? This blog brings that vision to life using **Azure SRE Agent**, an AI-powered autonomous agent that monitors, detects, and remediates production issues in real-time.

> 💡 **The magic**: Zero human intervention required. The agent handles detection, diagnosis, remediation, and reporting—all autonomously.

## 🎯 What You'll See in This Demo

Watch as we intentionally deploy "bad" code to production and observe how the SRE Agent:

1. **Detects the degradation** — Compares live response times against learned baselines
2. **Takes autonomous action** — Executes a slot swap to roll back to healthy code
3. **Communicates the incident** — Posts to Teams and creates a GitHub issue
4. **Generates reports** — Summarizes MTTD/MTTR metrics for stakeholders

## 🚀 Key Capabilities

| Capability | What It Shows |
|------------|---------------|
| **Proactive Baseline Learning** | Agent learns normal response times and stores them in a knowledge base |
| **Real-time Anomaly Detection** | Instant comparison of current vs. baseline metrics |
| **Autonomous Remediation** | Agent executes Azure CLI commands to swap slots without human approval |
| **Cross-platform Communication** | Automatic Teams posts and GitHub issue creation |
| **Incident Reporting** | End-of-day email summaries with deployment health metrics |

## Architecture Overview

The solution uses Azure SRE Agent with three specialized sub-agents working together:

![Architecture Diagram](https://raw.githubusercontent.com/meetshamir/dotnetday/main/docs/images/architecture-diagram.png)

### Components

**Application Layer:**
- .NET 9 Web API running on Azure App Service
- Application Insights for telemetry collection
- Azure Monitor Alerts for incident triggers

**Azure SRE Agent:**
- **AvgResponseTime Sub-Agent**: Captures baseline metrics every 15 minutes, stores in Knowledge Store
- **DeploymentHealthCheck Sub-Agent**: Triggered by deployment alerts, compares metrics to baseline, auto-remediates
- **DeploymentReporter Sub-Agent**: Generates daily summary emails from Teams activity

**External Integrations:**
- GitHub (issue creation, semantic code search, Copilot assignment)
- Microsoft Teams (incident notifications)
- Outlook (summary reports)

## Demo Flow

**[View Step-by-Step Instructions →](https://github.com/meetshamir/dotnetday#demo-flow)**

| Step | Action |
|------|--------|
| **Step 1** | [Deploy Infrastructure + Applications](https://github.com/meetshamir/dotnetday#step-1-setup-demo-environment) |
| **Step 2** | [Create Sub-Agents, Triggers & Schedules](https://github.com/meetshamir/dotnetday#step-2-configure-azure-sre-agent) |
| **Step 3** | [Swap bad code, watch agent remediate](https://github.com/meetshamir/dotnetday#step-3-run-the-demo) |

## Setting Up the Demo

### Prerequisites

- Azure subscription with Contributor access
- Azure CLI installed and logged in (`az login`)
- .NET 9.0 SDK
- PowerShell 7.0+

### Step 1: Deploy Infrastructure

```powershell
cd scripts
.\1-setup-demo.ps1 -ResourceGroupName "sre-demo-rg" -AppServiceName "sre-demo-app-12345"
```

This script will:
1. Prompt for Azure subscription selection
2. Deploy Azure infrastructure (App Service, App Insights, Alerts)
3. Build and deploy **healthy** code to production
4. Build and deploy **problematic** code to staging

**[Full Setup Instructions →](https://github.com/meetshamir/dotnetday#step-1-setup-demo-environment)**

### Step 2: Configure Azure SRE Agent

Navigate to Azure SRE Agents Portal Sub Agent builder tab and create three sub-agents:

| Sub-Agent | Purpose | Tools Used |
|-----------|---------|------------|
| **AvgResponseTime** | Captures baseline response time metrics | QueryAppInsightsByAppId, UploadKnowledgeDocument |
| **DeploymentHealthCheck** | Detects degradation and executes remediation | SearchMemory, QueryAppInsights, PostTeamsMessage, CreateGithubIssue, Az CLI commands |
| **DeploymentReporter** | Generates deployment summary reports | GetTeamsMessages, SendOutlookEmail |

#### Creating Each Sub-Agent

**AvgResponseTime + Baseline Task:**
![AvgResponseTime Sub-Agent Creation](https://github.com/meetshamir/dotnetday/blob/main/docs/screenshots/sre-agent/baseline.gif?raw=true)

**[Detailed Instructions →](https://github.com/meetshamir/dotnetday#creating-avgresponsetime-sub-agent--baselinetask-trigger)**

**DeploymentHealthCheck + Swap Alert:**
![DeploymentHealthCheck Sub-Agent Creation](https://github.com/meetshamir/dotnetday/blob/main/docs/screenshots/sre-agent/healthcheck.gif?raw=true)

**[Detailed Instructions →](https://github.com/meetshamir/dotnetday#creating-deploymenthealthcheck-sub-agent--swap-alert-trigger)**

**DeploymentReporter + Reporter Task:**
![DeploymentReporter Sub-Agent Creation](https://github.com/meetshamir/dotnetday/blob/main/docs/screenshots/sre-agent/reporter.gif?raw=true)

**[Detailed Instructions →](https://github.com/meetshamir/dotnetday#creating-deploymentreporter-sub-agent--reportertask-trigger)**

### Step 3: Run the Demo

```powershell
.\2-run-demo.ps1
```

This triggers the following flow:

```
Slot Swap Occurs (demo script)
       │
       ▼
Activity Log Alert Fires
       │
       ▼
Incident Trigger Activated
       │
       ▼
DeploymentHealthCheck Agent Runs
       │
       ├── Queries current response time from App Insights
       ├── Retrieves baseline from knowledge store
       ├── Compares (if >20% degradation)
       │   └── Executes: az webapp deployment slot swap
       ├── Creates GitHub issue (if degraded)
       └── Posts to Teams channel
```

**[Full Demo Instructions →](https://github.com/meetshamir/dotnetday#step-3-run-the-demo)**

## Demo Timeline

| Time | Event |
|------|-------|
| 0:00 | Run `2-run-demo.ps1` |
| 0:30 | Swap staging → production (bad code deployed) |
| 1:00 | Production now slow (~1500ms vs ~50ms baseline) |
| ~5:00 | Slot Swap Alert fires |
| ~5:04 | Agent executes slot swap (rollback) |
| ~5:30 | Production restored to healthy state |
| ~6:00 | Agent posts to Teams, creates GitHub issue |

## How the Performance Toggle Works

The app has a compile-time toggle in `ProductsController.cs`:

```csharp
private const bool EnableSlowEndpoints = false;  // false = fast, true = slow
```

The setup script creates two versions:
- **Production**: `EnableSlowEndpoints = false` → ~50ms responses
- **Staging**: `EnableSlowEndpoints = true` → ~1500ms responses (artificial delay)

## Get Started

🔗 **Full source code and instructions**: [github.com/meetshamir/dotnetday](https://github.com/meetshamir/dotnetday)

🔗 **Azure SRE Agent documentation**: [https://learn.microsoft.com/en-us/azure/sre-agent/](https://learn.microsoft.com/en-us/azure/sre-agent/)

---

## Technology Stack

- **Framework**: ASP.NET Core 9.0
- **Infrastructure**: Azure Bicep
- **Monitoring**: Application Insights + Log Analytics
- **Automation**: Azure SRE Agent
- **Scripts**: PowerShell 7.0+

---

*This demo was presented at .NET Day, showcasing how AI-powered autonomous agents can dramatically improve reliability by detecting and fixing issues before users are impacted.*

---

**Tags**: Azure, SRE Agent, DevOps, Reliability, .NET, App Service, Application Insights, Autonomous Remediation
