# VM + Cosmos DB Architecture Reference

## Overview

This document describes a common Azure architecture pattern: application VMs communicating with Azure Cosmos DB over private endpoints, monitored by Application Insights and Log Analytics.

## Components

### Application Tier — Azure Virtual Machines
- VMs in a dedicated subnet host the application workload (API, backend services)
- Typically behind an Azure Load Balancer or Application Gateway
- Managed identity enabled for authenticating to Azure services
- Azure Monitor Agent installed for sending OS-level metrics and logs to Log Analytics

### Data Tier — Azure Cosmos DB
- NoSQL database for application data (documents, key-value, graph)
- Connected via private endpoint in the application VNet — no public access
- Provisioned throughput (RU/s) or autoscale based on workload
- Diagnostic settings enabled: sends CDBDataPlaneRequests and CDBControlPlaneRequests to Log Analytics

### Networking
- **VNet**: Single VNet with subnets for VMs, private endpoints, and management
- **NSG**: Network Security Groups control inbound/outbound traffic per subnet
- **Private Endpoint**: Cosmos DB accessible only via private IP within the VNet
- **Private DNS Zone**: `privatelink.documents.azure.com` linked to VNet for name resolution

### Monitoring — Application Insights
- Application-level telemetry: requests, dependencies, exceptions, traces
- SDK integrated into the application code
- Connected to a Log Analytics workspace for long-term retention and cross-resource queries

### Monitoring — Log Analytics Workspace
- Central log aggregation for VM metrics (Perf table), Cosmos DB diagnostics, and activity logs
- KQL queries for investigation and alerting
- Linked to Application Insights for unified diagnostics

### Azure Monitor
- Platform-level metrics for VMs (CPU, disk, network) and Cosmos DB (RU consumption, throttling)
- Alert rules for automated incident detection
- Action groups for notification routing (PagerDuty, email, webhook)

## Data Flow

1. Client → Load Balancer → VM (application processes request)
2. VM → Private Endpoint → Cosmos DB (reads/writes data)
3. VM → Application Insights (sends telemetry via SDK)
4. VM → Azure Monitor Agent → Log Analytics (sends OS metrics and logs)
5. Cosmos DB → Diagnostic Settings → Log Analytics (sends data plane logs)
6. Azure Monitor → Alert Rule → Action Group → PagerDuty (triggers incident)

## Key Metrics to Monitor

| Component | Metric | Alert Threshold |
|-----------|--------|-----------------|
| VM | CPU % | > 90% for 10 min |
| VM | Memory % | > 95% for 5 min |
| VM | Disk Free % | < 10% |
| Cosmos DB | Total Request Units | > 80% of provisioned |
| Cosmos DB | HTTP 429 Count | > 0 sustained |
| Cosmos DB | P99 Latency | > 100ms |
| App Insights | HTTP 5xx Rate | > 5% of requests |
| App Insights | Dependency Failure Rate | > 10% |
