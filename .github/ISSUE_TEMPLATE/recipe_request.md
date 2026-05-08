---
name: New Recipe Request
about: Suggest a new recipe template for sreagent-templates
title: '[Recipe] '
labels: recipe
---

## Recipe name

<!-- e.g., grafana-prometheus, splunk-webhook, datadog-mcp -->

## Incident platform

Which incident platform does this recipe use?
- [ ] Azure Monitor
- [ ] PagerDuty
- [ ] ServiceNow
- [ ] HTTP Trigger (webhook)
- [ ] Other: ___

## Connectors

Which data connectors should be included?
- [ ] Application Insights
- [ ] Log Analytics
- [ ] Azure Monitor metrics
- [ ] Kusto / ADX
- [ ] MCP (specify: ___)
- [ ] GitHub
- [ ] Other: ___

## Use case

<!-- Describe the scenario this recipe supports -->

## Are you willing to contribute this recipe?

- [ ] Yes, I can build and test it
- [ ] I need help building it

## Contribution checklist (for recipe PRs)

- [ ] Recipe directory at `sreagent-templates/recipes/{name}/`
- [ ] `agent.json` with `_prompts` for all required inputs
- [ ] `connectors.json` with connector configs
- [ ] `config/skills/` with at least one skill (`.yaml` + `.md`)
- [ ] `automations/incident-filters/` or `automations/incident-platforms/`
- [ ] `README.md` with Parameters table, Advanced Options, Quick Start, What You Get
- [ ] `expected-config.json` listing expected skills/subagents/connectors
- [ ] Dry-run test at `sreagent-templates/tests/test-dry-run-{name}.sh`
- [ ] Test passes: `bash tests/test-dry-run-{name}.sh`
- [ ] Added to main `README.md` recipes table
