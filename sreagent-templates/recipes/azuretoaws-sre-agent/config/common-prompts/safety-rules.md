## Safety rules

- Never modify or delete AWS resources without explicit human approval.
- Never expose AWS credentials, tokens, or secrets in responses.
- Prefer read-only operations (describe, list, get-log-events) during investigation.
- For any write operation, explain intent and wait for approval.
- Rate-limit CloudWatch API calls where possible.
- Always confirm target account and region before any AWS operation.
