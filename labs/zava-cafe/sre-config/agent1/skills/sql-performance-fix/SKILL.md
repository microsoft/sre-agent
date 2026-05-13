---
metadata:
  api_version: azuresre.ai/v2
  kind: Skill
name: sql-performance-fix
description: Apply a fix for a diagnosed SQL performance issue. ALWAYS run AssessChangeRisk first and get user approval before making changes. Use AFTER sql-query-diagnosis has identified the root cause.
tools:
  - zava-mssql_mssql_execute_query
  - zava-mssql_mssql_run_sql_query
  - zava-mssql_mssql_connect_database
---

# SQL Performance Fix

## Overview
Apply fixes for SQL performance issues identified by sql-query-diagnosis. This skill handles risk assessment, human approval, and execution of the fix.

## When to Use
- AFTER sql-query-diagnosis has identified a missing index or stale statistics
- You know exactly what fix to apply

## Steps

1. **Assess the risk** — call `AssessChangeRisk` with:
   - operation: the SQL operation (e.g. "CREATE INDEX")
   - table_name: the target table
   - row_count: number of rows in the table
   - description: what this change does and why

2. **If the hook blocks** (risk is MEDIUM or HIGH): Use `AskUserQuestion` to present the risk assessment:
   - header: "Approval"
   - question: Full risk details — risk level, business hours status, table criticality, row count
   - options:
     - label: "Approve Now", description: "Proceed with the change. Risk factors have been reviewed."
     - label: "Schedule for 2 AM", description: "Defer to maintenance window (2-6 AM Pacific)."
     - label: "Cancel", description: "Do not proceed."

3. **If approved**: Execute the fix using `zava-mssql_mssql_execute_query`:
   - For indexes: `CREATE INDEX IX_{Table}_{Column} ON {Table}({Column})`
   - For statistics: `UPDATE STATISTICS {Table} WITH FULLSCAN`

4. **Verify** the fix worked — re-run the original slow query and compare duration.

5. **Visualize** the before/after using `PlotBarChart`.

## Example
- AssessChangeRisk("CREATE INDEX", "Products", 153600, "Add index on Category for slow queries")
- Hook blocks → AskUserQuestion → user approves
- Execute: CREATE INDEX IX_Products_Category ON Products(Category)
- Verify: 1,200ms → 60ms
