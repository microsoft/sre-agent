#!/usr/bin/env bash
# E2E: minimal × bicep
set -uo pipefail
cd "$(dirname "$0")/../.."

pwsh -NoProfile -Command "& './bin/ps/New-Agent.ps1' \
  -Recipe 'minimal' \
  -NonInteractive \
  -Set @{ \
    agentName='min-bic-e2e'; \
    resourceGroup='rg-min-bic-e2e'; \
    location='swedencentral'; \
    targetRGs='rg-ebc-demo3' \
  } \
  -Output '/tmp/min-bic-e2e/'"

pwsh -NoProfile -Command "& './bin/ps/Deploy-Agent.ps1' -InputPath '/tmp/min-bic-e2e' -Force"

pwsh -NoProfile -Command "& './bin/ps/Verify-Agent.ps1' -Subscription 'cbf44432-7f45-4906-a85d-d2b14a1e8328' -ResourceGroup 'rg-min-bic-e2e' -AgentName 'min-bic-e2e'"

# chat — save tastes
ENDPOINT=$(az resource show --resource-type "Microsoft.App/agents" -g rg-min-bic-e2e -n min-bic-e2e --query "properties.agentEndpoint" -o tsv)
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
pwsh -NoProfile -Command "& './bin/ps/Clone-Agent.ps1' -FromAgent 'min-bic-e2e' -FromResourceGroup 'rg-min-bic-e2e' -AgentName 'min-bic-e2e-cl' -ResourceGroup 'rg-min-bic-e2e-cl' -Force"

# verify clone + synth knowledge
pwsh -NoProfile -Command "& './bin/ps/Verify-Agent.ps1' -Subscription 'cbf44432-7f45-4906-a85d-d2b14a1e8328' -ResourceGroup 'rg-min-bic-e2e-cl' -AgentName 'min-bic-e2e-cl'"
CLONE_EP=$(az resource show --resource-type "Microsoft.App/agents" -g rg-min-bic-e2e-cl -n min-bic-e2e-cl --query "properties.agentEndpoint" -o tsv)
TOKEN=$(az account get-access-token --resource "https://azuresre.dev" --query accessToken -o tsv)
curl -sS "$CLONE_EP/api/v1/WorkspaceMemory/list?type=synthesized-knowledge" \
  -H "Authorization: Bearer $TOKEN" | jq -e '.files[] | select(.path | test("tastes";"i"))' || true
