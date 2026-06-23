---
metadata:
  api_version: azuresre.ai/v2
  kind: Skill
name: servicenow-change-management
description: Use whenever a Zava Learning investigation produces a durable fix that needs change management — after a GitHub PR is opened for an Infrastructure-as-Code or application code root cause, raise a ServiceNow Change Request referencing the PR and attach the RCA report. The single owner of ServiceNow Change Request and attachment operations.
tools:
  - CreateServiceNowChangeRequest
  - UploadServiceNowAttachment
---

## Zava Learning — ServiceNow Change Management

Use this skill to record a durable remediation in ServiceNow once the root cause is fixed in code or
IaC. It is the single owner of ServiceNow Change Request and attachment operations, and applies
after a GitHub PR has been opened (by `pr-delivery`) for the durable fix.

## When to use
- A connectivity/edge or application incident has been root-caused to an **IaC** (`infra/`) or
  **application** (`src/`) change, and a **GitHub PR** has been opened with the fix.
- An operator explicitly asks to open a Change Request or attach an RCA to an existing record.

Do not raise a Change Request for live mitigations alone (deleting an NSG rule, restarting/rolling
back a revision) — those are tracked as PagerDuty incident notes. The Change Request tracks the
**durable** code/IaC fix.

## Steps
1. **Create the Change Request** with `CreateServiceNowChangeRequest`:
   - `short_description`: one-line summary of the change (symptom + fix).
   - `description`: the RCA summary **including the GitHub PR URL**.
   - `change_type`: `normal` (default), `standard`, or `emergency` for active customer-impacting fixes.
   - `implementation_plan` / `risk` as appropriate.
   - Capture the returned change `number` (e.g. `CHG0030042`), `sys_id`, and the ready-to-use
     **clickable `link`** the tool returns. Surface the CR in the Artifacts & links section as a
     markdown hyperlink `[<number>](<link>)` using that returned `link` — never the bare CHG number,
     which is not clickable. (Do not try to build the URL from a `SERVICENOW_URL` env var — it is not
     available in the agent environment; the tool already returns the full clickable `link`.)
2. **Attach the RCA** with `UploadServiceNowAttachment`:
   - `table_sys_id`: the Change Request `sys_id` from step 1.
   - `file_name`: e.g. `rca-<symptom>.md`.
   - `content`: the full RCA report (timeline, root cause, fix, verification).
3. Reference the Change Request number back in the PagerDuty incident notes and the GitHub PR.

## Notes
- Apply the `zava-redaction` standard to the `description`, `implementation_plan`, and the attached
  RCA before submitting — mask any secret, token, connection string, or learner PII as
  `[REDACTED:<CLASS>]`. The Change Request and its attachment are operator-visible records.
- Credentials (`SERVICENOW_URL/USER/PASS`) are injected from the agent environment (Key Vault-backed);
  never request or hardcode them.
- If ServiceNow credentials are not configured, the tools return `success: false` — report that the
  Change Request could not be created and continue the incident lifecycle in PagerDuty.
