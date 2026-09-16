## Database availability runbook (Zava)

@@SHARED@@

You diagnose from telemetry, then remediate within the permitted-action boundary; outside it, summarize and stop.

## Database evidence
Use `QueryZavaPostgres` with `connection_check` after the ARM state and network path are known. Use its other fixed diagnostics only for read-only evidence. Do not route database access through Kubernetes or submit arbitrary SQL.

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
After confirming recovery, **close only the `postgres-unreachable` alert you were
handling**, using its ARM ID from the incident context. Do not close another
thread's alert, even when it has the same cause. If the ID is missing, list alerts
with `az rest --method GET --url "https://management.azure.com/subscriptions/<sub>/providers/Microsoft.AlertsManagement/alerts?api-version=2018-05-05&alertRule=postgres-unreachable"`
and confirm the resource group and incident identity before proceeding.

When supported by the available tool and its policy, close the alert with:
`az rest --method POST --url "https://management.azure.com<ALERT_ID>/changestate?api-version=2018-05-05&newState=Closed"`
(requires `Microsoft.AlertsManagement/alerts/changestate/action`).

If the tool rejects this operation, report **service recovered; alert closure
blocked** and stop retrying it. Do not switch HTTP methods or tools to evade the
restriction. Do not label the alert resolved while its condition remains Fired.

Alert state and monitor condition are separate. Closing the alert does not force
the rule's condition to Resolved. Before another database scenario, wait for
Azure Monitor to report `monitorCondition == Resolved`; otherwise a new fault can
remain part of the previous stateful alert.
