---
metadata:
  api_version: azuresre.ai/v2
  kind: Skill
name: repo-routing
description: |
  AUTHORITATIVE contract for which repository the agent reads from and
  writes to, and which tools are allowed for each operation. Replaces
  the legacy create-pr-or-issue skill (which incorrectly mandated the
  `gh` and `git` CLIs that are not available in the agent runtime).
---

# Repo Routing — single source of truth

> **Audience.** Both the agent runtime (this file is loaded as a skill)
> AND humans setting up or modifying the lab. Same content; do not
> fork into a separate ARCHITECTURE doc.

## The three repos and what each is for

```
┌──────────────────────────────────────────┐  ┌──────────────────────────────────────────┐
│  TEMPLATE (public)                       │  │  PER-USER SRE CONFIG (GitHub)            │
│  microsoft/placeholder-gh-template-repo                   │  │  demo-user/placeholder-gh-repo                 │
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
                                              │  placeholder-ado-org/placeholder-ado-project/_git/       │
                                              │  placeholder-ado-repo                            │
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
| Read GitHub file | `demo-user/placeholder-gh-repo` | `get_file_contents` |
| Create GitHub branch | `demo-user/placeholder-gh-repo` | `create_branch` |
| Commit single file to GitHub | `demo-user/placeholder-gh-repo` | `create_or_update_file` |
| Commit multiple files to GitHub | `demo-user/placeholder-gh-repo` | `push_files` |
| Open GitHub PR | `demo-user/placeholder-gh-repo` | `create_pull_request` |
| Open GitHub issue | `demo-user/placeholder-gh-repo` | `create_issue` |
| Update KB doc / runbook | `demo-user/placeholder-gh-repo` `knowledge-base/` | branch + `create_or_update_file` + `create_pull_request` |
| Read ADO file | `placeholder-ado-org/placeholder-ado-project/placeholder-ado-repo` | ADO MCP `get_file` |
| Open ADO PR (fix) | `placeholder-ado-org/placeholder-ado-project/placeholder-ado-repo` | `CreateFixPullRequest` |
| Trigger ADO build | `placeholder-ado-org/placeholder-ado-project` | ADO MCP run-pipeline |

## Forbidden — DO NOT do any of these

- ❌ `git clone`, `git push`, `git commit` (no git binary in runtime)
- ❌ `gh pr create`, `gh issue create`, any `gh` invocation
- ❌ writing to `microsoft/placeholder-gh-template-repo` (template, read-only)
- ❌ writing app source code to `demo-user/placeholder-gh-repo` (that's ADO's job)
- ❌ writing agent config to ADO (that's GitHub's job)

If the right tool is missing, **stop and report** — do NOT shell out to `git`/`gh`.

## How to file a fix PR (the common case)

You diagnosed a bug in `src/grid-status-api/server.js` and want to open a fix PR.

```
1. branch_name = "fix/grid-status-perf-INC0010069"
2. ADO MCP: GetFileContents owner=placeholder-ado-org project=placeholder-ado-project
            repo=placeholder-ado-repo path=src/grid-status-api/server.js
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
2. get_file_contents owner=demo-user repo=placeholder-gh-repo
                     path=knowledge-base/grid-status-tsg.md ref=main
3. Modify content in memory.
4. create_branch owner=demo-user repo=placeholder-gh-repo
                 branch=<branch_name> from_branch=main
5. create_or_update_file owner=demo-user repo=placeholder-gh-repo
                         branch=<branch_name>
                         path=knowledge-base/grid-status-tsg.md
                         content=<modified> message=<concise commit msg>
6. create_pull_request owner=demo-user repo=placeholder-gh-repo
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
