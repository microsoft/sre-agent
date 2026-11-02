"""Exercise both setup entry points with local CLI doubles; no cloud access."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
TENANT = "11111111-1111-1111-1111-111111111111"
OBJECT = "22222222-2222-2222-2222-222222222222"
RESOURCE = (
    f"/subscriptions/{TENANT}/resourceGroups/test/"
    "providers/Microsoft.ManagedIdentity/userAssignedIdentities/test"
)
PROJECT = "sre-test-project"
POOL = "projects/123456789012/locations/global/workloadIdentityPools/sre-agent-pool"
PRINCIPAL = f"principal://iam.googleapis.com/{POOL}/subject/{TENANT}::{OBJECT}"


def cli_double(command, args):
    case = json.loads(os.environ["GCP_SETUP_TEST_CASE"])
    scope = case["scope"]
    scope_id = PROJECT if scope == "project" else "987654321"
    parent = f"{'projects' if scope == 'project' else 'organizations'}/{scope_id}"
    output = Path(os.environ["GCP_SETUP_TEST_OUTPUT"])
    with (output / "commands.jsonl").open("a", encoding="utf-8") as log:
        log.write(json.dumps([command, *args]) + "\n")

    if command == "az":
        return {"tenantId": TENANT, "principalId": OBJECT}
    if command == "gcloud":
        if args[:2] == ["auth", "list"]:
            return [{"account": "test@example.invalid"}]
        if args[:3] == ["config", "get", "project"]:
            return PROJECT
        if args[:2] == ["projects", "describe"]:
            return {"projectId": PROJECT, "projectNumber": "123456789012"}
        if args[:2] == ["services", "list"]:
            return [
                {"config": {"name": name}}
                for name in ("serviceusage.googleapis.com", "iam.googleapis.com")
            ]
        if args[:3] == ["iam", "workload-identity-pools", "list"]:
            return []
        if args[:3] == ["iam", "roles", "list"]:
            return (
                [{"name": f"{parent}/roles/{role}"} for role in ("readSRE", "writeSRE")]
                if case["existing"]
                else []
            )
        if args[:3] == ["iam", "roles", "describe"]:
            return {"name": f"{parent}/roles/{args[3]}", "stage": "GA"}
        if args[1:2] == ["get-iam-policy"]:
            bindings = []
            if case["existing"]:
                for role in ("readSRE", "writeSRE", "SREAgentRole"):
                    binding = {
                        "role": f"{parent}/roles/{role}",
                        "members": ["user:other@example.invalid"],
                    }
                    if not case.get("other_only"):
                        binding["members"].append(PRINCIPAL)
                    if role == case.get("conditional"):
                        binding["condition"] = {
                            "title": "test",
                            "expression": "true",
                        }
                    bindings.append(binding)
            return {"bindings": bindings}
        if args[:2] == ["auth", "print-access-token"]:
            return "local-test-token"
    if command == "terraform":
        if args[:1] == ["version"]:
            return {"terraform_version": "1.7.0"}
        if args[:1] == ["import"]:
            config = json.loads(Path("revocations.tf.json").read_text())
            with (output / "revocations.json").open("w", encoding="utf-8") as target:
                json.dump(config, target)
            if case.get("import_failure"):
                print("Simulated import failure", file=sys.stderr)
                sys.exit(1)
            return ""
        if args[:1] == ["apply"]:
            if Path("revocations.tf.json").exists():
                raise AssertionError("Revocation configuration must be removed before apply")
            for name in ("guided.auto.tfvars.json", "imports.tf", "readSRE.json", "writeSRE.json"):
                shutil.copyfile(name, output / name)
            return ""
        if args[:1] == ["output"]:
            roles = ["readSRE"] + (["writeSRE"] if case["mode"] == "read-write" else [])
            return {
                "assigned_role_names": {"value": [f"{parent}/roles/{role}" for role in roles]},
                "workload_identity_provider": {"value": f"{POOL}/providers/sre-agent-provider"},
                "principal_id": {"value": PRINCIPAL},
            }
        if args[:1] == ["init"] or args[:1] == ["workspace"]:
            return ""
    raise AssertionError(f"Unexpected command: {command} {args}")


class SetupTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.pwsh = shutil.which("pwsh")
        cls.bash = shutil.which("bash")
        cls.python = sys.executable
        if not cls.pwsh or not cls.bash or not shutil.which("jq"):
            raise RuntimeError("Tests require PowerShell 7, Bash, Python, and jq on PATH")

    def run_setup(self, shell, **case):
        with tempfile.TemporaryDirectory(prefix="gcp-setup-test-") as directory:
            temp = Path(directory)
            bin_dir = temp / "bin"
            bin_dir.mkdir()
            stub = Path(__file__).resolve()
            for name in ("az", "gcloud", "terraform"):
                # PowerShell uses .cmd doubles on Windows; Bash uses executable shell doubles.
                if os.name == "nt":
                    (bin_dir / f"{name}.cmd").write_text(
                        f'@"{self.python}" "{stub}" --stub {name} %*\n',
                        encoding="utf-8",
                    )
                launcher = bin_dir / name
                launcher.write_text(
                    '#!/usr/bin/env bash\n'
                    f'exec "{Path(self.python).as_posix()}" "{stub.as_posix()}" --stub {name} "$@"\n',
                    encoding="utf-8",
                )
                launcher.chmod(0o755)
            env = os.environ.copy()
            env["PATH"] = str(bin_dir) + os.pathsep + env["PATH"]
            env["GCP_SETUP_TEST_CASE"] = json.dumps(case)
            env["GCP_SETUP_TEST_OUTPUT"] = str(temp)
            if shell == "pwsh":
                args = [
                    self.pwsh, "-NoProfile", "-File", str(ROOT / "setup.ps1"),
                    "-ResourceId", RESOURCE, "-AllowedPermissions", case["mode"],
                    "-SkipApproval", "true", "-AssignmentScope", case["scope"],
                ]
                if case["scope"] == "organization":
                    args += ["-OrganizationId", "987654321"]
            else:
                args = [
                    self.bash, (ROOT / "setup.sh").as_posix(),
                    "--resource-id", RESOURCE, "--allowed-permissions", case["mode"],
                    "--skip-approval", "true", "--assignment-scope", case["scope"],
                ]
                if case["scope"] == "organization":
                    args += ["--organization-id", "987654321"]
            result = subprocess.run(args, env=env, text=True, capture_output=True, timeout=90)
            files = {
                name: (temp / name).read_text(encoding="utf-8-sig")
                for name in (
                    "commands.jsonl", "guided.auto.tfvars.json", "imports.tf",
                    "revocations.json", "readSRE.json", "writeSRE.json",
                )
                if (temp / name).exists()
            }
            return result, files

    def test_assignment_modes_and_migration(self):
        for shell in ("pwsh", "bash"):
            for scope in ("project", "organization"):
                for mode in ("read-only", "read-write"):
                    for existing in (False, True):
                        with self.subTest(shell=shell, scope=scope, mode=mode, existing=existing):
                            result, files = self.run_setup(
                                shell, scope=scope, mode=mode, existing=existing,
                            )
                            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                            variables = json.loads(files["guided.auto.tfvars.json"])
                            self.assertEqual(variables["access_mode"], mode)
                            self.assertEqual(variables["assignment_scope"], scope)
                            self.assertEqual(variables["uami_object_id"], OBJECT)
                            self.assertNotIn("existing_role_permissions", variables)
                            for role in ("readSRE", "writeSRE"):
                                self.assertEqual(
                                    json.loads(files[f"{role}.json"]),
                                    json.loads((ROOT / f"{role}.json").read_text()),
                                )
                                address = f'google_{scope}_iam_custom_role.sre_agent["{role}"]'
                                self.assertEqual(address in files["imports.tf"], existing)
                                address = f'google_{scope}_iam_member.sre_agent["{role}"]'
                                self.assertEqual(
                                    address in files["imports.tf"],
                                    existing and (role == "readSRE" or mode == "read-write"),
                                )
                            if existing:
                                resource = json.loads(files["revocations.json"])["resource"]
                                revoked = resource[f"google_{scope}_iam_member"]["revoked"]
                                self.assertEqual(revoked["member"], PRINCIPAL)
                                self.assertEqual(
                                    set(revoked["for_each"]),
                                    {"SREAgentRole", "writeSRE"} if mode == "read-only" else {"SREAgentRole"},
                                )
                                commands = [json.loads(line) for line in files["commands.jsonl"].splitlines()]
                                imports = [c for c in commands if c[:2] == ["terraform", "import"]]
                                self.assertEqual(len(imports), len(revoked["for_each"]))
                                self.assertTrue(all(PRINCIPAL in c[-1] for c in imports))
                                self.assertTrue(all("user:other" not in c[-1] for c in imports))
                            else:
                                self.assertNotIn("revocations.json", files)

    def test_other_identities_are_not_revoked(self):
        for shell in ("pwsh", "bash"):
            with self.subTest(shell=shell):
                result, files = self.run_setup(
                    shell, scope="project", mode="read-only", existing=True, other_only=True,
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertNotIn("revocations.json", files)
                self.assertNotIn("iam_member.sre_agent", files["imports.tf"])

    def test_conditional_grants_block_unsafe_removal(self):
        for shell in ("pwsh", "bash"):
            for role in ("writeSRE", "SREAgentRole"):
                with self.subTest(shell=shell, role=role):
                    result, files = self.run_setup(
                        shell, scope="project", mode="read-only", existing=True, conditional=role,
                    )
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(f"conditional {role} assignment", result.stdout + result.stderr)
                    self.assertNotIn("guided.auto.tfvars.json", files)

    def test_import_failure_stops_apply(self):
        for shell in ("pwsh", "bash"):
            with self.subTest(shell=shell):
                result, files = self.run_setup(
                    shell, scope="project", mode="read-only", existing=True, import_failure=True,
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("guided.auto.tfvars.json", files)


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--stub":
        value = cli_double(sys.argv[2], sys.argv[3:])
        print(value if isinstance(value, str) else json.dumps(value))
    else:
        unittest.main()
