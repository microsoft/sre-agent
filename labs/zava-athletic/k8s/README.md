# k8s/

Plain Kubernetes manifests applied by `scripts/post-provision.ps1` after `azd up`.
The `${VAR}` placeholders are substituted at apply time (no Helm/Kustomize).

## No default-deny egress NetworkPolicy — by design

This directory ships **no baseline NetworkPolicy**. Pods can reach PostgreSQL,
the cluster DNS, and the wider internet by default. That is the intentional
"green" state of the demo.

Scenario 2 (`.github/skills/running-demo/scripts/break-network.ps1`) installs a misconfigured `database-tier-isolation`
NetworkPolicy on top of that empty baseline — that's how the network partition is
introduced and how the SRE Agent gets to demonstrate detection + remediation
(matching `ETIMEDOUT` errors, identifying the offending policy, and removing it).
The policy name is intentionally generic (a security-architect-style "tier
isolation" name) rather than a giveaway like `block-postgres`, so the agent
must reason from the egress rules, not from the policy name. If we shipped a
default-deny baseline here, the break script would have to layer on top of
more state and the diagnosis story would be muddier.

## Files

- `api-deployment.yaml` — Zava API Deployment (Node.js, workload identity to PG).
- `api-service.yaml` — ClusterIP Service fronting the API pods.
- `configmap.yaml` — App config (DB host/name, identity client ID, 1 Hz self-probe override).
- `ingress.yaml` — Public ingress for the storefront (and `/api` passthrough).
- `secret.yaml` — Placeholder Secret (no DB password — auth is AAD/workload identity).
- `service-account.yaml` — ServiceAccount annotated for federated workload identity.
- `storefront-deployment.yaml` — Static storefront Deployment (nginx + built React).
- `storefront-service.yaml` — ClusterIP Service for the storefront pods.
- `jobs/load-categories.yaml` — In-cluster category-page load generator Job, applied by `break-db-perf.ps1` (Scenario 3) so traffic drives the slow-query alert above its 30ms threshold without depending on the operator workstation's network. TTL'd 60s after completion.
