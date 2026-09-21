#!/usr/bin/env python3

import importlib.util
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parent.parent / "scripts/configure-pr-validation-repository.py"
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


if __name__ == "__main__":
    unittest.main()