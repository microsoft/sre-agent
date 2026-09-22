#!/usr/bin/env python3

import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import yaml


LAB_ROOT = Path(__file__).resolve().parent.parent
RENDERER = LAB_ROOT / "scripts/internal/render-workflow-template.py"
TEMPLATE = LAB_ROOT / "workflow-templates/incidentinvestigation-workflowtemplate.yaml"
SCHEDULED_TEMPLATE = LAB_ROOT / "workflow-templates/scheduled-tasks/reservation-daily-health-report.yaml"

spec = importlib.util.spec_from_file_location("workflow_renderer", RENDERER)
renderer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(renderer)


class WorkflowTemplateTests(unittest.TestCase):
    def test_incident_template_renders_only_incident_resources(self):
        extras = renderer.render(TEMPLATE)

        self.assertEqual([item["metadata"]["name"] for item in extras["skills"]], [
            "azure-monitor-rca",
            "github-issue-followup",
            "email-incident-followup",
        ])
        self.assertEqual([item["metadata"]["name"] for item in extras["subagents"]], [
            "alert-investigator",
        ])
        for agent in extras["subagents"]:
            self.assertNotIn("RunAzCliWriteCommands", agent["spec"]["tools"])
            self.assertIn("ListOutlookEmails", agent["spec"]["tools"])
            self.assertIn("SendOutlookEmail", agent["spec"]["tools"])
            self.assertIn("email-incident-followup", agent["spec"]["allowedSkills"])
            self.assertIn("configured", agent["spec"]["instructions"])
            self.assertIn("recipient", agent["spec"]["instructions"])
        self.assertNotIn("askApprovalTools", extras["installerRequirements"])

        response_plan = extras["incidentFilters"][0]
        self.assertEqual(response_plan["metadata"]["name"], "alert-investigation")
        self.assertEqual(response_plan["spec"]["priorities"], ["Sev1", "Sev2"])
        self.assertEqual(response_plan["spec"]["handlingAgent"], "alert-investigator")
        self.assertEqual(response_plan["spec"]["agentMode"], "Review")
        self.assertEqual(extras["scheduledTasks"], [])

    def test_scheduled_template_renders_only_scheduled_health_resources(self):
        extras = renderer.render(SCHEDULED_TEMPLATE)
        self.assertEqual([item["metadata"]["name"] for item in extras["skills"]], [
            "proactive-health-check",
            "email-incident-followup",
        ])
        self.assertEqual([item["metadata"]["name"] for item in extras["subagents"]], [
            "health-report-investigator",
        ])
        self.assertEqual(extras["incidentFilters"], [])
        scheduled_task = extras["scheduledTasks"][0]
        self.assertEqual(scheduled_task["metadata"]["name"], "reservation-daily-health-report")
        self.assertEqual(scheduled_task["spec"]["handlingAgent"], "health-report-investigator")
        self.assertEqual(scheduled_task["spec"]["mode"], "Review")
        self.assertTrue(scheduled_task["spec"]["enabled"])

    def test_rejects_unsupported_incident_platform(self):
        document = yaml.safe_load(TEMPLATE.read_text())
        document["trigger"]["platform"] = "pagerduty"
        with self.assertRaisesRegex(SystemExit, "azure-monitor incident platform"):
            self._render_document(document)

    def test_rejects_tool_in_both_attached_and_denied_groups(self):
        document = yaml.safe_load(TEMPLATE.read_text())
        document["custom_agent"]["tools"]["deny"].append("ReadFile")
        with self.assertRaisesRegex(SystemExit, "denied tool cannot also be attached"):
            self._render_document(document)

    def test_rejects_skill_source_outside_workflow_directory(self):
        document = yaml.safe_load(TEMPLATE.read_text())
        document["custom_agent"]["skills"][0]["source"] = "../../README.md"
        with self.assertRaisesRegex(SystemExit, "skill source must be a file under"):
            self._render_document(document)

    def test_rejects_malformed_scheduled_task_contract(self):
        for mutation, message in (
            (("enabled", False), "enabled must be true"),
            (("action_mode", "Autonomous"), "action_mode must be Review"),
            (("handling_agent", "wrong-agent"), "handling_agent must match"),
        ):
            with self.subTest(field=mutation[0]):
                changed = yaml.safe_load(SCHEDULED_TEMPLATE.read_text())
                changed["trigger"][mutation[0]] = mutation[1]
                with self.assertRaisesRegex(SystemExit, message):
                    self._render_document(changed, SCHEDULED_TEMPLATE)

    def test_renderer_cli_matches_python_contract(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "extras.json"
            result = subprocess.run([
                sys.executable,
                str(RENDERER),
                "--template", str(TEMPLATE),
                "--output", str(output),
            ], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(output.read_text()), renderer.render(TEMPLATE))

    def _render_document(self, document, base_template=TEMPLATE):
        with tempfile.NamedTemporaryFile(mode="w", suffix=".yaml", dir=base_template.parent, delete=False) as stream:
            template = Path(stream.name)
            template.write_text(yaml.safe_dump(document))
        try:
            return renderer.render(template)
        finally:
            template.unlink(missing_ok=True)


if __name__ == "__main__":
    unittest.main()