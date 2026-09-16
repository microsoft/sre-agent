"""Offline contracts only: no Azure authentication, telemetry, or mutations."""

import json
from pathlib import Path
import re
import subprocess
import sys
import unittest


LAB = Path(__file__).resolve().parents[1]
HOOK = LAB / "sre-config" / "hooks" / "readonly-evidence.py"
MONITOR = {
    "system-mcp-monitor_monitor_resource_log_query",
    "system-mcp-monitor_monitor_metrics_query",
}
POSTGRES_READ = "QueryZavaPostgres"


def nested_resources(template):
    for resource in template.get("resources", []):
        yield resource
        if resource["type"] == "Microsoft.Resources/deployments":
            yield from nested_resources(resource["properties"]["template"])


class ReadonlyHookTests(unittest.TestCase):
    def run_hook(self, payload):
        result = subprocess.run(
            [sys.executable, str(HOOK)],
            input=payload,
            capture_output=True,
            check=True,
            timeout=10,
        )
        self.assertEqual(result.stderr, b"")
        return json.loads(result.stdout)

    def assert_denied(self, payload):
        result = self.run_hook(payload)
        self.assertEqual(
            result,
            {
                "ok": False,
                "reason": (
                    "Read-only specialist guard: tool is outside this "
                    "agent's permitted read operations."
                ),
                "hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "deny",
                },
            },
        )

    def test_exact_read_allowlist_is_normal_pass_not_permission_override(self):
        for tool in MONITOR | {POSTGRES_READ,
            "read_skill_file", "ReadFile", "ListDir", "FileSearch", "GrepSearch"
        }:
            with self.subTest(tool=tool):
                self.assertEqual(
                    self.run_hook(json.dumps({"tool_name": tool}).encode()),
                    {"ok": True},
                )

    def test_write_core_delegation_and_near_match_tools_are_denied(self):
        for tool in (
            "RunInTerminal", "RunAzCliWriteCommands", "RunKubectlWriteCommand",
            "RunKubectlReadCommand", "RepairZavaPostgresIndexes", "ExecutePythonCode", "CreateFile",
            "Task", "Agent", "ReadFile ", "readfile", "ReadFile\n",
            "system-mcp-monitor_monitor_resource_log_query_write",
            "system-mcp-monitor_unknown", "read_skill_file_extra",
        ):
            with self.subTest(tool=tool):
                self.assert_denied(json.dumps({"tool_name": tool}).encode())

    def test_malformed_missing_and_wrong_type_contexts_fail_closed(self):
        for payload in (
            b"", b"{", b"null", b"[]", b"true", b'"ReadFile"', b"{}",
            b'{"tool_name":null}', b'{"tool_name":1}', b'{"tool_name":[]}',
            b'{"tool_name":{"name":"ReadFile"}}',
            b'{"tool_input":{"tool_name":"ReadFile"}}', b"\xff",
        ):
            with self.subTest(payload=payload):
                self.assert_denied(payload)

    def test_first_tool_identity_wins_over_duplicate_flattened_metadata(self):
        self.assert_denied(
            b'{"tool_name":"RunInTerminal","tool_name":"ReadFile"}'
        )
        self.assert_denied(b'{"tool_name":null,"tool_name":"ReadFile"}')
        self.assertEqual(
            self.run_hook(b'{"tool_name":"ReadFile","tool_name":"RunInTerminal"}'),
            {"ok": True},
        )

    def test_query_budget_and_resource_scope_are_not_enforced_by_hook(self):
        payload = {
            "tool_name": next(iter(MONITOR)),
            "tool_input": {"attempt": 100, "limit": 100000, "resource": "other"},
        }
        self.assertEqual(self.run_hook(json.dumps(payload).encode()), {"ok": True})


class ConfigurationTests(unittest.TestCase):
    def test_category_query_plan_is_exposed_in_manifest_and_runbooks(self):
        config = json.loads(
            (LAB / "sre-config" / "agent-config.json").read_text(encoding="utf-8")
        )
        query_tool = next(
            tool for tool in config["tools"] if tool["name"] == "QueryZavaPostgres"
        )
        parameter = query_tool["properties"]["parameters"][0]
        self.assertEqual(parameter["name"], "operation")
        self.assertIn("category_query_plan", parameter["description"])

        evidence = (LAB / "sre-config" / "skills" / "zava-database-evidence.md").read_text(
            encoding="utf-8"
        )
        performance = (LAB / "sre-config" / "skills" / "performance-incidents.md").read_text(
            encoding="utf-8"
        )
        self.assertIn("`category_query_plan`", evidence)
        self.assertIn("`category_query_plan`", performance)
        self.assertIn("FORMAT JSON", evidence)
        normalized_performance = " ".join(performance.split())
        self.assertIn(
            "full query shape, latency, query plan, and index statistics",
            normalized_performance,
        )
        self.assertIn("does not accept arbitrary `EXPLAIN`", performance)

    def test_readiness_and_staged_connector_contracts(self):
        result = subprocess.run(
            ["pwsh", "-NoProfile", "-File", str(LAB / "tests" / "readiness.Tests.ps1")],
            capture_output=True,
            text=True,
            timeout=120,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("All readiness contracts passed", result.stdout)

    def test_connectors_are_outside_core_provisioning(self):
        core = (LAB / "infra" / "modules" / "sre-agent.bicep").read_text(encoding="utf-8")
        main = (LAB / "infra" / "main.bicep").read_text(encoding="utf-8")
        staged = (LAB / "infra" / "modules" / "sre-agent-connectors.bicep").read_text(encoding="utf-8")
        setup = (LAB / "scripts" / "setup-sre-agent.ps1").read_text(encoding="utf-8")
        self.assertNotIn("Microsoft.App/agents/connectors@", core)
        self.assertNotIn("sre-agent-connectors.bicep", main)
        self.assertIn("Microsoft.App/agents/connectors@", staged)
        self.assertIn("loadJsonContent('../../sre-config/agent-config.json', '$.connectors')", staged)
        self.assertLess(setup.index("Wait-ZavaDataPlane -Client"), setup.index("$collections = @{}"))
        self.assertLess(setup.index("Assert-ZavaUpdateApproved $syncPlan"), setup.index("Sync-ZavaConnectors -Plan"))
        self.assertLess(setup.index("Sync-ZavaConnectors -Plan"), setup.index("Sync-ZavaResources $syncPlan 'skills'"))

        compiled = json.loads((LAB / "infra" / "main.json").read_text(encoding="utf-8"))
        resource_types = {resource["type"] for resource in nested_resources(compiled)}
        self.assertNotIn("Microsoft.App/agents/connectors", resource_types)

    def test_unknown_alert_is_disabled_and_resource_group_scoped(self):
        template = (LAB / "infra" / "modules" / "monitoring.bicep").read_text(
            encoding="utf-8"
        )
        alert = template.split("resource alertUnknownTest ", 1)[1]
        self.assertIn("enabled: false", alert)
        self.assertIn("scopes: [resourceGroupId]", alert)
        self.assertIn("{ field: 'category', equals: 'Administrative' }", alert)
        self.assertIn(
            "{ field: 'operationName', equals: 'Microsoft.Resources/tags/write' }",
            alert,
        )

    def test_evidence_queries_use_target_schema_and_millisecond_durations(self):
        cases = (
            ("zava-application-evidence.md", "AppRequests", "requests"),
            ("zava-database-evidence.md", "AppDependencies", "dependencies"),
        )
        for filename, workspace_table, classic_table in cases:
            with self.subTest(skill=filename):
                content = (LAB / "sre-config" / "skills" / filename).read_text(
                    encoding="utf-8"
                )
                queries = re.findall(r"```kusto\n(.*?)\n```", content, re.DOTALL)
                self.assertEqual(len(queries), 2)
                workspace, classic = queries
                self.assertTrue(workspace.startswith(workspace_table + "\n"))
                self.assertTrue(classic.startswith(classic_table + "\n"))
                for query, timestamp, role, duration in (
                    (workspace, "TimeGenerated", "AppRoleName", "DurationMs"),
                    (classic, "timestamp", "cloud_RoleName", "duration"),
                ):
                    self.assertIn(f'{role} == "zava-api"', query)
                    self.assertIn(f"{timestamp} >= datetime(<UTC_START>)", query)
                    self.assertIn(f"{timestamp} < datetime(<UTC_END>)", query)
                    self.assertIn(f"AvgMs=avg({duration})", query)
                    self.assertIn("| take 20", query)
                    self.assertNotRegex(query, r"duration\s*/\s*\d+ms")
                self.assertNotIn("DurationMs", classic)
                self.assertNotRegex(content, r"duration\s*/\s*\d+ms")
                self.assertIn("`subscription` argument", content)

    def test_agent_instructions_use_native_postgres_tools(self):
        config_files = list((LAB / "sre-config").rglob("*.md")) + [LAB / "sre-config" / "agent-config.json"]
        contents = "\n".join(path.read_text(encoding="utf-8") for path in config_files)
        self.assertIn("QueryZavaPostgres", contents)
        self.assertIn("RepairZavaPostgresIndexes", contents)
        self.assertNotIn("kubectl exec -n zava-demo deploy/zava-api -- node bin/run-sql.js", contents)
        self.assertNotIn("in-cluster SQL helper", contents)

    def test_native_postgres_bicep_contracts(self):
        vnet = (LAB / "infra" / "modules" / "vnet.bicep").read_text(encoding="utf-8")
        agent = (LAB / "infra" / "modules" / "sre-agent.bicep").read_text(encoding="utf-8")
        identity = (LAB / "infra" / "modules" / "identity.bicep").read_text(encoding="utf-8")
        aks = (LAB / "infra" / "modules" / "aks.bicep").read_text(encoding="utf-8")
        main = (LAB / "infra" / "main.bicep").read_text(encoding="utf-8")
        compiled = json.loads((LAB / "infra" / "main.json").read_text(encoding="utf-8"))
        self.assertIn("name: 'agent-link'", vnet)
        self.assertIn("name: 'agent-to-postgres-5432'", vnet)
        self.assertIn("destinationAddresses: ['10.20.16.0/24']", vnet)
        self.assertIn("destinationPorts: ['5432']", vnet)
        self.assertNotIn("name: 'allow-agent-python-packages'", vnet)
        self.assertNotIn("'pypi.org'", vnet)
        self.assertNotIn("'files.pythonhosted.org'", vnet)
        self.assertIn(
            """{
          name: 'pg8000'
          version: '1.30.5'
          packageManager: 'pip'
        }""",
            agent,
        )
        self.assertIn(
            """{
          name: 'azure-identity'
          version: '1.24.0'
          packageManager: 'pip'
        }""",
            agent,
        )
        self.assertIn("EnableAdcSharedWorkspace", agent)
        self.assertIn("EnableEgressProxy", agent)
        self.assertIn("output sreAgentIdentityClientId", identity)
        self.assertIn("sreAgentClientId: identity.outputs.sreAgentIdentityClientId", main)
        self.assertIn("useAADAuth: 'true'", aks)
        compiled_text = json.dumps(compiled)
        self.assertIn('useAADAuth', compiled_text)
        self.assertIn('agent-to-postgres-5432', compiled_text)
        self.assertIn('agent-link', compiled_text)

        agents = [
            resource
            for resource in nested_resources(compiled)
            if resource["type"] == "Microsoft.App/agents"
        ]
        self.assertEqual(len(agents), 1)
        self.assertEqual(
            agents[0]["properties"]["sandboxConfiguration"]["packages"],
            [
                {
                    "name": "pg8000",
                    "version": "1.30.5",
                    "packageManager": "pip",
                },
                {
                    "name": "azure-identity",
                    "version": "1.24.0",
                    "packageManager": "pip",
                },
            ],
        )
        self.assertEqual(
            agents[0]["properties"]["sandboxConfiguration"]["egress"]["allowedRegistries"],
            ["pypi"],
        )

    def test_pg_stat_statements_is_allowlisted_before_tracking_is_configured(self):
        source = (LAB / "infra" / "modules" / "postgresql.bicep").read_text(
            encoding="utf-8"
        )
        self.assertEqual(source.count("name: 'azure.extensions'"), 1)
        self.assertIn("value: 'pg_stat_statements'", source)
        self.assertLess(
            source.index("name: 'azure.extensions'"),
            source.index("name: 'pg_stat_statements.track'"),
        )
        self.assertIn("dependsOn: [pgExtensions]", source)

        compiled = json.loads(
            (LAB / "infra" / "main.json").read_text(encoding="utf-8")
        )
        configurations = [
            resource
            for resource in nested_resources(compiled)
            if resource["type"]
            == "Microsoft.DBforPostgreSQL/flexibleServers/configurations"
        ]
        extensions = [
            resource
            for resource in configurations
            if "azure.extensions" in json.dumps(resource["name"])
        ]
        tracking = [
            resource
            for resource in configurations
            if "pg_stat_statements.track" in json.dumps(resource["name"])
        ]
        self.assertEqual(len(extensions), 1)
        self.assertEqual(extensions[0]["properties"]["value"], "pg_stat_statements")
        self.assertEqual(len(tracking), 1)
        self.assertTrue(
            any(
                "azure.extensions" in json.dumps(dependency)
                for dependency in tracking[0].get("dependsOn", [])
            )
        )

    def test_powershell_render_and_sync_contracts(self):
        result = subprocess.run(
            ["pwsh", "-NoProfile", "-File", str(LAB / "tests" / "sre-config.Tests.ps1")],
            capture_output=True,
            text=True,
            timeout=120,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("All configuration contracts passed", result.stdout)


if __name__ == "__main__":
    unittest.main()
