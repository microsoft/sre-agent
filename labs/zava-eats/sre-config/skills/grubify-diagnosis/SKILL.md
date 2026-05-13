---
name: grubify-diagnosis
description: |
  Diagnose Grubify HTTP 500 errors and connection failures. Use when investigating
  any failure in the Grubify Container App (5xx responses, /menu endpoint failing,
  /health probe red, or operator reports of broken UI).
tools:
  - QueryAppInsightsByResourceId
  - QueryLogAnalyticsByWorkspaceId
  - RunAzCliReadCommands
  - CheckGrubifyHealth
---

# Grubify Diagnosis

## When to use

Trigger this skill whenever an alert fires for the Grubify Container App or a
user reports the Grubify menu/order pages are broken.

## Procedure

1. **Health probe** — call `CheckGrubifyHealth` to ping `/health` directly.
   - If `200 OK` and the alert says 5xx, the issue is intermittent / load-related.
   - If non-200, capture the response body — it usually contains the failing
     dependency name (e.g., "menu-db unreachable").

2. **App Insights exceptions** — query the last 30 min for `exceptions`,
   aggregated by `problemId` and `outerMessage`.

3. **Container console logs** — query `ContainerAppConsoleLogs_CL` for ERROR or
   Traceback in the affected ContainerAppName.

4. **Identify root cause** — usually one of: missing env var (config regression),
   bad image tag (deploy regression), downstream timeout, or OOMKill.

5. **Document findings** in the response thread; do not auto-remediate without
   operator approval.
