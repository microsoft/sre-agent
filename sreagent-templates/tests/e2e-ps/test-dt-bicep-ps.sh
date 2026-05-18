#!/usr/bin/env bash
# E2E: dynatrace-mcp × bicep
set -uo pipefail
: "${DT_TOKEN:?Set DT_TOKEN env var}"
cd "$(dirname "$0")/../.."

pwsh -NoProfile -Command "& './bin/ps/New-Agent.ps1' \
  -Recipe 'dynatrace-mcp' \
  -NonInteractive \
  -Set @{ \
    agentName='dt-bic-e2e'; \
    resourceGroup='rg-dt-bic-e2e'; \
    location='swedencentral'; \
    targetRGs='rg-contoso-swe,rg-aks-journal'; \
    lawId='/subscriptions/cbf44432-7f45-4906-a85d-d2b14a1e8328/resourceGroups/rg-contoso-swe/providers/Microsoft.OperationalInsights/workspaces/law-7defkiyvn3r44'; \
    dtTenant='dhu66396'; \
    dtToken='$DT_TOKEN' \
  } \
  -Output '/tmp/dt-bic-e2e/'"

pwsh -NoProfile -Command "& './bin/ps/Deploy-Agent.ps1' -InputPath '/tmp/dt-bic-e2e' -Force"

pwsh -NoProfile -Command "& './bin/ps/Verify-Agent.ps1' -Subscription 'cbf44432-7f45-4906-a85d-d2b14a1e8328' -ResourceGroup 'rg-dt-bic-e2e' -AgentName 'dt-bic-e2e'"

# chat — save tastes
ENDPOINT=$(az resource show --resource-type "Microsoft.App/agents" -g rg-dt-bic-e2e -n dt-bic-e2e --query "properties.agentEndpoint" -o tsv)
TOKEN=$(az account get-access-token --resource "https://azuresre.dev" --query accessToken -o tsv)
curl -sS -X POST "$ENDPOINT/api/v1/threads" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"StartMessage":{"Text":"can you save my preferences to look at telemetry and understand problem before looking at sourcecode as my tastes file"}}'

# wait for tastes.md
for i in $(seq 1 12); do
  sleep 10
  TOKEN=$(az account get-access-token --resource "https://azuresre.dev" --query accessToken -o tsv)
  if curl -sS "$ENDPOINT/api/v1/WorkspaceMemory/list?type=synthesized-knowledge" \
    -H "Authorization: Bearer $TOKEN" | jq -e '.files[] | select(.path | test("tastes";"i"))' 2>/dev/null; then
    break
  fi
done

# clone
pwsh -NoProfile -Command "& './bin/ps/Clone-Agent.ps1' -FromAgent 'dt-bic-e2e' -FromResourceGroup 'rg-dt-bic-e2e' -AgentName 'dt-bic-e2e-cl' -ResourceGroup 'rg-dt-bic-e2e-cl' -Force"

# verify clone + synth knowledge
pwsh -NoProfile -Command "& './bin/ps/Verify-Agent.ps1' -Subscription 'cbf44432-7f45-4906-a85d-d2b14a1e8328' -ResourceGroup 'rg-dt-bic-e2e-cl' -AgentName 'dt-bic-e2e-cl'"
CLONE_EP=$(az resource show --resource-type "Microsoft.App/agents" -g rg-dt-bic-e2e-cl -n dt-bic-e2e-cl --query "properties.agentEndpoint" -o tsv)
TOKEN=$(az account get-access-token --resource "https://azuresre.dev" --query accessToken -o tsv)
curl -sS "$CLONE_EP/api/v1/WorkspaceMemory/list?type=synthesized-knowledge" \
  -H "Authorization: Bearer $TOKEN" | jq -e '.files[] | select(.path | test("tastes";"i"))' || true
