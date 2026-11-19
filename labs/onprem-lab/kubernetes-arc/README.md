# Azure Arc-enabled Kubernetes SRE Agent lab

This lab deploys a small application to an on-premises Kubernetes cluster connected to Azure through Azure Arc and exposes application metrics to Azure Monitor Managed Prometheus. The workload is intentionally simple so the lab can focus on monitoring, fault injection, and SRE Agent investigation rather than application build infrastructure.

## Files

- `sample-app.yaml` deploys the Flask demo application and Kubernetes Service. The application source is stored in a ConfigMap and runs in `python:3.12-slim`, so no custom container image needs to be built or published.
- `load-generator.yaml` continuously calls `http://sample-app/api/data` so the application generates request and error metrics.
- `sample-app-servicemonitor.yaml` defines a ServiceMonitor that scrapes the application's `/metrics` endpoint.
- `ama-metrics-settings-configmap.yaml` enables annotation-based Prometheus scraping for pods in the `sre-demo` namespace. This provides an alternative annotation-based collection path in addition to the ServiceMonitor used by this lab.
- `setup.sh` creates the namespace, applies the manifests, waits for the workloads, and displays their status.

## Prerequisites

### 1. Prepare a Linux machine

Use an Ubuntu or other supported Linux machine or VM with outbound HTTPS access to Azure. Confirm that the machine can reach the Azure endpoints required by Azure Arc and Azure Monitor.

Install `curl` if it is not already available. You will also need Azure CLI on the machine from which you perform the Azure Arc onboarding steps.

### 2. Install k3s

Install k3s on the Linux machine:

```bash
curl -sfL https://get.k3s.io | sh -
```

Verify that the cluster is running:

```bash
sudo kubectl get nodes
```

The node should report `Ready`. If your user is configured to access the k3s kubeconfig directly, the remaining examples can use `kubectl` without `sudo`.

### 3. Connect the Kubernetes cluster to Azure Arc and enable Managed Prometheus

The `az` commands for prerequisites 3 and 4 are automated by two equivalent scripts:

- `scripts/configure-azure.sh` for Bash on Linux, WSL, or Azure Cloud Shell.
- `scripts/configure-azure.ps1` for PowerShell on Windows.

Run **one** of the scripts from a machine that has Azure CLI, `kubectl`, and a kubeconfig context for the k3s cluster. The script performs these steps:

1. Signs in to Azure when the current Azure CLI session is not authenticated.
2. Selects the specified Azure subscription.
3. Registers the Azure resource providers required by Azure Arc and Azure Monitor.
4. Installs or updates the `connectedk8s` and `k8s-extension` Azure CLI extensions.
5. Creates the specified resource group if it does not already exist.
6. Connects the current Kubernetes cluster to Azure Arc.
7. Creates an Azure Monitor workspace if it does not already exist.
8. Installs and configures the `Microsoft.AzureMonitor.Containers.Metrics` extension for Managed Prometheus.
9. Displays the Arc connectivity status and metrics extension provisioning state.

Both scripts require the subscription ID, resource group name, and Azure region. The cluster name and workspace name are optional. By default, the cluster name is based on the local machine name and the workspace is named `<cluster-name>-amw`.

Bash example:

```bash
chmod +x scripts/configure-azure.sh
./scripts/configure-azure.sh \
  --subscription-id "00000000-0000-0000-0000-000000000000" \
  --resource-group "rg-sre-onprem-k8s-lab" \
  --region "eastus" \
  --cluster-name "sre-onprem-k8s-01"
```

PowerShell example:

```powershell
.\scripts\configure-azure.ps1 `
  -SubscriptionId "00000000-0000-0000-0000-000000000000" `
  -ResourceGroupName "rg-sre-onprem-k8s-lab" `
  -Region "eastus" `
  -ClusterName "sre-onprem-k8s-01"
```

To choose a specific Azure Monitor workspace name, add `--workspace-name <name>` to the Bash command or `-WorkspaceName <name>` to the PowerShell command.

After the script completes, it prints the Arc connectivity status and Azure Monitor metrics extension provisioning state. The expected values are `Connected` and `Succeeded`. Provider registration and extension deployment can take several minutes.

You can then find the cluster in the Azure portal under **Azure Arc** > **Kubernetes clusters**. Open the cluster resource to confirm that its status is **Connected** and to view its properties, extensions, and Kubernetes resources. The resource appears in the subscription and resource group passed to the configuration script.

### 4. Verify the Azure resources

Confirm the resources created by the script:

```bash
az connectedk8s show \
  --name <arc-cluster-name> \
  --resource-group <resource-group> \
  --query connectivityStatus -o tsv

az k8s-extension show \
  --name azuremonitor-metrics \
  --cluster-type connectedClusters \
  --cluster-name <arc-cluster-name> \
  --resource-group <resource-group> \
  --query provisioningState -o tsv
```

The cluster should report `Connected`, and the `Microsoft.AzureMonitor.Containers.Metrics` extension should report `Succeeded`. The cluster must be able to resolve and reach the Azure Monitor ingestion endpoints. If metrics do not arrive later in the lab, use the DNS troubleshooting section rather than changing the workload manifests first.

### 5. Verify kubectl access

Before deploying the workload, verify that you can query the cluster:

```bash
kubectl get nodes
kubectl get namespaces
```

The node should be `Ready` and the commands should complete without authentication or connectivity errors.

## Access the k3s cluster from Windows

You can administer the cluster directly from Windows when the Windows machine can reach the Linux VM's Kubernetes API endpoint, normally TCP port `6443`.

### 1. Install kubectl.exe

Install `kubectl` on Windows using a supported package manager, or download it from the Kubernetes tools page. For example, with winget:

```powershell
winget install -e --id Kubernetes.kubectl
kubectl version --client
```

### 2. Copy the k3s kubeconfig

On the Linux machine, the administrator kubeconfig is stored at:

```text
/etc/rancher/k3s/k3s.yaml
```

Copy it to Windows using `scp` from PowerShell. Replace the host and user values for your lab:

```powershell
New-Item -ItemType Directory -Force "$HOME\.kube"
scp <linux-user>@<linux-vm-ip>:/etc/rancher/k3s/k3s.yaml "$HOME\.kube\k3s.yaml"
```

The file is normally readable only by root. If `scp` receives a permission error, create a temporary user-readable copy on Linux, copy that file to Windows, and then delete the temporary copy:

```bash
sudo cp /etc/rancher/k3s/k3s.yaml /tmp/k3s.yaml
sudo chown "$USER":"$USER" /tmp/k3s.yaml
```

### 3. Change the API server address

By default, `k3s.yaml` usually contains:

```yaml
server: https://127.0.0.1:6443
```

On Windows, edit `$HOME\.kube\k3s.yaml` and replace `127.0.0.1` with the Linux VM's IP address or a DNS name that Windows can resolve:

```yaml
server: https://<linux-vm-ip>:6443
```

The certificate and client credentials are embedded in `k3s.yaml`; do not remove the `certificate-authority-data`, `client-certificate-data`, or `client-key-data` values. Treat this file as an administrator credential and do not commit it to source control.

### 4. Use the kubeconfig

For the current PowerShell session:

```powershell
$env:KUBECONFIG = "$HOME\.kube\k3s.yaml"
kubectl get nodes
```

To avoid setting `KUBECONFIG`, you can instead save it as `$HOME\.kube\config`. If `kubectl get nodes` times out, verify that Windows can route to the Linux VM and that TCP `6443` is allowed through the Linux firewall, Windows/Hyper-V network, and any intervening network controls.

If direct network access to the cluster API is not desirable, Azure Arc cluster connect provides a separate proxy-based access path without opening an inbound port to the on-premises cluster.

## Deploy the lab

Run the setup script from this directory:

```bash
chmod +x setup.sh
./setup.sh
```

The script applies the checked-in YAML files rather than generating Kubernetes resources itself. This makes the manifests the source of truth for the lab.

After the script finishes, verify the resources:

```bash
kubectl get pods,svc -n sre-demo
kubectl get servicemonitor -n sre-demo
```

## Application and metrics

`sample-app.yaml` creates a ConfigMap containing a small Flask application and mounts it into a `python:3.12-slim` container. At startup, the container installs Flask and runs `/app/app.py`.

The application exposes:

- `/` - basic lab response
- `/health` - readiness/liveness health endpoint
- `/api/data` - workload endpoint used by the load generator
- `/metrics` - Prometheus metrics endpoint

The `/metrics` endpoint publishes these lab metrics:

- `demo_requests_total`
- `demo_errors_total`

`load-generator.yaml` calls `/api/data` every two seconds. This gives Managed Prometheus a continuous metric signal without requiring external traffic.

## Prometheus collection

### ServiceMonitor

`sample-app-servicemonitor.yaml` selects the `sample-app` Service through the `app: sample-app` label and scrapes the Service port named `http` at `/metrics` every 30 seconds.

The corresponding Service labels and named port are defined in `sample-app.yaml`. Keep the Service and ServiceMonitor definitions synchronized if you change either file.

### Annotation-based scraping

The sample application pod also contains these Prometheus annotations:

```yaml
prometheus.io/scrape: "true"
prometheus.io/path: "/metrics"
prometheus.io/port: "8080"
```

`ama-metrics-settings-configmap.yaml` enables annotation-based scraping for the `sre-demo` namespace. This is an alternative collection mechanism and is useful for comparing annotation-based discovery with ServiceMonitor-based discovery. The ServiceMonitor is the primary explicit scrape definition used in this lab.

## Verify metrics locally

Before investigating Azure ingestion, verify that the application itself exposes metrics:

```bash
kubectl run curl-test \
  --rm -it \
  --restart=Never \
  --image=curlimages/curl \
  -n sre-demo \
  -- curl -s http://sample-app/metrics
```

You should see output containing `demo_requests_total` and `demo_errors_total`.

## View Prometheus metrics in the Azure portal

After Managed Prometheus has started ingesting data:

1. In the Azure portal, open **Azure Monitor**.
2. Select **Workspaces**, then open the Azure Monitor workspace associated with this Arc-enabled Kubernetes cluster.
3. Select **Prometheus explorer** from the workspace menu.
4. In the PromQL editor, run:

```promql
demo_requests_total
```

5. Select **Run** and choose a time range that includes recent load-generator activity.
6. Run the error metric query:

```promql
demo_errors_total
```

7. After enabling fault injection, use `rate(demo_errors_total[5m])` to view the recent error rate.

You can also open the Arc-enabled Kubernetes resource and select its monitoring or insights experience when it is available. The Azure Monitor workspace's Prometheus explorer is the most direct place to confirm that the custom `demo_*` series reached Managed Prometheus.

If the query returns no series, first confirm the local `/metrics` endpoint, then check the ServiceMonitor/annotation configuration, Azure Monitor extension health, and DNS connectivity described below. Ingestion and portal query results can take several minutes to appear after initial onboarding.

## Set up SRE Agent

Open the [SRE Agent portal](https://sre.azure.com), create or open an SRE Agent, and add the lab's Azure resource group as a monitored resource. Specify the same resource group name passed to `configure-azure.sh` or `configure-azure.ps1`.

The resource group contains the Arc-enabled Kubernetes cluster and Azure Monitor workspace created for the lab. Monitoring the resource group gives SRE Agent the resource scope it needs to discover the cluster and query the Managed Prometheus telemetry. No individual Kubernetes resource or metric name needs to be added to the agent configuration.

Before injecting a failure, allow enough time for the healthy `demo_requests_total` baseline to appear in Managed Prometheus. You can optionally ask SRE Agent to check the application's current health before continuing.

## Fault injection

Use the checked-in `scripts/fault.sh` script to enable and reset the demo application's failure mode. The script locates the current `sample-app` pod and manages the `/fault/fail` marker inside it, so you do not need to run the underlying `kubectl exec` commands manually.

Make the script executable:

```bash
chmod +x scripts/fault.sh
```

Inject HTTP 500 failures:

```bash
./scripts/fault.sh fail
```

Leave the failure enabled for several minutes so multiple Prometheus scrape intervals capture the condition. The load generator should begin receiving HTTP 500 responses and `demo_errors_total` should increase.

Ask SRE Agent to investigate using a deliberately nonspecific prompt:

> Investigate the health of the applications and infrastructure in this resource group. Identify any recent anomalies, determine the likely cause, and summarize the supporting evidence.

Do not provide a time range, mention fault injection, name a failure type, or point SRE Agent to a specific metric. The purpose of the exercise is to verify that it can discover the relevant resources and determine when and how the behavior changed from the available telemetry.

After SRE Agent has completed its investigation, reset the application:

```bash
./scripts/fault.sh reset
```

Do not tell SRE Agent when the failure occurred. Ask it to identify the anomaly from the telemetry.

## Troubleshooting

If Managed Prometheus does not receive metrics, check the pipeline in this order:

1. Verify `/metrics` directly inside the cluster.
2. Verify the `sample-app` Service has the `app: sample-app` label and its port is named `http`.
3. Verify the `sample-app` ServiceMonitor exists in `sre-demo`.
4. Verify the Azure Monitor metrics extension is healthy.
5. Check CoreDNS logs and verify that the cluster can resolve the Azure Monitor ingestion hostname.
6. Verify outbound DNS and HTTPS connectivity from the on-premises environment.

This ordering separates application/scrape configuration problems from the Arc/Azure Monitor network path.

### DNS issue observed in the Hyper-V lab

Use this section when the application exposes metrics inside the cluster and the ServiceMonitor and Azure Monitor extension appear healthy, but custom Prometheus metrics do not appear in Azure Monitor. A common sign is that CoreDNS cannot resolve the Azure Monitor ingestion hostname or logs a connection failure to the configured DNS server on TCP port 53. Because DNS responses can fall back from UDP to TCP, the cluster's DNS server must support both UDP and TCP queries on port 53.

Use a temporary pod to distinguish cluster DNS from general network connectivity:

```bash
kubectl run dns-test \
  --rm -it \
  --restart=Never \
  --image=busybox:1.36 \
  -- nslookup <azure-monitor-ingestion-hostname>
```

Inspect CoreDNS logs:

```bash
kubectl logs -n kube-system deployment/coredns --tail=200
```

Check which resolver the Linux host uses:

```bash
cat /etc/resolv.conf
cat /run/systemd/resolve/resolv.conf
```

Test the intended DNS server from the Linux VM with both UDP and TCP. Replace the hostname with the Azure Monitor ingestion hostname shown in the CoreDNS error:

```bash
dig @<dns-server> <azure-monitor-ingestion-hostname>
dig +tcp @<dns-server> <azure-monitor-ingestion-hostname>
```

If UDP succeeds and TCP fails, fix the firewall or DNS server so both UDP and TCP port 53 work. In this lab, switching to a resolver that supported both protocols, such as `8.8.8.8`, allowed CoreDNS to resolve the ingestion endpoint.

For k3s, configure the kubelet resolver in `/etc/rancher/k3s/config.yaml`:

```yaml
resolv-conf: /run/systemd/resolve/resolv.conf
```

Ensure the referenced resolver file contains the working DNS server, then restart k3s:

```bash
sudo systemctl restart k3s
```

Do not edit generated service YAML or transient files that k3s rewrites. Use `/etc/rancher/k3s/config.yaml` for persistent k3s configuration. After the restart, repeat the `dns-test` lookup and check CoreDNS logs. Once name resolution succeeds, allow several minutes for Managed Prometheus ingestion and rerun `demo_requests_total` in Prometheus explorer.
