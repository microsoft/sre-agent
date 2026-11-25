# Teams and Outlook connectors

This example adds the Microsoft Teams and Outlook connectors to an agent through `connectors.json`. ARM creates the connection and the connector. A user then signs in once in the portal to authorize it.

## How it works

Teams and Outlook are managed connectors. Use the named connector types `Teams` and `Outlook` in the `connectors` array. You do not need an `api-connection` entry in `roles.yaml`.

The Bicep template deploys each entry as a `Microsoft.App/agents/connectors` resource, one at a time (`@batchSize(1)`). Parallel writes to managed connectors fail with `OperationConflict`.

| Field | Value | Notes |
|---|---|---|
| `dataConnectorType` | `Teams` or `Outlook` | Named managed connector type. Do not use `ConnectorGateway`. |
| `dataSource` | `placeholder` | Required by the schema. The service ignores it for managed connectors. |
| `extendedProperties.connectionParameterValueSet` | `{ "name": "oauthDelegated", "values": {} }` | Required for Outlook. Teams has no parameter sets, so leave it out. |
| `extendedProperties.selectedTools` | Array of operation names | Optional. Each name must be an operation of the managed API. |
| `extendedProperties.requireApprovalTools` | Array of operation names | Optional. |

If you leave out `connectionParameterValueSet` for Outlook, the deployment fails with:

```
Managed connector 'Outlook' requires connectionParameterValueSet.
```

## Usage

1. Copy `connectors.json` into your agent folder, or merge its `connectors` entries into your existing file.
2. Deploy as usual:

   ```bash
   ./bin/deploy.sh my-sre-agent/
   ```

3. Open the agent at [sre.azure.com](https://sre.azure.com), go to **Connectors**, and sign in on the Teams and Outlook connectors. Until then, each connector shows status `Disconnected` with the required action `SignIn`.
4. If you did not set `selectedTools`, select the tools to enable after sign-in.

Redeploying updates the connector definition. Sign in again in the portal if the connector shows `Disconnected`.

## Learn more

- [Deploy with Bicep (Teams)](https://sre.azure.com/docs/tutorials/connectors/setup-teams-connector#deploy-with-bicep)
- [Deploy with Bicep (Outlook)](https://sre.azure.com/docs/tutorials/connectors/setup-outlook-connector#deploy-with-bicep)
- [Managed connector types](https://sre.azure.com/docs/reference/api-reference#managed-connector-types)