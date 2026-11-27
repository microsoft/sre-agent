#!/usr/bin/env python3
"""Check governance examples without executing infrastructure commands."""

import ast
import json
from itertools import permutations
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[1]
CLI_TOOLS = ("RunAzCliWriteCommands", "RunKubectlWriteCommand")
RESTART_TOOLS = (
    "AutoScaleApp", "ModifyContainerAppScaleRule", "ScaleStatefulSet",
    "RolloutRestartDeployment", "RestartWebApp", "RestartWebApplication",
    "ScaleAppServicePlanVertically",
)
NSG_TOOLS = ("CreateOrUpdateNSGRule", "RemoveNSGRule", "APIMModifyNSGRule", "APIMRemoveNSGRule")
REMOVAL_TOOLS = ("RemoveNSGRule", "APIMRemoveNSGRule")
RESTART_PATTERN = r"(?:AutoScale|Scale|Restart|RolloutRestart|Modify.*Scale|Resize|Stop|Deallocate).*"
REMOVAL_PATTERN = r"(?:APIM)?RemoveNSGRule.*"
NSG_PATTERN = r"(?:APIM)?(?:CreateOrUpdate|Modify|Remove).*NSG.*"
VM_PATTERN = r"(?:" + RESTART_PATTERN + "|" + NSG_PATTERN + ")"


class GovernanceHookTests(unittest.TestCase):
    executions = 0

    def load_hook(self, name, count, tools, pattern=None):
        paths = sorted(ROOT.glob("**/config/hooks/" + name + ".yaml"))
        self.assertEqual(len(paths), count)
        source = paths[0].read_bytes()
        for path in paths:
            self.assertEqual(path.read_bytes(), source, str(path))
        if name == "deny-prod-deletes":
            default = ROOT / "bicep/defaults/hooks/deny-prod-deletes.yaml"
            self.assertEqual(default.read_bytes(), source)
        document = yaml.safe_load(source)
        self.assertEqual(document["metadata"]["name"], name)
        spec = document["spec"]
        self.assertEqual(set(spec), {"eventType", "hook", "enabled"})
        self.assertEqual(spec["eventType"], "PreToolUse")
        self.assertIs(spec["enabled"], True)
        hook = spec["hook"]
        self.assertEqual(set(hook), {"type", "matcher", "failMode", "timeout", "script"})
        self.assertEqual((hook["type"], hook["failMode"], hook["timeout"]), ("command", "block", 10))
        self.assertTrue(hook["script"].startswith("#!/usr/bin/env python3\n"))
        self.assertEqual(hook["matcher"], "aws-mcp_.*" if pattern is None else "|".join(CLI_TOOLS) + "|" + pattern)
        if pattern is not None:
            assignments = [
                node.value.value
                for node in ast.parse(hook["script"]).body
                if isinstance(node, ast.Assign) and isinstance(node.value, ast.Constant)
                and any(isinstance(target, ast.Name) and target.id in {"builtin_pattern", "removal_pattern"} for target in node.targets)
            ]
            self.assertEqual(assignments, [pattern])
        for tool in tools:
            self.assertIsNotNone(re.fullmatch(hook["matcher"], tool))
        self.assertIsNone(re.fullmatch(hook["matcher"], "prefix_" + tools[0]))
        self.assertIsNone(re.fullmatch(hook["matcher"], tools[0].swapcase()))
        return hook

    def execute(self, hook, event):
        GovernanceHookTests.executions += 1
        with tempfile.TemporaryDirectory() as directory:
            script = Path(directory) / "hook.py"
            script.write_text(hook["script"], encoding="utf-8")
            return subprocess.run(
                [sys.executable, str(script)], input=json.dumps(event),
                text=True, capture_output=True, timeout=10, check=False,
            )

    def check(self, hook, tool, arguments, decision):
        with self.subTest(tool=tool, arguments=arguments):
            self.assertIsNotNone(re.fullmatch(hook["matcher"], tool))
            result = self.execute(hook, {"tool_name": tool, "tool_input": arguments})
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stderr, "")
            output = json.loads(result.stdout)
            if decision is None:
                self.assertEqual(output, {"ok": True})
            elif decision == "deny":
                self.assertEqual(set(output), {"ok", "reason", "hookSpecificOutput"})
                self.assertIs(output["ok"], False)
                self.assertTrue(output["reason"].strip())
                self.assertEqual(output["hookSpecificOutput"], {"permissionDecision": "deny"})
            else:
                self.assertEqual(set(output), {"ok", "hookSpecificOutput"})
                self.assertIs(output["ok"], True)
                specific = output["hookSpecificOutput"]
                self.assertEqual(set(specific), {"permissionDecision", "permissionDecisionReason"})
                self.assertEqual(specific["permissionDecision"], "ask")
                self.assertTrue(specific["permissionDecisionReason"].strip())

    def check_invalid(self, hook, tool, cli=False):
        events = [[], {"tool_name": 1, "tool_input": {}}, {"tool_name": tool, "tool_input": []}]
        if cli:
            events += [
                {"tool_name": tool, "tool_input": {"command": value}}
                for value in (None, "")
            ]
        for event in events:
            with self.subTest(invalid=event):
                result = self.execute(hook, event)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")
                self.assertTrue(result.stderr)

    def test_deny_prod_deletes(self):
        hook = self.load_hook("deny-prod-deletes", 6, CLI_TOOLS + REMOVAL_TOOLS, REMOVAL_PATTERN)
        for tool, command, decision in [
            (CLI_TOOLS[0], "az group delete -n x-prod", "deny"),
            (CLI_TOOLS[0], "az group delete -n product-dev", "deny"),
            (CLI_TOOLS[0], "AZ GROUP REMOVE -n x-prd", "deny"),
            (CLI_TOOLS[1], "kubectl delete deployment app -n prod", "deny"),
            (CLI_TOOLS[0], "az group delete -n dev", None),
            (CLI_TOOLS[0], "az vm restart -g prod -n vm", None),
            (CLI_TOOLS[0], "az vm show -g prod -n vm", None),
        ]:
            self.check(hook, tool, {"command": command}, decision)
        for tool in REMOVAL_TOOLS:
            self.check(hook, tool, {"nsgResourceId": "/resourceGroups/prod/nsg"}, "deny")
        for tool in ("RemoveNSGRuleV2", "APIMRemoveNSGRuleBatch"):
            self.check(hook, tool, {"nsgResourceId": "/resourceGroups/prod/nsg"}, "deny")
            self.check(hook, tool, {"nsgResourceId": "/resourceGroups/dev/nsg"}, None)
        self.check_invalid(hook, CLI_TOOLS[0], cli=True)

    def test_restart_approval(self):
        hook = self.load_hook("require-approval-for-restarts", 4, CLI_TOOLS + RESTART_TOOLS, RESTART_PATTERN)
        for tool in RESTART_TOOLS:
            self.check(hook, tool, {}, "ask")
        for tool in (
            "AutoScaleQueue", "ModifyWorkerScaleSettings", "ScaleDeployment",
            "RolloutRestartStatefulSet", "RestartFunctionApp", "ResizeVM",
            "StopVM", "DeallocateVM",
        ):
            self.check(hook, tool, {}, "ask")
        for tool in NSG_TOOLS:
            self.assertIsNone(re.fullmatch(hook["matcher"], tool))
        for command, decision in [
            ("az vm restart -g rg -n vm", "ask"),
            ("az vm stop -g rg -n vm", "ask"),
            ("az vm deallocate -g rg -n vm", "ask"),
            ("az vm resize -g rg -n vm --size small", "ask"),
            ("az vm show -g prod -n vm", None),
            ("az group delete -n x-prod", "deny"),
            ("az vmss update --set sku.capacity=3", "ask"),
            ("az vmss update --set tags.env=prod", None),
            ("az webapp config set --always-on true", None),
            ("az aks nodepool show --name np1", None),
        ]:
            self.check(hook, CLI_TOOLS[0], {"command": command}, decision)
        for command in ("kubectl scale deployment app --replicas=3", "kubectl rollout restart deployment/app"):
            self.check(hook, CLI_TOOLS[1], {"command": command}, "ask")
        self.check_capacity_commands(hook)
        self.check_invalid(hook, CLI_TOOLS[0], cli=True)

    def check_capacity_commands(self, hook):
        for tool, command in [
            (CLI_TOOLS[0], "az vmss update --set sku.capacity=0"),
            (CLI_TOOLS[0], "az aks nodepool update --max-count 0"),
            (CLI_TOOLS[0], "az appservice plan update --number-of-workers 0"),
            (CLI_TOOLS[1], 'kubectl patch deployment web -p \'{"spec":{"replicas":0}}\''),
            (CLI_TOOLS[1], "kubectl apply -f x.yaml --replicas=3"),
        ]:
            self.check(hook, tool, {"command": command}, "ask")
        self.check(hook, CLI_TOOLS[0], {
            "command": "az webapp config set --always-on true",
            "tag": "replicas sku.capacity --max-count",
        }, None)

    def test_production_delete_denied_in_every_order(self):
        deny_path = ROOT / "agents/dg-azd-bash/config/hooks/deny-prod-deletes.yaml"
        deny_script = yaml.safe_load(deny_path.read_text(encoding="utf-8"))["spec"]["hook"]["script"]
        namespace = {"tool_name": "RunAzCliWriteCommands"}
        prefix = ast.parse(deny_script).body
        # Compare the evaluated predicate and exact denial payload, independent of variable names.
        reference = next(node for node in prefix if isinstance(node, ast.If) and
                         any(isinstance(child, ast.Constant) and child.value == "deny" for child in ast.walk(node)))
        reference_payload = next(child for child in ast.walk(reference) if isinstance(child, ast.Dict) and
                                 any(isinstance(key, ast.Constant) and key.value == "reason" for key in child.keys))
        expected_reason = ast.literal_eval(reference_payload)["reason"]
        directories = sorted({path.parent for path in ROOT.glob("**/config/hooks/deny-prod-deletes.yaml")})
        self.assertEqual(len(directories), 6)
        for directory in directories:
            hooks = [yaml.safe_load(path.read_text(encoding="utf-8"))["spec"]["hook"]
                     for path in sorted(directory.glob("*.yaml"))]
            for hook in hooks:
                body = ast.parse(hook["script"]).body
                denial = next((node for node in body if isinstance(node, ast.If) and
                               any(isinstance(child, ast.Constant) and child.value == "deny" for child in ast.walk(node))), None)
                self.assertIsNotNone(denial, directory)
                payload = next(child for child in ast.walk(denial) if isinstance(child, ast.Dict) and
                               any(isinstance(key, ast.Constant) and key.value == "reason" for key in child.keys))
                self.assertEqual(ast.literal_eval(payload), ast.literal_eval(reference_payload))
                for removal in (False, True):
                    for command in ("az vm restart", "az vm delete", "kubectl remove pod app"):
                        for resource in ("rg-prod", "rg-prd", "rg-dev"):
                            values = dict(namespace, removes_rule=removal, removal=removal, command=command,
                                          tool_input={"command": command, "resource": resource}, re=re, json=json)
                            actual = eval(compile(ast.Expression(denial.test), "<denial>", "eval"), values)
                            expected = eval(compile(ast.Expression(reference.test), "<reference>", "eval"), values)
                            self.assertEqual(bool(actual), bool(expected))
            for ordered in permutations(hooks):
                samples = [
                    (CLI_TOOLS[0], {"command": "az group delete -n rg-prod"}, "deny"),
                    (CLI_TOOLS[0], {"command": "az vm delete -g rg-prod -n vm1"}, "deny"),
                    (CLI_TOOLS[1], {"command": "kubectl delete deploy web -n prod"}, "deny"),
                    ("RemoveNSGRule", {"nsgResourceId": "/rg-prod/nsg"}, "deny"),
                    ("APIMRemoveNSGRule", {"nsgResourceId": "/rg-prod/nsg"}, "deny"),
                ]
                if len(hooks) > 1:
                    samples.append((CLI_TOOLS[0], {"command": "az vm restart -g rg-prod"}, "ask"))
                for tool, arguments, expected in samples:
                    with self.subTest(directory=directory.relative_to(ROOT), tool=tool, arguments=arguments,
                                      first=ordered[0]["matcher"]):
                        decision = None
                        for hook in ordered:
                            if not re.fullmatch(hook["matcher"], tool):
                                continue
                            result = self.execute(hook, {"tool_name": tool, "tool_input": arguments})
                            self.assertEqual(result.returncode, 0, result.stderr)
                            output = json.loads(result.stdout)
                            decision = output.get("hookSpecificOutput", {}).get("permissionDecision")
                            if decision in {"ask", "deny"}:
                                if decision == "deny":
                                    self.assertEqual(output["reason"], expected_reason)
                                break
                        self.assertEqual(decision, expected)

    def test_vm_remediation(self):
        hook = self.load_hook("vm-remediation-approval", 1, CLI_TOOLS + RESTART_TOOLS + NSG_TOOLS, VM_PATTERN)
        for tool in RESTART_TOOLS + NSG_TOOLS:
            self.check(hook, tool, {}, "ask")
        for tool in (
            "RestartFunctionApp", "ScaleDeployment", "ResizeVM", "StopVM",
            "CreateOrUpdateTenantNSGRule", "ModifyNetworkNSGRule",
            "APIMRemoveNetworkNSGRule", "RemoveNSGRuleV2",
        ):
            self.check(hook, tool, {}, "ask")
        for command, decision in [
            ("az vm update -g rg -n vm --set tags.owner=test", "ask"),
            ("az vmss update -g rg -n pool --set sku.capacity=3", "ask"),
            ("az network nsg rule create -g rg --nsg-name nsg -n rule", "ask"),
            ("az vm show -g prod -n vm", None),
            ("az vm run-command list -g rg", None),
            ("az vm get-instance-view -g rg -n vm", None),
            ("az vm show --query name; az vm delete -g rg -n vm", "ask"),
            ("az vm show && az network nsg rule delete -g rg -n rule", "ask"),
            ("az vm list | az vmss update --set sku.capacity=2", "ask"),
            ("az --subscription test vm show -g rg -n vm", "ask"),
            ("az storage account show -g rg -n store", None),
            ("az network nsg show -g rg -n show", None),
            ("az vmss update --set tags.env=prod", "ask"),
            ("az webapp config set --always-on true", None),
            ("az aks nodepool show --name np1", None),
        ]:
            self.check(hook, CLI_TOOLS[0], {"command": command}, decision)
        self.check_capacity_commands(hook)
        self.check_invalid(hook, CLI_TOOLS[0], cli=True)

    def test_regex_scope_excludes_unrelated_tools(self):
        hooks = [
            self.load_hook("deny-prod-deletes", 6, CLI_TOOLS + REMOVAL_TOOLS, REMOVAL_PATTERN),
            self.load_hook("require-approval-for-restarts", 4, CLI_TOOLS + RESTART_TOOLS, RESTART_PATTERN),
            self.load_hook("vm-remediation-approval", 1, CLI_TOOLS + RESTART_TOOLS + NSG_TOOLS, VM_PATTERN),
        ]
        for hook in hooks:
            for tool in (
                "GetNSGRules", "ListWorkloadRevisions", "CalculateScalingCost",
                "ReadFile", "RecycleApplication", "RunAzCliReadCommands",
                "RunKubectlReadCommand", "prefix_RestartWebApp", "restartWebApp",
            ):
                with self.subTest(matcher=hook["matcher"], tool=tool):
                    self.assertIsNone(re.fullmatch(hook["matcher"], tool))
                    result = self.execute(hook, {"tool_name": tool, "tool_input": {}})
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(json.loads(result.stdout), {"ok": True})

    def test_aws_operations(self):
        hook = self.load_hook("deny-aws-destructive", 1, ("aws-mcp_ec2_terminate-instances",))
        for tool, arguments, decision in [
            ("aws-mcp_ec2_terminate-instances", {}, "deny"),
            ("aws-mcp_s3_batch-delete-objects", {}, "deny"),
            ("aws-mcp_s3_BatchDeleteObjects", {}, "deny"),
            ("aws-mcp_cloudwatch_get-log-events", {"filterPattern": "service stop"}, None),
            ("aws-mcp_ec2_describe-instances", {"tag": "remove-me-team"}, None),
            ("aws-mcp_aws___ec2_terminate-instances", {}, "deny"),
            ("aws-mcp_aws___recommend", {}, None),
            ("aws-mcp_recommend", {}, None),
            ("aws-mcp_aws___list_regions", {}, None),
            ("aws-mcp_aws___search_documentation", {}, None),
            ("aws-mcp_aws___delete", {}, "deny"),
            ("aws-mcp_call_aws", {"cli_command": "aws ec2 terminate-instances --instance-ids test"}, "deny"),
            ("aws-mcp_aws___call_aws", {"cli_command": "aws ec2 reboot-instances --instance-ids i-1"}, "ask"),
            ("aws-mcp_aws__call_aws", {"cli_command": "aws ec2 describe-instances"}, "ask"),
            ("aws-mcp_run_script", {"script": "aws s3 ls; aws s3 rm s3://test/key"}, "deny"),
            ("aws-mcp_aws___execute", {"command": "aws --profile test --region=west ec2 stop-instances"}, "deny"),
            ("aws-mcp_invoke", {"command": "aws ec2 --output json batch-delete-items"}, "deny"),
            ("aws-mcp_run", {"command": "aws ec2 describe-instances\naws ec2 terminate-instances"}, "deny"),
            ("aws-mcp_call_aws", {"cli_command": "aws ec2 describe-instances --filters Name=tag:team,Values=remove-me-team"}, "ask"),
            ("aws-mcp_call_aws", {"cli_command": "aws logs filter-log-events --filter-pattern 'service stop'"}, "ask"),
            ("aws-mcp_call_aws", {"request": {"command": "aws ec2 terminate-instances"}}, "ask"),
            ("aws-mcp_call_aws", {"script": "aws ec2 'unterminated"}, "ask"),
            ("aws-mcp_call_aws", {}, "ask"),
            ("aws-mcp_call_aws", {"command": "aws --unknown-option ec2 terminate-instances"}, "ask"),
            ("aws-mcp_call_aws", {"script": "aws s3 ls 'unterminated", "command": "aws s3 rb s3://test"}, "deny"),
        ]:
            self.check(hook, tool, arguments, decision)
        self.check_invalid(hook, "aws-mcp_call_aws")


if __name__ == "__main__":
    program = unittest.main(exit=False)
    if program.result.wasSuccessful():
        print(f"PASS: 12/12 hook definitions; {GovernanceHookTests.executions} script cases")
    sys.exit(not program.result.wasSuccessful())
