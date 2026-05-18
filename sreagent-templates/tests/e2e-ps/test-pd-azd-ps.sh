#!/usr/bin/env bash
# E2E: pagerduty-law-vmcosmos × azd
set -uo pipefail
cd "$(dirname "$0")/../.."

pwsh -NoProfile -Command "& './bin/ps/New-Agent.ps1' \
  -Recipe 'pagerduty-law-vmcosmos' \
  -NonInteractive \
  -Set @{ \
    agentName='pd-azd-e2e'; \
    resourceGroup='rg-pd-azd-e2e'; \
    location='swedencentral'; \
    targetRGs='rg-groceryapp'; \
    lawId='/subscriptions/cbf44432-7f45-4906-a85d-d2b14a1e8328/resourceGroups/rg-ebc-demo3/providers/Microsoft.OperationalInsights/workspaces/law-ebc-demo3'; \
    pagerdutyApiKey='u+fake-pd-key' \
  } \
  -Output '/tmp/pd-azd-e2e/'"

# azd deploy
mkdir -p "./agents/pd-azd-e2e"
cp -r /tmp/pd-azd-e2e/* ./agents/pd-azd-e2e/ 2>/dev/null || true
azd env select pd-azd-e2e --no-prompt 2>/dev/null || azd env new pd-azd-e2e --no-prompt
azd env set AZURE_AGENT_NAME pd-azd-e2e --no-prompt
azd env set AZURE_RESOURCE_GROUP rg-pd-azd-e2e --no-prompt
azd env set AZURE_LOCATION swedencentral --no-prompt
azd env set AZURE_SUBSCRIPTION_ID cbf44432-7f45-4906-a85d-d2b14a1e8328 --no-prompt
azd up --no-prompt

pwsh -NoProfile -Command "& './bin/ps/Verify-Agent.ps1' -Subscription 'cbf44432-7f45-4906-a85d-d2b14a1e8328' -ResourceGroup 'rg-pd-azd-e2e' -AgentName 'pd-azd-e2e'"

# chat — save tastes
ENDPOINT=$(az resource show --resource-type "Microsoft.App/agents" -g rg-pd-azd-e2e -n pd-azd-e2e --query "properties.agentEndpoint" -o tsv)
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
pwsh -NoProfile -Command "& './bin/ps/Clone-Agent.ps1' -FromAgent 'pd-azd-e2e' -FromResourceGroup 'rg-pd-azd-e2e' -AgentName 'pd-azd-e2e-cl' -ResourceGroup 'rg-pd-azd-e2e-cl' -Force"

# verify clone + synth knowledge
pwsh -NoProfile -Command "& './bin/ps/Verify-Agent.ps1' -Subscription 'cbf44432-7f45-4906-a85d-d2b14a1e8328' -ResourceGroup 'rg-pd-azd-e2e-cl' -AgentName 'pd-azd-e2e-cl'"
CLONE_EP=$(az resource show --resource-type "Microsoft.App/agents" -g rg-pd-azd-e2e-cl -n pd-azd-e2e-cl --query "properties.agentEndpoint" -o tsv)
TOKEN=$(az account get-access-token --resource "https://azuresre.dev" --query accessToken -o tsv)
curl -sS "$CLONE_EP/api/v1/WorkspaceMemory/list?type=synthesized-knowledge" \
  -H "Authorization: Bearer $TOKEN" | jq -e '.files[] | select(.path | test("tastes";"i"))' || true
