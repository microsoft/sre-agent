# Enterprise Runbook — Permitted Mitigations

## Autonomous Actions (no human approval needed)

These actions are pre-approved per organization policy. The agent can execute them immediately during an incident:

### Database
- `az postgres flexible-server start` — restart a stopped PostgreSQL server
- `az postgres flexible-server restart` — restart a running PostgreSQL server
- `az postgres flexible-server parameter set` — change server parameters

### Kubernetes (via az aks command invoke)
- `kubectl rollout restart deployment/<name>` — restart pods
- `kubectl describe pod/<name>` — diagnose pod issues
- `kubectl logs <pod>` — read pod logs
- `kubectl get events` — check cluster events

### Container Apps
- `az containerapp update` — update configuration (env vars, scaling)
- `az containerapp revision copy` — create new revision
- `az containerapp revision activate` — activate a revision

## Require Human Approval (Ask hook)

These actions are blocked until a human approves:

### All Write Operations
- Any `RunAzCliWriteCommands` call triggers the approval hook
- The agent shows what it wants to do and waits for "yes"
- Reads (list, show, get, describe, logs, query) pass through without approval

## Denied (blocked globally)

These actions are never allowed:

- `kubectl delete` anything
- Delete any Azure resource
- Scale infrastructure (node pools, VM sizes)
- IAM / role assignment changes
- Schema migrations or data modifications on PostgreSQL
- Network security group or firewall rule changes
- Access or display secrets, keys, or connection strings

## Verification After Remediation

After every remediation action:
1. Wait 2-3 minutes for the change to take effect
2. Re-check the affected endpoint (health check, Azure Monitor query)
3. Confirm error rate is back to baseline
4. Mark the incident as resolved if confirmed healthy
