# Investigate HTTP 500 Errors

Investigate HTTP 500 server errors using Application Insights telemetry, Log Analytics, and Azure activity logs.

## Step 1: Query App Insights for Exceptions

Get recent exceptions and their frequency:

```kql
exceptions
| where timestamp > ago(1h)
| summarize Count = count(), LastSeen = max(timestamp) by type, outerMessage, problemId
| order by Count desc
| take 20
```

## Step 2: Group Exceptions by Type

Identify the most common exception types:

```kql
exceptions
| where timestamp > ago(4h)
| summarize Count = count() by type, bin(timestamp, 15m)
| order by timestamp desc
```

Look for sudden spikes in specific exception types that correlate with incident time.

## Step 3: Trace Error Flow

Follow the operation chain from request to exception:

```kql
requests
| where timestamp > ago(1h)
| where resultCode startswith "5"
| summarize Count = count(), AvgDuration = avg(duration) by name, resultCode, bin(timestamp, 5m)
| order by Count desc
```

```kql
requests
| where timestamp > ago(1h)
| where resultCode startswith "5"
| take 5
| project operation_Id, name, resultCode, duration, timestamp
```

For each operation_Id, get the full trace:

```kql
union requests, dependencies, exceptions, traces
| where operation_Id == "<operation_id>"
| order by timestamp asc
| project timestamp, itemType, name, resultCode, message, type, duration
```

## Step 4: Check for Recent Deployments

Look for deployments or configuration changes that correlate with the error onset:

```
az monitor activity-log list -g <resource-group> --offset 24h --query "[?contains(operationName.localizedValue, 'deploy') || contains(operationName.localizedValue, 'restart') || contains(operationName.localizedValue, 'swap')].{op:operationName.localizedValue, time:eventTimestamp, status:status.value, caller:caller}" -o table
```

## Step 5: Check Knowledge Base

Search the knowledge base for matching runbooks or known issues:
- Use `SearchMemory` with the exception type and error message
- Look for previously resolved incidents with similar patterns
- Check for documented workarounds or fixes

## Step 6: Check Dependencies

Query dependency failures that may cause cascading 500 errors:

```kql
dependencies
| where timestamp > ago(1h)
| where success == false
| summarize FailCount = count(), AvgDuration = avg(duration) by type, target, name, resultCode, bin(timestamp, 5m)
| order by FailCount desc
```

## Common Causes

- **Unhandled exceptions**: Null references, timeouts, serialization errors
- **Dependency failures**: Database unavailable, external API timeouts, connection pool exhaustion
- **Configuration errors**: Missing app settings after deployment, invalid connection strings
- **Resource exhaustion**: Thread pool starvation, memory pressure, CPU saturation
- **Deployment issues**: Bad deploy, missing DLLs, incompatible config changes

## Step 7: Recommend Fix

Based on findings:
- **Dependency failure**: Check dependency health, failover, or retry configuration
- **Code exception**: Identify the specific code path and suggest a fix or rollback
- **Deployment-related**: Recommend rollback to last known good deployment
- **Resource exhaustion**: Scale up or out, optimize resource usage
- **Configuration**: Identify missing or incorrect settings

## Output

Provide a structured summary:
1. **Error Pattern**: Exception types, affected endpoints, frequency
2. **Timeline**: When errors started, correlation with events
3. **Dependency Health**: Upstream/downstream service status
4. **Root Cause**: Most likely cause with evidence
5. **Recommended Actions**: Immediate fix + prevention steps
