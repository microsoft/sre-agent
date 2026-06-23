# Zava Learning — Redaction Standard (`zava-redaction`)

Sensitive data must NEVER appear in any operator-visible surface: the incident thread/chat, the
PagerDuty or ServiceNow notes, commit messages or pull-request bodies, or any report artifact (HTML,
PowerPoint, Teams card). This is the canonical, deterministic scrub. Retrieve it with
`SearchMemory("zava-redaction")` and apply it to every emitted string before posting.

## What counts as sensitive (always redact)
- **Secrets / credentials:** passwords, `PGPASSWORD`, connection strings, Key Vault secret VALUES,
  client secrets, API/access/account keys, SAS tokens, shared access keys.
- **Tokens:** GitHub PATs (`gho_`/`ghp_`/`ghs_`/`ghr_`/`ghu_`/`github_pat_…`), OAuth/AAD access
  tokens and JWTs (`eyJ…`), bearer / `Authorization:` header values.
- **Private keys:** any `-----BEGIN … PRIVATE KEY-----` block, SSH keys, certificate private keys.
- **Credentials embedded in URIs:** the password in `scheme://user:password@host`.
- **PII:** email addresses and any learner personal data pulled from the database
  (names, addresses, student IDs).

Resource names, resource groups, region names, container-app names, alert names, PR/CR numbers and
non-secret IDs are NOT sensitive — keep them; they are needed for the narrative.

## Hard behavioral rules
- **NEVER read or print the contents of credential files.** Treat these as off-limits — reference
  them by name only, never `cat`/`Get-Content`/`echo`/`type` their contents into the thread or a
  report: `.git/git-credentials`, `.env` / `*.env`, `*.pem`, `id_rsa*`, `*.pfx`, `*.p12`,
  `kubeconfig`, `~/.azure/*`, `*.tfstate`, `*.tfvars`.
- When a command can echo a secret (e.g. `az keyvault secret show`, `az containerapp ... --query …
  value`, printing an environment variable), do **not** paste its output into chat or a report.
  Confirm the fact ("the secret was rotated / is present") without revealing the value.
- If you are unsure whether a string is sensitive, redact it.
- Replacement marker: `[REDACTED:<CLASS>]` (e.g. `[REDACTED:GITHUB_TOKEN]`). For URI credentials,
  keep the scheme and username and mask only the password.

## Deterministic scrubber (run this on every emitted string)
Apply this with `ExecutePythonCode`. Inline `redact()` inside the report builder's `def main(...)`
and run it over every assembled chat summary, note body, PR/commit text, and the final HTML/Markdown
before writing or returning it. It is idempotent — running it twice is safe.

```python
import re

_PRIVATE_KEY = re.compile(
    r"-----BEGIN (?:[A-Z ]+ )?PRIVATE KEY-----.*?-----END (?:[A-Z ]+ )?PRIVATE KEY-----",
    re.DOTALL,
)
_GITHUB = re.compile(r"\b(?:gh[oprsu]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})\b")
_JWT = re.compile(r"\beyJ[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{6,}\b")
_BEARER = re.compile(r"(?i)\bBearer\s+[A-Za-z0-9._\-]+")
_URI_CRED = re.compile(r"\b([a-zA-Z][a-zA-Z0-9+.\-]*://[^:/?#\s]+):([^@/?#\s]+)@")
_SAS_SIG = re.compile(r"(?i)\bsig=[A-Za-z0-9%/+_-]{16,}")
_SECRET_KV = re.compile(
    r"(?i)\b(password|passwd|pwd|pgpassword|secret|client[_-]?secret|api[_-]?key|"
    r"access[_-]?key|account[_-]?key|shared[_-]?access[_-]?key|sas[_-]?token|"
    r"connection[_-]?string|authorization|token)\b\s*[:=]\s*[\"']?[^\s\"';,]+"
)
_EMAIL = re.compile(r"\b[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}\b")


def redact(text: str) -> str:
    """Mask secrets, tokens, private keys, URI credentials and PII. Idempotent."""
    if not text:
        return text
    s = str(text)
    s = _PRIVATE_KEY.sub("[REDACTED:PRIVATE_KEY]", s)
    s = _GITHUB.sub("[REDACTED:GITHUB_TOKEN]", s)
    s = _JWT.sub("[REDACTED:TOKEN]", s)
    s = _BEARER.sub("Bearer [REDACTED:TOKEN]", s)
    s = _URI_CRED.sub(r"\1:[REDACTED:SECRET]@", s)
    s = _SAS_SIG.sub("sig=[REDACTED:SECRET]", s)
    s = _SECRET_KV.sub(lambda m: m.group(0).split(m.group(1))[0] + m.group(1) + "=[REDACTED:SECRET]", s)
    s = _EMAIL.sub("[REDACTED:EMAIL]", s)
    return s


def main():
    # Self-test so the runtime confirms the scrubber works before you rely on it.
    samples = [
        "token=ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789",
        "postgres://zavaadmin:S3cr3tPass@psql-zava.postgres.database.azure.com:5432/zava",
        "Authorization: Bearer eyJhbGciOiJB.eyJzdWIiOiIx.s1Gn4tuRe",
        "PGPASSWORD=hunter2 student=ada@school.edu",
    ]
    return "\n".join(redact(x) for x in samples)
```

## Application points (run the scrub before emitting)
- **Chat / thread message** → scrub the markdown summary before posting.
- **PagerDuty note** (`AddNoteToPagerDutyIncident`) → scrub the plain-text body.
- **ServiceNow** change description / attachment → scrub before `CreateServiceNowChangeRequest` /
  `UploadServiceNowAttachment`.
- **pr-delivery** → scrub the PR body and commit message; never stage a secret into the diff.
- **zava-reporting** → run `redact()` over the assembled HTML/markdown (and any deck text) inside
  `def main(...)` before writing the downloadable file.

## Verification
Before any artifact or message leaves the agent, it has passed through `redact()` (or the equivalent
manual masking), contains no secret/token/private-key/URI-credential/PII value, and shows
`[REDACTED:<CLASS>]` markers in place of anything sensitive. No credential file was ever printed.
