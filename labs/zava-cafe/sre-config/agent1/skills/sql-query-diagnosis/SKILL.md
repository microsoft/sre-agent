---
metadata:
  api_version: azuresre.ai/v2
  kind: Skill
name: sql-query-diagnosis
description: Diagnose slow SQL queries by analyzing execution plans and identifying missing indexes. This skill ONLY investigates. Hand off to sql-performance-fix to apply the fix.
tools:
  - zava-mssql_mssql_execute_query
  - zava-mssql_mssql_run_sql_query
  - zava-mssql_mssql_get_schema
  - zava-mssql_mssql_connect_database
---

# SQL Query Diagnosis

## Overview
Investigate SQL query performance issues on the Zava Azure SQL database. Identify root cause but DO NOT make any changes.

## When to Use
- Users report slow page loads or API timeouts
- DTU alert fires
- App Insights shows high query duration

## Steps

1. **Connect** to the database using `zava-mssql_mssql_connect_database` if not already connected.

2. **Get table info** using `zava-mssql_mssql_get_schema` — check table sizes and existing indexes.

3. **Find slow queries** by checking query stats:
   `SELECT TOP 5 qs.total_elapsed_time/qs.execution_count as avg_ms, qs.execution_count, SUBSTRING(st.text, 1, 200) as query_text FROM sys.dm_exec_query_stats qs CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) st ORDER BY avg_ms DESC`

4. **Analyze the execution plan** — run the slow query with `SET SHOWPLAN_TEXT ON` to see if there are Table Scans indicating missing indexes.

5. **Check for missing index recommendations** from SQL Server:
   `SELECT d.statement as table_name, d.equality_columns, d.inequality_columns, s.avg_user_impact FROM sys.dm_db_missing_index_details d JOIN sys.dm_db_missing_index_groups g ON d.index_handle = g.index_handle JOIN sys.dm_db_missing_index_group_stats s ON g.index_group_handle = s.group_handle ORDER BY s.avg_user_impact DESC`

6. **Report findings**: table name, row count, missing index columns, estimated improvement. Use `PlotBarChart` to visualize query durations.

7. **Hand off** to `sql-performance-fix` skill to apply the fix.

## MCP Tools
- `zava-mssql_mssql_execute_query` — run diagnostic queries
- `zava-mssql_mssql_get_schema` — check table schema and indexes
