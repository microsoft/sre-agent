# Teams and Outlook connectors

This example adds the Microsoft Teams and Outlook connectors to an agent through `connectors.json`. ARM creates the connection and the connector. A user then signs in once in the portal to authorize it.

## How it works

Teams and Outlook are managed connectors. Set `dataConnectorType` to `Teams` or `Outlook` in the `connectors` array. You do not need an `api-connection` entry in `roles.yaml`.

The Bicep template deploys each entry as a `Microsoft.App/agents/connectors` resource. Separate managed connectors can be deployed in parallel.

| Field | Value | Notes |
|---|---|---|
| `dataConnectorType` | Managed connector name, e.g. `Teams` or `Outlook` | See the [full list of currently supported managed connectors](https://sre.azure.com/docs/reference/api-reference#managed-connector-types). |
| `dataSource` | Not required for managed connectors. | |
| `extendedProperties.connectionParameterValueSet` | `{ "name": "oauthDelegated", "values": {} }` | Required for Outlook. Teams has no parameter sets, so leave it out. |
| `extendedProperties.selectedTools` | `["GetEmailsV3"]` | Optional. Enables the named Outlook operation. |
| `extendedProperties.requireApprovalTools` | `["GetEmailsV3"]` | Optional. Requires approval to run the named operation. |

The Outlook example enables `GetEmailsV3` and requires approval to use it. The Teams example leaves tool selection to the portal. Change the arrays to fit your needs.

To find valid operation names, deploy without the tool arrays, then query `GET /api/v2/extendedAgent/connectors/metadata/{teams|outlook}`. Unknown names cause deployment to fail.

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
4. Select the Teams tools to enable after sign-in. If you remove `selectedTools` from the Outlook example, select Outlook tools in the portal too.

Redeploying updates the connector definition. Sign in again in the portal if the connector shows `Disconnected`.

## Learn more

- [Deploy with Bicep (Teams)](https://sre.azure.com/docs/tutorials/connectors/setup-teams-connector#deploy-with-bicep)
- [Deploy with Bicep (Outlook)](https://sre.azure.com/docs/tutorials/connectors/setup-outlook-connector#deploy-with-bicep)
- [Managed connector types](https://sre.azure.com/docs/reference/api-reference#managed-connector-types)