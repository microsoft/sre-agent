# Test Plan — SRE Agent IaC Toolkit

## Test flow (same for all scenarios)

1. `new-agent.sh` → create config directory
2. Verify output: files exist, placeholders resolved, secrets in .env, no EDIT_ME
3. `deploy.sh` → real Azure (S1-S3) or mocked (S4-S5)
4. Verify deployed agent: connectors healthy, skills present, subagents configured
5. `clone-agent.sh --from-agent` → clone to different region
6. Verify clone output + edit agent.json (new name/region)
7. Deploy clone → verify
8. Teardown: delete both agents + RGs

## 5 test scenarios

### Scenario 1: AzMonitor + core config

- Connectors: AppInsights, AzureMonitor, GitHub, Teams
- Config: 2 skills, 2 subagents (handoff chain), 2 hooks, 2 common prompts, scheduled task, HTTP trigger, incident filter (AzMon Sev0+1), GitHub repo
- Auth: MI (AI, AzMon), OAuth (GitHub), api-connection (Teams)
- Real Azure

### Scenario 2: PagerDuty + Kusto/MCP/ADO

- Connectors: LogAnalytics, Kusto, Dynatrace MCP, ADO (PAT), Outlook
- Config: 1 skill, 1 subagent, KustoTool, PythonTool, incident filter (PD high), knowledge doc, repo instructions
- Auth: MI (LAW, Kusto), bearer token (Dynatrace), PAT (ADO), api-connection (Outlook)
- Platform: PagerDuty
- Real Azure

### Scenario 3: ServiceNow + Datadog

- Connectors: AppInsights, Datadog MCP, HttpClientTool
- Config: 1 skill, 1 subagent, HttpClientTool, plugin config, incident filter (SNOW P1+P2)
- Auth: MI (AI), bearer token (Datadog)
- Platform: ServiceNow
- Real Azure

### Scenario 4: 1P IcM same-tenant (cert via Key Vault)

- Connectors: IcM (cert/KV), DGrep, GenevaMetrics, AppInsights
- Config: ICM skill, ICM subagent, incident filter (IcM Sev0+1), hooks, prompts, task
- 1P: adminUsers (same tenant)
- Auth: Cert/KV (IcM), MI (DGrep, Geneva, AI)
- Mocked

### Scenario 5: 1P IcM cross-tenant (MI + FIC)

- Connectors: IcM (MI), Kusto (ADO MI+FIC), GenevaMetrics, DGrep
- Config: same skill/subagent as S4, incident filter
- 1P: adminUsers (CORP→AME), ADO MI+FIC
- Auth: MI (IcM, DGrep, Geneva), MI+FIC (ADO Kusto)
- Mocked

## Coverage matrix — Connectors

| Connector | S1 | S2 | S3 | S4 | S5 |
|---|:---:|:---:|:---:|:---:|:---:|
| AppInsights | ✅ | | ✅ | ✅ | |
| LogAnalytics | | ✅ | | | |
| AzureMonitor | ✅ | | | | |
| Kusto/ADX | | ✅ | | | ✅ |
| Dynatrace MCP | | ✅ | | | |
| Datadog MCP | | | ✅ | | |
| GitHub | ✅ | | | | |
| ADO (PAT) | | ✅ | | | |
| ADO (MI+FIC) | | | | | ✅ |
| Teams | ✅ | | | | |
| Outlook | | ✅ | | | |
| IcM (cert/KV) | | | | ✅ | |
| IcM (MI) | | | | | ✅ |
| DGrep | | | | ✅ | ✅ |
| GenevaMetrics | | | | ✅ | ✅ |
| PagerDuty | | ✅ | | | |
| ServiceNow | | | ✅ | | |
| AzMonitor alerts | ✅ | | | | |

## Coverage matrix — Config items

| Config | S1 | S2 | S3 | S4 | S5 |
|---|:---:|:---:|:---:|:---:|:---:|
| Skills | ✅ 2 | ✅ 1 | ✅ 1 | ✅ 1 | ✅ 1 |
| Subagents + handoffs | ✅ 2 | ✅ 1 | ✅ 1 | ✅ 1 | ✅ 1 |
| KustoTool | | ✅ | | | |
| PythonTool | | ✅ | | | |
| HttpClientTool | | | ✅ | | |
| Hooks | ✅ 2 | | | ✅ | |
| Common prompts | ✅ 2 | | | ✅ | |
| Scheduled task | ✅ | | | ✅ | |
| HTTP trigger | ✅ | | | | |
| Incident filter | ✅ | ✅ | ✅ | ✅ | ✅ |
| Repo | ✅ | | | | |
| Plugin config | | | ✅ | | |
| Knowledge | | ✅ | | | |
| Repo instructions | | ✅ | | | |
| Cross-tenant | | | | | ✅ |

## Coverage matrix — Auth types

| Auth type | S1 | S2 | S3 | S4 | S5 |
|---|:---:|:---:|:---:|:---:|:---:|
| MI (auto RBAC) | ✅ | ✅ | ✅ | ✅ | ✅ |
| Bearer token | | ✅ | ✅ | | |
| OAuth (GitHub) | ✅ | | | | |
| PAT (ADO) | | ✅ | | | |
| MI+FIC (ADO) | | | | | ✅ |
| Cert/Key Vault (IcM) | | | | ✅ | |
| api-connection (Teams) | ✅ | | | | |
| api-connection (Outlook) | | ✅ | | | |
| Portal setup (PD/SNOW) | | ✅ | ✅ | | |
