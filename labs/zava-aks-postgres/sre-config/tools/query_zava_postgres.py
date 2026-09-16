"""Bounded, read-only PostgreSQL diagnostics for the Zava SRE Agent."""

import socket
import ssl
from datetime import date, datetime, time
from decimal import Decimal
from ipaddress import IPv4Address, IPv6Address

try:
    from azure.identity import ManagedIdentityCredential
except ImportError:  # pragma: no cover - sandbox supplies the package
    ManagedIdentityCredential = None

try:
    import pg8000.dbapi as pg8000
except ImportError:  # pragma: no cover - sandbox supplies the package
    pg8000 = None

OPERATIONS = (
    "connection_check",
    "active_sessions",
    "slow_queries",
    "table_statistics",
    "index_statistics",
    "category_query_plan",
)
RESULT_LIMIT = 50
STATEMENT_TIMEOUT_MS = 5000
LOCK_TIMEOUT_MS = 2000
PG_SCOPE = "https://ossrdbms-aad.database.windows.net/.default"
CONFIGURED_HOST = "@@DB_HOST@@"
CONFIGURED_DATABASE = "@@DB_NAME@@"
CONFIGURED_CLIENT_ID = "@@SRE_AGENT_CLIENT_ID@@"
CONFIGURED_PRINCIPAL_NAME = "@@SRE_AGENT_PRINCIPAL_NAME@@"

_QUERY_BY_OPERATION = {
    "connection_check": "SELECT current_database(), current_user, inet_server_addr(), inet_server_port()",
    "active_sessions": (
        "SELECT pid, usename, state, wait_event_type, wait_event, query_start, "
        "left(query, 200) AS query FROM pg_stat_activity "
        "WHERE pid <> pg_backend_pid() ORDER BY query_start DESC"
    ),
    "slow_queries": (
        "SELECT query, calls, total_exec_time, mean_exec_time, rows "
        "FROM pg_stat_statements ORDER BY mean_exec_time DESC"
    ),
    "table_statistics": (
        "SELECT schemaname, relname, n_live_tup, n_dead_tup, last_analyze, last_autoanalyze "
        "FROM pg_stat_user_tables ORDER BY n_dead_tup DESC"
    ),
    "index_statistics": (
        "SELECT schemaname, relname, indexrelname, idx_scan, idx_tup_read, idx_tup_fetch "
        "FROM pg_stat_user_indexes ORDER BY idx_scan ASC"
    ),
    "category_query_plan": (
        "EXPLAIN (FORMAT JSON) "
        "SELECT id, sku, name, price, category, stock_quantity "
        "FROM products WHERE category = 'Accessories' "
        "ORDER BY name LIMIT 100 OFFSET 7000"
    ),
}


class ToolInputError(ValueError):
    pass


def build_query(operation):
    if operation not in OPERATIONS:
        raise ToolInputError("operation must be one of: " + ", ".join(OPERATIONS))
    return _QUERY_BY_OPERATION[operation]


def add_result_limit(sql):
    if sql.lstrip().upper().startswith("SELECT") and "LIMIT " not in sql.upper():
        return sql.rstrip().rstrip(";") + f" LIMIT {RESULT_LIMIT}"
    return sql


def _error_category(exc):
    message = str(exc)
    lower = message.lower()
    if isinstance(exc, socket.gaierror) or any(
        token in lower for token in ("name or service not known", "nodename nor servname", "temporary failure in name resolution")
    ):
        return "dns"
    if any(token in lower for token in ("statement timeout", "lock timeout")):
        return "query"
    if isinstance(exc, TimeoutError) or any(token in lower for token in ("connection refused", "timed out", "timeout", "network is unreachable")):
        return "connection"
    if isinstance(exc, PermissionError) or any(token in lower for token in ("password authentication failed", "authentication", "invalid password")):
        return "authentication"
    if any(token in lower for token in ("permission denied", "not authorized", "must be owner", "insufficient privilege", "forbidden")):
        return "authorization"
    if isinstance(exc, ConnectionError) or any(token in lower for token in ("connection reset", "connection aborted")):
        return "connection"
    return "query"


def _credential_token(credential, client_id):
    if credential is None:
        if ManagedIdentityCredential is None:
            raise RuntimeError("azure-identity is not installed")
        credential = ManagedIdentityCredential(client_id=client_id)
    return credential.get_token(PG_SCOPE).token


def _json_value(value):
    if isinstance(value, (datetime, date, time)):
        return value.isoformat()
    if isinstance(value, Decimal):
        return str(value)
    if isinstance(value, (IPv4Address, IPv6Address)):
        return str(value)
    if isinstance(value, (list, tuple)):
        return [_json_value(item) for item in value]
    if isinstance(value, dict):
        return {str(key): _json_value(item) for key, item in value.items()}
    return value


def _column_name(description_item):
    name = getattr(description_item, "name", None)
    if name is not None:
        return str(name)
    if isinstance(description_item, (list, tuple)) and description_item:
        return str(description_item[0])
    return str(description_item)


def _connection_kwargs(host, database, principal_name, token, ssl_context):
    return {
        "host": host,
        "port": 5432,
        "database": database,
        "user": principal_name,
        "password": token,
        "ssl_context": ssl_context,
        "timeout": 10,
    }


def run_operation(operation, *, host, database, client_id, principal_name="", credential=None, connector=None):
    if not host or not host.lower().endswith(".postgres.database.azure.com"):
        raise ToolInputError("host must be an Azure PostgreSQL FQDN")
    if not database or not client_id or not principal_name:
        raise ToolInputError("database, client_id, and principal_name are required")
    sql = add_result_limit(build_query(operation))

    connection = None
    result = None
    operation_error = None
    cleanup_error = None
    try:
        token = _credential_token(credential, client_id)
        context = ssl.create_default_context()
        connect = connector or (pg8000.connect if pg8000 else None)
        if connect is None:
            raise RuntimeError("pg8000 is not installed")
        connection = connect(**_connection_kwargs(host, database, principal_name, token, context))
        connection.autocommit = True
        cursor = connection.cursor()
        cursor.execute("BEGIN READ ONLY")
        cursor.execute(f"SET LOCAL statement_timeout = {STATEMENT_TIMEOUT_MS}")
        cursor.execute(f"SET LOCAL lock_timeout = {LOCK_TIMEOUT_MS}")
        cursor.execute(sql)
        columns = [
            _column_name(item)
            for item in getattr(cursor, "description", [])
        ]
        rows = cursor.fetchall()
        result = {"ok": True, "operation": operation, "columns": columns, "rows": [_json_value(list(row)) for row in rows[:RESULT_LIMIT]], "rowCount": min(len(rows), RESULT_LIMIT)}
    except Exception as exc:
        operation_error = exc
    finally:
        if connection is not None:
            try:
                connection.rollback()
            except Exception as exc:
                cleanup_error = exc
            try:
                connection.close()
            except Exception as exc:
                if cleanup_error is None:
                    cleanup_error = exc

    error = operation_error or cleanup_error
    if error is not None:
        return {"ok": False, "operation": operation, "error": {"category": _error_category(error), "message": str(error)[:500]}}
    return result


def main(operation):
    return run_operation(
        operation,
        host=CONFIGURED_HOST,
        database=CONFIGURED_DATABASE,
        client_id=CONFIGURED_CLIENT_ID,
        principal_name=CONFIGURED_PRINCIPAL_NAME,
    )
