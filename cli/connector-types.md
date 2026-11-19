# Connector types

`az sre connector create --data-connector-type` takes the values below. Matching is
case-insensitive, and the portal's names are accepted too.

| Value | Portal name | Notes |
|---|---|---|
| `KustoClient` (default) | Azure Data Explorer | Queries clusters the agent's identity can reach |
| `Kusto` | Azure Data Explorer Cluster | Pins the connector to one cluster; requires `--data-source` |
| `LogAnalytics` | Log Analytics Workspace | |
| `Mcp` | MCP server | Use `--mcp-endpoint`, or `--github` for the GitHub MCP server |
| `Icm` | IcM connector | |
| `Dgrep` | DGrep | |
| `Ev2Mcp` | EV2 | |
| `GenevaMetrics` | Geneva Metrics | |
| `S360` | S360 connector | |
| `Documentation` | Documentation connector | |
| `AppInsights` | Application Insights | |
| `KnowledgeText` | Knowledge: text | Use `--file-path` |
| `KnowledgeFile` | Knowledge: file | Use `--file-path` |
| `KnowledgeWebPage` | Knowledge: web page | |
| `KnowledgeRepository` | Knowledge: repository | |

Creating a connector links it to the agent. For an EntraOAuth MCP connector, check
`consentStatus` with `az sre connector show`; for one created with `--oauth-dcr true`,
finish and check the sign-in in the portal. Grant the agent's identity access to the
data source.

## Managed connectors

Office 365 Outlook, Microsoft Teams, Gmail, SharePoint, OneDrive for Business and the
portal's other managed connectors are set up in the portal, where you sign in and pick
their tools. `az sre` doesn't create them, and `--data-connector-type` rejects their
names with an error like this:

```
Set up Office 365 Outlook in the portal: Connectors > Add connector.
```

That includes the old `Outlook` and `Teams` values, which the service now creates as
managed connectors. Creating an `Outlook` connector fails because the request doesn't
choose a sign-in method, and creating a `Teams` connector succeeds but leaves it signed
out with no tools. `connector update` rejects both values too. Existing Outlook and Teams
connectors still show up in `az sre connector list` and `show`, and
`az sre connector delete` removes them.

Learn documents a
[REST API for managed connectors](https://learn.microsoft.com/azure/sre-agent/setup-managed-connector#set-up-a-managed-connector-with-the-rest-api).
`az sre` doesn't call it, and OAuth connectors still need the portal to sign in.
