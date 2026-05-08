# HTTP 500 Error Investigation Runbook

## Overview
This runbook provides systematic steps for diagnosing HTTP 500 (Internal Server Error) responses in Azure-hosted applications.

## Quick Triage

### 1. Determine Scope
- Is the error affecting all endpoints or specific routes?
- Is it intermittent or consistent?
- When did it start? Correlate with deployment or config change times.

### 2. Check Application Insights — Exceptions

```kql
exceptions
| where timestamp > ago(1h)
| summarize Count = count() by type, outerMessage, problemId
| order by Count desc
```

### 3. Check Request Failure Rate

```kql
requests
| where timestamp > ago(4h)
| summarize Total = count(), Failed = countif(resultCode startswith "5"), FailRate = round(100.0 * countif(resultCode startswith "5") / count(), 2) by bin(timestamp, 15m)
| order by timestamp desc
```

### 4. Trace a Failed Request

```kql
requests
| where timestamp > ago(1h) and resultCode startswith "5"
| take 1
| project operation_Id
```

Then trace the full operation:
```kql
union requests, dependencies, exceptions, traces
| where operation_Id == "<operation_id>"
| order by timestamp asc
| project timestamp, itemType, name, resultCode, message, type
```

## Common Causes and Fixes

### Unhandled Null Reference
- **Symptom**: `NullReferenceException` in exceptions table
- **Root Cause**: Missing null checks, often after a data model change
- **Fix**: Add null guards, verify data contracts match expectations

### Database Connection Exhaustion
- **Symptom**: `SqlException` or `TimeoutException`, dependency failures to SQL
- **Root Cause**: Connection pool maxed out, long-running queries, connection leaks
- **Fix**: Check `max pool size` setting, look for unclosed connections, optimize slow queries
- **KQL**:
```kql
dependencies
| where timestamp > ago(1h)
| where type == "SQL" and success == false
| summarize FailCount = count(), AvgDuration = avg(duration) by target, bin(timestamp, 5m)
```

### External API Timeout
- **Symptom**: `TaskCanceledException` or `HttpRequestException` in dependencies
- **Root Cause**: Downstream service slow or unreachable
- **Fix**: Add circuit breaker, increase timeout, check dependency health
- **KQL**:
```kql
dependencies
| where timestamp > ago(1h)
| where success == false
| summarize FailCount = count() by type, target, resultCode, bin(timestamp, 5m)
| order by FailCount desc
```

### Configuration Error After Deployment
- **Symptom**: Errors started immediately after a deployment slot swap or release
- **Root Cause**: Missing app setting, wrong connection string, incompatible config
- **Fix**: Compare current app settings with last known good, rollback if needed
- **Check Activity Log**:
```
az monitor activity-log list -g <rg> --offset 6h --query "[?contains(operationName.localizedValue,'swap') || contains(operationName.localizedValue,'deploy')]" -o table
```

### Memory Pressure / Thread Starvation
- **Symptom**: Intermittent 500s, increasing response times, `OutOfMemoryException`
- **Root Cause**: Memory leak, sync-over-async, unbounded caches
- **Fix**: Check process metrics (private bytes, thread count), restart as temporary fix, profile for leaks

### Cosmos DB Throttling Causing 500s
- **Symptom**: Dependency failures to Cosmos DB with 429 status
- **Root Cause**: Exceeded provisioned RU/s
- **Fix**: Scale RUs, enable autoscale, optimize queries
- **KQL**:
```kql
dependencies
| where timestamp > ago(1h)
| where type contains "Cosmos" or type contains "DocumentDb"
| where resultCode == "429"
| summarize ThrottleCount = count() by target, bin(timestamp, 5m)
```

## Escalation Criteria
- Error rate > 50% for more than 15 minutes
- All endpoints affected (not just one route)
- Cascading failures to downstream services
- Data corruption suspected

## Post-Incident
- Document root cause and timeline
- Create follow-up work items for permanent fixes
- Update this runbook with new patterns discovered
