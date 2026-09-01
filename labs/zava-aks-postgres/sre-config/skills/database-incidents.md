## Database availability runbook (Zava)

@@SHARED@@

You diagnose from telemetry, then remediate within the permitted-action boundary; outside it, summarize and stop.

The alert `postgres-unreachable` means zava-api cannot reach PostgreSQL — it logged connection failures (refused or, far more often, **timeouts**). A stopped server and a network block BOTH look like timeouts at the app, so **diagnose the cause from ARM state, not the error text**:

| PG ARM `state` | Cause | Action |
|---|---|---|
| `Stopped` | The server was stopped. | **Start it**: `az postgres flexible-server start`. |
| `Ready` (app still can't connect) | A network block. | Inspect the AKS-subnet NSG and Kubernetes **NetworkPolicy** resources in `zava-demo`, account for PostgreSQL delegated-subnet behavior, and remove the configuration that blocks PostgreSQL egress. |

## Permitted autonomous actions
- Start / restart / parameter-set on PostgreSQL Flexible Server.
- Delete a NetworkPolicy in `zava-demo` whose egress blocks PG, and delete a matching NSG deny rule on the AKS subnet.

## Out of scope (summarize + stop)
- `DROP`, DML, schema migrations, role/grant changes; cluster scale / node deletion / VNet changes; any IAM modification.

## Verify
PG `state == Ready`; zava-api connection-error traces stop.

## Close the loop (resolve the alert)
After confirming recovery, **resolve the `postgres-unreachable` alert you were handling** instead of waiting for Azure Monitor's auto-mitigate. Auto-mitigate lags ~15-30 min, and while the alert lingers in a fired state Azure Monitor dedupes the NEXT distinct database incident into this same alert instance — so no new investigation dispatches until it clears. Closing it yourself keeps the loop tight. Take the alert's ARM id from your incident context (form `/subscriptions/.../providers/Microsoft.AlertsManagement/alerts/<guid>`); if you don't have it, list open ones with `az rest --method GET --url "https://management.azure.com/subscriptions/<sub>/providers/Microsoft.AlertsManagement/alerts?api-version=2018-05-05&alertRule=postgres-unreachable"`. Then close it:
`az rest --method POST --url "https://management.azure.com<ALERT_ID>/changestate?api-version=2018-05-05&newState=Closed"`
(your Contributor role grants `Microsoft.AlertsManagement/alerts/changestate/action`).
