#!/usr/bin/env python3

import importlib.util
import tempfile
import unittest
from pathlib import Path

import yaml


LAB_ROOT = Path(__file__).resolve().parent.parent
RENDERER = LAB_ROOT / "scripts/internal/render-workflow-template.py"
TEMPLATE = LAB_ROOT / "workflow-templates/incidentinvestigation-workflowtemplate.yaml"
SCHEDULED_TASK = LAB_ROOT / "workflow-templates/scheduled-tasks/reservation-daily-health-report.yaml"
PR_VALIDATION = LAB_ROOT / "workflow-templates/http-triggers/pr-validation.yaml"
PR_RENDERER = LAB_ROOT / "scripts/internal/render-pr-validation-template.py"

spec = importlib.util.spec_from_file_location("workflow_renderer", RENDERER)
renderer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(renderer)

pr_spec = importlib.util.spec_from_file_location("pr_validation_renderer", PR_RENDERER)
pr_renderer = importlib.util.module_from_spec(pr_spec)
pr_spec.loader.exec_module(pr_renderer)


class WorkflowTemplateTests(unittest.TestCase):
    def test_current_template_renders_expected_agent_resources(self):
        workflow = yaml.safe_load(TEMPLATE.read_text())
        self.assertEqual(
            workflow["scheduled_task"],
            "./scheduled-tasks/reservation-daily-health-report.yaml",
        )
        extras = renderer.render(TEMPLATE, "operator@example.com")

        self.assertEqual([item["metadata"]["name"] for item in extras["skills"]], [
            "azure-monitor-rca",
            "github-issue-followup",
            "email-incident-followup",
            "proactive-health-check",
        ])
        self.assertEqual(len(extras["subagents"]), 2)
        custom_agent = extras["subagents"][0]
        self.assertEqual(custom_agent["metadata"]["name"], "alert-investigator")
        self.assertIn("operator@example.com", custom_agent["spec"]["instructions"])
        self.assertNotIn("{{notificationEmailRecipient}}", custom_agent["spec"]["instructions"])
        self.assertIn("SearchMemory", custom_agent["spec"]["tools"])
        self.assertNotIn("RunAzCliWriteCommands", custom_agent["spec"]["tools"])
        self.assertEqual(custom_agent["spec"]["allowedSkills"], [
            "azure-monitor-rca",
            "github-issue-followup",
            "email-incident-followup",
        ])
        self.assertIn("PlotAreaChartWithCorrelation", custom_agent["spec"]["tools"])
        self.assertIn("PlotBarChart", custom_agent["spec"]["tools"])
        health_agent = extras["subagents"][1]
        self.assertEqual(health_agent["metadata"]["name"], "health-report-investigator")
        self.assertEqual(health_agent["spec"]["allowedSkills"], [
            "proactive-health-check",
            "email-incident-followup",
        ])
        self.assertIn("operator@example.com", health_agent["spec"]["instructions"])
        self.assertNotIn("RunAzCliWriteCommands", health_agent["spec"]["tools"])
        self.assertIn("PlotAreaChartWithCorrelation", health_agent["spec"]["tools"])
        self.assertIn("PlotBarChart", health_agent["spec"]["tools"])
        self.assertEqual(len(extras["incidentFilters"]), 1)
        response_plan = extras["incidentFilters"][0]
        self.assertEqual(response_plan["metadata"]["name"], "alert-investigation")
        self.assertEqual(response_plan["spec"]["priorities"], ["Sev1", "Sev2"])
        self.assertEqual(response_plan["spec"]["titleContains"], "flu")
        self.assertEqual(response_plan["spec"]["handlingAgent"], "alert-investigator")
        self.assertEqual(response_plan["spec"]["agentMode"], "Review")
        self.assertEqual(response_plan["spec"]["mergeWindowHours"], 3)
        self.assertNotIn("deepInvestigationEnabled", response_plan["spec"])

        self.assertEqual(len(extras["scheduledTasks"]), 1)
        scheduled_task = extras["scheduledTasks"][0]
        self.assertEqual(scheduled_task["metadata"]["name"], "reservation-daily-health-report")
        self.assertEqual(scheduled_task["spec"]["schedule"], "0 9 * * 1-5")
        self.assertEqual(scheduled_task["spec"]["mode"], "Review")
        self.assertTrue(scheduled_task["spec"]["enabled"])
        self.assertEqual(
            scheduled_task["spec"]["handlingAgent"],
            "health-report-investigator",
        )

        self.assertNotIn("httpTriggers", extras)
        self.assertNotIn("enableWebhookBridge", extras)

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

    def test_rejects_disabled_scheduled_task(self):
        document = yaml.safe_load(TEMPLATE.read_text())
        scheduled_task = yaml.safe_load(SCHEDULED_TASK.read_text())
        scheduled_task["trigger"]["enabled"] = False
        with self.assertRaisesRegex(SystemExit, "must be true"):
            self._render_document(document, scheduled_task)

    def test_rejects_scheduled_task_agent_mismatch(self):
        document = yaml.safe_load(TEMPLATE.read_text())
        scheduled_task = yaml.safe_load(SCHEDULED_TASK.read_text())
        scheduled_task["trigger"]["handling_agent"] = "another-agent"
        with self.assertRaisesRegex(SystemExit, "handling_agent must match"):
            self._render_document(document, scheduled_task)

    def test_rejects_invalid_notification_email_recipient(self):
        with self.assertRaisesRegex(SystemExit, "valid email address"):
            renderer.render(TEMPLATE, "not-an-email")

    def test_requires_recipient_placeholder_in_both_scopes(self):
        document = yaml.safe_load(TEMPLATE.read_text())
        scheduled_task = yaml.safe_load(SCHEDULED_TASK.read_text())
        scheduled_task["custom_agent"]["instructions"] = "Run the health check."
        with self.assertRaisesRegex(SystemExit, "scheduled_task.custom_agent.instructions must include"):
            self._render_document(document, scheduled_task)

    def _render_document(self, document, scheduled_task=None):
        scheduled_task_path = None
        if scheduled_task is not None:
            with tempfile.NamedTemporaryFile(
                mode="w", suffix=".yaml", dir=SCHEDULED_TASK.parent, delete=False
            ) as stream:
                scheduled_task_path = Path(stream.name)
                scheduled_task_path.write_text(yaml.safe_dump(scheduled_task))
            document["scheduled_task"] = f"./scheduled-tasks/{scheduled_task_path.name}"
        with tempfile.NamedTemporaryFile(
            mode="w", suffix=".yaml", dir=TEMPLATE.parent, delete=False
        ) as stream:
            template = Path(stream.name)
            template.write_text(yaml.safe_dump(document))
        try:
            return renderer.render(template, "operator@example.com")
        finally:
            template.unlink(missing_ok=True)
            if scheduled_task_path is not None:
                scheduled_task_path.unlink(missing_ok=True)


class PullRequestValidationTemplateTests(unittest.TestCase):
    def test_current_template_renders_only_pr_validation_resources(self):
        extras = pr_renderer.render(PR_VALIDATION)

        self.assertEqual([item["metadata"]["name"] for item in extras["skills"]], [
            "ticketing-pr-validation",
        ])
        self.assertEqual(len(extras["subagents"]), 1)
        agent = extras["subagents"][0]
        self.assertEqual(agent["metadata"]["name"], "pr-validator")
        self.assertEqual(agent["spec"]["allowedSkills"], ["ticketing-pr-validation"])
        self.assertIn("FetchGithubIssue", agent["spec"]["tools"])
        self.assertIn("PlotAreaChartWithCorrelation", agent["spec"]["tools"])
        self.assertNotIn("RunAzCliWriteCommands", agent["spec"]["tools"])

        self.assertEqual(len(extras["httpTriggers"]), 1)
        trigger = extras["httpTriggers"][0]
        self.assertEqual(trigger["name"], "ticketing-pr-validation")
        self.assertEqual(trigger["spec"]["handlingAgent"], "pr-validator")
        self.assertEqual(trigger["spec"]["agentMode"], "Review")
        self.assertTrue(extras["enableWebhookBridge"])
        self.assertNotIn("incidentFilters", extras)
        self.assertNotIn("scheduledTasks", extras)

    def test_rejects_agent_mismatch(self):
        document = yaml.safe_load(PR_VALIDATION.read_text())
        document["trigger"]["handling_agent"] = "another-agent"
        with self.assertRaisesRegex(SystemExit, "handling_agent must match"):
            self._render_document(document)

    def test_rejects_non_review_mode(self):
        document = yaml.safe_load(PR_VALIDATION.read_text())
        document["trigger"]["action_mode"] = "Auto"
        with self.assertRaisesRegex(SystemExit, "must be Review"):
            self._render_document(document)

    def test_rejects_skill_source_outside_workflow_directory(self):
        document = yaml.safe_load(PR_VALIDATION.read_text())
        document["custom_agent"]["skills"][0]["source"] = "../../../README.md"
        with self.assertRaisesRegex(SystemExit, "skill source must be a file under"):
            self._render_document(document)

    def _render_document(self, document):
        with tempfile.NamedTemporaryFile(
            mode="w", suffix=".yaml", dir=PR_VALIDATION.parent, delete=False
        ) as stream:
            template = Path(stream.name)
            template.write_text(yaml.safe_dump(document))
        try:
            return pr_renderer.render(template)
        finally:
            template.unlink(missing_ok=True)


if __name__ == "__main__":
    unittest.main()
