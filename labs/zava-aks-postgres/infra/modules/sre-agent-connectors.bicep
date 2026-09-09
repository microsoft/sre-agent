// Applied by setup-sre-agent.ps1 only after authenticated data-plane readiness.
param agentName string
param appInsightsId string
param logAnalyticsId string
param connectorNames array
param tagsByName object = {}

var definitions = loadJsonContent('../../sre-config/agent-config.json', '$.connectors')
var properties = [for connector in definitions: json(
  replace(
    replace(
      replace(
        replace(string(connector.properties), '@@APPINSIGHTS_ID@@', appInsightsId),
        '@@WORKSPACE_ID@@', logAnalyticsId
      ),
      '@@APPINSIGHTS_NAME@@', last(split(appInsightsId, '/'))
    ),
    '@@WORKSPACE_NAME@@', last(split(logAnalyticsId, '/'))
  )
)]

#disable-next-line BCP081
resource connectors 'Microsoft.App/agents/connectors@2025-05-01-preview' = [for (connector, i) in definitions: if (contains(connectorNames, connector.name)) {
  name: '${agentName}/${connector.name}'
  tags: contains(tagsByName, connector.name) ? tagsByName[connector.name] : {}
  properties: properties[i]
}]
