# azmon-aca-servicenow-powergrid-ops

PowerGrid SRE ops agent — investigates ACA incidents, correlates AppInsights/LAW, auto-remediates (scale, rollback, fix-PR), syncs to ServiceNow.

## What this recipe ships

- 8 subagents: deployment-validator, incident-handler, pipeline-failure-investigator, pod-incident-remediator, release-orchestrator, utility-ops-agent, vm-ops-agent, web-app-troubleshooter
- 15 skills (PowerGrid runbooks)
- ServiceNow MCP connector for bi-directional incident sync
- Azure Monitor + App Insights + Log Analytics connectors
- Safety hooks (deny-prod-deletes, require-approval-for-restarts)
- Response plan filter for Sev0/Sev1 alerts

## Prerequisites

See `agent.json._prerequisites`. The companion lab at
`labs/powergrid-zeroops/` provides an `azd up` deployment of the underlying
Container Apps + observability + ServiceNow integration.

## Deploy

```bash
./bin/new-agent.sh --recipe azmon-aca-servicenow-powergrid-ops --target ./my-agent
cd my-agent
# Fill .env with secrets (SN_PASSWORD, GITHUB_PAT)
./bin/deploy.sh
./bin/verify-agent.sh
```

## Source

This recipe is generated from
[`microsoft/sre-agent/labs/powergrid-zeroops/sre-config/`](../../labs/powergrid-zeroops/sre-config/)
via `setup/generate-recipes.py`. Edit the lab source and re-run the generator
to refresh.
