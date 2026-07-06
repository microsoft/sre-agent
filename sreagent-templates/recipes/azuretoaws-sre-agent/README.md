# azuretoaws-sre-agent

SRE Agent connected to AWS resources via the AWS MCP SDK. Uses CloudWatch for
observability (logs, metrics, alarms, X-Ray traces) instead of third-party APM tools.
Includes a diagnostic skill and subagent for investigating serverless app issues.

## Prerequisites

- AWS account with IAM access (STS temporary credentials recommended)
- GitHub repo with your AWS app source code
- Azure subscription with a resource group for the agent
- All [CLI tools](../../README.md#prerequisites) installed (`./bin/install-prerequisites.sh --check`)

## Quick Start

### Step 1 — Get AWS credentials

```bash
# Generate short-lived STS credentials (12 hours)
aws sts get-session-token --duration-seconds 43200 --output json
```

Save `AccessKeyId`, `SecretAccessKey`, and `SessionToken` from the output.

### Step 2 — Generate agent config

Bash:

```bash
./bin/new-agent.sh --recipe azuretoaws-sre-agent --non-interactive \
  --set agentName=aws-sre-agent \
  --set resourceGroup=rg-aws-sre-agent \
  --set location=eastus2 \
  --set awsRegion=us-east-1 \
  --set githubRepo=https://github.com/dm-chelupati/todo-app-dynatrace-aws.git \
  -o aws-agent/
```

PowerShell:

```powershell
./bin/ps/New-Agent.ps1 -Recipe azuretoaws-sre-agent -NonInteractive `
  -Set @{agentName='aws-sre-agent'; resourceGroup='rg-aws-sre-agent'; location='eastus2';
    awsRegion='us-east-1'; githubRepo='https://github.com/dm-chelupati/todo-app-dynatrace-aws.git'} `
  -Output aws-agent/
```

### Step 3 — Add AWS credentials to secrets file

```bash
# Edit the generated secrets file (gitignored, never committed)
cat > aws-agent/connectors.secrets.env << 'EOF'
AWS_ACCESS_KEY_ID=<paste AccessKeyId from Step 1>
AWS_SECRET_ACCESS_KEY=<paste SecretAccessKey from Step 1>
AWS_SESSION_TOKEN=<paste SessionToken from Step 1>
EOF
```

### Step 4 — Deploy (pick any backend)

| Backend | Command |
|---------|---------|
| Bicep | `./bin/deploy.sh aws-agent/` |
| Terraform | `./bin/deploy-tf.sh aws-agent/` |
| PowerShell | `./bin/ps/Deploy-Agent.ps1 -InputPath aws-agent/` |
| azd | `azd up` (see main README for setup) |

## Parameters

| Parameter | Required | Default | Notes |
|-----------|----------|---------|-------|
| agentName | Yes | `aws-sre-agent` | Lowercase, hyphens ok |
| resourceGroup | Yes | `rg-aws-sre-agent` | Azure RG for agent infra |
| location | Yes | | Azure region for the agent (eastus2, swedencentral, etc.) |
| awsRegion | Yes | `us-east-1` | AWS region where your workloads are deployed (determines MCP endpoint + SigV4 signing) |
| githubRepo | No | `dm-chelupati/todo-app-dynatrace-aws` | GitHub repo for code context |
| targetRGs | No | | Azure RGs to monitor (comma-separated, leave empty for AWS-only) |

### Secrets (connectors.secrets.env)

These go in the secrets file, **never** on the command line:

| Variable | Source | Notes |
|----------|--------|-------|
| `AWS_ACCESS_KEY_ID` | `aws sts get-session-token` | Temporary key |
| `AWS_SECRET_ACCESS_KEY` | `aws sts get-session-token` | Temporary secret |
| `AWS_SESSION_TOKEN` | `aws sts get-session-token` | Session token (required for STS creds) |

### Advanced Options

| Parameter | Default | Notes |
|-----------|---------|-------|
| existingUamiId | (create new) | ARM resource ID of existing UAMI |
| existingAgentAppInsightsId | (create new) | ARM resource ID of existing App Insights |
| modelProvider | Anthropic | AI model provider (Anthropic or Azure OpenAI) |

## What You Get

| Component | Details |
|-----------|---------|
| Connectors | AWS MCP (stdio, SigV4 via mcp-proxy-for-aws), AWS Knowledge MCP (remote, no auth) |
| Skills | `investigate-aws-app-errors` — CloudWatch + Lambda + DynamoDB diagnostics |
| Subagents | `aws-investigator` — autonomous investigation using AWS MCP tools |
| Hooks | `deny-aws-destructive` — blocks delete/terminate/remove without approval |
| Common Prompts | `safety-rules` — AWS-specific safety guardrails |
| Repos | GitHub repo connected for code context |

## How It Works

### AWS MCP Server (stdio connector)

The agent spawns `mcp-proxy-for-aws` as a child process inside its container. This proxy:
1. Receives tool calls from the agent
2. Signs them with SigV4 using the AWS credentials you provide
3. Forwards to `https://aws-mcp.<region>.api.aws/mcp`
4. Returns results (CloudWatch logs, Lambda config, DynamoDB state, etc.)

### AWS Knowledge MCP Server (remote connector)

Direct HTTPS connection to `https://knowledge-mcp.global.api.aws`. No auth required.
Provides AWS documentation, best practices, code samples, and regional availability info.

## After Deploy

1. Open [SRE Agent portal](https://sre.azure.com/) → verify agent shows "Running"
2. Go to **Connectors** → verify both `aws-mcp` and `aws-knowledge` show "Connected"
3. Go to **Repos** → verify GitHub repo is linked
4. Test with a prompt:
   > "Check CloudWatch for any Lambda errors in the todo-app-api function in the last 24 hours"

## Credential Rotation

STS credentials expire (default 12 hours). To rotate:

1. Generate new credentials: `aws sts get-session-token --duration-seconds 43200`
2. Update `connectors.secrets.env` with new values
3. Redeploy: `./bin/deploy.sh aws-agent/`

For production use, consider:
- AWS IAM Roles Anywhere (X.509 certificate-based, no manual rotation)
- A scheduled task that rotates credentials automatically

## Via Portal (no IaC)

If you prefer to configure via the SRE Agent portal instead of recipes:

1. **Create agent** at sre.azure.com → New Agent
2. **Add AWS MCP connector** → Builder → Connectors → Add → MCP Server → Process (stdio)
   - Command: `uvx`
   - Args: `mcp-proxy-for-aws@1.6.0 https://aws-mcp.us-east-1.api.aws/mcp --region us-east-1`
   - Env: `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`, `AWS_REGION`
3. **Add AWS Knowledge connector** → Add → MCP Server → Remote (URL)
   - URL: `https://knowledge-mcp.global.api.aws`
   - Auth: None
4. **Add GitHub repo** → Repos → Add → paste repo URL
5. **Create skill** → Skills → Add → paste YAML from `config/skills/`
6. **Create subagent** → Subagents → Add → paste YAML from `config/subagents/`
7. **Add hook** → Hooks → Add → paste YAML from `config/hooks/`
