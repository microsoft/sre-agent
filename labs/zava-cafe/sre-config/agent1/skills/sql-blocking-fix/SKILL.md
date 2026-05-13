---
metadata:
  api_version: azuresre.ai/v2
  kind: Skill
name: sql-blocking-fix
description: Resolve SQL blocking by killing the head blocker session. ALWAYS run AssessChangeRisk first and get user approval before killing any session. Use AFTER sql-blocking-diagnosis has identified the blocker.
tools:
  - zava-mssql_mssql_execute_query
  - zava-mssql_mssql_run_sql_query
  - zava-mssql_mssql_connect_database
---

# SQL Blocking Fix

## Overview
Resolve SQL blocking chains by killing the head blocker session, after risk assessment and human approval.

## When to Use
- AFTER sql-blocking-diagnosis has identified the head blocker
- You know which session to kill and its impact

## Steps

1. **Assess the risk** — call `AssessChangeRisk` with:
   - operation: "KILL"
   - table_name: the table being blocked
   - row_count: number of blocked sessions
   - description: who the blocker is (program_name, login_name) and what it is doing

2. **If the hook blocks**: Use `AskUserQuestion`:
   - header: "Approval"
   - question: Blocker details — SPID, program name, what query it is running, how many sessions are blocked
   - options:
     - label: "Kill Session", description: "Terminate the blocking session. Blocked queries will resume."
     - label: "Wait 5 Minutes", description: "Give the blocker time to complete naturally."
     - label: "Cancel", description: "Do not kill. App will remain hung."

3. **If approved**: Execute `KILL {session_id}` using `zava-mssql_mssql_execute_query`.

4. **Verify** blocking is resolved:
   `SELECT COUNT(*) as still_blocked FROM sys.dm_exec_requests WHERE blocking_session_id > 0`

5. **Report**: blocker identity, how many unblocked, total wait time resolved.
