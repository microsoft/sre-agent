"""Offline contracts for the learner guide, separate from live agent validation."""

import unittest
import re
from pathlib import Path

import yaml


LAB = Path(__file__).resolve().parents[1]


class LessonTests(unittest.TestCase):
    def test_runtime_guide_has_all_learning_checkpoints(self):
        content = (
            LAB / "agent-recipe/config/skills/onboarding-lab-guide.md"
        ).read_text(encoding="utf-8")
        for heading in ("Discover", "Investigate", "Teach", "Reuse", "Schedule", "Take away"):
            with self.subTest(heading=heading):
                self.assertIn(f"## {heading}", content)
        self.assertIn("fresh conversation", content)
        self.assertIn("read-back", content)
        self.assertIn("disable", content)
        self.assertNotIn("PostgreSqlFaultInjection", content)

    def test_guide_registration_resolves_to_content_without_tool_grants(self):
        registration = yaml.safe_load(
            (LAB / "agent-recipe/config/skills/onboarding-lab-guide.yaml").read_text()
        )
        self.assertEqual(registration["metadata"]["name"], "onboarding-lab-guide")
        self.assertEqual(registration["metadata"]["spec"]["tools"], [])
        self.assertTrue(
            (LAB / "agent-recipe/config" / registration["skillContent"]).is_file()
        )

    def test_local_assistant_entry_and_facilitator_boundaries_exist(self):
        self.assertTrue((LAB / "AGENTS.md").is_file())
        self.assertTrue((LAB / ".github/skills/onboarding-lab/SKILL.md").is_file())
        facilitator = (LAB / "docs/facilitator.md").read_text(encoding="utf-8")
        self.assertIn("facilitator", facilitator)
        self.assertIn("Namespaces do not", facilitator)
        self.assertIn("actual run", facilitator)

    def test_startup_prompt_and_skill_trigger_match(self):
        readme = (LAB / "README.md").read_text(encoding="utf-8")
        guide = (LAB / "agent-recipe/config/skills/onboarding-lab-guide.md").read_text(
            encoding="utf-8"
        )
        registration = yaml.safe_load(
            (LAB / "agent-recipe/config/skills/onboarding-lab-guide.yaml").read_text()
        )
        prompt_start = "Use onboarding-lab-guide to start the onboarding lab."
        self.assertIn(prompt_start, readme)
        self.assertIn(prompt_start, guide)
        self.assertIn("start the onboarding lab", registration["metadata"]["description"])
        self.assertIn("No slash command is required.", readme)
        self.assertIn("No slash command is required.", guide)
        self.assertIn("**New chat**", readme)
        self.assertIn("If the guide is unavailable", readme)
        self.assertIn("one next action", readme)

    def test_coaching_is_explicit_and_excluded_from_incident_skill_selection(self):
        registration = yaml.safe_load(
            (LAB / "agent-recipe/config/skills/onboarding-lab-guide.yaml").read_text()
        )
        self.assertIn("Use only", registration["metadata"]["description"])
        self.assertIn("explicitly requests", registration["metadata"]["description"])
        workflow = yaml.safe_load(
            (LAB / "workflow-templates/incidentinvestigation-workflowtemplate.yaml").read_text()
        )
        selected = [skill["name"] for skill in workflow["custom_agent"]["skills"]]
        self.assertNotIn("onboarding-lab-guide", selected)
        readme = (LAB / "README.md").read_text(encoding="utf-8")
        self.assertIn("not a blind benchmark", readme)

    def test_standard_lesson_includes_authenticated_github_and_outlook_followups(self):
        readme = (LAB / "README.md").read_text(encoding="utf-8")
        setup = (LAB / "docs/setup.md").read_text(encoding="utf-8")
        guide = (LAB / "agent-recipe/config/skills/onboarding-lab-guide.md").read_text(
            encoding="utf-8"
        )
        self.assertIn("GitHub and Outlook are part of the standard lab", readme)
        self.assertIn("Turn the investigation into follow-up work", readme)
        self.assertIn("issue link and email receipt", readme)
        self.assertIn("-Stage Connect", setup)
        self.assertIn("-CoreOnly", setup)
        self.assertIn("## Share the investigation", guide)
        self.assertIn("obtain separate approval to send", guide)

    def test_local_document_links_resolve(self):
        documents = [
            LAB / "README.md",
            LAB / "AGENTS.md",
            LAB / "agent-recipe/README.md",
            *sorted((LAB / "docs").glob("*.md")),
        ]
        for document in documents:
            for link in re.findall(r"\[[^\]]*\]\(([^)]+)\)", document.read_text(encoding="utf-8")):
                if "://" in link or link.startswith("#"):
                    continue
                with self.subTest(document=document.name, link=link):
                    self.assertTrue((document.parent / link.split("#")[0]).exists())


if __name__ == "__main__":
    unittest.main()
