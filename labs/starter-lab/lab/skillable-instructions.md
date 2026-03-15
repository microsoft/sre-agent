# Azure SRE Agent Hands-On Lab

Welcome, @lab.User.FirstName! In this lab you will deploy an **Azure SRE Agent** connected to a sample application, watch it diagnose and remediate issues autonomously, and explore three personas: **IT Operations**, **Developer**, and **Workflow Automation**.

**Estimated time:** 60 minutes

---

## Lab Environment

| Resource | Value |
|:---------|:------|
| **Azure Portal** | @lab.CloudPortal.SignInLink |
| **Username** | ++@lab.CloudPortalCredential(User1).Username++ |
| **Password** | ++@lab.CloudPortalCredential(User1).Password++ |
| **Subscription ID** | ++@lab.CloudSubscription.Id++ |

---

### Optional: GitHub Integration

> [!Note] The **core lab** (IT Persona — incident detection, log analysis, remediation) works **without GitHub**. If you have a GitHub account, signing in via OAuth during setup unlocks two bonus scenarios: source code root cause analysis and automated issue triage.

If you want to use GitHub:

1. **Fork the Grubify repo** — Open a **Git Bash** terminal and run:

    ```
    gh auth login
    gh repo fork dm-chelupati/grubify --clone=false
    ```

    Follow the browser prompts to sign in. Select **HTTPS** when asked.

2. Enter your GitHub username below:

**GitHub Username:** @lab.TextBox(githubUser)

> [!Alert] GitHub OAuth uses browser sign-in — no tokens to manage. After deployment, sign in via the OAuth URL printed by the setup script. The agent accesses your forked repo through the OAuth connection.

===

# Part 1: Deploy the Environment

In this section you will clone the lab repository and deploy all Azure resources with a single command. The deployment creates:

- **Grubify** — A sample food ordering app on Azure Container Apps
- **Azure SRE Agent** — Connected to the app's resource group with Azure Monitor
- **Knowledge Base** — HTTP error runbooks and app architecture documentation
- **Alert Rules** — Azure Monitor alerts for HTTP 5xx errors and error log spikes
- **Subagent** — Incident handler with search memory and log analysis tools
- *(If GitHub configured)* GitHub OAuth connector, code-analyzer, and issue-triager subagents

> [!Knowledge] Architecture Overview
>
> ```
> ┌──────────────────────────────────────────────────────────────┐
> │                    Azure Resource Group                      │
> │                                                              │
> │  ┌──────────────┐    alerts     ┌────────────────────────┐   │
> │  │  Grubify App  │─────────────▶│   Azure Monitor         │   │
> │  │ (Container    │              │   Alert Rules            │   │
> │  │  Apps)        │              └──────────┬─────────────┘   │
> │  └──────────────┘                         │ auto-flow        │
> │                                           ▼                  │
> │  ┌──────────────┐              ┌───────────────────────────┐ │
> │  │ Log Analytics │◄────logs────│      Azure SRE Agent      │ │
> │  │ + App Insights│              │                           │ │
> │  └──────────────┘              │  ┌─────────────────────┐  │ │
> │                                │  │  Knowledge Base      │  │ │
> │  ┌──────────────┐              │  │  • http-500-errors   │  │ │
> │  │ Managed       │              │  │  • app architecture  │  │ │
> │  │ Identity      │              │  └─────────────────────┘  │ │
> │  │ (Reader RBAC) │              │                           │ │
> │  └──────────────┘              │  ┌─────────────────────┐  │ │
> │                                │  │  Subagents           │  │ │
> │                                │  │  • incident-handler  │  │ │
> │                                │  │  • (code-analyzer)   │  │ │
> │                                │  │  • (issue-triager)   │  │ │
> │                                │  └─────────────────────┘  │ │
> │                                │                           │ │
> │                                │  ┌─────────────────────┐  │ │
> │                                │  │  GitHub OAuth (opt.)  ─┼──┼─▶ GitHub
> │                                │  └─────────────────────┘  │ │
> │                                └───────────────────────────┘ │
> └──────────────────────────────────────────────────────────────┘
> ```

---

### Prerequisites (Windows lab)

> [!Knowledge] **Required before starting:**
>
> 1. **Install Python 3** (needed by the setup script):
>    ```
>    winget install Python.Python.3.12 --accept-source-agreements --accept-package-agreements
>    ```
> 2. **Disable Windows Store Python aliases** — Open **Settings → Apps → Advanced app settings → App execution aliases** → turn OFF `python.exe` and `python3.exe`
> 3. **Register the resource provider:**
>    ```
>    az provider register -n Microsoft.App --wait
>    ```
> 4. **Verify** (open a NEW CMD window):
>    ```
>    python --version
>    git --version
>    az --version
>    azd version
>    ```

### What gets deployed

> [!Knowledge] The deployment creates these resources and configurations:
>
> **Azure Resources** ([learn more](https://sre.azure.com/docs/get-started/create-and-setup)):
> - SRE Agent with managed identity
> - Grubify sample app on Container Apps
> - Log Analytics + App Insights for monitoring
> - Azure Monitor alert rules for HTTP 5xx errors
> - Container Registry for app images
>
> **RBAC Roles** ([learn more](https://sre.azure.com/docs/tutorials/agent-config/manage-permissions)):
> - SRE Agent Administrator on the agent resource
> - Reader + Monitoring Reader + Log Analytics Reader on the resource group
>
> **Agent Configuration** (via post-provision script):
> - Knowledge base files ([Memory & Knowledge](https://sre.azure.com/docs/concepts/memory))
> - incident-handler subagent ([Custom Agents](https://sre.azure.com/docs/concepts/subagents))
> - Azure Monitor incident platform ([Incident Platforms](https://sre.azure.com/docs/concepts/incident-platforms))
> - Response plan for HTTP 500 alerts ([Response Plans](https://sre.azure.com/docs/capabilities/incident-response-plans))
> - *(Optional)* GitHub OAuth connector + code-analyzer + issue-triager ([Connectors](https://sre.azure.com/docs/concepts/connectors))

### Step 1: Sign in to Azure

1. [] Open a **Git Bash** terminal on the lab VM (search for "Git Bash" in the Start menu, or open VS Code and select Git Bash as the terminal).

1. [] Sign in to Azure CLI:

    ```
    az login
    ```

    Follow the browser prompts using the lab credentials shown above.

1. [] Set the subscription:

    ```
    az account set --subscription "@lab.CloudSubscription.Id"
    ```

---

### Step 2: Clone the lab repository

1. [] Clone the lab repo and navigate into it:

    ```
    git clone https://github.com/microsoft/sre-agent.git --branch labs/starter-lab
    cd sre-agent/labs/starter-lab
    ```

---

### Step 3: Deploy with azd up

1. [] Initialize the azd environment:

    ```
    azd env new sre-lab
    ```

1. [] *(Only if you entered GitHub details above)* Set GitHub variables:

    ```
    # GitHub: sign in via OAuth URL after deployment (no PAT needed)
    azd env set GITHUB_USER "@lab.Variable(githubUser)"
    ```

> [!Hint] If you did **not** enter GitHub details, skip the commands above. The core lab works without GitHub.

1. [] Deploy everything with a single command:

    ```
    azd up
    ```

1. [] When prompted, select:
    - **Subscription**: Your lab subscription
    - **Location**: ++eastus2++

> [!Alert] Deployment takes approximately **8-12 minutes**. The command provisions Azure resources via Bicep, deploys the Grubify app, then runs a post-provision script that configures the SRE Agent with knowledge base, subagents, and response plans.

> [!Knowledge] **Windows lab note:** If the post-provision script fails with `'bash' is not recognized` or `Python was not found`, run these commands in a **CMD** window:
>
> ```
> set PATH=%PATH%;C:\Users\LabUser\AppData\Local\Programs\Python\Python312
> "C:\Program Files\Git\bin\bash.exe" scripts/post-provision.sh
> ```
>
> If the Grubify app still shows the default placeholder page after the script completes, deploy the images manually:
>
> ```
> for /f "tokens=*" %a in ('azd env get-value AZURE_CONTAINER_REGISTRY_NAME') do set ACR=%a
> for /f "tokens=*" %a in ('azd env get-value CONTAINER_APP_NAME') do set APP=%a
> for /f "tokens=*" %a in ('azd env get-value FRONTEND_APP_NAME') do set FE=%a
> az containerapp update --name %APP% --resource-group rg-sre-lab --image %ACR%.azurecr.io/grubify-api:latest
> az containerapp update --name %FE% --resource-group rg-sre-lab --image %ACR%.azurecr.io/grubify-frontend:latest
> ```

1. [] Wait for the deployment to complete. You will see a success banner:

    ```
    ✅ SRE Agent Lab Setup Complete!
    SRE Agent Portal:  https://sre.azure.com
    Grubify App:       https://ca-grubify-xxxxx.eastus2.azurecontainerapps.io
    ```

1. [] Copy the **Grubify App URL** from the output and paste it here for quick reference:

    **Grubify URL:** @lab.TextBox(grubifyUrl)

===

# Part 2: Explore the SRE Agent

Before diving into specific scenarios, explore what `azd up` configured for you.

---

### Step 1: Open the SRE Agent Portal

1. [] Open <[sre.azure.com](https://sre.azure.com)> in a browser and sign in with your lab credentials.

1. [] Find your agent in the list and click on it.

> [!Knowledge] The SRE Agent was created via Bicep as a `Microsoft.App/agents` resource with:
> - **Autonomous mode** — the agent takes actions without waiting for approval
> - **Azure Monitor integration** — alerts from your resource group flow to the agent automatically
> - **Managed Identity** — with Reader, Monitoring Reader, and Log Analytics Reader roles on the resource group

---

### Step 2: Explore the Knowledge Base

1. [] Click **Builder** in the left sidebar.

1. [] Select **Knowledge base**.

1. [] Verify you see uploaded files:

    | File | Purpose |
    |:-----|:--------|
    | **http-500-errors.md** | HTTP error troubleshooting runbook with KQL queries |
    | **grubify-architecture.md** | App architecture, endpoints, scaling config |
    | **github-issue-triage.md** | Grubify app issue triage runbook (if GitHub configured) |

> [!Note] These files were uploaded automatically by the post-provision script. The agent references YOUR runbooks during investigations — not generic advice.

---

### Step 3: Explore the Subagents

1. [] Click **Builder** → **Subagent builder**.

1. [] You should see the **incident-handler** subagent with:
    - **Autonomy:** Autonomous
    - **Tools:** SearchMemory, RunAzCliReadCommands, QueryLogAnalyticsByWorkspaceId (+ github/* if GitHub was configured)

1. [] Click on **incident-handler** to see its system prompt and tool assignments.

> [!Knowledge] If you set up GitHub OAuth, you'll also see **code-analyzer** and **issue-triager** subagents on the canvas.

---

### Step 4: Explore Connectors (if GitHub configured)

1. [] Click **Builder** → **Connectors**.

1. [] If you set up GitHub OAuth, you should see **github** with a green **Connected** status.

> [!Hint] If you didn't set up GitHub OAuth and want to add it now, run:
>
> ```
> ./scripts/setup-github.sh
> ./scripts/setup-github.sh
> ```

---

### Step 5: Verify the Grubify App

1. [] In your terminal, check the app is running:

    ```
    curl https://@lab.Variable(grubifyUrl)/api/restaurants
    ```

    You should see a JSON response with weather data.

---

### Step 6: Chat with Your Agent

Before we break things, try a few prompts to see the agent in action.

> [!Alert] Always start a **new chat thread** for each prompt — do not use the welcome thread. Click the **+ New Chat** button in the SRE Agent portal.

1. [] Try one of these prompts (pick either one):

    **Option A** — Ask about deployed resources:
    ```
    How many container apps are deployed for the Grubify application?
    List them with their endpoints.
    ```

    **Option B** — Ask for the frontend URL:
    ```
    What is the public endpoint URL for the Grubify frontend
    container app?
    ```

    The agent should find the container apps and return their URLs. Copy the frontend URL from the response.

1. [] Open the Grubify app in your browser:

    - [] Click the frontend URL the agent gave you
    - [] You should see the Grubify food ordering app with restaurants
    - [] Click on a restaurant, browse the menu
    - [] **Add an item to your cart** — it should work fine
    - [] This is the app working normally — remember this for when we break it!

1. [] Ask about the app's API routes using the knowledge base:

    ```
    Using the grubify-architecture document in the knowledge base,
    what are the API routes for the Grubify backend API?
    Give me a curl command to try one of them.
    ```

    The agent should search the knowledge base, return the API endpoints (restaurants, food items, orders, cart), and give you a curl command. Try running it in your terminal!

> [!Knowledge] These prompts demonstrate the agent's built-in tools: `RunAzCliReadCommands` for Azure resource queries and `SearchMemory` for knowledge base search. All configured automatically by `azd up`.

===

# Part 3: IT Persona — Incident Detection & Remediation

> [!Knowledge] **This is the core lab — no GitHub required.**

**Scenario:** You are an SRE/Ops engineer. The Grubify application starts experiencing memory pressure from a cart API memory leak. Azure Monitor fires alerts for high memory usage and container restarts. The SRE Agent automatically investigates using logs, knowledge base, and memory — then remediates the issue.

```
                  IT Persona Flow
                  ================

  You (run script)                           SRE Agent
  ──────────────                             ─────────
  1. Flood cart API ———————▶ Grubify App ————▶ Memory grows
     (POST /api/cart)                │              │
                                     │              ▼
                                     │        OOM / 500 errors
                                     │
                                     ▼
                              Azure Monitor ————▶ Alerts fire:
                                     │            • High memory (>80%)
                                     │            • Container restarts
                                     │            • HTTP 5xx errors
                                     ▼ (auto-flow)
                               SRE Agent investigates:
                                 ├── Searches memory for similar incidents
                                 ├── Queries Log Analytics (KQL)
                                 │    • Memory metrics over time
                                 │    • OOM / restart events
                                 │    • Error logs + stack traces
                                 ├── Checks knowledge base (runbook)
                                 ├── Applies remediation (restart/scale)
                                 └── Shows investigation summary
```

---

### Step 1: Break the App

1. [] Run the fault injection script:

    ```
    ./scripts/break-app.sh
    ```

    This script:
    - Floods the `/api/cart/demo-user/items` endpoint with rapid POST requests
    - Each request adds items to an in-memory cart, causing memory to grow
    - Eventually the container hits its 1Gi memory limit → OOM kill → restarts
    - Azure Monitor fires alerts for high memory, container restarts, and HTTP errors

> [!Alert] After running the script, **wait 5-8 minutes** for Azure Monitor to fire the alert and the SRE Agent to pick it up. The memory leak takes a few minutes to build up enough pressure to trigger alerts.

1. [] While waiting, go back to the Grubify frontend app in your browser:

    - [] Try adding an item to your cart
    - [] Notice the app is **slow, unresponsive, or returning errors**
    - [] This confirms the app is broken — the memory leak is causing problems
    - [] Compare this to how smoothly it worked in Step 6!

---

### Step 2: Watch the Agent Investigate

1. [] Go back to the SRE Agent portal at <[sre.azure.com](https://sre.azure.com)>.

1. [] Click **Activities** → **Incidents** in the left sidebar.

1. [] A new incident should appear — the Azure Monitor alert for HTTP 5xx errors on Grubify.

1. [] Click on the incident to see the agent's investigation thread.

1. [] Observe the agent's workflow:

    - [] **Memory search**: The agent searches for similar past incidents
    - [] **Log analysis**: Queries Log Analytics for memory pressure indicators, OOM events, and error logs
    - [] **Metrics check**: Analyzes container memory usage trends (WorkingSetBytes rising over time)
    - [] **Knowledge base**: References the http-500-errors.md runbook for memory leak diagnosis steps
    - [] **Root cause**: Identifies the `/api/cart` endpoint accumulating data without eviction
    - [] **Remediation**: Takes corrective action (restart container revision, scale up memory)
    - [] **Summary**: Provides root cause analysis with evidence (memory timeline, error logs, KQL queries)

---

### Step 3: Examine the Investigation Details

1. [] In the agent's investigation thread, look for:

    - [] **Sources** showing references to your knowledge base files
    - [] KQL queries the agent executed against Log Analytics
    - [] Timeline of events (when errors started, when remediation was applied)
    - [] Root cause conclusion

> [!Knowledge] **What just happened?** The entire investigation was autonomous. The response plan routes all Azure Monitor alerts from the managed resource group to the `incident-handler` subagent. That subagent used KQL queries from the knowledge base runbook, searched memory for patterns, checked metrics, and applied remediation — then created a GitHub issue documenting everything. All without human intervention.

---

### Step 4 (Optional): Ask the Agent to Mitigate

> [!Knowledge] This step is optional. If you're short on time, skip ahead to **Part 4**. You can always come back to try mitigation later.

1. [] In the same incident thread, type the following in the chat:

    ```
    Can you mitigate this issue?
    ```

1. [] Watch the agent take action:
    - [] **Mitigate**: The agent may restart the container app revision or scale out replicas to recover
    - [] **Verify**: Checks the app endpoints to confirm it's healthy again

1. [] Once the agent confirms the app is back, verify it yourself:

    ```
    curl https://@lab.Variable(grubifyUrl)/api/restaurants
    ```

    - [] You should get a JSON response — the app is healthy again!

---

### Step 5: Break the App Again (for Part 4)

> [!Alert] Run the break script again to generate fresh error traffic for the Developer persona scenario in Part 4.

```
./scripts/break-app.sh
```

This sends another burst of requests to the cart API, triggering new 500 errors and memory pressure that the code-analyzer subagent will investigate.

===

# Part 4: Developer Persona — Deep Root Cause with Source Code

> [!Alert] **This section requires GitHub OAuth.** If you did not set up GitHub during setup, skip to **Part 6: Review & Cleanup**. You can also add GitHub now by running: `./scripts/setup-github.sh`

**Scenario:** The incident-handler subagent (Part 3) created a GitHub issue using only log analysis. Now use the **code-analyzer** subagent to create a RICHER issue that includes source code references. Compare the two issues to see the value of connecting source code.

> [!Knowledge] **What's different between the two subagents?**
>
> | | incident-handler (Part 3) | code-analyzer (Part 4) |
> |:--|:--|:--|
> | **Log analysis** | ✅ | ✅ |
> | **Knowledge base** | ✅ | ✅ |
> | **Source code search** | ❌ Told NOT to search code | ✅ Searches GitHub repo |
> | **File:line references** | ❌ | ✅ |
> | **Code fix suggestions** | ❌ | ✅ |
> | **GitHub issue detail** | Basic (log evidence only) | Rich (code + logs + fix) |

---

### Step 1: Investigate with Source Code

1. [] In the SRE Agent portal, start a **new chat** by clicking the **+ New Chat** button.

1. [] Type `/agent` in the chat box and select the **code-analyzer** subagent from the dropdown.

1. [] Send the following prompt:

    ```
    The Grubify API is not responding — specifically the "Add to Cart" 
    is failing. Can you investigate, find the root cause in the source 
    code and create a GitHub issue with your detailed findings?
    ```

1. [] Observe the ADDITIONAL steps compared to the incident-handler:
    - [] **Source code search**: Searches the Grubify repo for cart API implementation
    - [] **Code correlation**: Maps error logs to specific functions and files
    - [] **File:line references**: Points to the exact code causing the memory leak
    - [] **Fix suggestion**: Proposes a code change (e.g., add cache eviction, size limit)

---

### Step 2: Compare the Two GitHub Issues

1. [] Go to [github.com/@lab.Variable(githubUser)/grubify/issues](https://github.com/@lab.Variable(githubUser)/grubify/issues).

1. [] Compare the two issues side by side:

    - [] **Issue from incident-handler** (Part 3): Log-based analysis — "Memory pressure detected, container restarted, KQL evidence shows error spike at timestamp X"
    - [] **Issue from code-analyzer** (Part 4): Same log evidence PLUS — "Root cause in `CartService.cs` line 45: in-memory dictionary grows unbounded. Suggested fix: add LRU eviction or max size limit"

> [!Knowledge] **The delta is clear:** Adding source code search to the investigation takes the agent from "what happened" (logs) to "why it happened and how to fix it" (code). Same tools, different instructions — the code-analyzer subagent is instructed to search source code and provide code-level fixes, producing significantly richer findings.

---

### Step 3: Ask the Agent to Mitigate

1. [] Start a **new chat** by clicking the **+ New Chat** button.

1. [] Ask the agent to fix the issue:

    ```
    Can you mitigate the Grubify cart API memory leak issue?
    ```

1. [] Watch the agent:
    - [] **Mitigate**: The agent may restart the container app or scale out replicas
    - [] **Verify** the endpoints are responding

1. [] Confirm the app is back yourself:

    ```
    curl https://@lab.Variable(grubifyUrl)/api/restaurants
    ```

    - [] You should get a JSON response — the app is healthy again!

===

# Part 5: Workflow Automation — Issue Triage

> [!Alert] **This section requires GitHub OAuth.** If you did not set up GitHub during setup, skip to **Part 6: Review & Cleanup**.

**Scenario:** During setup, `azd up` created 5 sample customer-reported issues in `@lab.Variable(githubUser)/grubify` — these simulate real user complaints like "App crashes when adding items to cart" and "Can't place an order." Now use the **issue-triager** subagent to triage those issues — classify them, add labels, and post a structured comment. A scheduled task runs this automatically every 12 hours.

---

### Step 1: Check the Customer Issues

1. [] Go to [github.com/@lab.Variable(githubUser)/grubify/issues](https://github.com/@lab.Variable(githubUser)/grubify/issues).

1. [] You should see several issues — look for the ones with **[Customer Issue]** in the title. These are the simulated customer reports that need triaging.

---

### Step 2: Run the Triage Task

1. [] In the SRE Agent portal, go to **Builder → Scheduled tasks**.

1. [] Find the **triage-grubify-issues** task.

1. [] Click **Run task now** to trigger it immediately.

1. [] Watch the agent:
    - [] Lists open issues from the repository
    - [] Reads each issue and classifies it (Bug, Performance, Feature Request, Question)
    - [] Adds labels (bug, api-bug, memory-leak, severity-high, etc.)
    - [] Posts a triage comment starting with "🤖 **Grubify SRE Agent Bot**"

---

### Step 3: Check the Triage Comments

1. [] Once the task completes, go to [github.com/@lab.Variable(githubUser)/grubify/issues](https://github.com/@lab.Variable(githubUser)/grubify/issues).

1. [] Open one of the **[Customer Issue]** issues (e.g., "App crashes when adding items to cart").

1. [] Scroll down to the comments section. You should see a triage comment:

    - [] Comment starts with "🤖 **Grubify SRE Agent Bot**"
    - [] Classification: Bug, Performance, Feature Request, or Question
    - [] Labels applied: `bug`, `api-bug`, `severity-high`, `needs-more-info`, etc.
    - [] Status line at the end (e.g., "Ready for investigation" or "Waiting for info")

1. [] Check a few other [Customer Issue] issues to see how different types were classified:
    - [] The cart crash → Bug (api-bug, severity-high)
    - [] Slow menu page → Performance
    - [] Restaurant search → Feature Request
    - [] How to clear cart → Question

> [!Knowledge] The triager only processes issues with **[Customer Issue]** in the title — it skips the detailed incident reports created by the incident-handler and code-analyzer (since those are already fully analyzed). The scheduled task runs automatically every 12 hours, so new customer issues get triaged without manual intervention.

===

# Part 6: Review & Cleanup

## What You Learned

| Persona | What the Agent Did | Key Capabilities |
|:--------|:-------------------|:-----------------|
| **IT Operations** | Detected alert → investigated logs + KB → remediated → summarized | Azure Monitor, Knowledge base, Search memory, Autonomous mode |
| **Developer** | Searched source code → correlated logs to code → suggested fixes | GitHub OAuth, Code search, file:line references |
| **Workflow Automation** | Triaged issues → classified → labeled → commented | GitHub OAuth tools, Runbook-driven automation |

---

## What azd up Automated

Everything below was configured automatically when you ran `azd up`:

- [] SRE Agent resource (Bicep: `Microsoft.App/agents`)
- [] Managed Identity with Reader + Monitoring Reader + Log Analytics Reader RBAC (Bicep)
- [] Log Analytics Workspace + Application Insights (Bicep)
- [] Grubify Container App with external ingress (Bicep)
- [] Azure Monitor alert rules — HTTP 5xx metric + error log alerts (Bicep)
- [] Knowledge base files uploaded (post-provision script)
- [] Incident handler subagent created (post-provision script)
- [] Incident response plan created (post-provision script)
- [] *(If GitHub configured)* GitHub OAuth connector, code-analyzer, issue-triager, sample customer issues (post-provision script)

---

## Key SRE Agent Concepts

> [!Knowledge] Quick reference for the concepts you explored:
>
> - **[Managed Resources](https://sre.azure.com/docs/capabilities/incident-response)**: Resource group IDs the agent monitors — Azure Monitor alerts from these RGs flow automatically
> - **[Knowledge Base](https://sre.azure.com/docs/concepts/memory)**: Your team's runbooks, uploaded as files — the agent references them during investigations
> - **[Memory](https://sre.azure.com/docs/concepts/memory)**: The agent learns from every conversation — past incidents, user memories, and knowledge base are all searchable via SearchMemory
> - **[Subagents](https://sre.azure.com/docs/concepts/subagents)**: Specialized agents with specific tools and instructions for different tasks — invoke with `/agent` in chat
> - **[Agent Identity](https://sre.azure.com/docs/concepts/permissions)**: A managed identity assigned to the agent, granting it Reader/Monitoring/Log Analytics access to your Azure resources
> - **[Connectors](https://sre.azure.com/docs/concepts/connectors)**: External tool integrations (GitHub, Datadog, etc.) using the Model Context Protocol
> - **[Response Plans](https://sre.azure.com/docs/capabilities/incident-response)**: Rules that match incoming alerts to subagents based on severity and title patterns
> - **[Scheduled Tasks](https://sre.azure.com/docs/capabilities/scheduled-tasks)**: Cron-based automation that runs a subagent on a schedule (e.g., triage issues every 12 hours)
> - **[Autonomous Mode](https://sre.azure.com/docs/concepts/subagents)**: The agent takes actions without requiring human approval

---

## Cleanup

1. [] Tear down all Azure resources:

    ```
    azd down --purge
    ```

1. [] Delete the SRE Agent resource (not removed by azd down):

    ```
    az resource delete --ids $(az resource list --resource-group rg-$(azd env get-value AZURE_ENV_NAME) --resource-type Microsoft.App/agents --query "[0].id" -o tsv) 2>/dev/null
    ```

1. [] Delete the resource group if it still exists:

    ```
    az group delete --name rg-$(azd env get-value AZURE_ENV_NAME) --yes --no-wait
    ```

> [!Alert] This **permanently deletes** all Azure resources. Make sure you have saved any notes or screenshots before proceeding.

> [!Note] `azd down` does not currently recognize the `Microsoft.App/agents` resource type, so the SRE Agent must be deleted separately.

===

# Congratulations! 🎉

You have successfully deployed and explored Azure SRE Agent across three personas:

1. **IT Operations** — Autonomous incident detection, investigation, and remediation using logs and knowledge base
2. **Developer** — Source code root cause analysis with file:line references
3. **Workflow Automation** — Automated GitHub issue triage following a custom runbook

All of this was set up with a single `azd up` command.

## Resources

- [Azure SRE Agent Documentation](https://sre.azure.com/docs)
- [Azure SRE Agent Portal](https://sre.azure.com)
- [Grubify Sample App](https://github.com/dm-chelupati/grubify)
- [Lab Source Code](https://github.com/microsoft/sre-agent/tree/labs/starter-lab/labs/starter-lab)

**Thank you for completing this lab, @lab.User.FirstName!**
