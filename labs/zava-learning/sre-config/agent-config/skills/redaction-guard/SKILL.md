---
metadata:
  api_version: azuresre.ai/v2
  kind: Skill
name: redaction-guard
description: Use whenever you are about to emit operator-visible content — a chat/thread message, a PagerDuty or ServiceNow note, a commit message or pull-request body, or any report artifact (HTML, PowerPoint, Teams card). Deterministically masks secrets, credentials, tokens, private keys, URI-embedded passwords, and PII so they never appear in the thread or in any deliverable. This is a cross-cutting guardrail invoked by the output-producing skills, not a runbook step.
tools:
  - SearchMemory
  - ExecutePythonCode
---

## Zava Learning — Redaction Guard

A cross-cutting safety layer: nothing sensitive ever reaches an operator-visible surface. The
triggering alert is symptom-only and the investigation touches Key Vault secrets, connection
strings, access tokens and learner PII — none of which may be exposed in chat, notes, PRs, or
reports.

## Load the standard, then scrub
Retrieve the canonical policy and scrubber with `SearchMemory("zava-redaction")`. It defines what
counts as sensitive, the credential files you must never print, and a deterministic `redact()`
function. Apply `redact()` (via `ExecutePythonCode`) to **every** string you are about to emit —
chat summary, note body, PR/commit text, and the assembled HTML/markdown/deck — before it leaves the
agent. The scrubber is idempotent, so running it more than once is safe.

## What to redact (summary — see `zava-redaction` for the full list)
- Secrets & credentials: passwords, `PGPASSWORD`, connection strings, Key Vault secret **values**,
  client secrets, API / access / account keys, SAS tokens.
- Tokens: GitHub PATs (`gho_`/`ghp_`/`github_pat_…`), JWTs / AAD access tokens (`eyJ…`), bearer /
  `Authorization` values.
- Private keys: any `-----BEGIN … PRIVATE KEY-----` block, SSH/cert keys.
- Credentials inside URIs: the password in `scheme://user:password@host`.
- PII: email addresses and learner personal data from the database.

Keep resource names, resource groups, regions, app names, alert names, and PR/CR numbers — they are
not sensitive and are needed for the narrative.

## Hard rules
- **Never read or print credential files.** Reference them by name only — never `cat` / `Get-Content`
  / `echo` / `type` the contents of `.git/git-credentials`, `.env`, `*.pem`, `id_rsa*`, `*.pfx`,
  `kubeconfig`, `~/.azure/*`, or `*.tfstate` into the thread or a report.
- When a command can echo a secret (e.g. `az keyvault secret show`), do not paste its output —
  confirm the fact ("secret present / rotated") without revealing the value.
- When in doubt, redact. Replace with `[REDACTED:<CLASS>]`; for URI credentials keep the scheme and
  username and mask only the password.

## How the other skills use this
`zava-reporting`, `pagerduty-incident-update`, `servicenow-change-management`, and `pr-delivery` each
call `redact()` on their output before emitting. Because loading a separate skill swaps the active
toolset, those skills inline the `redact()` function (retrieved via `SearchMemory("zava-redaction")`)
within their own `ExecutePythonCode` step rather than handing off here — this skill is the
authoritative definition they follow.

## Verification
Every operator-visible string has passed through `redact()` (or equivalent manual masking) and shows
`[REDACTED:<CLASS>]` in place of any secret, token, private key, URI credential, or PII. No
credential file was ever printed to the thread or a deliverable.
