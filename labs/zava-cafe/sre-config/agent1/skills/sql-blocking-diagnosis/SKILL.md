---
metadata:
  api_version: azuresre.ai/v2
  kind: Skill
name: sql-blocking-diagnosis
description: Diagnose SQL blocking chains that cause application hangs. Identifies head blocker, blocked sessions, wait times. This skill ONLY investigates. Hand off to sql-blocking-fix to resolve.
tools:
  - zava-mssql_mssql_execute_query
  - zava-mssql_mssql_run_sql_query
  - zava-mssql_mssql_connect_database
---

# SQL Blocking Diagnosis

## Overview
Investigate SQL blocking chains on the Zava Azure SQL database. Identify the head blocker and impact but DO NOT kill any sessions.

## When to Use
- App is hanging or not responding
- API requests are timing out across the board
- Users report the app is frozen

## Steps

1. **Connect** using `zava-mssql_mssql_connect_database`.

2. **Check for active blocking**:
   `SELECT r.session_id AS blocked, r.blocking_session_id AS blocker, r.wait_type, r.wait_time/1000 AS wait_sec, t.text AS blocked_query FROM sys.dm_exec_requests r CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) t WHERE r.blocking_session_id > 0 ORDER BY r.wait_time DESC`

3. **Identify the head blocker** — the session blocking others but not blocked itself:
   `SELECT s.session_id, s.login_name, s.host_name, s.program_name, r.command, r.status, t.text AS current_query FROM sys.dm_exec_sessions s LEFT JOIN sys.dm_exec_requests r ON s.session_id = r.session_id OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) t WHERE s.session_id IN (SELECT DISTINCT blocking_session_id FROM sys.dm_exec_requests WHERE blocking_session_id > 0)`

4. **Assess impact**: How many sessions blocked? How long waiting? Is it a batch job or user query?

5. **Report findings**: head blocker SPID, program name, how many blocked, total wait time. Use `PlotBarChart` to show blocked session wait times.

6. **Hand off** to `sql-blocking-fix` to resolve.

## MCP Tools
- `zava-mssql_mssql_execute_query` — query DMVs
