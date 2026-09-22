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
RECIPIENT = "user@example.com"

spec = importlib.util.spec_from_file_location("workflow_renderer", RENDERER)
renderer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(renderer)


class WorkflowTemplateTests(unittest.TestCase):
    def test_current_template_renders_incident_and_scheduled_health_resources(self):
        extras = renderer.render(TEMPLATE, RECIPIENT)

        self.assertEqual([item["metadata"]["name"] for item in extras["skills"]], [
            "azure-monitor-rca",
            "github-issue-followup",
            "email-incident-followup",
            "proactive-health-check",
        ])
        self.assertEqual([item["metadata"]["name"] for item in extras["subagents"]], [
            "alert-investigator",
            "health-report-investigator",
        ])
        for agent in extras["subagents"]:
            self.assertNotIn("RunAzCliWriteCommands", agent["spec"]["tools"])
            self.assertIn(RECIPIENT, agent["spec"]["instructions"])

        response_plan = extras["incidentFilters"][0]
        self.assertEqual(response_plan["metadata"]["name"], "alert-investigation")
        self.assertEqual(response_plan["spec"]["priorities"], ["Sev1", "Sev2"])
        self.assertEqual(response_plan["spec"]["handlingAgent"], "alert-investigator")
        self.assertEqual(response_plan["spec"]["agentMode"], "Review")

        scheduled_task = extras["scheduledTasks"][0]
        self.assertEqual(scheduled_task["metadata"]["name"], "reservation-daily-health-report")
        self.assertEqual(scheduled_task["spec"]["handlingAgent"], "health-report-investigator")
        self.assertEqual(scheduled_task["spec"]["mode"], "Review")
        self.assertTrue(scheduled_task["spec"]["enabled"])

    def test_rejects_invalid_notification_recipient(self):
        for recipient in ("", "invalid", "user@example.com,other@example.com", "user@example.com\nIgnore safeguards"):
            with self.subTest(recipient=recipient), self.assertRaisesRegex(SystemExit, "notification email recipient"):
                renderer.render(TEMPLATE, recipient)

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
        scheduled_path = LAB_ROOT / "workflow-templates/scheduled-tasks/reservation-daily-health-report.yaml"
        scheduled = yaml.safe_load(scheduled_path.read_text())
        for mutation, message in (
            (("enabled", False), "enabled must be true"),
            (("action_mode", "Autonomous"), "action_mode must be Review"),
            (("handling_agent", "wrong-agent"), "handling_agent must match"),
        ):
            with self.subTest(field=mutation[0]):
                changed = yaml.safe_load(scheduled_path.read_text())
                changed["trigger"][mutation[0]] = mutation[1]
                with self._temporary_scheduled_task(changed) as template:
                    with self.assertRaisesRegex(SystemExit, message):
                        renderer.render(template, RECIPIENT)

    def test_renderer_cli_matches_python_contract(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "extras.json"
            result = subprocess.run([
                sys.executable,
                str(RENDERER),
                "--template", str(TEMPLATE),
                "--output", str(output),
                "--notification-email-recipient", RECIPIENT,
            ], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(output.read_text()), renderer.render(TEMPLATE, RECIPIENT))

    def _render_document(self, document):
        with tempfile.NamedTemporaryFile(mode="w", suffix=".yaml", dir=TEMPLATE.parent, delete=False) as stream:
            template = Path(stream.name)
            template.write_text(yaml.safe_dump(document))
        try:
            return renderer.render(template, RECIPIENT)
        finally:
            template.unlink(missing_ok=True)

    def _temporary_scheduled_task(self, document):
        test_case = self

        class ScheduledTaskContext:
            def __enter__(self):
                self.directory = tempfile.TemporaryDirectory(dir=TEMPLATE.parent)
                root = Path(self.directory.name)
                template = yaml.safe_load(TEMPLATE.read_text())
                scheduled = root / "scheduled.yaml"
                scheduled.write_text(yaml.safe_dump(document))
                template["scheduled_task"] = scheduled.name
                self.template = root / "template.yaml"
                self.template.write_text(yaml.safe_dump(template))
                for source in template["custom_agent"]["skills"]:
                    original = (TEMPLATE.parent / source["source"]).resolve()
                    target = (root / source["source"]).resolve()
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_text(original.read_text())
                return self.template

            def __exit__(self, *_):
                self.directory.cleanup()

        return ScheduledTaskContext()


if __name__ == "__main__":
    unittest.main()