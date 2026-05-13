#!/usr/bin/env python3
"""
sql_entra.py — Run T-SQL against Azure SQL using an Entra (AAD) access token.

Portable replacement for `sqlcmd -G --access-token …` on systems where the old
Microsoft sqlcmd (Windows 15.x) doesn't support --access-token.

Requires: pyodbc, azure-identity. If either is missing, prints install hints
and exits with code 2 (so the caller can treat it as a soft skip).
"""
from __future__ import annotations

import argparse
import re
import struct
import sys
from pathlib import Path


def _import_deps():
    try:
        import pyodbc  # type: ignore
        from azure.identity import DefaultAzureCredential  # type: ignore
        return pyodbc, DefaultAzureCredential
    except ImportError as e:
        sys.stderr.write(
            f"sql_entra.py: missing dependency ({e}). Install with:\n"
            f"  pip install pyodbc azure-identity\n"
        )
        sys.exit(2)


def _pick_driver(pyodbc) -> str:
    drivers = [d for d in pyodbc.drivers() if "ODBC Driver" in d and "SQL Server" in d]
    if not drivers:
        sys.stderr.write(
            "sql_entra.py: no 'ODBC Driver for SQL Server' found.\n"
            "  Windows: winget install Microsoft.MsOdbcSql\n"
            "  macOS:   brew install msodbcsql18\n"
            "  Linux:   https://learn.microsoft.com/sql/connect/odbc/linux-mac/\n"
        )
        sys.exit(2)
    drivers.sort(reverse=True)
    return drivers[0]


def _split_batches(sql: str) -> list[str]:
    """Split a T-SQL script on GO batch separators (case-insensitive, line-anchored)."""
    parts = re.split(r"(?im)^\s*GO\s*;?\s*$", sql)
    return [p.strip() for p in parts if p.strip()]


def main() -> int:
    p = argparse.ArgumentParser(description="Run T-SQL on Azure SQL via Entra access token.")
    p.add_argument("--server", required=True, help="SQL Server FQDN (e.g. sql-foo.database.windows.net)")
    p.add_argument("--database", required=True, help="Database name")
    src = p.add_mutually_exclusive_group(required=True)
    src.add_argument("--file", help="Path to .sql file to execute")
    src.add_argument("--query", help="Inline T-SQL to execute")
    p.add_argument("--timeout", type=int, default=60, help="Connection timeout (seconds)")
    args = p.parse_args()

    pyodbc, DefaultAzureCredential = _import_deps()
    driver = _pick_driver(pyodbc)

    if args.file:
        sql_text = Path(args.file).read_text(encoding="utf-8-sig")
    else:
        sql_text = args.query or ""

    cred = DefaultAzureCredential(exclude_interactive_browser_credential=False)
    token = cred.get_token("https://database.windows.net/.default").token.encode("utf-16-le")
    token_struct = struct.pack(f"=i{len(token)}s", len(token), token)
    SQL_COPT_SS_ACCESS_TOKEN = 1256

    conn_str = (
        f"Driver={{{driver}}};"
        f"Server=tcp:{args.server},1433;"
        f"Database={args.database};"
        f"Encrypt=yes;TrustServerCertificate=no;"
        f"Connection Timeout={args.timeout};"
    )

    try:
        with pyodbc.connect(conn_str, attrs_before={SQL_COPT_SS_ACCESS_TOKEN: token_struct}) as conn:
            conn.autocommit = True
            cur = conn.cursor()
            batches = _split_batches(sql_text)
            for i, batch in enumerate(batches, 1):
                try:
                    cur.execute(batch)
                    while cur.nextset():
                        pass
                except pyodbc.Error as e:
                    sys.stderr.write(f"sql_entra.py: batch {i} failed: {e}\n")
                    return 1
            print(f"sql_entra.py: executed {len(batches)} batch(es) on {args.server}/{args.database}")
            return 0
    except pyodbc.Error as e:
        sys.stderr.write(f"sql_entra.py: connection failed: {e}\n")
        return 1


if __name__ == "__main__":
    sys.exit(main())
