"""Bounded PostgreSQL index maintenance for the Zava performance demo."""

import socket
import ssl
from datetime import date, datetime, time
from decimal import Decimal

try:
    from azure.identity import ManagedIdentityCredential
except ImportError:
    ManagedIdentityCredential = None

try:
    import pg8000.dbapi as pg8000
except ImportError:
    pg8000 = None

STATEMENT_TIMEOUT_MS = 30000
LOCK_TIMEOUT_MS = 2000
PG_SCOPE = "https://ossrdbms-aad.database.windows.net/.default"
CONFIGURED_HOST = "@@DB_HOST@@"
CONFIGURED_DATABASE = "@@DB_NAME@@"
CONFIGURED_CLIENT_ID = "@@SRE_AGENT_CLIENT_ID@@"
CONFIGURED_PRINCIPAL_NAME = "@@SRE_AGENT_PRINCIPAL_NAME@@"

def _credential_token(credential, client_id):
    if credential is None:
        if ManagedIdentityCredential is None:
            raise RuntimeError("azure-identity is not installed")
        credential = ManagedIdentityCredential(client_id=client_id)
    return credential.get_token(PG_SCOPE).token

def _connection_kwargs(host, database, principal_name, token, ssl_context):
    return {"host": host, "port": 5432, "database": database, "user": principal_name, "password": token, "ssl_context": ssl_context, "timeout": 10}

def _error_category(exc):
    message = str(exc).lower()
    if isinstance(exc, socket.gaierror) or any(token in message for token in ("name or service not known", "nodename nor servname", "temporary failure in name resolution")):
        return "dns"
    if any(token in message for token in ("password authentication failed", "invalid password", "authentication")):
        return "authentication"
    if any(token in message for token in ("permission denied", "not authorized", "must be owner", "insufficient privilege", "forbidden")):
        return "authorization"
    if any(token in message for token in ("connection refused", "timed out", "network is unreachable")):
        return "connection"
    return "query"

OPERATIONS = (
    "restore_category_indexes",
    "analyze",
    "reindex_category_indexes",
)

_EXPECTED_INDEXES = {
    "idx_products_category": {
        "schema": "public",
        "table": "products",
        "method": "btree",
        "predicate": None,
        "columns": ("category",),
        "canonical_definition": (
            "CREATE INDEX idx_products_category ON public.products "
            "USING btree (category)"
        ),
    },
    "idx_products_category_name": {
        "schema": "public",
        "table": "products",
        "method": "btree",
        "predicate": None,
        "columns": ("category", "name"),
        "canonical_definition": (
            "CREATE INDEX idx_products_category_name ON public.products "
            "USING btree (category, name)"
        ),
    },
}

_CATEGORY_INDEX_VERIFICATION = """
SELECT
    index_namespace.nspname,
    table_class.relname,
    index_class.relname,
    index_metadata.indisvalid,
    index_metadata.indisready,
    access_method.amname,
    index_metadata.indpred,
    key_column.ordinality,
    CASE
        WHEN key_column.attnum = 0 THEN '<expression>'
        ELSE attribute.attname
    END AS key_name,
    pg_get_indexdef(index_metadata.indexrelid) AS canonical_definition,
    index_metadata.indexrelid AS index_oid
FROM pg_index AS index_metadata
JOIN pg_class AS table_class
    ON table_class.oid = index_metadata.indrelid
JOIN pg_namespace AS table_namespace
    ON table_namespace.oid = table_class.relnamespace
JOIN pg_class AS index_class
    ON index_class.oid = index_metadata.indexrelid
JOIN pg_am AS access_method
    ON access_method.oid = index_class.relam
JOIN pg_namespace AS index_namespace
    ON index_namespace.oid = index_class.relnamespace
JOIN LATERAL unnest(index_metadata.indkey) WITH ORDINALITY
    AS key_column(attnum, ordinality)
    ON key_column.ordinality <= index_metadata.indnkeyatts
LEFT JOIN pg_attribute AS attribute
    ON attribute.attrelid = table_class.oid
    AND attribute.attnum = key_column.attnum
WHERE index_class.relname = '{index_name}'
ORDER BY key_column.ordinality
"""

_CATEGORY_INDEX_FINAL_VERIFICATION = """
SELECT
    index_namespace.nspname,
    table_class.relname,
    index_class.relname,
    index_metadata.indisvalid,
    index_metadata.indisready,
    access_method.amname,
    index_metadata.indpred,
    key_column.ordinality,
    CASE
        WHEN key_column.attnum = 0 THEN '<expression>'
        ELSE attribute.attname
    END AS key_name,
    pg_get_indexdef(index_metadata.indexrelid) AS canonical_definition,
    index_metadata.indexrelid AS index_oid
FROM pg_index AS index_metadata
JOIN pg_class AS table_class
    ON table_class.oid = index_metadata.indrelid
JOIN pg_class AS index_class
    ON index_class.oid = index_metadata.indexrelid
JOIN pg_am AS access_method
    ON access_method.oid = index_class.relam
JOIN pg_namespace AS index_namespace
    ON index_namespace.oid = index_class.relnamespace
JOIN LATERAL unnest(index_metadata.indkey) WITH ORDINALITY
    AS key_column(attnum, ordinality)
    ON key_column.ordinality <= index_metadata.indnkeyatts
LEFT JOIN pg_attribute AS attribute
    ON attribute.attrelid = table_class.oid
    AND attribute.attnum = key_column.attnum
WHERE index_class.relname IN (
    'idx_products_category',
    'idx_products_category_name'
)
ORDER BY index_class.relname, key_column.ordinality
"""


class RepairStep:
    def __init__(self, sql, verification, expected_index=None):
        self.sql = sql
        self.verification = verification
        self.expected_index = expected_index


_STEPS = {
    "restore_category_indexes": (
        RepairStep(
            "CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_products_category ON public.products (category)",
            _CATEGORY_INDEX_VERIFICATION.format(index_name="idx_products_category"),
            "idx_products_category",
        ),
        RepairStep(
            "CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_products_category_name ON public.products (category, name)",
            _CATEGORY_INDEX_VERIFICATION.format(index_name="idx_products_category_name"),
            "idx_products_category_name",
        ),
    ),
    "analyze": (
        RepairStep(
            "ANALYZE public.products",
            "SELECT last_analyze FROM pg_stat_user_tables "
            "WHERE schemaname = 'public' AND relname = 'products'",
        ),
    ),
    "reindex_category_indexes": (
        RepairStep(
            "REINDEX INDEX CONCURRENTLY public.idx_products_category",
            _CATEGORY_INDEX_VERIFICATION.format(index_name="idx_products_category"),
            "idx_products_category",
        ),
        RepairStep(
            "REINDEX INDEX CONCURRENTLY public.idx_products_category_name",
            _CATEGORY_INDEX_VERIFICATION.format(index_name="idx_products_category_name"),
            "idx_products_category_name",
        ),
    ),
}


class ToolInputError(ValueError):
    pass


class IndexVerificationError(RuntimeError):
    def __init__(
        self,
        message,
        *,
        code,
        expected,
        actual,
        target_index,
        recovery_operation=None,
    ):
        super().__init__(message)
        self.code = code
        self.expected = expected
        self.actual = actual
        self.target_index = target_index
        self.recovery_operation = recovery_operation


def build_steps(operation):
    if operation not in OPERATIONS:
        raise ToolInputError("operation must be one of: " + ", ".join(OPERATIONS))
    return _STEPS[operation]


def _json_value(value):
    if isinstance(value, (datetime, date, time)):
        return value.isoformat()
    if isinstance(value, Decimal):
        return str(value)
    if isinstance(value, (list, tuple)):
        return [_json_value(item) for item in value]
    if isinstance(value, dict):
        return {str(key): _json_value(item) for key, item in value.items()}
    return value


def _expected_index_detail(index_name):
    expected = _EXPECTED_INDEXES[index_name]
    return {
        "schema": expected["schema"],
        "table": expected["table"],
        "name": index_name,
        "method": expected["method"],
        "predicate": expected["predicate"],
        "columns": list(expected["columns"]),
        "canonicalDefinition": expected["canonical_definition"],
        "valid": True,
        "ready": True,
    }


def _inspect_index(index_name, rows):
    expected = _expected_index_detail(index_name)
    normalized = [tuple(row) for row in rows]
    if not normalized:
        return expected, {"exists": False}, False, False

    first = normalized[0]
    actual = {
        "exists": True,
        "schema": first[0] if len(first) > 0 else None,
        "table": first[1] if len(first) > 1 else None,
        "name": first[2] if len(first) > 2 else None,
        "valid": first[3] if len(first) > 3 else None,
        "ready": first[4] if len(first) > 4 else None,
        "method": first[5] if len(first) > 5 else None,
        "predicate": first[6] if len(first) > 6 else None,
        "columns": [
            row[8]
            for row in normalized
            if len(row) > 8
        ],
        "canonicalDefinition": first[9] if len(first) > 9 else None,
        "indexOid": first[10] if len(first) > 10 else None,
        "rows": [_json_value(row) for row in normalized],
    }
    semantics_match = len(normalized) == len(expected["columns"])
    if semantics_match:
        for ordinal, (row, column) in enumerate(
            zip(normalized, expected["columns"]),
            start=1,
        ):
            semantics_match = (
                len(row) == 11
                and row[0] == expected["schema"]
                and row[1] == expected["table"]
                and row[2] == index_name
                and row[5] == expected["method"]
                and row[6] is expected["predicate"]
                and row[7] == ordinal
                and row[8] == column
                and row[9] == expected["canonicalDefinition"]
                and row[10] == actual["indexOid"]
            )
            if not semantics_match:
                break
    valid_ready = semantics_match and all(
        row[3] is True and row[4] is True
        for row in normalized
    )
    return expected, actual, semantics_match, valid_ready


def _verify_index(
    index_name,
    rows,
    *,
    allow_invalid=False,
    missing_code="index_verification_failed",
    recovery_operation=None,
):
    expected, actual, semantics_match, valid_ready = _inspect_index(
        index_name,
        rows,
    )
    if not rows:
        raise IndexVerificationError(
            f"verification failed for public.{index_name}: index was not found",
            code=missing_code,
            expected=expected,
            actual=actual,
            target_index=index_name,
        )
    if not semantics_match:
        raise IndexVerificationError(
            f"verification failed for public.{index_name}: "
            "unexpected index definition",
            code="unexpected_index_definition",
            expected=expected,
            actual=actual,
            target_index=index_name,
        )
    if not allow_invalid and not valid_ready:
        raise IndexVerificationError(
            f"verification failed for public.{index_name}: "
            "expected index definition exists but is invalid or not ready",
            code="invalid_expected_index",
            expected=expected,
            actual=actual,
            target_index=index_name,
            recovery_operation=recovery_operation,
        )


def _semantic_fingerprint(actual):
    return (
        actual.get("schema"),
        actual.get("table"),
        actual.get("name"),
        actual.get("method"),
        actual.get("predicate"),
        tuple(actual.get("columns", ())),
        actual.get("canonicalDefinition"),
    )


def _raise_concurrent_schema_change(index_name, expected, actual, reason):
    raise IndexVerificationError(
        f"concurrent schema change for public.{index_name}: {reason}",
        code="concurrent_schema_change",
        expected=expected,
        actual=actual,
        target_index=index_name,
    )


def _require_concurrent_exact(index_name, rows, *, require_valid_ready):
    expected, actual, semantics_match, valid_ready = _inspect_index(
        index_name,
        rows,
    )
    if not rows:
        _raise_concurrent_schema_change(
            index_name,
            expected,
            actual,
            "index was not found",
        )
    if not semantics_match:
        _raise_concurrent_schema_change(
            index_name,
            expected,
            actual,
            "index definition changed",
        )
    if require_valid_ready and not valid_ready:
        _raise_concurrent_schema_change(
            index_name,
            expected,
            actual,
            "index is invalid or not ready",
        )
    return expected, actual


def _final_index_rows(rows):
    grouped = {index_name: [] for index_name in _EXPECTED_INDEXES}
    for row in rows:
        normalized = tuple(row)
        if len(normalized) > 2 and normalized[2] in grouped:
            grouped[normalized[2]].append(normalized)
    return grouped


def _finalize_index_results(cursor, results, last_accepted_oid_by_index):
    cursor.execute(_CATEGORY_INDEX_FINAL_VERIFICATION)
    final_rows = _final_index_rows(cursor.fetchall())
    result_by_index = {item["index"]: item for item in results}
    for index_name in _EXPECTED_INDEXES:
        rows = final_rows[index_name]
        expected, actual = _require_concurrent_exact(
            index_name,
            rows,
            require_valid_ready=True,
        )
        expected_oid = last_accepted_oid_by_index[index_name]
        if actual["indexOid"] != expected_oid:
            expected = dict(expected)
            expected["indexOid"] = expected_oid
            _raise_concurrent_schema_change(
                index_name,
                expected,
                actual,
                "index identity changed after the last accepted verification",
            )
        result_by_index[index_name]["verification"] = (
            _CATEGORY_INDEX_FINAL_VERIFICATION
        )
        result_by_index[index_name]["rows"] = [
            _json_value(list(row))
            for row in rows[:10]
        ]


def run_operation(operation, *, host, database, client_id, principal_name="", credential=None, connector=None):
    if not host or not host.lower().endswith(".postgres.database.azure.com"):
        raise ToolInputError("host must be an Azure PostgreSQL FQDN")
    if not database or not client_id or not principal_name:
        raise ToolInputError("database, client_id, and principal_name are required")
    steps = build_steps(operation)
    connection = None
    try:
        token = _credential_token(credential, client_id)
        connect = connector or (pg8000.connect if pg8000 else None)
        if connect is None:
            raise RuntimeError("pg8000 is not installed")
        connection = connect(**_connection_kwargs(host, database, principal_name, token, ssl.create_default_context()))
        connection.autocommit = True
        cursor = connection.cursor()
        cursor.execute(f"SET statement_timeout = {STATEMENT_TIMEOUT_MS}")
        cursor.execute(f"SET lock_timeout = {LOCK_TIMEOUT_MS}")
        results = []
        preflight_rows_by_index = {}
        preflight_state_by_index = {}
        last_accepted_oid_by_index = {}
        if operation in (
            "restore_category_indexes",
            "reindex_category_indexes",
        ):
            for step in steps:
                cursor.execute(step.verification)
                preflight_rows = cursor.fetchall()
                preflight_rows_by_index[step.expected_index] = preflight_rows
                if operation == "restore_category_indexes":
                    if preflight_rows:
                        _verify_index(
                            step.expected_index,
                            preflight_rows,
                            recovery_operation="reindex_category_indexes",
                        )
                        _, actual, _, _ = _inspect_index(
                            step.expected_index,
                            preflight_rows,
                        )
                        last_accepted_oid_by_index[
                            step.expected_index
                        ] = actual["indexOid"]
                else:
                    _verify_index(
                        step.expected_index,
                        preflight_rows,
                        allow_invalid=True,
                        missing_code="unexpected_index_definition",
                    )
                    _, actual, _, _ = _inspect_index(
                        step.expected_index,
                        preflight_rows,
                    )
                    preflight_state_by_index[step.expected_index] = {
                        "actual": actual,
                        "index_oid": actual["indexOid"],
                        "fingerprint": _semantic_fingerprint(actual),
                    }
        if operation == "restore_category_indexes":
            for step in steps:
                preflight_rows = preflight_rows_by_index[step.expected_index]
                if preflight_rows:
                    results.append(
                        {
                            "index": step.expected_index,
                            "status": "already_valid",
                            "operation": None,
                            "verification": step.verification,
                            "rows": [
                                _json_value(list(row))
                                for row in preflight_rows[:10]
                            ],
                        }
                    )
                    continue
                cursor.execute(step.verification)
                immediate_rows = cursor.fetchall()
                if immediate_rows:
                    expected, actual, semantics_match, valid_ready = (
                        _inspect_index(step.expected_index, immediate_rows)
                    )
                    if semantics_match and valid_ready:
                        last_accepted_oid_by_index[
                            step.expected_index
                        ] = actual["indexOid"]
                        results.append(
                            {
                                "index": step.expected_index,
                                "status": "already_valid",
                                "operation": None,
                                "verification": step.verification,
                                "rows": [
                                    _json_value(list(row))
                                    for row in immediate_rows[:10]
                                ],
                            }
                        )
                        continue
                    _raise_concurrent_schema_change(
                        step.expected_index,
                        expected,
                        actual,
                        "index appeared before create with an unexpected state",
                    )
                cursor.execute(step.sql)
                cursor.execute(step.verification)
                rows = cursor.fetchall()
                _, actual = _require_concurrent_exact(
                    step.expected_index,
                    rows,
                    require_valid_ready=True,
                )
                last_accepted_oid_by_index[
                    step.expected_index
                ] = actual["indexOid"]
                results.append(
                    {
                        "index": step.expected_index,
                        "status": "created",
                        "operation": step.sql,
                        "verification": step.verification,
                        "rows": [
                            _json_value(list(row))
                            for row in rows[:10]
                        ],
                    }
                )
            _finalize_index_results(
                cursor,
                results,
                last_accepted_oid_by_index,
            )
            return {
                "ok": True,
                "operation": operation,
                "results": results,
            }
        if operation == "reindex_category_indexes":
            for step in steps:
                preflight_state = preflight_state_by_index[
                    step.expected_index
                ]
                cursor.execute(step.verification)
                immediate_rows = cursor.fetchall()
                _, immediate_actual, semantics_match, _ = _inspect_index(
                    step.expected_index,
                    immediate_rows,
                )
                if not immediate_rows:
                    _raise_concurrent_schema_change(
                        step.expected_index,
                        preflight_state["actual"],
                        immediate_actual,
                        "index was not found before reindex",
                    )
                if (
                    not semantics_match
                    or immediate_actual["indexOid"]
                    != preflight_state["index_oid"]
                    or _semantic_fingerprint(immediate_actual)
                    != preflight_state["fingerprint"]
                ):
                    _raise_concurrent_schema_change(
                        step.expected_index,
                        preflight_state["actual"],
                        immediate_actual,
                        "index identity or definition changed before reindex",
                    )
                cursor.execute(step.sql)
                cursor.execute(step.verification)
                rows = cursor.fetchall()
                _, actual = _require_concurrent_exact(
                    step.expected_index,
                    rows,
                    require_valid_ready=True,
                )
                last_accepted_oid_by_index[
                    step.expected_index
                ] = actual["indexOid"]
                results.append(
                    {
                        "index": step.expected_index,
                        "status": "reindexed",
                        "operation": step.sql,
                        "verification": step.verification,
                        "rows": [
                            _json_value(list(row))
                            for row in rows[:10]
                        ],
                    }
                )
            _finalize_index_results(
                cursor,
                results,
                last_accepted_oid_by_index,
            )
            return {
                "ok": True,
                "operation": operation,
                "results": results,
            }
        for step in steps:
            cursor.execute(step.sql)
            cursor.execute(step.verification)
            rows = cursor.fetchall()
            if step.expected_index:
                _verify_index(
                    step.expected_index,
                    rows,
                    recovery_operation=(
                        "reindex_category_indexes"
                        if operation == "restore_category_indexes"
                        else None
                    ),
                )
            elif not rows or all(row[0] is None for row in rows):
                raise RuntimeError(f"verification returned no evidence for {step.sql}")
            results.append(
                {
                    "operation": step.sql,
                    "verification": step.verification,
                    "rows": [_json_value(list(row)) for row in rows[:10]],
                }
            )
        return {"ok": True, "operation": operation, "results": results}
    except Exception as exc:
        if connection is not None:
            try:
                connection.rollback()
            except Exception:
                pass
        error = {
            "category": _error_category(exc),
            "message": str(exc)[:500],
        }
        if isinstance(exc, IndexVerificationError):
            error.update(
                {
                    "code": exc.code,
                    "expected": _json_value(exc.expected),
                    "actual": _json_value(exc.actual),
                    "targetIndex": exc.target_index,
                }
            )
            if exc.recovery_operation:
                error["recoveryOperation"] = exc.recovery_operation
        return {"ok": False, "operation": operation, "error": error}
    finally:
        if connection is not None:
            try:
                connection.close()
            except Exception:
                pass


def main(operation):
    return run_operation(
        operation,
        host=CONFIGURED_HOST,
        database=CONFIGURED_DATABASE,
        client_id=CONFIGURED_CLIENT_ID,
        principal_name=CONFIGURED_PRINCIPAL_NAME,
    )
