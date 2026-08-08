// Firewall rule: allow the SRE Agent to reach its OWN data-plane endpoint.
//
// Deployed as a SEPARATE rule collection group (not inside vnet.bicep's
// DefaultNetworkRuleCollectionGroup) so it can depend on the agent resource
// and use the agent's exact hostname — which is platform-assigned AFTER the
// agent is created and cannot be computed at vnet-deploy time.
//
// The agent's sandbox egress is forced through the hub firewall. Without this
// rule the agent cannot read or write the configuration surfaces ARM does not
// expose (custom instructions, hooks, knowledge files, tool enablement). The
// failure is confusing: DNS resolves, TCP 443 connects, then TLS is RESET
// (SSL_ERROR_SYSCALL) — it reads like a certificate problem, not a firewall
// denial.
//
// SECURITY NOTE: this is a self-modification path. The same data-plane API
// that lets the agent READ its config also lets it WRITE it (skills, always-on
// prompts). For this lab that is the point; set allowAgentSelfManagement=false
// in main.bicep to deploy this collection group with no allow rules.

@description('Name of the firewall policy to add the rule collection group to.')
param firewallPolicyName string

@description('The agent data-plane endpoint URL (e.g. https://<agent>--<hash>.<hash>.<region>.azuresre.ai). The host is extracted automatically.')
param agentEndpoint string

@description('Source address prefix for the agent subnet (must match vnet.bicep).')
param agentSubnetPrefix string = '10.30.0.0/27'

@description('Whether the exact-host data-plane allow rule is active. False removes the rule on incremental deployments.')
param enabled bool = true

// Extract the FQDN from the full endpoint URL.
// agentEndpoint is e.g. 'https://sre-agent-zava-g5kb--c618a660.6d6a35f1.swedencentral.azuresre.ai'
var agentFqdn = split(replace(agentEndpoint, 'https://', ''), '/')[0]

resource firewallPolicy 'Microsoft.Network/firewallPolicies@2023-11-01' existing = {
  name: firewallPolicyName
}

// Separate rule collection group — priority 250, after the existing
// DefaultNetworkRuleCollectionGroup (priority 200). Using a distinct group
// avoids having to duplicate the full rule set from vnet.bicep.
resource agentDataPlaneRcg 'Microsoft.Network/firewallPolicies/ruleCollectionGroups@2023-11-01' = {
  parent: firewallPolicy
  name: 'AgentDataPlaneRuleCollectionGroup'
  properties: {
    priority: 250
    ruleCollections: enabled ? [
      {
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        name: 'allow-agent-data-plane'
        priority: 100
        action: { type: 'Allow' }
        rules: [
          {
            ruleType: 'ApplicationRule'
            name: 'allow-agent-data-plane'
            // Pinned to this agent's exact hostname — not the broad *.azuresre.ai
            // wildcard. Standard firewall handles exact FQDNs fine (FQDN/SNI match).
            //
            // NOTE: the token AUDIENCE is `https://azuresre.dev` but the network
            // HOST is `*.azuresre.ai` — two different domains. Allow-listing the
            // audience domain does nothing.
            description: 'SRE Agent data-plane: ${agentFqdn}'
            sourceAddresses: [agentSubnetPrefix]
            protocols: [{ protocolType: 'Https', port: 443 }]
            targetFqdns: [agentFqdn]
          }
        ]
      }
    ] : []
  }
}

output agentDataPlaneFqdn string = agentFqdn
