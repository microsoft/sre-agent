#!/usr/bin/env python3
"""Exercise preflight with mocked CLIs; no GitHub or Azure calls are made."""

import errno
import os
from pathlib import Path
import pty
import select
import subprocess
import tempfile
import time
import unittest


LAB_DIR = Path(__file__).resolve().parents[1]


class PreflightTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.log = self.root / "calls"
        self.env = {
            **os.environ,
            "PATH": f"{self.root}:/usr/bin:/bin",
            "CALL_LOG": str(self.log),
            "FORK_STATE": str(self.root / "fork"),
            "GITHUB_USER": "",
            "TEST_USER": "octocat",
            "TEST_EXISTS": "true",
            "TEST_PARENT": "dm-chelupati/grubify",
            "TEST_FAILURE": "",
        }
        self.write_cli("azd", """#!/usr/bin/env bash
set -eu
echo "azd $*" >> "$CALL_LOG"
case "$*" in
  "env get-value GITHUB_USER")
    case "$TEST_FAILURE" in
      missing-key)
        printf "\\nERROR: key not found in environment values: 'GITHUB_USER'\\n\\nSuggestion: Run 'azd env get-values' to see available keys.\\n"
        exit 1 ;;
      env)
        echo "ERROR: failed to load azd environment"
        exit 1 ;;
    esac
    echo "${TEST_CONFIG_USER:-}" ;;
  "env set GITHUB_USER octocat") ;;
  *) echo "Unexpected azd call: $*" >&2; exit 1 ;;
esac
""")
        self.write_cli("gh", """#!/usr/bin/env bash
set -eu
echo "gh $*" >> "$CALL_LOG"
case "$*" in
  "auth status --hostname github.com")
    if [ "$TEST_FAILURE" = auth ]; then echo "authentication failed" >&2; exit 1; fi ;;
  "auth refresh --hostname github.com -s delete_repo")
    if [ "$TEST_FAILURE" = scope-auth ]; then echo "authorization failed" >&2; exit 1; fi
    touch "$FORK_STATE.auth" ;;
  "api --hostname github.com user --jq .login") echo "$TEST_USER" ;;
  "api --hostname github.com --paginate user/repos?affiliation=owner&per_page=100 --jq "*)
    if [ "$TEST_FAILURE" = list ]; then echo "HTTP 503" >&2; exit 1; fi
    if [ "$TEST_EXISTS" = true ]; then echo "octocat/grubify"; fi ;;
  "repo view github.com/octocat/grubify --json isFork,parent --jq "*)
    if [ "$TEST_EXISTS" != true ] && [ ! -f "$FORK_STATE" ]; then
      echo "repository unavailable" >&2; exit 1
    fi
    echo "$TEST_PARENT" ;;
  "repo fork github.com/dm-chelupati/grubify --clone=false")
    if [ "$TEST_FAILURE" = fork ]; then echo "fork failed" >&2; exit 1; fi
    touch "$FORK_STATE" ;;
  "repo delete github.com/octocat/grubify --yes")
    if [[ "$TEST_FAILURE" == scope* ]] && [ ! -f "$FORK_STATE.auth" ]; then
      echo 'HTTP 403: Must have admin rights to Repository.' >&2
      echo 'This API operation needs the "delete_repo" scope.' >&2
      exit 1
    fi
    if [[ "$TEST_FAILURE" = delete || "$TEST_FAILURE" = scope-retry ]]; then
      echo "delete permission denied" >&2; exit 1
    fi ;;
  "repo edit github.com/octocat/grubify --enable-issues")
    if [ "$TEST_FAILURE" = issues ]; then echo "issues permission denied" >&2; exit 1; fi ;;
  *) echo "Unexpected gh call: $*" >&2; exit 1 ;;
esac
""")

    def write_cli(self, name, content):
        path = self.root / name
        path.write_text(content)
        path.chmod(0o755)

    def run_preflight(self, *, answers=None, flags=(), **env):
        self.log.unlink(missing_ok=True)
        (self.root / "fork").unlink(missing_ok=True)
        (self.root / "fork.auth").unlink(missing_ok=True)
        command = ["bash", str(LAB_DIR / "scripts/preflight.sh"), *flags]
        environment = {**self.env, **env}
        if answers is None:
            result = subprocess.run(
                command, env=environment, input="", text=True,
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=10,
            )
            status, output = result.returncode, result.stdout
        else:
            master, slave = pty.openpty()
            try:
                with subprocess.Popen(
                    command, env=environment, stdin=slave, stdout=slave, stderr=slave
                ) as process:
                    os.close(slave)
                    slave = None
                    os.write(master, answers.encode())
                    chunks = []
                    deadline = time.monotonic() + 10
                    while True:
                        if time.monotonic() > deadline:
                            process.kill()
                            self.fail("Interactive preflight timed out")
                        if not select.select([master], [], [], 0.1)[0]:
                            continue
                        try:
                            data = os.read(master, 4096)
                        except OSError as error:
                            if error.errno != errno.EIO:
                                raise
                            break
                        if not data:
                            break
                        chunks.append(data)
                    status = process.wait(timeout=2)
                    output = b"".join(chunks).decode()
            finally:
                if slave is not None:
                    os.close(slave)
                os.close(master)
        calls = self.log.read_text() if self.log.exists() else ""
        return status, output, calls

    def test_core_only_needs_no_github(self):
        status, output, calls = self.run_preflight()
        self.assertEqual(status, 0, output)
        self.assertIn("skipped", output)
        self.assertNotIn("gh ", calls)

    def test_missing_azd_key_prompts_for_username(self):
        status, output, calls = self.run_preflight(
            TEST_FAILURE="missing-key", answers="octocat\nkeep\n"
        )
        self.assertEqual(status, 0, output)
        self.assertIn("GitHub username", output)
        self.assertIn("env set GITHUB_USER octocat", calls)

    def test_missing_azd_key_can_be_skipped(self):
        status, output, calls = self.run_preflight(
            TEST_FAILURE="missing-key", answers="\n"
        )
        self.assertEqual(status, 0, output)
        self.assertIn("skipped", output)
        self.assertNotIn("gh ", calls)

    def test_other_azd_errors_are_reported(self):
        status, output, calls = self.run_preflight(TEST_FAILURE="env")
        self.assertNotEqual(status, 0, output)
        self.assertIn("failed to load azd environment", output)
        self.assertNotIn("gh ", calls)

    def test_existing_fork_kept_noninteractively(self):
        status, output, calls = self.run_preflight(TEST_CONFIG_USER="OctoCat")
        self.assertEqual(status, 0, output)
        self.assertIn("repo edit github.com/octocat/grubify --enable-issues", calls)
        self.assertIn("env set GITHUB_USER octocat", calls)
        self.assertNotIn("repo delete", calls)
        self.assertNotIn("repo fork", calls)

    def test_prompt_for_username_and_fork(self):
        status, output, calls = self.run_preflight(
            answers="octocat\ny\n", TEST_EXISTS="false"
        )
        self.assertEqual(status, 0, output)
        self.assertIn("repo fork github.com/dm-chelupati/grubify", calls)
        self.assertIn("repo view github.com/octocat/grubify", calls)

    def test_missing_fork_fails_without_confirmation(self):
        for answers in (None, "n\n"):
            with self.subTest(answers=answers):
                status, output, calls = self.run_preflight(
                    GITHUB_USER="octocat", TEST_EXISTS="false", answers=answers
                )
                self.assertNotEqual(status, 0, output)
                self.assertNotIn("repo fork", calls)
                self.assertNotIn("env set", calls)

    def test_recreate_requires_matching_name(self):
        status, output, calls = self.run_preflight(
            GITHUB_USER="octocat", answers="recreate\nwrong/repo\n"
        )
        self.assertNotEqual(status, 0, output)
        self.assertNotIn("repo delete", calls)

    def test_confirmed_recreation(self):
        status, output, calls = self.run_preflight(
            GITHUB_USER="octocat", answers="recreate\noctocat/grubify\n"
        )
        self.assertEqual(status, 0, output)
        self.assertLess(calls.index("repo delete"), calls.index("repo fork"))
        self.assertLess(calls.index("repo fork"), calls.index("repo edit"))

    def test_missing_delete_scope_can_be_requested_and_retried(self):
        status, output, calls = self.run_preflight(
            GITHUB_USER="octocat", TEST_FAILURE="scope",
            answers="recreate\noctocat/grubify\ny\n",
        )
        self.assertEqual(status, 0, output)
        self.assertEqual(calls.count("repo delete"), 2)
        self.assertLess(calls.index("auth refresh"), calls.rindex("repo delete"))
        self.assertLess(calls.rindex("repo delete"), calls.index("repo fork"))

    def test_missing_delete_scope_can_be_declined(self):
        status, output, calls = self.run_preflight(
            GITHUB_USER="octocat", TEST_FAILURE="scope",
            answers="recreate\noctocat/grubify\nn\n",
        )
        self.assertNotEqual(status, 0, output)
        self.assertIn("nothing was deleted", output)
        self.assertEqual(calls.count("repo delete"), 1)
        self.assertNotIn("auth refresh", calls)
        self.assertNotIn("repo fork", calls)

    def test_permission_refresh_and_retry_failures_stop_recreation(self):
        for failure, attempts in (("scope-auth", 1), ("scope-retry", 2)):
            with self.subTest(failure=failure):
                status, output, calls = self.run_preflight(
                    GITHUB_USER="octocat", TEST_FAILURE=failure,
                    answers="recreate\noctocat/grubify\ny\n",
                )
                self.assertNotEqual(status, 0, output)
                self.assertEqual(calls.count("repo delete"), attempts)
                self.assertNotIn("repo fork", calls)
                self.assertNotIn("env set", calls)

    def test_explicit_recreation_still_requires_interactive_confirmation(self):
        status, output, calls = self.run_preflight(
            GITHUB_USER="octocat", flags=("--recreate-fork",)
        )
        self.assertNotEqual(status, 0, output)
        self.assertNotIn("repo delete", calls)

    def test_explicit_recreation_prompt(self):
        status, output, calls = self.run_preflight(
            GITHUB_USER="octocat", flags=("--recreate-fork",),
            answers="octocat/grubify\n",
        )
        self.assertEqual(status, 0, output)
        self.assertIn("repo delete", calls)

    def test_unrelated_repository_is_never_deleted(self):
        for parent in ("someone/other", ""):
            with self.subTest(parent=parent):
                status, output, calls = self.run_preflight(
                    GITHUB_USER="octocat", TEST_PARENT=parent,
                    answers="recreate\noctocat/grubify\n",
                )
                self.assertNotEqual(status, 0, output)
                self.assertIn("not a fork", output)
                self.assertNotIn("repo delete", calls)
                self.assertNotIn("repo edit", calls)

    def test_wrong_account_is_rejected(self):
        status, output, calls = self.run_preflight(
            GITHUB_USER="octocat", TEST_USER="someone"
        )
        self.assertNotEqual(status, 0, output)
        self.assertIn("not octocat", output)
        self.assertNotIn("repo delete", calls)

    def test_cli_failures_are_not_success_or_absence(self):
        for failure, answers, exists in (
            ("auth", None, "true"), ("list", None, "true"),
            ("fork", "y\n", "false"),
            ("delete", "recreate\noctocat/grubify\n", "true"),
            ("issues", None, "true"),
        ):
            with self.subTest(failure=failure):
                status, output, calls = self.run_preflight(
                    GITHUB_USER="octocat", TEST_FAILURE=failure,
                    TEST_EXISTS=exists, answers=answers,
                )
                self.assertNotEqual(status, 0, output)
                self.assertNotIn("env set", calls)
                if failure in ("auth", "list", "delete"):
                    self.assertNotIn("repo fork", calls)
                    self.assertNotIn("auth refresh", calls)


if __name__ == "__main__":
    unittest.main()
