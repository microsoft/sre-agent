## Application 5xx runbook (Zava)

@@SHARED@@

`Zava-http-5xx-errors` fires when zava-api returns more than five HTTP 5xx responses
in five minutes. Because database outages can also produce 5xx responses, first
check PostgreSQL availability and query latency.

## Investigate
1. Confirm PG `state == Ready`, review connection-failure traces, and check `/api/products` latency. If database availability or query latency is affected, use the matching domain runbook.
2. Compare the 5xx onset with recent `zava-api` rollout history and `ScalingReplicaSet` events. Liveness, readiness, and `/api/health` can remain healthy during a route-specific regression.

Load `incident-correlation` when nearby alerts require comparison. Confirm a shared
mechanism in dependency telemetry before assigning a common cause. If the other alert
is already acknowledged, report the relationship and leave remediation to that thread.

## Permitted autonomous actions
- Roll back a `zava-demo` deployment to its previous revision with `RunKubectlWriteCommand` (`kubectl rollout undo deployment/zava-api -n zava-demo`) when a 5xx regression correlates with a recent rollout.
- Restart deployments in `zava-demo`.

## Out of scope (summarize + stop)
- Schema/role/IAM changes; cluster scale / node deletion / VNet changes.

## Verify
`GET /api/products` returns 200; 5xx rate returns to baseline; the alert auto-mitigates.
