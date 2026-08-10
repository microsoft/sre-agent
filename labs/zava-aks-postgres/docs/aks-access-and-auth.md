# AKS access, identity, and kubeconfig in this lab

This lab deliberately uses a private AKS API server and a VNet-injected SRE Agent. That makes Kubernetes access more realistic than a public demo cluster, but it also means several independent controls must all succeed before a `kubectl` command works.

Use this guide to understand the access path. Incident runbooks should still use the agent's built-in `RunKubectlReadCommand` and `RunKubectlWriteCommand` tools.

## The four gates behind a successful kubectl call

`kubectl get pods` is one command, but it crosses four separate gates:

| Gate | Question | Typical failure |
|---|---|---|
| Name resolution and routing | Can the caller resolve and reach the API server's private endpoint? | DNS failure, timeout, or no route |
| TLS trust | Does each side of the connection trust the certificate presented by the next hop? | `x509: certificate signed by unknown authority`, reset, or proxy handshake failure |
| Authentication | Can the caller obtain a valid Microsoft Entra token for AKS? | `kubelogin` or token acquisition error |
| Authorization | Is that Entra identity allowed to perform the requested Kubernetes action? | HTTP 403 `Forbidden` |

These gates are independent. A fresh token does not create a network route. A valid kubeconfig does not grant RBAC. Repairing the client certificate chain does not necessarily repair an intermediary's trust of the upstream AKS server.

## The Zava cluster posture

The lab declares the following AKS settings in [`infra/modules/aks.bicep`](../infra/modules/aks.bicep):

```bicep
aadProfile: {
  managed: true
  enableAzureRBAC: true
}
apiServerAccessProfile: {
  enablePrivateCluster: true
  privateDNSZone: 'system'
  enablePrivateClusterPublicFQDN: false
}
```

The practical result is:

- The Kubernetes API is reached through a private endpoint.
- AKS creates and manages a private DNS zone for the API server.
- No public API-server FQDN is published for the cluster.
- Microsoft Entra ID authenticates callers.
- Azure RBAC authorizes Kubernetes API operations.
- Both SRE Agent identities receive the **Azure Kubernetes Service RBAC Cluster Admin** role on this demo cluster.

The broad cluster-admin grant is intentional for an autonomous break/fix lab. A production deployment should normally replace it with namespace-scoped Reader, Writer, or Admin assignments that match the agent's required actions.

## What a kubeconfig contains

A kubeconfig is connection configuration, not a universal access credential. Its important sections are:

```yaml
clusters:
- name: zava
  cluster:
    server: https://<private-aks-api-fqdn>:443
    certificate-authority-data: <cluster-ca>

users:
- name: zava-identity
  user:
    exec:
      command: kubelogin
      args:
      - get-token
      - --login
      - msi

contexts:
- name: zava
  context:
    cluster: zava
    user: zava-identity
    namespace: zava-demo

current-context: zava
```

- **`clusters`** says where the API server is and which certificate authority signs its TLS certificate.
- **`users`** says how the client obtains credentials. Modern Entra-integrated AKS configurations commonly use the `kubelogin` exec plugin rather than embedding a long-lived token.
- **`contexts`** pair one cluster with one user and, optionally, a default namespace.
- **`current-context`** selects the active pairing.

`az aks get-credentials` retrieves connection configuration through the Azure Resource Manager control plane and normally merges it into `~/.kube/config`. Permission to retrieve that configuration and permission to use the Kubernetes API are separate checks. On an Entra-integrated cluster, the eventual data-plane access still depends on the signed-in identity's AKS RBAC assignment.

## The agent's built-in Kubernetes path

For this lab, a built-in call follows this logical flow:

```text
RunKubectlReadCommand / RunKubectlWriteCommand
        |
        | 1. Resolve AKS connection information through Azure
        | 2. Select the agent managed identity
        | 3. Build a temporary per-call kubeconfig
        | 4. Add the runtime proxy CA needed by the client-side TLS hop
        | 5. Obtain an Entra token through kubelogin managed-identity login
        v
VNet-injected runtime and egress proxy
        |
        | 6. Reach the AKS private endpoint over the connected VNets
        | 7. Validate the AKS server using the cluster CA
        v
AKS API server
        |
        | 8. Authorize the identity with Azure RBAC for Kubernetes
        v
Requested Kubernetes operation
```

The temporary kubeconfig is deleted after the tool call. A built-in call does **not** rewrite or leave a repaired kubeconfig in `~/.kube/config`.

This is why the built-in tools are more than command wrappers. They accept normal kubectl arguments, but the runtime also supplies the managed identity, temporary kubeconfig, certificate handling, private network path, and tool policy.

## Terminal kubectl

Incident runbooks should use the built-in Kubernetes tools. They create temporary
connection material for each call and do not modify `~/.kube/config`.

Terminal-native kubectl requires its own valid kubeconfig, identity, private
network path, and TLS configuration. Treat it as an operator access path, not a
dependency of agent automation.

## Human and CI access paths

The agent's built-in tools are not the only valid way to operate a private cluster. The right path depends on who is calling and whether the access is interactive or automated.

| Caller | Recommended path | Why |
|---|---|---|
| SRE Agent incident skill | `RunKubectlReadCommand` / `RunKubectlWriteCommand` | Uses the runtime identity, private path, and temporary connection setup |
| Lab operator without private network connectivity | `az aks command invoke` through `Invoke-AksCommand` | Runs kubectl through the Azure API without exposing the private endpoint to the workstation |
| Developer or administrator | Workstation or jump host connected through VNet peering, VPN, ExpressRoute, or Bastion | Supports full interactive Kubernetes tooling over the private endpoint |
| CI/CD automation | Self-hosted runner on a connected VNet | Stable private DNS and routing for programmatic access |

This repo uses `az aks command invoke` for setup and demo scripts because it keeps the workstation prerequisites small. Microsoft documents that path as an operator convenience, not a general programmatic-access transport: it depends on an in-cluster command pod, has a 60-second ARM scheduling timeout, and limits output to 512 KB.

## API-server exposure options

The following choices are easy to conflate:

| Model | Network behavior | When it fits |
|---|---|---|
| **Private cluster, public FQDN disabled** - this lab | The API server has a private endpoint and private DNS only. Callers need connected private networking or an Azure-brokered command path. | Enterprise isolation, private automation, and demonstrations of VNet-injected operations |
| **Private cluster, public FQDN enabled** | AKS publishes a publicly resolvable DNS name, but API communication still goes to the private endpoint. It does **not** create a public API endpoint. | Connected clients that need public DNS resolution while retaining private network reachability |
| **Public API server with authorized IP ranges** | The API server has a public endpoint and rejects source addresses outside configured CIDRs. | Simpler external administration when a public control-plane endpoint is acceptable |

API-server authorized IP ranges are not a way to make a private cluster selectively public. Microsoft documents that authorized IP ranges cannot be used with private clusters.

The lab chose the first model because it demonstrates the customer pattern the sample is intended to teach:

- the agent operates from a dedicated management spoke;
- the Kubernetes control plane is not exposed to the internet;
- private DNS, peering, identity, and authorization remain visible architectural concerns;
- human setup can still use `az aks command invoke`;
- production-style private runners, VPN, or ExpressRoute can replace command invoke without changing the cluster posture.

## Troubleshooting by layer

| Symptom | Most likely layer | Check |
|---|---|---|
| API FQDN does not resolve | Private DNS | VNet link, DNS forwarding, and whether the caller uses a connected network |
| TCP timeout or no route | Network | Peering, route tables, NSGs, firewall rules, VPN/ExpressRoute |
| `x509: certificate signed by unknown authority` | Client-side TLS trust | Kubeconfig CA data and any runtime intermediary CA |
| Reset or HTTP/2 error after client trust is correct | TLS or intermediary path | Use the built-in Kubernetes tools or validate the operator access path |
| `kubelogin` or token error | Authentication | Login mode, managed-identity client ID, Entra tenant, token audience |
| HTTP 403 `Forbidden` | Authorization | AKS Azure RBAC assignment and its scope |
| `az aks get-credentials` denied | ARM credential retrieval | Cluster User/Admin credential role, which is separate from Kubernetes data-plane RBAC |

Avoid changing several layers at once. First establish private DNS and routing, then TLS, then token acquisition, then RBAC.

## References

- [Create a private AKS cluster](https://learn.microsoft.com/azure/aks/private-clusters)
- [Access a private AKS cluster with command invoke](https://learn.microsoft.com/azure/aks/access-private-cluster)
- [Use Microsoft Entra ID authorization for the Kubernetes API](https://learn.microsoft.com/azure/aks/manage-azure-rbac)
- [Control access to AKS kubeconfig](https://learn.microsoft.com/azure/aks/control-kubeconfig-access)
- [API server authorized IP ranges](https://learn.microsoft.com/azure/aks/api-server-authorized-ip-ranges)
- [kubelogin documentation](https://azure.github.io/kubelogin/)
