# Repo Routing — single source of truth

> **Audience.** Both the agent runtime (this file is loaded as a skill)
> AND humans setting up or modifying the lab. Same content; do not
> fork into a separate ARCHITECTURE doc.

## The three repos and what each is for

```
┌──────────────────────────────────────────┐  ┌──────────────────────────────────────────┐
│  TEMPLATE (public)                       │  │  PER-USER SRE CONFIG (GitHub)            │
│  {{GH_TEMPLATE_ORG}}/{{GH_TEMPLATE_REPO}}                   │  │  {{GH_USER}}/{{GH_REPO}}                 │
│                                          │  │                                          │
│  - simulator/  setup/  templates/        │  │  - skills/  tools/  agents/              │
│  - docs/  README.md                      │  │  - knowledge-base/                       │
│  - NO secrets, NO per-user values        │  │  - scheduled-tasks/  hooks/              │
│                                          │  │                                          │
│  AGENT WRITES: NEVER                     │  │  AGENT WRITES: KB updates, post-mortems  │
│  HUMAN: clone to bootstrap a new lab     │  │  HUMAN: source of truth for agent config │
└──────────────────────────────────────────┘  └──────────────────────────────────────────┘
                                              ┌──────────────────────────────────────────┐
                                              │  PER-USER APP SOURCE (Azure DevOps)      │
                                              │  {{ADO_ORG}}/{{ADO_PROJECT}}/_git/       │
                                              │  {{ADO_REPO}}                            │
                                              │                                          │
                                              │  - src/  infra/  pipelines/              │
                                              │  - bicep modules                         │
                                              │                                          │
                                              │  AGENT WRITES: fix PRs                   │
                                              │  HUMAN: PR review, prod code             │
                                              └──────────────────────────────────────────┘
```

## Allowed tools by operation (HARD CONTRACT)

| Operation | Target | Use this tool ONLY |
|---|---|---|
| Read GitHub file | `{{GH_USER}}/{{GH_REPO}}` | `get_file_contents` |
| Create GitHub branch | `{{GH_USER}}/{{GH_REPO}}` | `create_branch` |
| Commit single file to GitHub | `{{GH_USER}}/{{GH_REPO}}` | `create_or_update_file` |
| Commit multiple files to GitHub | `{{GH_USER}}/{{GH_REPO}}` | `push_files` |
| Open GitHub PR | `{{GH_USER}}/{{GH_REPO}}` | `create_pull_request` |
| Open GitHub issue | `{{GH_USER}}/{{GH_REPO}}` | `create_issue` |
| Update KB doc / runbook | `{{GH_USER}}/{{GH_REPO}}` `knowledge-base/` | branch + `create_or_update_file` + `create_pull_request` |
| Read ADO file | `{{ADO_ORG}}/{{ADO_PROJECT}}/{{ADO_REPO}}` | ADO MCP `get_file` |
| Open ADO PR (fix) | `{{ADO_ORG}}/{{ADO_PROJECT}}/{{ADO_REPO}}` | `CreateFixPullRequest` |
| Trigger ADO build | `{{ADO_ORG}}/{{ADO_PROJECT}}` | ADO MCP run-pipeline |

## Forbidden — DO NOT do any of these

- ❌ `git clone`, `git push`, `git commit` (no git binary in runtime)
- ❌ `gh pr create`, `gh issue create`, any `gh` invocation
- ❌ writing to `{{GH_TEMPLATE_ORG}}/{{GH_TEMPLATE_REPO}}` (template, read-only)
- ❌ writing app source code to `{{GH_USER}}/{{GH_REPO}}` (that's ADO's job)
- ❌ writing agent config to ADO (that's GitHub's job)

If the right tool is missing, **stop and report** — do NOT shell out to `git`/`gh`.

## How to file a fix PR (the common case)

You diagnosed a bug in `src/grid-status-api/server.js` and want to open a fix PR.

```
1. branch_name = "fix/grid-status-perf-INC0010069"
2. ADO MCP: GetFileContents owner={{ADO_ORG}} project={{ADO_PROJECT}}
            repo={{ADO_REPO}} path=src/grid-status-api/server.js
   → modify content in memory
3. CreateFixPullRequest with the modified content + branch_name + title
   "Fix grid-status-api perf regression (INC0010069)"
4. Post the PR URL back to ServiceNow via UpdateServiceNowWorkNotes.
```

## How to update a knowledge-base doc

You learned a new diagnostic pattern during incident response and want
to capture it in `knowledge-base/grid-status-tsg.md`.

```
1. branch_name = "kb/INC0010069-checksum-pattern"
2. get_file_contents owner={{GH_USER}} repo={{GH_REPO}}
                     path=knowledge-base/grid-status-tsg.md ref=main
3. Modify content in memory.
4. create_branch owner={{GH_USER}} repo={{GH_REPO}}
                 branch=<branch_name> from_branch=main
5. create_or_update_file owner={{GH_USER}} repo={{GH_REPO}}
                         branch=<branch_name>
                         path=knowledge-base/grid-status-tsg.md
                         content=<modified> message=<concise commit msg>
6. create_pull_request owner={{GH_USER}} repo={{GH_REPO}}
                       head=<branch_name> base=main
                       title="KB: <summary>" body="See INC<n>"
7. Post PR URL to SNOW work notes.
```

## Why this exists

Earlier the agent failed a doc update because the prior `create-pr-or-issue`
skill mandated `git push` — but the runtime has no git binary and no
PAT for it. This skill mandates **MCP tools only**, which work autonomously
without portal interaction once the GitHub MCP server is wired with a PAT
that has `Contents:write` + `Pull requests:write` + `Issues:write`.
