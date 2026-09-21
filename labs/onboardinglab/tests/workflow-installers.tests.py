#!/usr/bin/env python3
"""Exercise both installers against local command/HTTP doubles; never contact Azure."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


LAB_ROOT = Path(__file__).resolve().parent.parent
SUBSCRIPTION = "00000000-0000-0000-0000-000000000001"

MOCK = r'''
import json, os, pathlib, sys
root = pathlib.Path(os.environ["WORKFLOW_TEST_STATE"])
mode = os.environ.get("WORKFLOW_TEST_MODE", "core")
command, *args = sys.argv[1:]
with (root / "calls.jsonl").open("a") as stream:
    stream.write(json.dumps([command, args]) + "\n")
def output(value):
    print(json.dumps(value))
if command == "merge":
    state = root / "applied.json"
    merged = json.loads(state.read_text(encoding="utf-8-sig")) if state.exists() else {}
    merged.update(json.loads(pathlib.Path(args[0]).read_text(encoding="utf-8-sig")))
    state.write_text(json.dumps(merged))
elif command == "az":
    if args[:2] == ["resource", "list"]:
        output([{"id": "/subscriptions/test/resourceGroups/test/providers/Microsoft.App/agents/lab", "resourceGroup": "test"}])
    elif args[:2] == ["account", "get-access-token"]:
        print("test-token")
    elif args[0] == "rest":
        url = args[args.index("--url")+1]
        if "/DataConnectors?" in url:
            output({"value": [] if mode == "no-telemetry" else [{"properties": {"dataConnectorType": "AppInsights", "provisioningState": "Succeeded"}}]})
        else:
            output({"properties": {"agentEndpoint": "https://agent.example", "incidentManagementConfiguration": {"type": "AzMonitor"}}})
    else:
        sys.exit("Unexpected az call: " + repr(args))
elif command == "curl":
    url = next(item for item in args if item.startswith("https://"))
    if "/api/v2/repos" in url:
        output({"value": [] if mode == "no-repo" else [{"name": "ticketingapp-source", "properties": {"url": "https://github.com/example/repo"}}]})
    elif "/github/domains" in url:
        output({"values": [{"name": "github.com", "isHealthy": mode != "github-unhealthy"}]})
    elif "/connectorV2/mcpservers" in url:
        output({"value": [{"name": "office365"}]})
    elif "/connectorV2/connections/" in url:
        output({"properties": {"overallStatus": "Unauthenticated" if mode == "email-unconsented" else "Connected"}})
    elif "-X" in args:
        body = json.loads(args[args.index("--data")+1])
        (root / "filter.json").write_text(json.dumps(body))
        pathlib.Path(args[args.index("-o")+1]).write_text("{}")
        print("403" if mode == "write-rejected" else "200", end="")
    elif "/extendedAgent/agents/" in url:
        name = url.rsplit("/", 1)[-1].rstrip("\r")
        agent = next(item for item in json.loads((root / "applied.json").read_text(encoding="utf-8-sig"))["subagents"] if item["metadata"]["name"] == name)
        if mode == "stale-tools":
            agent["spec"]["tools"].append("RunAzCliWriteCommands")
        output({"name": agent["metadata"]["name"], "properties": agent["spec"]})
    elif "/extendedAgent/skills/" in url:
        output({"name": url.rsplit("/", 1)[-1]})
    elif "/extendedAgent/incidentFilters/" in url:
        output(json.loads((root / "filter.json").read_text(encoding="utf-8-sig")))
    elif "/extendedAgent/scheduledtasks" in url:
        tasks = json.loads((root / "applied.json").read_text(encoding="utf-8-sig"))["scheduledTasks"]
        output({"value": [{"name": task["metadata"]["name"], "properties": {
            "cronExpression": task["spec"]["schedule"],
            "agent": task["spec"]["handlingAgent"],
            "agentMode": task["spec"]["mode"],
            "isEnabled": task["spec"]["enabled"],
        }} for task in tasks]})
    else:
        sys.exit("Unexpected HTTP call: " + url)
else:
    sys.exit("Unexpected command: " + command)
'''

PS_HARNESS = r'''
param([string] $Installer, [string] $Template, [string] $Mode)
$ErrorActionPreference = 'Stop'
function az {
    & $env:WORKFLOW_TEST_PYTHON $env:WORKFLOW_TEST_MOCK az @args
    if ($LASTEXITCODE -ne 0) { throw 'Mock az failed' }
}
function Invoke-RestMethod {
    param($Method, $Uri, $Headers, $TimeoutSec)
    $result = & $env:WORKFLOW_TEST_PYTHON $env:WORKFLOW_TEST_MOCK curl $Uri
    if ($LASTEXITCODE -ne 0) { throw 'Mock GET failed' }
    $result | ConvertFrom-Json
}
function Invoke-WebRequest {
    param($Method, $Uri, $Headers, $ContentType, $Body, [switch] $SkipHttpErrorCheck, $TimeoutSec)
    $outputFile = Join-Path $env:WORKFLOW_TEST_STATE 'put-result.json'
    $status = & $env:WORKFLOW_TEST_PYTHON $env:WORKFLOW_TEST_MOCK curl $Uri -X PUT --data $Body -o $outputFile
    if ($LASTEXITCODE -ne 0) { throw 'Mock PUT failed' }
    [pscustomobject]@{ StatusCode = [int]$status; Content = '{}' }
}
& $Installer -Subscription '00000000-0000-0000-0000-000000000001' -AgentName lab `
    -NotificationEmailRecipient 'user@example.com' -Template $Template
'''


class WorkflowInstallerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.pwsh = shutil.which("pwsh")
        git_bash = Path(os.environ.get("ProgramFiles", "")) / "Git/bin/bash.exe"
        cls.bash = str(git_bash) if os.name == "nt" and git_bash.is_file() else shutil.which("bash")
        if not cls.pwsh or not cls.bash or not shutil.which("jq"):
            raise unittest.SkipTest("Both PowerShell, Bash, and jq are required for installer parity tests")

    def _run(self, shell, mode="core"):
        with tempfile.TemporaryDirectory(prefix="workflow-install-test-") as directory:
            root = Path(directory)
            lab = root / "labs/onboardinglab"
            scripts = lab / "scripts"
            scripts.mkdir(parents=True)
            shutil.copytree(LAB_ROOT / "scripts/internal", scripts / "internal")
            shutil.copytree(LAB_ROOT / "workflow-templates", lab / "workflow-templates")
            for suffix in ("ps1", "sh"):
                shutil.copy2(LAB_ROOT / f"scripts/install-workflow-template.{suffix}", scripts)
            shared = root / "sreagent-templates/bicep"
            shared.mkdir(parents=True)
            (shared / "Apply-Extras.ps1").write_text(
                "param($Subscription,$ResourceGroup,$AgentName,$ExtrasFile)\n"
                "& $env:WORKFLOW_TEST_PYTHON $env:WORKFLOW_TEST_MOCK merge $ExtrasFile\n"
                "if ($LASTEXITCODE -ne 0) { throw 'Mock merge failed' }\n",
                encoding="utf-8")
            apply_sh = shared / "apply-extras.sh"
            apply_sh.write_text(
                '#!/usr/bin/env bash\nset -euo pipefail\n'
                '"$WORKFLOW_TEST_PYTHON" "$WORKFLOW_TEST_MOCK" merge "$4"\n',
                encoding="utf-8")
            apply_sh.chmod(0o755)
            mock = root / "mock.py"
            mock.write_text(MOCK, encoding="utf-8")
            env = os.environ.copy()
            env.update(WORKFLOW_TEST_STATE=str(root), WORKFLOW_TEST_MODE=mode,
                       WORKFLOW_TEST_PYTHON=sys.executable, WORKFLOW_TEST_MOCK=str(mock))
            template = lab / "workflow-templates/incidentinvestigation-workflowtemplate.yaml"
            if shell == "ps":
                harness = root / "harness.ps1"
                harness.write_text(PS_HARNESS, encoding="utf-8")
                command = [self.pwsh, "-NoProfile", "-File", str(harness),
                           "-Installer", str(scripts / "install-workflow-template.ps1"),
                           "-Template", str(template), "-Mode", mode]
            else:
                harness = root / "harness.sh"
                harness.write_text(
                    '#!/usr/bin/env bash\nset -euo pipefail\n'
                    'az() { "$WORKFLOW_TEST_PYTHON" "$WORKFLOW_TEST_MOCK" az "$@"; }\n'
                    'curl() { "$WORKFLOW_TEST_PYTHON" "$WORKFLOW_TEST_MOCK" curl "$@"; }\n'
                    'jq() { command jq "$@" | tr -d "\\r"; }\n'
                    'python3() { "$WORKFLOW_TEST_PYTHON" "$@"; }\n'
                    'installer="$1"; shift\nsource "$installer" "$@"\n',
                    encoding="utf-8",
                )
                env["WORKFLOW_TEST_PYTHON"] = Path(sys.executable).as_posix()
                env["WORKFLOW_TEST_MOCK"] = mock.as_posix()
                env["WORKFLOW_TEST_STATE"] = root.as_posix()
                command = [self.bash, str(harness), str(scripts / "install-workflow-template.sh"), "--subscription", SUBSCRIPTION,
                           "--agent-name", "lab", "--notification-email-recipient", "user@example.com",
                           "--template", str(template)]
            result = subprocess.run(command, env=env, capture_output=True, text=True, timeout=90)
            applied = root / "applied.json"
            calls = root / "calls.jsonl"
            return result, json.loads(applied.read_text(encoding="utf-8-sig")) if applied.exists() else None, (
                [json.loads(line) for line in calls.read_text().splitlines()] if calls.exists() else [])

    def test_incident_and_scheduled_health_installer_parity(self):
        results = {}
        for shell in ("ps", "bash"):
            with self.subTest(shell=shell):
                result, applied, _ = self._run(shell)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIsNotNone(applied)
                self.assertEqual(len(applied["subagents"]), 2)
                self.assertEqual(len(applied["scheduledTasks"]), 1)
                results[shell] = applied
        if len(results) == 2:
            self.assertEqual(results["ps"], results["bash"])

    def test_invalid_prerequisites_stop_before_writes_in_both_shells(self):
        for mode in ("no-telemetry",):
            for shell in ("ps", "bash"):
                with self.subTest(shell=shell, mode=mode):
                    result, applied, calls = self._run(shell, mode)
                    self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertIsNone(applied, "Prerequisite failure must precede skill/subagent writes")
                    self.assertNotIn('"PUT"', json.dumps(calls))

    def test_rejected_response_plan_and_stale_readback_fail(self):
        for mode in ("write-rejected", "stale-tools"):
            for shell in ("ps", "bash"):
                with self.subTest(shell=shell, mode=mode):
                    result, _, _ = self._run(shell, mode)
                    self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertNotIn("installed with response plan", result.stdout)


if __name__ == "__main__":
    unittest.main()
