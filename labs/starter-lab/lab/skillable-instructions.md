# Azure SRE Agent Hands-On Lab

Welcome, @lab.User.FirstName! Deploy an **Azure SRE Agent**, break a sample app, and watch it diagnose and fix the issue - all in under 60 minutes.

> [!Knowledge] **Full documentation, architecture diagram, and detailed walkthrough:**
> [Lab README on GitHub](https://github.com/microsoft/sre-agent/tree/main/labs/starter-lab#readme)

| Resource | Value |
|:---------|:------|
| **Azure Portal** | ++https://portal.azure.com++ |
| **Username** | ++@lab.CloudPortalCredential(User1).Username++ |
| **Password** | ++@lab.CloudPortalCredential(User1).Password++ |
| **TAP Password** | ++@lab.CloudPortalCredential(User1).AccessToken++ |
| **Subscription ID** | ++@lab.CloudSubscription.Id++ |

---

## Step 1: Install Python

1. [] Install Python 3:

    ```
    winget install Python.Python.3.12 --accept-source-agreements --accept-package-agreements
    ```

1. [] **Disable Windows Store Python aliases** - Open **Settings → Apps → Advanced app settings → App execution aliases** → turn OFF `python.exe` and `python3.exe`

1. [] **Close and reopen** your CMD window (so Python is in PATH).

---

## Step 2: Clone and Run Setup

1. [] Clone the repo:

    ```
    git clone https://github.com/microsoft/sre-agent.git
    ```

1. [] Navigate to the lab:

    ```
    cd sre-agent\labs\starter-lab
    ```

1. [] Run the setup script — it handles everything (login, deploy, configure):

    ```
    "C:\Program Files\Git\bin\bash.exe" scripts/setup.sh "@lab.CloudSubscription.Id"
    ```

    The script will:
    - ✅ Check prerequisites
    - ✅ Sign in to Azure (use **device code** — open browser inside VM, enter code, sign in with **Username**, **Password**, and **TAP Password** from above)
    - ✅ Sign in to Azure Developer CLI
    - ✅ Register resource providers
    - ✅ Ask for GitHub username (optional — press Enter to skip)
    - ✅ Deploy infrastructure (~5-8 min)
    - ✅ Configure SRE Agent (knowledge base, subagents, Azure Monitor)

1. [] Copy the **Grubify App URL** from the output:

    **Grubify URL:** @lab.TextBox(grubifyUrl)

> [!Alert] If the setup fails partway, you can re-run specific parts:
> ```
> azd up
> "C:\Program Files\Git\bin\bash.exe" scripts/post-provision.sh --retry
> ```

---

## Optional: GitHub (if you skipped during setup)

> [!Note] If you entered a GitHub username during setup, GitHub is already configured. Skip this section.

1. [] Sign in to GitHub CLI:

    ```
    gh auth login
    ```

1. [] Fork the Grubify repo:

    ```
    gh repo fork dm-chelupati/grubify --clone=false
    ```

1. [] Enter your GitHub username: **@lab.TextBox(githubUser)**

1. [] Set it and re-run:

    ```
    azd env set GITHUB_USER "@lab.Variable(githubUser)"
    ```

    ```
    "C:\Program Files\Git\bin\bash.exe" scripts/post-provision.sh --retry
    ```

    When the OAuth URL appears, open it in a browser and click **Authorize**.

> [!Knowledge] **GitHub Issues:** Make sure Issues are enabled on your fork — go to `github.com/@lab.Variable(githubUser)/grubify` → **Settings** → **General** → **Features** → check **Issues**.

===

# Explore Your Agent

1. [] Open <[sre.azure.com](https://sre.azure.com)> and sign in. Find your agent.

1. [] Click **Full Setup** - verify green checkmarks on Code, Incidents, Azure resources.

1. [] Click **"Done and go to agent"** to open the agent chat.

---

## Team Onboarding

The agent opens a **Team onboarding** thread. Try these prompts:

1. [] Ask about the app architecture:

    ```
    What do you know about the Grubify app architecture?
    ```

1. [] Ask about the runbook:

    ```
    Summarize the HTTP errors runbook
    ```

1. [] Ask about Azure resources:

    ```
    What Azure resources are in my resource group?
    ```

1. [] Ask for next steps:

    ```
    What should I do next?
    ```

> [!Knowledge] The agent saves your team information to memory and references it in future investigations.

---

## Test the App

1. [] Open the Grubify app in your browser: `@lab.Variable(grubifyUrl)`
    - Browse restaurants, add an item to cart - **it should work fine**.
    - Remember this for when we break it!

---

## Chat Prompts

Start a **new chat** (click **+ New Chat**) for each prompt:

1. [] Ask about deployed resources:

    ```
    How many container apps are deployed for the Grubify application? List them with their endpoints.
    ```

1. [] Try a knowledge base search:

    ```
    Using the grubify-architecture document in the knowledge base, what are the API routes for the Grubify backend API?
    ```

===

# Break & Investigate

**Goal:** Break the Grubify app and ask the SRE Agent to investigate and remediate.

## Step 1: Break the App

1. [] Run the break script:

    ```
    "C:\Program Files\Git\bin\bash.exe" scripts/break-app.sh
    ```

1. [] Open the **Grubify frontend** in your browser:
    - Try adding an item to cart - it's **slow or returning errors**
    - The app is broken!

## Step 2: Investigate

1. [] Start a **new chat** in the SRE Agent portal.

1. [] Type `/` in the chat box to see available custom agents. Select either **incident-handler** or **code-analyzer** (both work the same way).

1. [] Send this prompt:

    ```
    The Grubify API is not responding - specifically the "Add to Cart" is failing. Can you investigate, find the root cause, and create a GitHub issue with your detailed findings?
    ```

    > [!Knowledge] If you didn't connect GitHub, the agent will still investigate logs + knowledge base and identify the root cause — it just won't create a GitHub issue. If you did connect GitHub, the agent will also search source code for file:line references and create an issue with the fix suggestion.

> [!Hint] If the agent fails to create a GitHub issue or PR, nudge it with:
> ```
> Use the GitHub API to create the issue if the direct tool isn't working
> ```

## Step 3: Remediate

1. [] Ask the agent to fix it:

    ```
    Can you mitigate this issue?
    ```

1. [] Verify the app recovered — open in your browser:

    ```
    @lab.Variable(grubifyUrl)/api/restaurants
    ```

    You should see JSON data. Or refresh the Grubify frontend and try adding to cart again.

---

## Check for Automated Alert

> [!Knowledge] By now (~10-15 min after running break-app.sh in Step 1), Azure Monitor may have fired an alert automatically.

1. [] Go to **sre.azure.com → Activities → Incidents**.

1. [] If an incident appears, click it to see how the agent investigated **autonomously** — without you asking in chat. This is the fully automated incident response flow.

1. [] If you connected GitHub, the agent may have also **created a GitHub issue** automatically with its findings. Check `github.com/@lab.Variable(githubUser)/grubify/issues` for an issue created by the agent.

> [!Knowledge] This is the same investigation you did manually in Step 2, but triggered automatically by Azure Monitor. In production, this means incidents get investigated 24/7 without anyone needing to be online.

===

# Scenario 2: Issue Triage (Optional — Requires GitHub)

> [!Alert] Skip this if you didn't set up GitHub. Jump to **Review & Cleanup**.

**Goal:** The SRE Agent triages customer-reported issues — classifies them, adds labels, and posts a structured comment.

1. [] If sample issues weren't created during setup, create them now:

    ```
    "C:\Program Files\Git\bin\bash.exe" scripts/create-sample-issues.sh @lab.Variable(githubUser)/grubify
    ```

    This creates 5 simulated customer issues like "App crashes when adding items to cart" and "Can't place an order."

1. [] Go to `github.com/@lab.Variable(githubUser)/grubify/issues` — verify the `[Customer Issue]` issues exist.

1. [] Go to **Builder → Scheduled tasks** → find **triage-grubify-issues** → **Run task now**.

1. [] Watch the agent triage each issue — it classifies them (Bug, Performance, Feature Request, Question), adds labels, and posts a comment.

1. [] Check the issues again — each `[Customer Issue]` should now have a triage comment with classification and labels.

===

# Review & Cleanup

## What You Accomplished

| Persona | What the Agent Did |
|:--------|:-------------------|
| **IT Operations** | Investigated logs + KB → identified root cause → remediated |
| **Developer** | Same + source code search → file:line references → GitHub issue |
| **Workflow Automation** | Triaged customer issues → classified → labeled → commented |

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
