# AWS Serverless App Architecture — Investigation Guide

## Purpose

This knowledge file teaches the agent how to discover, map, and investigate AWS serverless applications. Do NOT assume resource names. Always discover them at runtime using the AWS MCP tools.

## Architecture Pattern: Serverless Web App on AWS

Typical stack:
- **Frontend**: S3 static website or CloudFront distribution
- **API**: API Gateway (HTTP API or REST API) routing to Lambda
- **Compute**: Lambda functions (Python, Node.js, Go, etc.)
- **Database**: DynamoDB, RDS, or Aurora Serverless
- **Observability**: CloudWatch Logs + Metrics + Alarms + X-Ray
- **Alerts**: CloudWatch Alarms → SNS → Email/PagerDuty/Slack

## Discovery Process

Always start by discovering what exists before investigating. Never assume names.

### Step 1 — Discover Lambda Functions
- List all functions in the region
- For each function, get its configuration (runtime, timeout, memory, env vars, VPC)
- Note which functions share a naming prefix (likely same app)

### Step 2 — Discover API Gateway
- List APIs to find which front the Lambda functions
- Check integration targets to map routes → functions

### Step 3 — Discover DynamoDB Tables
- List tables, then describe each to get key schema, billing mode, indexes
- Cross-reference with Lambda env vars (usually TABLE_NAME or similar)

### Step 4 — Discover CloudWatch Configuration
- List alarms to find what thresholds are configured
- List log groups matching `/aws/lambda/<function-name>`
- Check for custom metric namespaces

### Step 5 — Check Source Code (GitHub)
- Look at the connected repo for IaC files (Terraform, CDK, SAM, CloudFormation)
- IaC files are the source of truth for what SHOULD exist
- Compare deployed state vs IaC definition to find drift

## Observability Signals and Where to Find Them

### CloudWatch Logs
- **Log groups**: `/aws/lambda/<function-name>` (auto-created per function)
- **Structured logs**: Look for JSON-formatted messages with level, requestId, message
- **Platform events**: START, END, REPORT lines contain duration, memory used, init duration
- **Error detection**: Filter for ERROR, Exception, Traceback, stackTrace

### CloudWatch Metrics
- **Lambda namespace** (`AWS/Lambda`):
  - `Invocations` — total calls
  - `Errors` — unhandled exceptions or explicit failures
  - `Duration` — execution time
  - `Throttles` — concurrency limit exceeded
  - `ConcurrentExecutions` — active instances
  - `IteratorAge` — for stream-triggered functions
- **DynamoDB namespace** (`AWS/DynamoDB`):
  - `ConsumedReadCapacityUnits` / `ConsumedWriteCapacityUnits`
  - `ThrottledRequests`
  - `SystemErrors`
  - `SuccessfulRequestLatency`
- **API Gateway namespace** (`AWS/ApiGateway`):
  - `4XXError`, `5XXError`
  - `Latency`, `IntegrationLatency`
  - `Count`
- **Custom namespaces**: App-specific metrics (discover via list-metrics)

### CloudWatch Alarms
- Check alarm state: OK, ALARM, INSUFFICIENT_DATA
- Check alarm history for recent state transitions
- Alarm actions tell you who gets notified (SNS topic ARN)

### X-Ray Traces
- Trace summaries show end-to-end latency and error rates
- Individual traces show per-segment timing (API GW → Lambda → DynamoDB)
- Filter by annotation, duration, status code, or time range

## Common Failure Patterns

### Lambda Failures
| Symptom | What to Check | Likely Cause |
|---------|--------------|--------------|
| High error rate | Logs for stack traces | Code bug, missing dependency, bad env var |
| Timeout | Duration metric, log for slow operations | Downstream latency (DB, external API) |
| Throttle | ConcurrentExecutions metric | Reached account/function concurrency limit |
| Cold start spikes | REPORT lines with initDuration | VPC ENI attach, large package, runtime init |
| Out of memory | REPORT lines showing max memory used | Increase memory configuration |

### DynamoDB Failures
| Symptom | What to Check | Likely Cause |
|---------|--------------|--------------|
| Throttled requests | ThrottledRequests metric | Hot partition, burst capacity exhausted |
| High latency | SuccessfulRequestLatency | Large items, query without index |
| System errors | SystemErrors metric | AWS-side issue (rare, check Service Health) |
| Validation errors | Lambda logs | Bad key schema, missing required attributes |

### API Gateway Failures
| Symptom | What to Check | Likely Cause |
|---------|--------------|--------------|
| 5xx errors | Integration latency, Lambda errors | Lambda failing or timing out |
| 4xx errors | Access logs | Client sending bad requests, CORS, auth |
| High latency | Latency vs IntegrationLatency | If equal: Lambda slow. If gateway higher: routing overhead |

## Investigation Methodology

1. **Time-bound**: Always establish the time window (when did it start, is it ongoing?)
2. **Scope**: Which functions/tables/APIs are affected? One or many?
3. **Correlate**: Did anything change? Check GitHub commits, deployments, config changes near the start time
4. **Quantify**: What's the error rate? What percentage of requests are affected?
5. **Root cause vs symptom**: Lambda errors are symptoms. The root cause is in the code, config, or downstream dependency
6. **Evidence**: Always provide specific log lines, metric values, or trace IDs as evidence

## Source Code Patterns to Look For

When you have access to the GitHub repo:
- **IaC files** (Terraform/CDK/SAM): Ground truth for intended infrastructure
- **Handler code**: Entry points, error handling, retry logic
- **Dependencies**: requirements.txt, package.json — version issues, missing packages
- **CI/CD workflows**: .github/workflows/ — deployment process, what triggers deploys
- **Environment config**: How env vars are set, what values are expected
- **Recent commits**: Changes near the incident start time are prime suspects
