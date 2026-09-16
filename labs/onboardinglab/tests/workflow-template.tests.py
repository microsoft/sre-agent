#!/usr/bin/env python3

import importlib.util
import tempfile
import unittest
from pathlib import Path

import yaml


LAB_ROOT = Path(__file__).resolve().parent.parent
RENDERER = LAB_ROOT / "scripts/internal/render-workflow-template.py"
TEMPLATE = LAB_ROOT / "workflow-templates/incidentinvestigation-workflowtemplate.yaml"

spec = importlib.util.spec_from_file_location("workflow_renderer", RENDERER)
renderer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(renderer)


class WorkflowTemplateTests(unittest.TestCase):
    def test_current_template_renders_expected_agent_resources(self):
        extras = renderer.render(TEMPLATE)

        self.assertEqual([item["metadata"]["name"] for item in extras["skills"]], [
            "azure-monitor-rca",
            "github-issue-followup",
            "email-incident-followup",
        ])
        self.assertEqual(len(extras["subagents"]), 1)
        custom_agent = extras["subagents"][0]
        self.assertEqual(custom_agent["metadata"]["name"], "alert-investigator")
        self.assertIn("SearchMemory", custom_agent["spec"]["tools"])
        self.assertNotIn("RunAzCliWriteCommands", custom_agent["spec"]["tools"])
        self.assertEqual(custom_agent["spec"]["allowedSkills"], [
            "azure-monitor-rca",
            "github-issue-followup",
            "email-incident-followup",
        ])

        self.assertEqual(len(extras["incidentFilters"]), 1)
        response_plan = extras["incidentFilters"][0]
        self.assertEqual(response_plan["metadata"]["name"], "alert-investigation")
        self.assertEqual(response_plan["spec"]["priorities"], ["Sev1", "Sev2"])
        self.assertEqual(response_plan["spec"]["titleContains"], "flu")
        self.assertEqual(response_plan["spec"]["handlingAgent"], "alert-investigator")
        self.assertEqual(response_plan["spec"]["agentMode"], "Review")
        self.assertEqual(response_plan["spec"]["mergeWindowHours"], 3)
        self.assertNotIn("deepInvestigationEnabled", response_plan["spec"])

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

    def _render_document(self, document):
        with tempfile.NamedTemporaryFile(
            mode="w", suffix=".yaml", dir=TEMPLATE.parent, delete=False
        ) as stream:
            template = Path(stream.name)
            template.write_text(yaml.safe_dump(document))
        try:
            return renderer.render(template)
        finally:
            template.unlink(missing_ok=True)


if __name__ == "__main__":
    unittest.main()
