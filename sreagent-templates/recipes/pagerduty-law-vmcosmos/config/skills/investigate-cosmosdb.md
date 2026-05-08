# Investigate Cosmos DB Issues

Diagnose Azure Cosmos DB problems including RU consumption, throttling, latency, and partition hot spots.

## Step 1: Identify Cosmos DB Accounts

List Cosmos DB accounts in the monitored resource group:
```
az cosmosdb list -g <resource-group> --query "[].{name:name, kind:kind, location:locations[0].locationName}" -o table
```

## Step 2: Check RU Consumption and Throttling

Query Azure Monitor metrics for total requests and throttled requests:
```
az monitor metrics list --resource <cosmos-resource-id> --metric TotalRequests --interval PT5M --start-time <1h-ago> --end-time <now> -o table
az monitor metrics list --resource <cosmos-resource-id> --metric TotalRequestUnits --interval PT5M --start-time <1h-ago> --end-time <now> -o table
```

Check for HTTP 429 (throttling) responses:
```
az monitor metrics list --resource <cosmos-resource-id> --metric TotalRequests --filter "StatusCode eq '429'" --interval PT5M --start-time <1h-ago> --end-time <now> -o table
```

## Step 3: Query Data Plane Logs in Log Analytics

If CDBDataPlaneRequests is available in the Log Analytics workspace:

```kql
CDBDataPlaneRequests
| where TimeGenerated > ago(1h)
| where StatusCode >= 400
| summarize Count = count(), AvgDuration = avg(DurationMs), P95Duration = percentile(DurationMs, 95) by StatusCode, OperationName, bin(TimeGenerated, 5m)
| order by Count desc
```

```kql
CDBDataPlaneRequests
| where TimeGenerated > ago(1h)
| summarize TotalRU = sum(RequestCharge), AvgRU = avg(RequestCharge), MaxRU = max(RequestCharge) by OperationName, bin(TimeGenerated, 5m)
| order by TotalRU desc
```

## Step 4: Check Partition Key Distribution

Look for hot partitions consuming disproportionate RUs:

```kql
CDBDataPlaneRequests
| where TimeGenerated > ago(1h)
| summarize TotalRU = sum(RequestCharge), RequestCount = count() by PartitionKey = tostring(PartitionKeyRangeId)
| order by TotalRU desc
| take 10
```

## Step 5: Check for Recent Configuration Changes

```
az monitor activity-log list -g <resource-group> --offset 24h --query "[?contains(resourceType.value, 'Microsoft.DocumentDb')].{op:operationName.localizedValue, time:eventTimestamp, status:status.value}" -o table
```

Watch for: throughput changes, indexing policy updates, failover events, consistency level changes.

## Step 6: Recommend Remediation

Based on findings:
- **Throttling (429s)**: Scale up provisioned RUs, enable autoscale, or optimize queries to reduce RU cost
- **High Latency**: Check if requests cross regions, optimize query patterns, add composite indexes
- **Hot Partitions**: Redesign partition key for better distribution, consider synthetic partition keys
- **High RU Queries**: Add indexes, use point reads instead of queries where possible, reduce cross-partition queries
- **Recent Changes**: Correlate issues with configuration changes in activity log

Always search the knowledge base (`SearchMemory`) for existing Cosmos DB troubleshooting guides first.

## Output

Provide a structured summary:
1. **Affected Accounts/Databases**: Name and current status
2. **RU Consumption**: Current vs. provisioned throughput
3. **Throttling**: 429 count and trend
4. **Latency**: P50/P95/P99 by operation type
5. **Root Cause Hypothesis**: Based on evidence
6. **Recommended Actions**: Prioritized remediation steps
