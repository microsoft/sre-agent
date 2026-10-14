#!/usr/bin/env python3

import importlib.util
import json
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parent.parent / "scripts/configure-pr-validation-repository.py"
REPO_ROOT = Path(__file__).resolve().parents[3]
WORKFLOW = REPO_ROOT / ".github/workflows/sre-agent-pr-validation.yml"
WORKFLOW_TEMPLATE = (
    Path(__file__).resolve().parent.parent
    / "workflow-templates/http-triggers/github-pr-validation.yml"
)
spec = importlib.util.spec_from_file_location("repository_configurator", SCRIPT)
configurator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(configurator)


class GitHubSlugTests(unittest.TestCase):
    def test_parses_https_origin(self):
        self.assertEqual(
            configurator.github_slug("https://github.com/attendee/ticketing-app.git"),
            "attendee/ticketing-app",
        )

    def test_parses_ssh_origin(self):
        self.assertEqual(
            configurator.github_slug("git@github.com:attendee/ticketing-app.git"),
            "attendee/ticketing-app",
        )

    def test_rejects_non_github_origin(self):
        with self.assertRaisesRegex(SystemExit, "origin remote must be a GitHub"):
            configurator.github_slug("https://example.com/attendee/ticketing-app.git")


class WorkflowPayloadTests(unittest.TestCase):
    def test_checked_in_workflow_matches_participant_template(self):
        self.assertEqual(WORKFLOW.read_text(), WORKFLOW_TEMPLATE.read_text())

    def test_workflow_loads_changed_files_from_disk(self):
        workflow = WORKFLOW_TEMPLATE.read_text()

        self.assertIn('--slurpfile changed_files "$changed_files_file"', workflow)
        self.assertIn("changed_files: ($changed_files[0] // [])", workflow)
        self.assertIn('--data-binary @"$payload_file"', workflow)
        self.assertNotIn("--argjson changed_files", workflow)

    def test_workflow_bounds_webhook_delivery_and_rejects_direct_agent_url(self):
        workflow = WORKFLOW_TEMPLATE.read_text()

        self.assertIn("--connect-timeout 15 --max-time 90", workflow)
        self.assertIn("https://*.azuresre.ai|https://*.azuresre.ai/*)", workflow)
        self.assertIn(
            "SRE_AGENT_WEBHOOK_URL must be the Logic App callback URL", workflow
        )

    @unittest.skipUnless(shutil.which("jq"), "jq is required")
    def test_slurpfile_supports_patches_larger_than_native_argument_limit(self):
        changed_files = [{
            "filename": "large.patch",
            "status": "modified",
            "additions": 1,
            "deletions": 1,
            "changes": 2,
            "patch": "x" * 200_000,
        }]
        with tempfile.TemporaryDirectory() as directory:
            changed_files_path = Path(directory) / "changed-files.json"
            changed_files_path.write_text(json.dumps(changed_files))
            result = subprocess.run(
                [
                    shutil.which("jq"),
                    "-n",
                    "--slurpfile",
                    "changed_files",
                    str(changed_files_path),
                    "{changed_files: $changed_files[0]}",
                ],
                capture_output=True,
                text=True,
                check=False,
            )

        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(len(payload["changed_files"][0]["patch"]), 200_000)


if __name__ == "__main__":
    unittest.main()
