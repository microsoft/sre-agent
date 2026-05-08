# Secrets Management

## Where secrets are stored

| Secret | GitHub Actions | Local dev |
|---|---|---|
| PagerDuty API key | Repo secret: `PAGERDUTY_API_KEY` | `connectors.secrets.env` |
| Dynatrace token | Repo secret: `DYNATRACE_BEARER_TOKEN` | `connectors.secrets.env` |
| Azure credentials | `AZURE_CREDENTIALS` (service principal JSON) | `az login` |

## How secrets flow

```
GitHub Secret / Azure Key Vault
    ↓
new-agent.sh --set pagerdutyApiKey=${{ secrets.PAGERDUTY_API_KEY }}
    ↓
connectors.secrets.env (local only, gitignored)
    ↓
deploy.sh reads env file → passes to ARM / data-plane
```

## Local development

```bash
# connectors.secrets.env is auto-created by new-agent.sh
# Edit to add/change secrets:
cat my-agent/connectors.secrets.env
# PAGERDUTY_API_KEY=u+abCdEf...
# DYNATRACE_BEARER_TOKEN=dt0c01.ABCDEF...
```

> **Never commit `connectors.secrets.env`** — it's in `.gitignore` by default.

## GitHub Actions setup

```yaml
env:
  RECIPE: "azmon-lawappinsights"
  AGENT_NAME: "my-agent"
  RESOURCE_GROUP: "rg-my-agent"
  LOCATION: "swedencentral"
  TARGET_RGS: "rg-my-workload"

steps:
  - uses: azure/login@v2
    with:
      creds: ${{ secrets.AZURE_CREDENTIALS }}
  - run: |
      ./bin/new-agent.sh --recipe $RECIPE --non-interactive \
        --set agentName=$AGENT_NAME \
        --set resourceGroup=$RESOURCE_GROUP \
        --set location=$LOCATION \
        --set targetRGs=$TARGET_RGS \
        -o /tmp/$AGENT_NAME
      ./bin/deploy.sh /tmp/$AGENT_NAME --force
```

See [github-actions-deploy.yml](github-actions-deploy.yml) for a complete workflow.
