# Export and Import Azure SRE Agent Live Reports

`livereportclone.py` has two workflows:

1. **Export** a saved Live report from a source SRE Agent into a portable
   `.livereport.json` file that you can share.
2. **Import** a Live report file into a target SRE Agent.

The report bundle is independent of this utility. The workflow uses the SRE
Agent chat API and its `ListReports`, `GetReport`, and `SaveReport` tools;
there is no documented direct Live Reports REST export endpoint.

## Requirements

- Python 3.8+ and Azure CLI, with `az login` completed.
- Your identity can start a thread on the source agent to export, or the target
  agent to import.
- Azure CLI is using a tenant that can access the agent. The data-plane token
  comes from the current Azure CLI context, so having access to the subscription
  in the portal does not by itself ensure the CLI is using the agent's tenant.
- The source and target agents are identified by their ARM resource URIs:
  `/subscriptions/<subscription>/resourceGroups/<resource-group>/providers/Microsoft.App/agents/<agent-name>`.
- Reports that require approval still require a human to review the request in
  the SRE Agent conversation.

Before running either command, select and verify the agent's subscription and
tenant:

```bash
az account set --subscription <agent-subscription-id>
az account show --query '{subscriptionId:id, tenantId:tenantId}' -o json
```

If needed, sign in to the tenant that owns the agent with `az login --tenant
<agent-tenant-id>`, then select the subscription again. Source and target can
be the same agent; the CLI still needs a data-plane token from the correct
tenant.

## Export from the source agent

Export one report by its exact name:

```bash
python3 livereportclone.py export \
  --source /subscriptions/<subscription>/resourceGroups/<resource-group>/providers/Microsoft.App/agents/<source-agent> \
  --reports "Live Report Name ABC" \
  --out ./livereport-export
```

Or export all reports:

```bash
python3 livereportclone.py export \
  --source /subscriptions/<subscription>/resourceGroups/<resource-group>/providers/Microsoft.App/agents/<source-agent> \
  --allReports \
  --out ./livereport-export
```

You can also select one report by its ID from the agent's Live Reports URL:

```bash
python3 livereportclone.py export \
  --source /subscriptions/<subscription>/resourceGroups/<resource-group>/providers/Microsoft.App/agents/<source-agent> \
  --report-id <report-id> \
  --out ./livereport-export
```

The tool starts a chat with the source agent, asks it to use `ListReports` and
`GetReport`, then validates and writes the returned bundle file(s) to the
output directory. It only accepts complete JSON bundles with a matching HTML
checksum; it does not save truncated or invalid output.

Live Report source is returned through chat, so export is currently limited to
**128 KiB of HTML per report**. This command does not provide an alternate
repository transfer for larger reports. Use `--dry-run` to preview the request
without contacting Azure.
The source agent must return the complete bundle inline in its chat response.
If it returns only a downloadable thread artifact, the CLI currently cannot
fetch that artifact automatically and will not write a local bundle.

## Share and import into the target agent

Share the exported `.livereport.json` file with the target-agent operator. They
can import it directly from disk:

```bash
python3 livereportclone.py import \
  --bundle ./livereport-export/Third-Party-Software-Update-Tracker-<hash>.livereport.json \
  --target /subscriptions/<subscription>/resourceGroups/<resource-group>/providers/Microsoft.App/agents/<target-agent> \
  --name "New report name" \
  --set "subscription=SUBSCRIPTION_ID" \
  --set "workspace=WORKSPACE_ID" \
  --set "resourceGroup=WORKSPACE_RESOURCE_GROUP"
```

Replace the example binding values with actual values for the target
environment. Only provide `--set` values for bindings present in the bundle.
Import validates the bundle and checksum, applies requested replacements, then
sends the bundle to the target agent in a chat request. `--name` changes the
saved report name without modifying its HTML. The bundle plus
instructions must fit within 512 KiB, and the HTML is limited to **128 KiB**.
The target agent checks for a report with the same name and stops rather than
overwriting it.
`--dry-run` validates the bundle and bindings without contacting Azure.

The agent may ask for tool-access approval while exporting or saving. The CLI
does not approve requests; open the corresponding conversation in the SRE Agent
portal and review the approval there. It appears in the conversation, not
necessarily in portal notifications. If the embedded agent page in VS Code
does not load, open the portal in an external browser. A pending approval is
reported as a non-success result.

Exported bundles preserve the report HTML and metadata; they are not
anonymized. Review the bundle for customer names, environment identifiers, or
other sensitive content before sharing it.

## Troubleshooting

- **No complete bundle returned:** inspect the printed source thread in the
  SRE Agent portal. The report may exceed the chat output limit, or the agent
  may not have `ListReports`/`GetReport` available.
- **Thread has a download link but no local bundle:** the source agent returned
  an artifact instead of inline JSON. The CLI currently requires the inline
  bundle format and does not download thread artifacts automatically.
- **Checksum mismatch:** the HTML was altered or truncated during export or
  sharing. Re-export it from the saved report source.
- **Required binding missing:** rerun import with `--set name=value` for every
  required binding reported by the tool.
- **Import stopped because the name exists:** rename the report or remove the
  existing target report yourself, then retry. The utility does not overwrite.
- **403 mentioning cross-tenant permission:** verify the active Azure CLI
  tenant with `az account show` and select the agent's subscription/tenant.
  Source and target being the same agent does not correct a token issued for
  another tenant. If a correctly tenant-scoped token still gets this error,
  check the caller's access to the agent.
- **401 / permission error:** check Azure CLI sign-in and the caller's access
  to the relevant agent. The data-plane token audience is
  `https://azuresre.dev`.
