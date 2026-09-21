"""Offline contracts for the learner guide, separate from live agent validation."""

import json
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

    def test_readme_restores_participant_driven_three_scenario_flow(self):
        readme = (LAB / "README.md").read_text(encoding="utf-8")
        for heading in (
            "## 1. Deploy the workload and final agent",
            "### Finalize deployment access",
            "## 2. Clone the repository and install the workflows",
            "### Install the incident and health workflows",
            "## Scenario 1: Incident workflow",
            "## Scenario 2: Scheduled health check and Live Report",
            "## Scenario 3: Pull-request validation",
        ):
            with self.subTest(heading=heading):
                self.assertIn(heading, readme)
        self.assertIn("participant-driven", readme)
        self.assertIn("git clone https://github.com/microsoft/sre-agent.git", readme)
        self.assertIn("install-workflow-template", readme)
        self.assertIn("install-pr-validation", readme)

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
        self.assertIn("read-only incident response workflow", readme)

    def test_readme_presents_equal_workload_options_and_postgresql_limitation(self):
        readme = (LAB / "README.md").read_text(encoding="utf-8")
        self.assertIn("## Choose a workload option", readme)
        self.assertNotIn("neither option is preferred", readme)
        self.assertIn("**App Service**", readme)
        self.assertIn("**App Service + PostgreSQL**", readme)
        self.assertIn("PostgreSQL 16 with `Standard_B1ms` in Sweden Central", readme)
        self.assertIn("does not silently change the selected option", readme)
        self.assertIn("| **1. Incident workflow** |", readme)
        self.assertIn("| **2. Scheduled health check and Live Report** |", readme)
        self.assertIn("| **3. Pull-request validation** |", readme)
        self.assertIn("$WorkloadOption", readme)
        self.assertIn('--workload-option "$workload_option"', readme)

    def test_readme_documents_temporary_access_and_fallback_request(self):
        readme = (LAB / "README.md").read_text(encoding="utf-8")
        self.assertIn("**Privileged** permissions in **Review**", readme)
        self.assertIn("**Reader** permissions", readme)
        self.assertIn("`High` and `Low` access", readme)
        self.assertIn("temporary **Owner** access", readme)
        self.assertIn("automatically removes temporary Owner", readme)
        self.assertIn("Office 365 Outlook", readme)
        self.assertIn("Outlook authentication remains interactive", readme)
        self.assertIn("- WORKLOAD_OPTION: <app-service OR app-service-postgresql>", readme)
        self.assertIn("* Report when external finalization is safe.", readme)
        self.assertNotIn("PR #341", readme)

    def test_agent_driven_setup_uses_one_agent_and_external_finalization(self):
        bootstrap = (LAB / "scripts/bootstrap-agent.ps1").read_text(encoding="utf-8")
        runbook = (LAB / "agent-deploy-runbook.md").read_text(encoding="utf-8")
        infrastructure = (LAB / "infra/main.bicep").read_text(encoding="utf-8")
        compiled_infrastructure = LAB / "infra/main.arm.json"
        deployment_script = (LAB / "scripts/deploy-agent.sh").read_text(encoding="utf-8")

        self.assertFalse((LAB / "scripts/bootstrap-labcreator.ps1").exists())
        self.assertIn("[switch] $Finalize", bootstrap)
        self.assertIn("'--role', 'Owner'", bootstrap)
        self.assertIn("'role', 'assignment', 'delete'", bootstrap)
        self.assertIn("accessLevel = 'Low'", bootstrap)
        self.assertIn("function Wait-ForVerifiedDeployment", bootstrap)
        self.assertIn("Automatically finalizing deployment access", bootstrap)
        self.assertIn("Using default lab resource group", bootstrap)
        self.assertNotIn("Resource group for the lab [SreAgentOnboardingLabRG]", bootstrap)
        self.assertIn("optional/connectorv2/outlook.yaml", deployment_script)
        self.assertIn('"ListOutlookEmails"', deployment_script)
        self.assertIn('"SendOutlookEmail"', deployment_script)
        self.assertIn("function Get-KnowledgeResourceName", bootstrap)
        self.assertNotIn("onboardinglab-incident-r-2bcbfae", bootstrap)
        self.assertIn("/api/v2/repos", bootstrap)
        self.assertIn("No connected repository was found", bootstrap)
        self.assertIn("'--assignee-principal-type', 'User'", bootstrap)
        self.assertIn("'--role', 'SRE Agent Administrator'", bootstrap)
        self.assertIn("https://azuresre.dev/.default", bootstrap)
        self.assertNotIn("--use-device-code", bootstrap)
        self.assertIn("Automatic thread creation is unavailable", bootstrap)
        self.assertIn("onboardingLabDeploymentStatus", bootstrap)
        for provider in (
            "Microsoft.App",
            "Microsoft.Authorization",
            "Microsoft.DBforPostgreSQL",
            "Microsoft.Insights",
            "Microsoft.ManagedIdentity",
            "Microsoft.Network",
            "Microsoft.OperationalInsights",
            "Microsoft.Web",
        ):
            self.assertIn(f"'{provider}'", bootstrap)
        self.assertIn("Keep the operator informed", runbook)
        self.assertIn(
            "supportedServerEditions[]?.supportedServerSkus[]?.name",
            deployment_script,
        )
        self.assertNotIn("[?name=='Standard_B1ms']", deployment_script)
        self.assertIn(
            "deployment script once",
            bootstrap,
        )
        self.assertIn("First find the local workspace directory", bootstrap)
        self.assertIn("wait and retry periodically", bootstrap)
        self.assertIn("do not", bootstrap.lower())
        self.assertNotIn("Work through every step", bootstrap)
        self.assertIn("* Report when external finalization is safe.", bootstrap)
        self.assertNotIn("*.bicep.azure.com", bootstrap)
        self.assertIn(
            "https://sre.azure.com/agents/subscriptions/$subId/resourceGroups/"
            "$LabResourceGroup/providers/Microsoft.App/agents/$AgentName",
            bootstrap,
        )
        self.assertNotIn("https://sre.azure.com/#/agent/", bootstrap)
        self.assertNotIn("https://sre.azure.com/#/agent/", runbook)

        finalize = bootstrap[
            bootstrap.index("if ($Finalize) {"):
            bootstrap.index("# ── Step 1: register resource providers")
        ]
        self.assertIn(
            "Invoke-Az @('role', 'assignment', 'delete', '--ids', $ownerAssignmentId)",
            finalize,
        )
        self.assertNotIn("$signedInUserObjectId", finalize)
        self.assertLess(
            finalize.index("onboardingLabDeploymentStatus"),
            finalize.index("Invoke-Az @('role', 'assignment', 'delete'"),
        )

        self.assertIn("deploy-agent.sh", runbook)
        self.assertIn("## Locate the repository", runbook)
        self.assertIn("do not\nclone a second copy", runbook)
        self.assertIn("Do not duplicate", runbook)
        self.assertTrue(deployment_script.startswith("#!/usr/bin/env bash\naz login --identity --client-id"))
        self.assertIn('available_kb="$(df -Pk /tmp', deployment_script)
        self.assertIn("from zipfile import ZIP_DEFLATED, ZipFile", deployment_script)
        self.assertIn("--template-file \"$TEMPLATE\"", deployment_script)
        self.assertIn("--async true", deployment_script)
        self.assertIn("az webapp log deployment list", deployment_script)
        self.assertIn("monitoring it instead of uploading again", deployment_script)
        self.assertIn("already succeeded; reusing the completed application deployment", deployment_script)
        self.assertIn("Waiting for the SRE Agent data-plane endpoint", deployment_script)
        self.assertIn("Database fault rule is Allow.", deployment_script)
        self.assertIn("FAILED during $CURRENT_STAGE", deployment_script)
        self.assertIn("az deployment operation group list", deployment_script)
        self.assertIn("infrastructure_failure_is_workspace_propagation", deployment_script)
        self.assertIn('contains("workspace could not be found")', deployment_script)
        self.assertIn("attempt ${infrastructure_attempt}/3", deployment_script)
        self.assertIn("Failed OneDeploy record", deployment_script)
        self.assertIn("/tmp/onboardinglab-deploy.log", deployment_script)
        self.assertIn("Apply-Extras.ps1", deployment_script)
        self.assertIn("Verify-Agent.ps1", deployment_script)
        self.assertIn("del(.incidentPlatforms, .toolPermissions)", deployment_script)
        self.assertIn('.agent.accessLevel = "High"', deployment_script)
        self.assertIn('.agent.actionMode = "Review"', deployment_script)
        self.assertIn("Permanent action-identity and system-identity roles are present.", deployment_script)
        self.assertIn("wait_for_role_assignments", deployment_script)
        self.assertIn("Waiting for permanent RBAC propagation", deployment_script)
        self.assertIn("reconciling the current Bicep-authored template", deployment_script)
        self.assertNotIn("reusing its verified outputs", deployment_script)
        self.assertIn("Applying the durable tool policy after workload and telemetry verification.", deployment_script)
        self.assertLess(
            deployment_script.index("Waiting for Application Insights telemetry."),
            deployment_script.index("Applying the durable tool policy after workload and telemetry verification."),
        )
        self.assertIn("onboardingLabDeploymentStatus=verified", deployment_script)
        self.assertIn("External finalization is safe", deployment_script)
        self.assertIn("module workload", infrastructure)
        self.assertIn("module agentConfiguration", infrastructure)
        compiled = json.loads(compiled_infrastructure.read_text(encoding="utf-8"))
        self.assertEqual(compiled["$schema"].split("/")[-1], "deploymentTemplate.json#")
        self.assertTrue(compiled["resources"])

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
