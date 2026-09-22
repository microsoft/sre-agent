import importlib.util
import shutil
import tempfile
import unittest
from pathlib import Path


LAB = Path(__file__).resolve().parents[1]
SCRIPT = LAB / "scripts" / "create-pr-validation-sample.py"
SOURCE = LAB / "ticketingapp-source" / "app"

spec = importlib.util.spec_from_file_location("create_pr_validation_sample", SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class CreatePrValidationSampleTests(unittest.TestCase):
    def apply(self, workload_option, scenario):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        repo = Path(temporary.name)
        (repo / "app" / "test").mkdir(parents=True)
        shutil.copy2(SOURCE / "handler.js", repo / "app" / "handler.js")
        shutil.copy2(
            SOURCE / "test" / "handler.test.js",
            repo / "app" / "test" / "handler.test.js",
        )
        module.apply_scenario(repo, workload_option, scenario)
        return (
            (repo / "app" / "handler.js").read_text(encoding="utf-8"),
            (repo / "app" / "test" / "handler.test.js").read_text(encoding="utf-8"),
        )

    def test_app_service_pass_centralizes_retry_guidance(self):
        handler, tests = self.apply("app-service", "pass")
        self.assertIn("const APP_FAULT_RETRY_SECONDS = 3;", handler)
        self.assertIn("String(APP_FAULT_RETRY_SECONDS)", handler)
        self.assertIn("assert.match(response.headers['Retry-After'], /^\\d+$/);", tests)

    def test_app_service_block_introduces_unbounded_fault_wait(self):
        handler, _ = self.apply("app-service", "block")
        self.assertIn("await new Promise(() => {});", handler)
        self.assertNotIn("success = env.APP_FAULT_ENABLED !== 'true';", handler)

    def test_postgresql_pass_tightens_shared_deadline(self):
        handler, tests = self.apply("app-service-postgresql", "pass")
        self.assertIn("const DB_TIMEOUT_MS = 4500;", handler)
        self.assertIn("tick(4499)", tests)
        self.assertIn("connectionTimeoutMillis, 4500", tests)

    def test_postgresql_block_awaits_client_cleanup(self):
        handler, _ = self.apply("app-service-postgresql", "block")
        self.assertIn("await client.end();", handler)
        self.assertNotIn("Promise.resolve(client.end()).catch(() => {});", handler)


if __name__ == "__main__":
    unittest.main()