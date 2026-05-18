#!/usr/bin/env bash
# E2E: azmon-lawappinsights × terraform
set -uo pipefail
cd "$(dirname "$0")/../.."

pwsh -NoProfile -Command "& './bin/ps/New-Agent.ps1' \
  -Recipe 'azmon-lawappinsights' \
  -NonInteractive \
  -Set @{ \
    agentName='azmon-tf-e2e'; \
    resourceGroup='rg-azmon-tf-e2e'; \
    location='swedencentral'; \
    targetRGs='aks-demo-app-cluster'; \
    lawId='/subscriptions/cbf44432-7f45-4906-a85d-d2b14a1e8328/resourceGroups/rg-contoso-swe/providers/Microsoft.OperationalInsights/workspaces/law-7defkiyvn3r44'; \
    appInsightsId='/subscriptions/cbf44432-7f45-4906-a85d-d2b14a1e8328/resourceGroups/rg-contoso-swe/providers/microsoft.insights/components/sreagent-recipes-telemetry'; \
    appInsightsAppId='3b50188a-a191-4f74-994a-2e7ed8afc018' \
  } \
  -Output '/tmp/azmon-tf-e2e/'"

pwsh -NoProfile -Command "& './bin/ps/Deploy-Tf.ps1' -InputPath '/tmp/azmon-tf-e2e'"

pwsh -NoProfile -Command "& './bin/ps/Verify-Agent.ps1' -Subscription 'cbf44432-7f45-4906-a85d-d2b14a1e8328' -ResourceGroup 'rg-azmon-tf-e2e' -AgentName 'azmon-tf-e2e'"

# chat — save tastes
ENDPOINT=$(az resource show --resource-type "Microsoft.App/agents" -g rg-azmon-tf-e2e -n azmon-tf-e2e --query "properties.agentEndpoint" -o tsv)
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
pwsh -NoProfile -Command "& './bin/ps/Clone-Agent.ps1' -FromAgent 'azmon-tf-e2e' -FromResourceGroup 'rg-azmon-tf-e2e' -AgentName 'azmon-tf-e2e-cl' -ResourceGroup 'rg-azmon-tf-e2e-cl' -Backend 'terraform' -Force"

# verify clone + synth knowledge
pwsh -NoProfile -Command "& './bin/ps/Verify-Agent.ps1' -Subscription 'cbf44432-7f45-4906-a85d-d2b14a1e8328' -ResourceGroup 'rg-azmon-tf-e2e-cl' -AgentName 'azmon-tf-e2e-cl'"
CLONE_EP=$(az resource show --resource-type "Microsoft.App/agents" -g rg-azmon-tf-e2e-cl -n azmon-tf-e2e-cl --query "properties.agentEndpoint" -o tsv)
TOKEN=$(az account get-access-token --resource "https://azuresre.dev" --query accessToken -o tsv)
curl -sS "$CLONE_EP/api/v1/WorkspaceMemory/list?type=synthesized-knowledge" \
  -H "Authorization: Bearer $TOKEN" | jq -e '.files[] | select(.path | test("tastes";"i"))' || true
