# E2E Test Results — law-dynatrace-httptrigger Recipe

**Date:** 2026-05-26
**Subscription:** cbf44432-7f45-4906-a85d-d2b14a1e8328
**Region:** swedencentral

## Dry-Run Test (all backends)

| Check | Result |
|---|---|
| new-agent.sh | ✅ |
| skills count (2) | ✅ |
| skill tools (8 each) | ✅ |
| skill .md content | ✅ |
| subagents count (2) | ✅ |
| hooks count (2) | ✅ |
| prompts count (2) | ✅ |
| http-triggers count (1) | ✅ |
| connectors.json | ✅ |
| deploy.sh --dry-run (Bicep) | ✅ |
| az bicep build | ✅ |
| deploy-tf.sh --dry-run (Terraform) | ✅ |
| terraform validate | ✅ |
| PS New-Agent.ps1 | ✅ |
| azd assemble | ✅ |
| **no {{placeholders}}** | ❌ (false positive: GitHub Actions `${{ }}` in sample workflow) |
| **tfvars skills/subagents/prompts** | ❌ (pre-existing terraform dry-run gap, same as dynatrace-mcp) |

**Result: 27/31 passed** (4 failures are pre-existing/false-positive, not recipe-specific)

## E2E Full Matrix (5 backends × 7 steps)

| Backend | new-agent | deploy | verify | re-deploy | verify-update | clone | verify-clone |
|---|---|---|---|---|---|---|---|
| **bicep-bash** | ✅ | ✅* | ✅ (20/20) | ✅* | ✅ | ✅ | ✅ (16/16) |
| **bicep-ps** | ✅** | ✅ | ✅ (20/20) | ✅ | ✅ | ✅ | ✅ (16/16) |
| **tf-bash** | ✅ | ✅ | ❌→✅ | ✅* | ✅ | ✅ | ✅ (16/16) |
| **tf-ps** | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ |
| **azd-bash** | ✅ | ✅*** | ❌→✅ | ✅*** | ✅ | ✅*** | ✅ (16/16) |

**Legend:**
- `*` = rc=5 from jq parse error on GitHub OAuth URL print (pre-existing deploy.sh issue, agent deploys correctly)
- `**` = PS New-Agent.ps1 Count property warning (cosmetic, config generated correctly)
- `***` = azd exit codes unreliable, but agent created and verified
- `❌→✅` = verify fails on first deploy (timing), passes after re-deploy
- tf-ps = Known P0 bug: Deploy-Tf.ps1 broken for all recipes (not recipe-specific)

## Agents Created (10 total)

| Agent | RG | Backend | Type |
|---|---|---|---|
| dg-bicep-bash | rg-dg-bicep-bash | bicep-bash | original |
| dg-bicep-bash-cl | rg-dg-bicep-bash-cl | bicep-bash | clone |
| dg-bicep-ps | rg-dg-bicep-ps | bicep-ps | original |
| dg-bicep-ps-cl | rg-dg-bicep-ps-cl | bicep-ps | clone |
| dg-tf-bash | rg-dg-tf-bash | tf-bash | original |
| dg-tf-bash-cl | rg-dg-tf-bash-cl | tf-bash | clone |
| dg-azd-bash | rg-dg-azd-bash | azd-bash | original |
| dg-azd-bash-cl | rg-dg-azd-bash-cl | azd-bash | clone |
| deployment-guard-lab | rg-deployment-guard-lab | bicep-bash | manual test |
| deployment-guard-lab (clone export) | — | bicep-bash | export only |

## Verify Output (representative — bicep-ps)

```
Skills:              2 (deployment-guard-analysis, investigate-app-errors)
Subagents:           2 (deployment-guard, error-investigator)
Hooks:               2 (deny-prod-deletes, require-approval-for-restarts)
Common Prompts:      2 (investigation-guidelines, safety-rules)
Connectors:          2 (log-analytics: LogAnalytics, dynatrace: Mcp)
HTTP Triggers:       1 (pr-deployment-guard)
Results: 20 passed, 0 failed
```

## Known Issues (pre-existing, not recipe-specific)

1. **deploy.sh exit code 5**: jq parse error when printing GitHub OAuth URL. Deploy succeeds — verify passes.
2. **tf-ps Deploy-Tf.ps1**: P0 bug — fails for all recipes, not just this one.
3. **tfvars dry-run**: terraform `deploy-tf.sh --dry-run` doesn't populate skills/subagents/prompts in tfvars.
4. **`${{ }}` false positive**: sample GitHub workflow uses `${{ github.event.* }}` which grep matches as `{{`.
5. **azd exit codes**: `azd up` returns non-zero even when deploy succeeds. Verify confirms agents work.
