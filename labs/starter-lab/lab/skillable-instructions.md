# Azure SRE Agent Hands-On Lab

Welcome, @lab.User.FirstName! Deploy an **Azure SRE Agent**, break a sample app, and watch it diagnose and fix the issue — all in under 60 minutes.

> [!Knowledge] **Full documentation, architecture diagram, and detailed walkthrough:**
> [Lab README on GitHub](https://github.com/microsoft/sre-agent/tree/main/labs/starter-lab#readme)

| Resource | Value |
|:---------|:------|
| **Azure Portal** | @lab.CloudPortal.SignInLink |
| **Username** | ++@lab.CloudPortalCredential(User1).Username++ |
| **Password** | ++@lab.CloudPortalCredential(User1).Password++ |
| **Subscription ID** | ++@lab.CloudSubscription.Id++ |

---

## Step 1: Install Prerequisites

1. [] Install Python 3:

    ```
    winget install Python.Python.3.12 --accept-source-agreements --accept-package-agreements
    ```

1. [] **Disable Windows Store Python aliases** — Open **Settings → Apps → Advanced app settings → App execution aliases** → turn OFF `python.exe` and `python3.exe`

1. [] **Close and reopen** your CMD window (so Python is in PATH).

---

## Step 2: Sign In to Azure

1. [] Sign in to Azure CLI:

    ```
    az login --use-device-code
    ```

    Open a browser **inside the VM**, go to ++https://microsoft.com/devicelogin++, enter the code. Sign in with **Username** and **Password** above (not TAP).

1. [] Set the subscription:

    ```
    az account set --subscription "@lab.CloudSubscription.Id"
    ```

1. [] Register the resource provider:

    ```
    az provider register -n Microsoft.App --wait
    ```

1. [] Sign in to Azure Developer CLI:

    ```
    azd auth login --use-device-code
    ```

    Same process — open browser, enter code, sign in.

---

## Step 3: Deploy

1. [] Clone the repo:

    ```
    git clone https://github.com/microsoft/sre-agent.git
    ```

1. [] Navigate to the lab:

    ```
    cd sre-agent\labs\starter-lab
    ```

1. [] Run prerequisites check:

    ```
    "C:\Program Files\Git\bin\bash.exe" scripts/prereqs.sh
    ```

1. [] Create environment and set location:

    ```
    azd env new sre-lab
    ```

    ```
    azd env set AZURE_LOCATION eastus2
    ```

1. [] Deploy infrastructure (~5-8 min):

    ```
    azd up
    ```

    Select your subscription when prompted.

1. [] Configure the SRE Agent:

    ```
    "C:\Program Files\Git\bin\bash.exe" scripts/post-provision.sh
    ```

    This uploads knowledge base, creates subagents, and configures Azure Monitor.

1. [] Copy the **Grubify App URL** from the output:

    **Grubify URL:** @lab.TextBox(grubifyUrl)

> [!Alert] If `post-provision.sh` fails on the response plan, wait 30 seconds and run:
> ```
> "C:\Program Files\Git\bin\bash.exe" scripts/post-provision.sh --retry
> ```

---

## Optional: GitHub Integration

> [!Note] The core lab (Scenario 1) works **without GitHub**. GitHub unlocks bonus scenarios (source code analysis + issue triage).

1. [] Sign in to GitHub CLI:

    ```
    gh auth login
    ```

    Select **HTTPS** when asked. Follow the browser prompts.

1. [] Fork the Grubify repo:

    ```
    gh repo fork dm-chelupati/grubify --clone=false
    ```

1. [] Enter your GitHub username: **@lab.TextBox(githubUser)**

1. [] Set it in azd:

    ```
    azd env set GITHUB_USER "@lab.Variable(githubUser)"
    ```

1. [] Re-run the setup to configure GitHub:

    ```
    "C:\Program Files\Git\bin\bash.exe" scripts/post-provision.sh --retry
    ```

    When the OAuth URL appears, open it in a browser and click **Authorize**.

===

# Explore Your Agent

1. [] Open <[sre.azure.com](https://sre.azure.com)> and sign in. Find your agent.

1. [] Click **Full Setup** — verify green checkmarks on Code, Incidents, Azure resources.

1. [] Open the Grubify app: `http://@lab.Variable(grubifyUrl)`
    - Browse restaurants, add an item to cart — **it should work fine**.
    - Remember this for when we break it!

1. [] Start a **new chat** in the agent portal. Try:

    ```
    How many container apps are deployed for the Grubify application? List them with their endpoints.
    ```

1. [] Try a knowledge base search:

    ```
    Using the grubify-architecture document in the knowledge base, what are the API routes for the Grubify backend API?
    ```

===

# Scenario 1: Break the App (No GitHub Required)

**Goal:** Break the Grubify app → Azure Monitor fires an alert → SRE Agent investigates autonomously using logs and knowledge base.

1. [] Run the break script:

    ```
    "C:\Program Files\Git\bin\bash.exe" scripts/break-app.sh
    ```

1. [] While waiting (~5-8 min for alerts), open the **Grubify frontend** in your browser:
    - Try adding an item to cart — it's **slow or returning errors**
    - The app is broken!

1. [] Go to **sre.azure.com → Activities → Incidents**. A new incident should appear.

1. [] Click the incident — watch the agent:
    - [] Search memory for similar incidents
    - [] Query Log Analytics (KQL) for error patterns
    - [] Reference the HTTP errors runbook
    - [] Identify the `/api/cart` memory leak
    - [] Apply remediation

1. [] After the agent investigates, ask in the incident thread:

    ```
    Can you mitigate this issue?
    ```

1. [] Verify the app recovered:

    ```
    curl http://@lab.Variable(grubifyUrl)/api/restaurants
    ```

===

# Scenario 2: Source Code Analysis (Requires GitHub)

> [!Alert] Skip this if you didn't set up GitHub. Jump to **Review & Cleanup**.

1. [] Run `"C:\Program Files\Git\bin\bash.exe" scripts/break-app.sh` again for fresh errors.

1. [] Start a **new chat** → type `/agent` → select **code-analyzer**.

1. [] Send:

    ```
    The Grubify API is not responding — specifically the "Add to Cart" is failing. Can you investigate, find the root cause in the source code and create a GitHub issue with your detailed findings?
    ```

1. [] Compare the two GitHub issues at `github.com/@lab.Variable(githubUser)/grubify/issues`:
    - **incident-handler** issue: log evidence only
    - **code-analyzer** issue: logs + source code file:line references + fix suggestion

---

# Scenario 3: Issue Triage (Requires GitHub)

1. [] Go to **Builder → Scheduled tasks** → find **triage-grubify-issues** → **Run task now**.

1. [] Check `github.com/@lab.Variable(githubUser)/grubify/issues` — each `[Customer Issue]` should have a triage comment with classification and labels.

===

# Review & Cleanup

## What You Accomplished

| Persona | What the Agent Did |
|:--------|:-------------------|
| **IT Operations** | Detected alert → investigated logs + KB → remediated |
| **Developer** | Searched source code → file:line references → created detailed issue |
| **Workflow Automation** | Triaged issues → classified → labeled → commented |

## Cleanup

```
azd down --purge
```

## Resources

| Resource | Link |
|:---------|:-----|
| **SRE Agent Portal** | [sre.azure.com](https://sre.azure.com) |
| **Documentation** | [sre.azure.com/docs](https://sre.azure.com/docs) |
| **Blog** | [aka.ms/sreagent/blog](https://aka.ms/sreagent/blog) |
| **Labs** | [aka.ms/sreagent/lab](https://aka.ms/sreagent/lab) |
| **Pricing** | [aka.ms/sreagent/pricing](https://aka.ms/sreagent/pricing) |
| **Support** | [aka.ms/sreagent/github](https://aka.ms/sreagent/github) |

**Thank you for completing this lab, @lab.User.FirstName!**
