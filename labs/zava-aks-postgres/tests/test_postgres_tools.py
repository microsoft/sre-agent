import importlib.util
import inspect
import json
import re
import socket
import unittest
from datetime import date, datetime, time, timezone
from decimal import Decimal
from ipaddress import ip_address
from pathlib import Path
from unittest.mock import Mock


LAB = Path(__file__).resolve().parents[1]


def load_module(name, relative_path):
    path = LAB / relative_path
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    import sys
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


QUERY = load_module("query_zava_postgres", "sre-config/tools/query_zava_postgres.py")
REPAIR = load_module("repair_zava_postgres_indexes", "sre-config/tools/repair_zava_postgres_indexes.py")


class QueryToolTests(unittest.TestCase):
    def test_platform_entrypoint_accepts_the_declared_operation_parameter(self):
        self.assertEqual(list(inspect.signature(QUERY.main).parameters), ["operation"])

    def test_only_named_diagnostic_operations_are_allowed(self):
        self.assertEqual(set(QUERY.OPERATIONS), {
            "connection_check", "active_sessions", "slow_queries",
            "table_statistics", "index_statistics", "category_query_plan",
        })
        with self.assertRaises(QUERY.ToolInputError):
            QUERY.build_query("select * from pg_catalog.pg_user")

    def test_queries_are_fixed_and_rows_are_capped(self):
        sql = QUERY.build_query("active_sessions")
        self.assertIn("pg_stat_activity", sql)
        self.assertNotIn("{", sql)
        self.assertEqual(QUERY.RESULT_LIMIT, 50)
        self.assertIn("LIMIT", QUERY.add_result_limit(sql))

    def test_category_query_plan_is_fixed_machine_readable_and_does_not_execute_workload(self):
        sql = QUERY.build_query("category_query_plan")
        normalized = " ".join(sql.split())
        routes = (LAB / "src" / "api" / "routes" / "products.js").read_text(
            encoding="utf-8"
        )
        application_query = re.search(
            r"pool\.query\('([^']+FROM products WHERE category = \$1[^']+)'",
            routes,
        ).group(1)
        fixed_application_query = (
            application_query.replace("$1", "'Accessories'")
            .replace("$2", "100")
            .replace("$3", "7000")
        )
        self.assertTrue(normalized.startswith("EXPLAIN (FORMAT JSON"))
        self.assertNotIn("ANALYZE", normalized.upper())
        self.assertIn(fixed_application_query, normalized)
        self.assertNotIn("$1", sql)
        self.assertNotIn("{", sql)

    def test_real_azure_fqdn_is_accepted_and_connection_uses_tls_and_bounded_timeouts(self):
        calls = {}

        class Connection:
            def __init__(self):
                self._autocommit = False

            @property
            def autocommit(self):
                return self._autocommit

            @autocommit.setter
            def autocommit(self, value):
                calls.setdefault("events", []).append(("autocommit", value))
                self._autocommit = value

            def cursor(self):
                return self

            def execute(self, sql):
                calls.setdefault("sql", []).append(sql)
                calls.setdefault("events", []).append(("execute", sql))

            def fetchall(self):
                return [(1,)]

            def close(self):
                pass

            def rollback(self):
                pass

            def commit(self):
                pass

        def connect(**kwargs):
            calls["kwargs"] = kwargs
            return Connection()

        result = QUERY.run_operation(
            "connection_check",
            host="zava-pg-abc.postgres.database.azure.com",
            database="zava_store",
            principal_name="sre-agent",
            client_id="client-id",
            credential=Mock(get_token=Mock(return_value=Mock(token="token"))),
            connector=connect,
        )
        self.assertEqual(result["ok"], True)
        self.assertEqual(calls["kwargs"]["ssl_context"].check_hostname, True)
        self.assertEqual(calls["kwargs"]["port"], 5432)
        self.assertEqual(
            calls["events"][:2],
            [("autocommit", True), ("execute", "BEGIN READ ONLY")],
        )
        self.assertEqual(calls["sql"][0], "BEGIN READ ONLY")
        self.assertEqual(
            calls["sql"][1:3],
            [
                f"SET LOCAL statement_timeout = {QUERY.STATEMENT_TIMEOUT_MS}",
                f"SET LOCAL lock_timeout = {QUERY.LOCK_TIMEOUT_MS}",
            ],
        )

    def test_invalid_operation_is_rejected_before_credentials_or_connection(self):
        credential = Mock()
        connector = Mock()

        with self.assertRaises(QUERY.ToolInputError):
            QUERY.run_operation(
                "select_anything",
                host="zava-pg-abc.postgres.database.azure.com",
                database="zava_store",
                principal_name="sre-agent",
                client_id="client-id",
                credential=credential,
                connector=connector,
            )

        credential.get_token.assert_not_called()
        connector.assert_not_called()

    def test_errors_are_structured_and_classified(self):
        class DnsError(OSError):
            pass

        result = QUERY.run_operation(
            "connection_check",
            host="missing.private.postgres.database.azure.com",
            database="zava_store",
            principal_name="sre-agent",
            client_id="client-id",
            credential=Mock(get_token=Mock(side_effect=DnsError("Name or service not known"))),
            connector=Mock(),
        )
        self.assertEqual(result["ok"], False)
        self.assertEqual(result["error"]["category"], "dns")
        self.assertIn("message", result["error"])

    def test_postgres_statement_and_lock_timeouts_are_query_errors(self):
        for message in (
            "canceling statement due to statement timeout",
            "canceling statement due to lock timeout",
        ):
            with self.subTest(message=message):
                self.assertEqual(
                    QUERY._error_category(RuntimeError(message)),
                    "query",
                )

    def test_read_only_transaction_and_json_serializable_results(self):
        calls = []

        class Cursor:
            description = [
                ("QUERY PLAN", 114, None, None, None, None, None),
            ]
            def execute(self, sql):
                calls.append(sql)
            def fetchall(self):
                return [([{"Plan": {"Node Type": "Index Scan"}, "Server": ip_address("10.20.16.4")}],)]
        class Connection:
            def cursor(self):
                return Cursor()
            def close(self):
                calls.append("CLOSE")
            def rollback(self):
                calls.append("ROLLBACK")
            def commit(self):
                raise AssertionError("read-only operation must not commit")
        result = QUERY.run_operation(
            "category_query_plan",
            host="zava-pg-abc.postgres.database.azure.com",
            database="zava_store",
            principal_name="sre-agent",
            client_id="client-id",
            credential=Mock(get_token=Mock(return_value=Mock(token="token"))),
            connector=Mock(return_value=Connection()),
        )
        json.dumps(result)
        self.assertEqual(result["ok"], True)
        self.assertEqual(result["columns"], ["QUERY PLAN"])
        self.assertEqual(
            result["rows"],
            [[[{"Plan": {"Node Type": "Index Scan"}, "Server": "10.20.16.4"}]]],
        )
        self.assertEqual(calls[0], "BEGIN READ ONLY")
        self.assertEqual(
            calls[1:3],
            [
                f"SET LOCAL statement_timeout = {QUERY.STATEMENT_TIMEOUT_MS}",
                f"SET LOCAL lock_timeout = {QUERY.LOCK_TIMEOUT_MS}",
            ],
        )
        self.assertTrue(calls[3].startswith("EXPLAIN (FORMAT JSON"))
        self.assertEqual(calls[-2:], ["ROLLBACK", "CLOSE"])

    def test_pg8000_description_sequence_uses_column_name(self):
        class Cursor:
            description = [
                ("current_database", 25, None, None, None, None, None),
            ]

            def execute(self, sql):
                pass

            def fetchall(self):
                return [("zava_store",)]

        class Connection:
            def cursor(self):
                return Cursor()

            def rollback(self):
                pass

            def close(self):
                pass

        result = QUERY.run_operation(
            "connection_check",
            host="zava-pg-abc.postgres.database.azure.com",
            database="zava_store",
            principal_name="sre-agent",
            client_id="client-id",
            credential=Mock(get_token=Mock(return_value=Mock(token="token"))),
            connector=Mock(return_value=Connection()),
        )

        self.assertEqual(result["ok"], True)
        self.assertEqual(result["columns"], ["current_database"])

    def test_opened_connection_closes_when_rollback_fails_after_query_error(self):
        calls = []

        class Cursor:
            description = []

            def execute(self, sql):
                calls.append(sql)
                if sql.startswith("SELECT"):
                    raise RuntimeError("query failed")

        class Connection:
            def cursor(self):
                return Cursor()

            def rollback(self):
                calls.append("ROLLBACK")
                raise RuntimeError("rollback failed")

            def close(self):
                calls.append("CLOSE")

        result = QUERY.run_operation(
            "connection_check",
            host="zava-pg-abc.postgres.database.azure.com",
            database="zava_store",
            principal_name="sre-agent",
            client_id="client-id",
            credential=Mock(get_token=Mock(return_value=Mock(token="token"))),
            connector=Mock(return_value=Connection()),
        )

        self.assertEqual(result["ok"], False)
        self.assertEqual(result["error"]["category"], "query")
        self.assertEqual(calls[-2:], ["ROLLBACK", "CLOSE"])


class RepairToolTests(unittest.TestCase):
    INDEX_OIDS = {
        "idx_products_category": 41001,
        "idx_products_category_name": 41002,
    }
    CANONICAL_INDEX_DEFINITIONS = {
        "idx_products_category": (
            "CREATE INDEX idx_products_category ON public.products "
            "USING btree (category)"
        ),
        "idx_products_category_name": (
            "CREATE INDEX idx_products_category_name ON public.products "
            "USING btree (category, name)"
        ),
    }
    INDEX_ROWS = {
        "idx_products_category": [
            (
                "public", "products", "idx_products_category", True, True,
                "btree", None, 1, "category",
            ),
        ],
        "idx_products_category_name": [
            (
                "public", "products", "idx_products_category_name", True, True,
                "btree", None, 1, "category",
            ),
            (
                "public", "products", "idx_products_category_name", True, True,
                "btree", None, 2, "name",
            ),
        ],
    }

    def run_index_operation(self, operation, verification_results=None):
        calls = []
        result_queues = {
            index_name: list(result_sets)
            for index_name, result_sets in (verification_results or {}).items()
        }

        def normalize_rows(index_name, rows):
            normalized = []
            for row in rows:
                values = tuple(row)
                if len(values) == 9:
                    values += (
                        RepairToolTests.CANONICAL_INDEX_DEFINITIONS[index_name],
                    )
                if len(values) == 10:
                    values += (RepairToolTests.INDEX_OIDS[index_name],)
                normalized.append(values)
            return normalized

        def next_rows(index_name):
            queue = result_queues.get(index_name)
            rows = (
                queue.pop(0)
                if queue
                else RepairToolTests.INDEX_ROWS[index_name]
            )
            return normalize_rows(index_name, rows)

        class Cursor:
            current_sql = None

            def execute(self, sql):
                self.current_sql = sql
                calls.append(sql)

            def fetchall(self):
                if (
                    "index_class.relname IN" in self.current_sql
                    and "__final__" in result_queues
                ):
                    queue = result_queues["__final__"]
                    rows = queue.pop(0) if queue else []
                    return [
                        tuple(row)
                        for row in rows
                    ]
                if "index_class.relname IN" in self.current_sql:
                    return [
                        row
                        for index_name in RepairToolTests.INDEX_ROWS
                        for row in next_rows(index_name)
                    ]
                index_name = (
                    "idx_products_category_name"
                    if "idx_products_category_name" in self.current_sql
                    else "idx_products_category"
                )
                return next_rows(index_name)

        class Connection:
            def __init__(self):
                self._autocommit = False

            @property
            def autocommit(self):
                return self._autocommit

            @autocommit.setter
            def autocommit(self, value):
                self._autocommit = value
                calls.append(f"AUTOCOMMIT {value}")

            def cursor(self):
                return Cursor()

            def rollback(self):
                calls.append("ROLLBACK")

            def close(self):
                calls.append("CLOSE")

        result = REPAIR.run_operation(
            operation,
            host="zava-pg-abc.postgres.database.azure.com",
            database="zava_store",
            principal_name="sre-agent",
            client_id="client-id",
            credential=Mock(get_token=Mock(return_value=Mock(token="token"))),
            connector=Mock(return_value=Connection()),
        )
        return result, calls

    def run_analyze(self, row):
        calls = []

        class Cursor:
            def execute(self, sql):
                calls.append(sql)

            def fetchall(self):
                return [row]

        class Connection:
            def cursor(self):
                return Cursor()

            def rollback(self):
                calls.append("ROLLBACK")

            def close(self):
                calls.append("CLOSE")

        result = REPAIR.run_operation(
            "analyze",
            host="zava-pg-abc.postgres.database.azure.com",
            database="zava_store",
            principal_name="sre-agent",
            client_id="client-id",
            credential=Mock(get_token=Mock(return_value=Mock(token="token"))),
            connector=Mock(return_value=Connection()),
        )
        return result, calls

    def test_platform_entrypoint_accepts_the_declared_operation_parameter(self):
        self.assertEqual(list(inspect.signature(REPAIR.main).parameters), ["operation"])

    def test_only_fixed_repairs_are_allowed(self):
        self.assertEqual(set(REPAIR.OPERATIONS), {
            "restore_category_indexes", "analyze", "reindex_category_indexes",
        })
        with self.assertRaises(REPAIR.ToolInputError):
            REPAIR.build_steps("DROP TABLE users")

        credential = Mock(
            get_token=Mock(side_effect=AssertionError("credential requested"))
        )
        connector = Mock(side_effect=AssertionError("connection opened"))

        with self.assertRaises(REPAIR.ToolInputError):
            REPAIR.run_operation(
                "DROP TABLE users",
                host="zava-pg-abc.postgres.database.azure.com",
                database="zava_store",
                principal_name="sre-agent",
                client_id="client-id",
                credential=credential,
                connector=connector,
            )

        credential.get_token.assert_not_called()
        connector.assert_not_called()

    def test_maintenance_timeout_allows_bounded_index_work(self):
        self.assertEqual(REPAIR.STATEMENT_TIMEOUT_MS, 30_000)
        self.assertEqual(REPAIR.LOCK_TIMEOUT_MS, 2_000)

    def test_each_repair_has_fixed_verification(self):
        for operation in REPAIR.OPERATIONS:
            steps = REPAIR.build_steps(operation)
            self.assertGreaterEqual(len(steps), 1)
            self.assertTrue(steps[-1].verification)
            self.assertNotIn("{", " ".join(step.sql for step in steps))

    def test_repairs_return_structured_failure_without_arbitrary_sql(self):
        result = REPAIR.run_operation(
            "restore_category_indexes",
            host="db.private.postgres.database.azure.com",
            database="zava_store",
            principal_name="sre-agent",
            client_id="client-id",
            credential=Mock(get_token=Mock(side_effect=Exception("permission denied"))),
            connector=Mock(),
        )
        self.assertEqual(result["ok"], False)
        self.assertEqual(result["error"]["category"], "authorization")
        self.assertEqual(
            REPAIR._error_category(
                socket.gaierror(11001, "resolver returned no address")
            ),
            "dns",
        )

    def test_repairs_use_the_application_index_and_concurrent_steps_are_transaction_free(self):
        for operation in ("restore_category_indexes", "reindex_category_indexes"):
            steps = REPAIR.build_steps(operation)
            sql = " ".join(step.sql for step in steps)
            self.assertIn("idx_products_category_name", sql)
            self.assertNotIn("idx_products_category_price", sql)
            self.assertTrue(all("CONCURRENTLY" in step.sql.upper() for step in steps))
            self.assertTrue(all("pg_index" in step.verification for step in steps))
            self.assertTrue(all("pg_class" in step.verification for step in steps))
            self.assertTrue(all("pg_namespace" in step.verification for step in steps))
            self.assertTrue(all("pg_attribute" in step.verification for step in steps))
            self.assertTrue(all("WITH ORDINALITY" in step.verification for step in steps))
            self.assertTrue(all("{" not in step.verification for step in steps))

        restore_sql = " ".join(
            step.sql for step in REPAIR.build_steps("restore_category_indexes")
        )
        self.assertIn("ON public.products", restore_sql)
        reindex_sql = " ".join(
            step.sql for step in REPAIR.build_steps("reindex_category_indexes")
        )
        self.assertIn("public.idx_products_category", reindex_sql)
        self.assertIn("public.idx_products_category_name", reindex_sql)

    def test_analyze_is_schema_qualified_and_verification_is_unambiguous(self):
        step = REPAIR.build_steps("analyze")[0]

        self.assertEqual(step.sql, "ANALYZE public.products")
        self.assertIn("schemaname = 'public'", step.verification)
        self.assertIn("relname = 'products'", step.verification)

    def test_analyze_timestamp_is_json_serializable_iso_text(self):
        analyzed_at = datetime(2026, 9, 16, 5, 30, tzinfo=timezone.utc)
        analyzed_date = date(2026, 9, 16)
        analyzed_time = time(5, 30, 15, tzinfo=timezone.utc)
        row = (
            analyzed_at,
            analyzed_date,
            analyzed_time,
            Decimal("123.4500"),
            [date(2026, 9, 17), Decimal("2.50")],
            (time(6, 45), Decimal("3.75")),
            {
                "observedAt": analyzed_at,
                "ratio": Decimal("0.875"),
            },
        )

        result, calls = self.run_analyze(row)

        self.assertEqual(result["ok"], True)
        self.assertEqual(
            result["results"][0]["rows"],
            [[
                "2026-09-16T05:30:00+00:00",
                "2026-09-16",
                "05:30:15+00:00",
                "123.4500",
                ["2026-09-17", "2.50"],
                ["06:45:00", "3.75"],
                {
                    "observedAt": "2026-09-16T05:30:00+00:00",
                    "ratio": "0.875",
                },
            ]],
        )
        json.dumps(result)
        self.assertIn("ANALYZE public.products", calls)

    def test_index_verification_query_requires_btree_and_no_partial_predicate(self):
        for operation in ("restore_category_indexes", "reindex_category_indexes"):
            for step in REPAIR.build_steps(operation):
                normalized = " ".join(step.verification.split())
                self.assertIn("pg_am", step.verification)
                self.assertIn("amname", step.verification)
                self.assertIn("indpred", step.verification)
                self.assertIn("pg_get_indexdef(index_metadata.indexrelid)", normalized)
                self.assertIn(
                    "index_metadata.indexrelid AS index_oid",
                    normalized,
                )
                self.assertIn(
                    "LEFT JOIN pg_attribute AS attribute",
                    normalized,
                )
                self.assertIn(
                    "WHEN key_column.attnum = 0 THEN '<expression>'",
                    normalized,
                )
                self.assertIn(
                    "ORDER BY key_column.ordinality",
                    normalized,
                )
                self.assertNotIn(
                    "table_namespace.nspname = 'public'",
                    step.verification,
                )
                self.assertNotIn(
                    "index_namespace.nspname = 'public'",
                    step.verification,
                )

    def test_restore_and_reindex_accept_exact_valid_ready_index_metadata(self):
        for operation in ("restore_category_indexes", "reindex_category_indexes"):
            with self.subTest(operation=operation):
                result, calls = self.run_index_operation(operation)

                self.assertEqual(result["ok"], True)
                json.dumps(result)
                self.assertEqual(len(result["results"]), 2)
                self.assertEqual(calls[0], "AUTOCOMMIT True")
                self.assertNotIn("ROLLBACK", calls)
                self.assertEqual(calls[-1], "CLOSE")

    def test_restore_preflights_every_target_before_any_write(self):
        unexpected_second = [(
            "public", "products", "idx_products_category_name", True, True,
            "btree", None, 1, "category",
            "CREATE UNIQUE INDEX idx_products_category_name "
            "ON public.products USING btree (category, name)",
        )]
        invalid_second = [
            (
                "public", "products", "idx_products_category_name",
                False, True, "btree", None, 1, "category",
            ),
            (
                "public", "products", "idx_products_category_name",
                False, True, "btree", None, 2, "name",
            ),
        ]
        for case, second_rows, expected_code, recovery in (
            (
                "unexpected",
                unexpected_second,
                "unexpected_index_definition",
                None,
            ),
            (
                "invalid",
                invalid_second,
                "invalid_expected_index",
                "reindex_category_indexes",
            ),
        ):
            with self.subTest(case=case):
                result, calls = self.run_index_operation(
                    "restore_category_indexes",
                    {
                        "idx_products_category": [[]],
                        "idx_products_category_name": [second_rows],
                    },
                )

                self.assertEqual(result["ok"], False)
                self.assertEqual(result["error"]["code"], expected_code)
                self.assertEqual(
                    result["error"].get("recoveryOperation"),
                    recovery,
                )
                self.assertFalse(
                    any(
                        sql.startswith(("CREATE INDEX", "REINDEX", "DROP"))
                        for sql in calls
                    )
                )

    def test_restore_creates_only_targets_missing_after_full_preflight(self):
        cases = (
            (
                "first_valid_second_absent",
                {
                    "idx_products_category": [
                        self.INDEX_ROWS["idx_products_category"],
                    ],
                    "idx_products_category_name": [
                        [],
                        [],
                        self.INDEX_ROWS["idx_products_category_name"],
                    ],
                },
                "idx_products_category_name",
            ),
            (
                "first_absent_second_valid",
                {
                    "idx_products_category": [
                        [],
                        [],
                        self.INDEX_ROWS["idx_products_category"],
                    ],
                    "idx_products_category_name": [
                        self.INDEX_ROWS["idx_products_category_name"],
                    ],
                },
                "idx_products_category",
            ),
        )
        for case, verification_results, created_name in cases:
            with self.subTest(case=case):
                result, calls = self.run_index_operation(
                    "restore_category_indexes",
                    verification_results,
                )

                self.assertEqual(result["ok"], True)
                creates = [
                    sql for sql in calls if sql.startswith("CREATE INDEX")
                ]
                self.assertEqual(len(creates), 1)
                self.assertIn(created_name, creates[0])
                self.assertEqual(
                    [item["status"] for item in result["results"]],
                    [
                        "already_valid"
                        if name != created_name else "created"
                        for name in self.CANONICAL_INDEX_DEFINITIONS
                    ],
                )

    def test_restore_both_absent_reads_both_before_first_create(self):
        result, calls = self.run_index_operation(
            "restore_category_indexes",
            {
                "idx_products_category": [
                    [],
                    [],
                    self.INDEX_ROWS["idx_products_category"],
                ],
                "idx_products_category_name": [
                    [],
                    [],
                    self.INDEX_ROWS["idx_products_category_name"],
                ],
            },
        )

        self.assertEqual(result["ok"], True)
        verification_positions = [
            index for index, sql in enumerate(calls)
            if "FROM pg_index AS index_metadata" in sql
        ]
        create_positions = [
            index for index, sql in enumerate(calls)
            if sql.startswith("CREATE INDEX")
        ]
        self.assertEqual(len(verification_positions), 7)
        self.assertEqual(len(create_positions), 2)
        self.assertLess(verification_positions[1], create_positions[0])
        self.assertEqual(
            [item["status"] for item in result["results"]],
            ["created", "created"],
        )

    def test_index_operations_use_the_expected_catalog_and_write_order(self):
        def operation_order(calls):
            order = []
            for sql in calls:
                if "index_class.relname IN" in sql:
                    order.append("verify:final")
                elif "FROM pg_index AS index_metadata" in sql:
                    index_name = (
                        "idx_products_category_name"
                        if "idx_products_category_name" in sql
                        else "idx_products_category"
                    )
                    order.append(f"verify:{index_name}")
                elif sql.startswith("CREATE INDEX"):
                    index_name = (
                        "idx_products_category_name"
                        if "idx_products_category_name" in sql
                        else "idx_products_category"
                    )
                    order.append(f"create:{index_name}")
                elif sql.startswith("REINDEX INDEX"):
                    index_name = (
                        "idx_products_category_name"
                        if "idx_products_category_name" in sql
                        else "idx_products_category"
                    )
                    order.append(f"reindex:{index_name}")
            return order

        restore_result, restore_calls = self.run_index_operation(
            "restore_category_indexes",
            {
                "idx_products_category": [
                    [],
                    [],
                    self.INDEX_ROWS["idx_products_category"],
                ],
                "idx_products_category_name": [
                    [],
                    [],
                    self.INDEX_ROWS["idx_products_category_name"],
                ],
            },
        )
        reindex_result, reindex_calls = self.run_index_operation(
            "reindex_category_indexes",
        )

        self.assertEqual(restore_result["ok"], True)
        self.assertEqual(
            operation_order(restore_calls),
            [
                "verify:idx_products_category",
                "verify:idx_products_category_name",
                "verify:idx_products_category",
                "create:idx_products_category",
                "verify:idx_products_category",
                "verify:idx_products_category_name",
                "create:idx_products_category_name",
                "verify:idx_products_category_name",
                "verify:final",
            ],
        )
        self.assertEqual(reindex_result["ok"], True)
        self.assertEqual(
            operation_order(reindex_calls),
            [
                "verify:idx_products_category",
                "verify:idx_products_category_name",
                "verify:idx_products_category",
                "reindex:idx_products_category",
                "verify:idx_products_category",
                "verify:idx_products_category_name",
                "reindex:idx_products_category_name",
                "verify:idx_products_category_name",
                "verify:final",
            ],
        )

    def test_restore_both_valid_performs_no_create(self):
        result, calls = self.run_index_operation("restore_category_indexes")

        self.assertEqual(result["ok"], True)
        self.assertFalse(any(sql.startswith("CREATE INDEX") for sql in calls))
        self.assertEqual(
            [item["status"] for item in result["results"]],
            ["already_valid", "already_valid"],
        )

    def test_restore_absent_target_that_appears_exact_valid_before_create_is_skipped(self):
        result, calls = self.run_index_operation(
            "restore_category_indexes",
            {
                "idx_products_category": [
                    [],
                    self.INDEX_ROWS["idx_products_category"],
                ],
            },
        )

        self.assertEqual(result["ok"], True)
        self.assertFalse(
            any(
                sql.startswith("CREATE INDEX")
                and "idx_products_category " in sql
                for sql in calls
            )
        )
        self.assertEqual(result["results"][0]["status"], "already_valid")
        self.assertEqual(
            len([
                sql for sql in calls
                if "FROM pg_index AS index_metadata" in sql
            ]),
            4,
        )

    def test_restore_absent_target_that_appears_changed_fails_before_create(self):
        cases = (
            (
                "wrong_definition",
                [(
                    "public", "products", "idx_products_category", True, True,
                    "hash", None, 1, "category",
                )],
            ),
            (
                "invalid",
                [(
                    "public", "products", "idx_products_category", False, True,
                    "btree", None, 1, "category",
                )],
            ),
        )
        for case, appeared_rows in cases:
            with self.subTest(case=case):
                result, calls = self.run_index_operation(
                    "restore_category_indexes",
                    {
                        "idx_products_category": [[], appeared_rows],
                    },
                )

                self.assertEqual(result["ok"], False)
                self.assertEqual(
                    result["error"]["code"],
                    "concurrent_schema_change",
                )
                self.assertEqual(
                    result["error"]["targetIndex"],
                    "idx_products_category",
                )
                self.assertNotIn("recoveryOperation", result["error"])
                self.assertFalse(
                    any(sql.startswith("CREATE INDEX") for sql in calls)
                )

    def test_restore_post_create_discrepancy_is_concurrent_schema_change(self):
        conflicting_rows = [(
            "public", "products", "idx_products_category", False, True,
            "btree", None, 1, "category",
        )]
        result, calls = self.run_index_operation(
            "restore_category_indexes",
            {
                "idx_products_category": [
                    [],
                    [],
                    conflicting_rows,
                ],
            },
        )

        self.assertEqual(result["ok"], False)
        self.assertEqual(
            result["error"]["code"],
            "concurrent_schema_change",
        )
        self.assertEqual(
            result["error"]["targetIndex"],
            "idx_products_category",
        )
        self.assertNotIn("recoveryOperation", result["error"])
        self.assertEqual(
            len([sql for sql in calls if sql.startswith("CREATE INDEX")]),
            1,
        )

    def test_restore_initially_valid_target_changed_before_final_pass_fails(self):
        wrong_final = [(
            "public", "products", "idx_products_category", True, True,
            "hash", None, 1, "category",
            "CREATE INDEX idx_products_category ON public.products "
            "USING hash (category)",
            self.INDEX_OIDS["idx_products_category"],
        )]
        final_rows = (
            wrong_final
            + [
                tuple(row)
                + (
                    self.CANONICAL_INDEX_DEFINITIONS[
                        "idx_products_category_name"
                    ],
                    self.INDEX_OIDS["idx_products_category_name"],
                )
                for row in self.INDEX_ROWS["idx_products_category_name"]
            ]
        )
        result, calls = self.run_index_operation(
            "restore_category_indexes",
            {"__final__": [final_rows]},
        )

        self.assertEqual(result["ok"], False)
        self.assertEqual(
            result["error"]["code"],
            "concurrent_schema_change",
        )
        self.assertFalse(any(sql.startswith("CREATE INDEX") for sql in calls))

    def test_reindex_changed_oid_before_write_fails_closed(self):
        changed_oid_rows = [(
            "public", "products", "idx_products_category", True, True,
            "btree", None, 1, "category",
            self.CANONICAL_INDEX_DEFINITIONS["idx_products_category"],
            99901,
        )]
        result, calls = self.run_index_operation(
            "reindex_category_indexes",
            {
                "idx_products_category": [
                    self.INDEX_ROWS["idx_products_category"],
                    changed_oid_rows,
                ],
            },
        )

        self.assertEqual(result["ok"], False)
        self.assertEqual(
            result["error"]["code"],
            "concurrent_schema_change",
        )
        self.assertEqual(
            result["error"]["expected"]["indexOid"],
            self.INDEX_OIDS["idx_products_category"],
        )
        self.assertEqual(result["error"]["actual"]["indexOid"], 99901)
        self.assertFalse(any(sql.startswith("REINDEX INDEX") for sql in calls))

    def test_reindex_changed_definition_before_write_fails_closed(self):
        changed_definition_rows = [(
            "public", "products", "idx_products_category", True, True,
            "hash", None, 1, "category",
            "CREATE INDEX idx_products_category ON public.products "
            "USING hash (category)",
            self.INDEX_OIDS["idx_products_category"],
        )]
        result, calls = self.run_index_operation(
            "reindex_category_indexes",
            {
                "idx_products_category": [
                    self.INDEX_ROWS["idx_products_category"],
                    changed_definition_rows,
                ],
            },
        )

        self.assertEqual(result["ok"], False)
        self.assertEqual(
            result["error"]["code"],
            "concurrent_schema_change",
        )
        self.assertFalse(any(sql.startswith("REINDEX INDEX") for sql in calls))

    def test_reindex_missing_before_write_fails_closed(self):
        result, calls = self.run_index_operation(
            "reindex_category_indexes",
            {
                "idx_products_category": [
                    self.INDEX_ROWS["idx_products_category"],
                    [],
                ],
            },
        )

        self.assertEqual(result["ok"], False)
        self.assertEqual(
            result["error"]["code"],
            "concurrent_schema_change",
        )
        self.assertFalse(any(sql.startswith("REINDEX INDEX") for sql in calls))

    def test_reindex_postwrite_changed_oid_with_exact_semantics_is_allowed(self):
        postwrite_rows = [(
            "public", "products", "idx_products_category", True, True,
            "btree", None, 1, "category",
            self.CANONICAL_INDEX_DEFINITIONS["idx_products_category"],
            99902,
        )]
        result, calls = self.run_index_operation(
            "reindex_category_indexes",
            {
                "idx_products_category": [
                    self.INDEX_ROWS["idx_products_category"],
                    self.INDEX_ROWS["idx_products_category"],
                    postwrite_rows,
                    postwrite_rows,
                ],
            },
        )

        self.assertEqual(result["ok"], True)
        self.assertEqual(
            [sql for sql in calls if sql.startswith("REINDEX INDEX")],
            [
                "REINDEX INDEX CONCURRENTLY public.idx_products_category",
                "REINDEX INDEX CONCURRENTLY "
                "public.idx_products_category_name",
            ],
        )
        self.assertEqual(result["results"][0]["rows"][0][10], 99902)

    def test_final_pass_catches_first_target_change_while_second_is_processed(self):
        wrong_final = [(
            "public", "products", "idx_products_category", True, False,
            "btree", None, 1, "category",
            self.CANONICAL_INDEX_DEFINITIONS["idx_products_category"],
            99903,
        )]
        final_rows = (
            wrong_final
            + [
                tuple(row)
                + (
                    self.CANONICAL_INDEX_DEFINITIONS[
                        "idx_products_category_name"
                    ],
                    self.INDEX_OIDS["idx_products_category_name"],
                )
                for row in self.INDEX_ROWS["idx_products_category_name"]
            ]
        )
        result, calls = self.run_index_operation(
            "reindex_category_indexes",
            {"__final__": [final_rows]},
        )

        self.assertEqual(result["ok"], False)
        self.assertEqual(
            result["error"]["code"],
            "concurrent_schema_change",
        )
        self.assertEqual(
            len([
                sql for sql in calls
                if "index_class.relname IN" in sql
            ]),
            1,
        )

    def test_final_pass_discrepancies_fail_closed(self):
        exact_first = [
            tuple(row)
            + (
                self.CANONICAL_INDEX_DEFINITIONS[
                    "idx_products_category"
                ],
                self.INDEX_OIDS["idx_products_category"],
            )
            for row in self.INDEX_ROWS["idx_products_category"]
        ]
        exact_second = [
            tuple(row)
            + (
                self.CANONICAL_INDEX_DEFINITIONS[
                    "idx_products_category_name"
                ],
                self.INDEX_OIDS["idx_products_category_name"],
            )
            for row in self.INDEX_ROWS["idx_products_category_name"]
        ]
        cases = (
            ("missing", exact_second),
            (
                "invalid",
                [
                    tuple(exact_first[0][:3])
                    + (False,)
                    + tuple(exact_first[0][4:])
                ] + exact_second,
            ),
            (
                "not_ready",
                [
                    tuple(exact_first[0][:4])
                    + (False,)
                    + tuple(exact_first[0][5:])
                ] + exact_second,
            ),
            (
                "semantic_change",
                [
                    tuple(exact_first[0][:5])
                    + ("hash",)
                    + tuple(exact_first[0][6:9])
                    + (
                        "CREATE INDEX idx_products_category "
                        "ON public.products USING hash (category)",
                        exact_first[0][10],
                    )
                ] + exact_second,
            ),
            (
                "oid_change",
                [
                    tuple(exact_first[0][:10])
                    + (99904,)
                ] + exact_second,
            ),
        )
        for case, final_rows in cases:
            with self.subTest(case=case):
                result, calls = self.run_index_operation(
                    "restore_category_indexes",
                    {"__final__": [final_rows]},
                )

                self.assertEqual(result["ok"], False)
                self.assertEqual(
                    result["error"]["code"],
                    "concurrent_schema_change",
                )
                if case == "oid_change":
                    self.assertNotEqual(result.get("ok"), True)
                    self.assertEqual(
                        result["error"]["targetIndex"],
                        "idx_products_category",
                    )
                    self.assertEqual(
                        result["error"]["expected"]["indexOid"],
                        self.INDEX_OIDS["idx_products_category"],
                    )
                    self.assertEqual(
                        result["error"]["actual"]["indexOid"],
                        99904,
                    )
                self.assertEqual(
                    len([
                        sql for sql in calls
                        if "index_class.relname IN" in sql
                    ]),
                    1,
                )

    def test_restore_final_oid_check_uses_last_accepted_snapshot(self):
        exact_second = [
            tuple(row)
            + (
                self.CANONICAL_INDEX_DEFINITIONS[
                    "idx_products_category_name"
                ],
                self.INDEX_OIDS["idx_products_category_name"],
            )
            for row in self.INDEX_ROWS["idx_products_category_name"]
        ]
        cases = (
            ("appeared_before_create", [[], [(
                "public", "products", "idx_products_category", True, True,
                "btree", None, 1, "category",
                self.CANONICAL_INDEX_DEFINITIONS["idx_products_category"],
                99907,
            )]], 99907, 99908, 0),
            ("created", [[], [], [(
                "public", "products", "idx_products_category", True, True,
                "btree", None, 1, "category",
                self.CANONICAL_INDEX_DEFINITIONS["idx_products_category"],
                99909,
            )]], 99909, 99910, 1),
        )
        for case, snapshots, accepted_oid, final_oid, create_count in cases:
            with self.subTest(case=case):
                final_first = [(
                    "public", "products", "idx_products_category", True, True,
                    "btree", None, 1, "category",
                    self.CANONICAL_INDEX_DEFINITIONS[
                        "idx_products_category"
                    ],
                    final_oid,
                )]
                result, calls = self.run_index_operation(
                    "restore_category_indexes",
                    {
                        "idx_products_category": snapshots,
                        "__final__": [final_first + exact_second],
                    },
                )

                self.assertEqual(result["ok"], False)
                self.assertNotEqual(result.get("ok"), True)
                self.assertEqual(
                    result["error"]["code"],
                    "concurrent_schema_change",
                )
                self.assertEqual(
                    result["error"]["targetIndex"],
                    "idx_products_category",
                )
                self.assertEqual(
                    result["error"]["expected"]["indexOid"],
                    accepted_oid,
                )
                self.assertEqual(
                    result["error"]["actual"]["indexOid"],
                    final_oid,
                )
                self.assertEqual(
                    len([
                        sql for sql in calls if sql.startswith("CREATE INDEX")
                    ]),
                    create_count,
                )

    def test_reindex_final_oid_only_replacement_fails_closed(self):
        postwrite_rows = [(
            "public", "products", "idx_products_category", True, True,
            "btree", None, 1, "category",
            self.CANONICAL_INDEX_DEFINITIONS["idx_products_category"],
            99905,
        )]
        replaced_final_rows = [
            tuple(postwrite_rows[0][:10])
            + (99906,)
        ] + [
            tuple(row)
            + (
                self.CANONICAL_INDEX_DEFINITIONS[
                    "idx_products_category_name"
                ],
                self.INDEX_OIDS["idx_products_category_name"],
            )
            for row in self.INDEX_ROWS["idx_products_category_name"]
        ]
        result, calls = self.run_index_operation(
            "reindex_category_indexes",
            {
                "idx_products_category": [
                    self.INDEX_ROWS["idx_products_category"],
                    self.INDEX_ROWS["idx_products_category"],
                    postwrite_rows,
                ],
                "__final__": [replaced_final_rows],
            },
        )

        self.assertEqual(result["ok"], False)
        self.assertNotEqual(result.get("ok"), True)
        self.assertEqual(
            result["error"]["code"],
            "concurrent_schema_change",
        )
        self.assertEqual(
            result["error"]["targetIndex"],
            "idx_products_category",
        )
        self.assertEqual(result["error"]["expected"]["indexOid"], 99905)
        self.assertEqual(result["error"]["actual"]["indexOid"], 99906)
        self.assertEqual(
            len([sql for sql in calls if sql.startswith("REINDEX INDEX")]),
            2,
        )

    def test_restore_post_create_failures_are_structured(self):
        invalid_rows = [(
            "public", "products", "idx_products_category", False, True,
            "btree", None, 1, "category",
        )]
        unexpected_rows = [(
            "public", "products", "idx_products_category", True, True,
            "btree", None, 1, "category",
            "CREATE UNIQUE INDEX idx_products_category "
            "ON public.products USING btree (category)",
        )]
        for case, post_rows, code, recovery in (
            ("missing", [], "concurrent_schema_change", None),
            (
                "invalid",
                invalid_rows,
                "concurrent_schema_change",
                None,
            ),
            (
                "unexpected",
                unexpected_rows,
                "concurrent_schema_change",
                None,
            ),
        ):
            with self.subTest(case=case):
                result, calls = self.run_index_operation(
                    "restore_category_indexes",
                    {
                        "idx_products_category": [[], [], post_rows],
                        "idx_products_category_name": [
                            self.INDEX_ROWS["idx_products_category_name"],
                        ],
                    },
                )

                self.assertEqual(result["ok"], False)
                self.assertEqual(result["error"]["code"], code)
                self.assertEqual(
                    result["error"].get("recoveryOperation"),
                    recovery,
                )
                self.assertEqual(
                    len([
                        sql for sql in calls if sql.startswith("CREATE INDEX")
                    ]),
                    1,
                )

    def test_restore_rejects_noncanonical_index_variants_before_writes(self):
        expected = self.CANONICAL_INDEX_DEFINITIONS["idx_products_category"]
        variants = {
            "unique": (
                expected.replace("CREATE INDEX", "CREATE UNIQUE INDEX"),
                "btree", None, "category",
            ),
            "include": (
                expected + " INCLUDE (name)", "btree", None, "category",
            ),
            "sort_nulls": (
                expected.replace(
                    "(category)", "(category DESC NULLS FIRST)"
                ),
                "btree", None, "category",
            ),
            "collation": (
                expected.replace("(category)", '(category COLLATE "C")'),
                "btree", None, "category",
            ),
            "operator_class": (
                expected.replace(
                    "(category)", "(category text_pattern_ops)"
                ),
                "btree", None, "category",
            ),
            "partial": (
                expected + " WHERE (category IS NOT NULL)",
                "btree", "{VAR :varno 1}", "category",
            ),
            "hash": (
                expected.replace("USING btree", "USING hash"),
                "hash", None, "category",
            ),
            "expression": (
                expected.replace("(category)", "(lower(category))"),
                "btree", None, "<expression>",
            ),
        }
        for case, (definition, method, predicate, column) in variants.items():
            with self.subTest(case=case):
                rows = [(
                    "public", "products", "idx_products_category", True, True,
                    method, predicate, 1, column, definition,
                )]
                result, calls = self.run_index_operation(
                    "restore_category_indexes",
                    {"idx_products_category": [rows]},
                )

                self.assertEqual(result["ok"], False)
                self.assertEqual(
                    result["error"]["code"],
                    "unexpected_index_definition",
                )
                self.assertNotIn("recoveryOperation", result["error"])
                self.assertFalse(
                    any(
                        sql.startswith(("CREATE INDEX", "REINDEX", "DROP"))
                        for sql in calls
                    )
                )

    def test_hash_index_is_rejected_as_unexpected_definition(self):
        hash_rows = [
            (
                "public", "products", "idx_products_category", True, True,
                "hash", None, 1, "category",
            ),
        ]

        result, _ = self.run_index_operation(
            "restore_category_indexes",
            {"idx_products_category": [hash_rows]},
        )

        self.assertEqual(result["ok"], False)
        self.assertEqual(result["error"]["code"], "unexpected_index_definition")
        self.assertNotIn("recoveryOperation", result["error"])

    def test_partial_index_is_rejected_as_unexpected_definition(self):
        partial_rows = [
            (
                "public", "products", "idx_products_category", True, True,
                "btree", "{VAR :varno 1}", 1, "category",
            ),
        ]

        result, _ = self.run_index_operation(
            "restore_category_indexes",
            {"idx_products_category": [partial_rows]},
        )

        self.assertEqual(result["ok"], False)
        self.assertEqual(result["error"]["code"], "unexpected_index_definition")
        self.assertNotIn("recoveryOperation", result["error"])

    def test_restore_invalid_expected_index_returns_reindex_recovery_guidance(self):
        for case, valid, ready in (
            ("invalid", False, True),
            ("not_ready", True, False),
        ):
            with self.subTest(case=case):
                invalid_rows = [
                    (
                        "public", "products", "idx_products_category",
                        valid, ready, "btree", None, 1, "category",
                    ),
                ]

                result, calls = self.run_index_operation(
                    "restore_category_indexes",
                    {"idx_products_category": [invalid_rows]},
                )

                self.assertEqual(result["ok"], False)
                self.assertEqual(
                    result["error"]["code"],
                    "invalid_expected_index",
                )
                self.assertEqual(
                    result["error"]["recoveryOperation"],
                    "reindex_category_indexes",
                )
                self.assertIn("expected", result["error"])
                self.assertIn("actual", result["error"])
                self.assertFalse(any(sql.startswith("REINDEX") for sql in calls))
                json.dumps(result)

    def test_restore_wrong_definition_has_no_recovery_operation(self):
        for case, wrong_rows in (
            (
                "wrong_schema",
                [(
                    "private", "products", "idx_products_category", True, True,
                    "btree", None, 1, "category",
                )],
            ),
            (
                "wrong_table",
                [(
                    "public", "archived_products", "idx_products_category",
                    True, True, "btree", None, 1, "category",
                )],
            ),
            (
                "wrong_index_name",
                [(
                    "public", "products", "idx_products_category_old",
                    True, True, "btree", None, 1, "category",
                )],
            ),
            (
                "wrong_column",
                [(
                    "public", "products", "idx_products_category", True, True,
                    "btree", None, 1, "name",
                )],
            ),
        ):
            with self.subTest(case=case):
                result, calls = self.run_index_operation(
                    "restore_category_indexes",
                    {"idx_products_category": [wrong_rows]},
                )

                self.assertEqual(result["ok"], False)
                self.assertEqual(
                    result["error"]["code"],
                    "unexpected_index_definition",
                )
                self.assertIn("expected", result["error"])
                self.assertIn("actual", result["error"])
                self.assertNotIn("recoveryOperation", result["error"])
                self.assertFalse(
                    any(sql.startswith(("REINDEX", "DROP")) for sql in calls)
                )

    def test_restore_missing_index_after_create_has_no_reindex_guidance(self):
        result, calls = self.run_index_operation(
            "restore_category_indexes",
            {"idx_products_category": [[], [], []]},
        )

        self.assertEqual(result["ok"], False)
        self.assertNotIn("recoveryOperation", result["error"])
        self.assertFalse(
            any(sql.startswith(("REINDEX", "DROP")) for sql in calls)
        )

    def test_restore_and_reindex_fail_closed_for_wrong_composite_key_columns(self):
        for case, wrong_rows in (
            (
                "reversed",
                [
                    (
                        "public", "products", "idx_products_category_name",
                        True, True, "btree", None, 1, "name",
                    ),
                    (
                        "public", "products", "idx_products_category_name",
                        True, True, "btree", None, 2, "category",
                    ),
                ],
            ),
            (
                "expression_key",
                [
                    (
                        "public", "products", "idx_products_category_name",
                        True, True, "btree", None, 1, "category",
                    ),
                    (
                        "public", "products", "idx_products_category_name",
                        True, True, "btree", None, 2, "<expression>",
                    ),
                ],
            ),
        ):
            for operation in (
                "restore_category_indexes",
                "reindex_category_indexes",
            ):
                with self.subTest(case=case, operation=operation):
                    result, calls = self.run_index_operation(
                        operation,
                        {"idx_products_category_name": [wrong_rows]},
                    )

                    self.assertEqual(result["ok"], False)
                    self.assertEqual(result["error"]["category"], "query")
                    self.assertIn(
                        "idx_products_category_name",
                        result["error"]["message"],
                    )
                    self.assertEqual(
                        result["error"]["code"],
                        "unexpected_index_definition",
                    )
                    json.dumps(result)
                    maintenance_calls = [
                        sql for sql in calls
                        if sql.startswith(("CREATE INDEX", "REINDEX INDEX"))
                    ]
                    self.assertEqual(len(maintenance_calls), 0)
                    self.assertEqual(calls[-2:], ["ROLLBACK", "CLOSE"])

    def test_reindex_preflight_allows_exact_invalid_index_then_requires_ready_post_state(self):
        for case, valid, ready in (
            ("invalid", False, True),
            ("not_ready", True, False),
        ):
            with self.subTest(case=case):
                invalid_rows = [
                    (
                        "public", "products", "idx_products_category",
                        valid, ready, "btree", None, 1, "category",
                    ),
                ]
                result, calls = self.run_index_operation(
                    "reindex_category_indexes",
                    {
                        "idx_products_category": [
                            invalid_rows,
                            self.INDEX_ROWS["idx_products_category"],
                        ],
                    },
                )

                self.assertEqual(result["ok"], True)
                reindex_calls = [
                    sql for sql in calls
                    if sql.startswith("REINDEX INDEX")
                ]
                self.assertEqual(
                    reindex_calls,
                    [
                        "REINDEX INDEX CONCURRENTLY "
                        "public.idx_products_category",
                        "REINDEX INDEX CONCURRENTLY "
                        "public.idx_products_category_name",
                    ],
                )
                preflight_positions = [
                    index for index, sql in enumerate(calls)
                    if "FROM pg_index AS index_metadata" in sql
                ][:2]
                first_reindex = next(
                    index for index, sql in enumerate(calls)
                    if sql.startswith("REINDEX INDEX")
                )
                self.assertEqual(len(preflight_positions), 2)
                self.assertLess(preflight_positions[-1], first_reindex)

    def test_reindex_preflight_wrong_definition_executes_no_reindex_or_drop(self):
        first_index_not_ready = [(
            "public", "products", "idx_products_category", True, False,
            "btree", None, 1, "category",
        )]
        second_index_wrong_definition = [(
            "public", "products", "idx_products_category_name", False, False,
            "hash", None, 1, "category",
        )]
        second_index_expression_key = [
            (
                "public", "products", "idx_products_category_name", True, True,
                "btree", None, 1, "category",
            ),
            (
                "public", "products", "idx_products_category_name", True, True,
                "btree", None, 2, "<expression>",
            ),
        ]
        for case, verification_results in (
            (
                "first_index_wrong_definition",
                {"idx_products_category": [[(
                    "public", "products", "idx_products_category", False, False,
                    "hash", None, 1, "category",
                )]]},
            ),
            ("first_index_missing", {"idx_products_category": [[]]}),
            (
                "second_index_wrong_definition",
                {
                    "idx_products_category": [
                        first_index_not_ready,
                        self.INDEX_ROWS["idx_products_category"],
                    ],
                    "idx_products_category_name": [
                        second_index_wrong_definition,
                    ],
                },
            ),
            (
                "second_index_missing",
                {
                    "idx_products_category": [
                        first_index_not_ready,
                        self.INDEX_ROWS["idx_products_category"],
                    ],
                    "idx_products_category_name": [[]],
                },
            ),
            (
                "second_index_expression_key",
                {
                    "idx_products_category": [
                        first_index_not_ready,
                        self.INDEX_ROWS["idx_products_category"],
                    ],
                    "idx_products_category_name": [
                        second_index_expression_key,
                    ],
                },
            ),
        ):
            with self.subTest(case=case):
                result, calls = self.run_index_operation(
                    "reindex_category_indexes",
                    verification_results,
                )

                self.assertEqual(result["ok"], False)
                self.assertEqual(
                    result["error"]["code"],
                    "unexpected_index_definition",
                )
                self.assertNotIn("recoveryOperation", result["error"])
                self.assertFalse(
                    any(sql.startswith(("REINDEX", "DROP")) for sql in calls)
                )

    def test_failed_verification_stops_later_maintenance_steps(self):
        invalid_rows = [
            (
                "public", "products", "idx_products_category", False, False,
                "btree", None, 1, "category",
            ),
        ]
        restore_result, restore_calls = self.run_index_operation(
            "restore_category_indexes",
            {"idx_products_category": [invalid_rows]},
        )
        reindex_result, reindex_calls = self.run_index_operation(
            "reindex_category_indexes",
            {
                "idx_products_category": [
                    self.INDEX_ROWS["idx_products_category"],
                    self.INDEX_ROWS["idx_products_category"],
                    invalid_rows,
                ],
            },
        )

        self.assertEqual(restore_result["ok"], False)
        self.assertFalse(
            any(
                sql.startswith("CREATE INDEX")
                and "idx_products_category_name" in sql
                for sql in restore_calls
            ),
        )
        self.assertEqual(reindex_result["ok"], False)
        self.assertEqual(
            [sql for sql in reindex_calls if sql.startswith("REINDEX INDEX")],
            ["REINDEX INDEX CONCURRENTLY public.idx_products_category"],
        )

    def test_connection_timeout_is_not_classified_as_dns(self):
        result = QUERY.run_operation(
            "connection_check",
            host="zava-pg-abc.postgres.database.azure.com",
            database="zava_store",
            principal_name="sre-agent",
            client_id="client-id",
            credential=Mock(get_token=Mock(return_value=Mock(token="token"))),
            connector=Mock(side_effect=TimeoutError("connection timed out")),
        )
        self.assertEqual(result["error"]["category"], "connection")


if __name__ == "__main__":
    unittest.main()
