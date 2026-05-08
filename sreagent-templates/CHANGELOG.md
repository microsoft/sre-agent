# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

- **MAJOR**: Breaking changes (new required params, changed agent.json format, removed recipes)
- **MINOR**: New features (new recipe, new deploy backend, new CLI flag)
- **PATCH**: Bug fixes, docs, test improvements

## [Unreleased]

## [1.0.0] — 2026-05-07

### Deploy Backends
- **Bicep** (`deploy.sh`) — ARM deployment via `az deployment sub create`
- **Terraform** (`deploy-tf.sh`) — azapi provider, per-agent workspaces, same config dir
- **PowerShell** (`Deploy-Agent.ps1`) — full PS7 port of all bash scripts
- **azd** (`azd up`) — Azure Developer CLI wrapper via hooks

### Recipes (3P)
- `azmon-lawappinsights` — Azure Monitor alert response with App Insights + Log Analytics
- `pagerduty-law-vmcosmos` — PagerDuty with VM, CosmosDB, HTTP error investigation
- `httptrigger-dynatrace` — Dynatrace MCP + webhook bridge + GitHub issue creation

### Core Scripts
- `new-agent.sh` / `New-Agent.ps1` — interactive or `--non-interactive` recipe setup
- `deploy.sh` / `deploy-tf.sh` / `Deploy-Agent.ps1` — multi-backend deploy
- `export-agent.sh` / `Export-Agent.ps1` — export live agent for cloning
- `verify-agent.sh` / `Verify-Agent.ps1` — 22-point post-deploy verification
- `diff-agent.sh` / `Diff-Agent.ps1` — compare config vs live agent
- `apply-extras.sh` / `Apply-Extras.ps1` — ARM sub-resources + data-plane config

### Infrastructure
- Bicep: `main.bicep` + `agent-core.bicep` + `agent-extensions.bicep`
- Terraform: `main.tf` + `variables.tf` + `outputs.tf` + `versions.tf`
- RBAC: system MI + UAMI roles on target RGs (Reader, Log Analytics Reader, Contributor)
- Connector timeouts: 10min guard for K8s extension install hangs

### Testing
- Dry-run test suite: 6 recipes × 4 backends (Bicep, TF, PS, azd-style)
- Content validation: skill specs, subagent handoffs, connector types, no unreplaced placeholders

### Fixes in this release
- ARM sub-resource migration for Cloud Shell compatibility
- System MI RBAC on target RGs (was missing — caused 403 on connector queries)
- Skill encoding for TF (restructured to match Bicep: name, description, tools, skillContent)
- KnowledgeFile connectors via apply-extras ARM PUT (not Bicep — avoids K8s hang)
- Region: removed hardcoded `eastus2` default, location now required
- Model provider: added prompt with Anthropic/GitHubCopilot/MicrosoftFoundry + EU data residency warning
- PS bugs: Get-ChildItem -Include, stderr in JSON parse, StrictMode safety, parameter mismatches
- Empty repo URL handling: skip GitHub auth prompt when no repo configured
- Recipe fixes: incident platform type casing, trailing commas, missing fields, expected-config.json connector lists

---

_When upgrading: check Breaking Changes section. If empty, upgrade is safe._
_To check your version: `cat VERSION`_
_To see what changed: `git log v<old>..v<new> --oneline`_
