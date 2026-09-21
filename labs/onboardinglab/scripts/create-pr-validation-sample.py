#!/usr/bin/env python3

import argparse
import os
import subprocess
from pathlib import Path


SCENARIOS = {
    ("app-service-postgresql", "pass"): {
        "branch": "lab/pr-validation-pass",
        "title": "Tighten checkout database deadline",
        "body": """## Summary

Reduce the shared PostgreSQL checkout deadline from five seconds to 4.5 seconds and update the focused timing assertions.

## Validation

- `npm test`
- `npm run check`

This PR is for SRE Agent validation only. Do not merge or deploy it.
""",
    },
    ("app-service-postgresql", "block"): {
        "branch": "lab/pr-validation-block",
        "title": "Wait for PostgreSQL clients to close cleanly",
        "body": """## Summary

Wait for PostgreSQL clients to finish graceful shutdown before completing checkout cleanup.

## Validation

- `npm test`
- `npm run check`

This PR is for SRE Agent validation only. Do not merge or deploy it.
""",
    },
    ("app-service", "pass"): {
        "branch": "lab/pr-validation-pass",
        "title": "Centralize checkout retry guidance",
        "body": """## Summary

Centralize the App Service checkout retry interval and verify the public response remains bounded.

## Validation

- `npm test`
- `npm run check`

This PR is for SRE Agent validation only. Do not merge or deploy it.
""",
    },
    ("app-service", "block"): {
        "branch": "lab/pr-validation-block",
        "title": "Wait for application fault recovery",
        "body": """## Summary

Wait for the App Service checkout fault to clear before returning a response.

## Validation

- `npm test`
- `npm run check`

This PR is for SRE Agent validation only. Do not merge or deploy it.
""",
    },
}


def run(*args, cwd, capture=False):
    result = subprocess.run(
        args,
        cwd=cwd,
        check=True,
        text=True,
        capture_output=capture,
    )
    return result.stdout.strip() if capture else ""


def replace_once(path, old, new):
    content = path.read_text(encoding="utf-8")
    if content.count(old) != 1:
        raise SystemExit(f"Expected exactly one baseline match in {path}: {old!r}")
    path.write_text(content.replace(old, new), encoding="utf-8")


def apply_scenario(repo, workload_option, scenario):
    handler = repo / "app" / "handler.js"
    tests = repo / "app" / "test" / "handler.test.js"
    if workload_option == "app-service" and scenario == "pass":
        replace_once(
            handler,
            "const MAX_DB_ATTEMPTS = 4;",
            "const MAX_DB_ATTEMPTS = 4;\nconst APP_FAULT_RETRY_SECONDS = 3;",
        )
        replace_once(
            handler,
            "response.setHeader('Retry-After', '3');",
            "response.setHeader('Retry-After', String(APP_FAULT_RETRY_SECONDS));",
        )
        replace_once(
            tests,
            "assert.equal(response.headers['Retry-After'], '3');\n  assert.equal(f.clients.length, 0);",
            "assert.equal(response.headers['Retry-After'], '3');\n  assert.match(response.headers['Retry-After'], /^\\d+$/);\n  assert.equal(f.clients.length, 0);",
        )
    elif workload_option == "app-service" and scenario == "block":
        replace_once(
            handler,
            "success = env.APP_FAULT_ENABLED !== 'true';",
            "if (env.APP_FAULT_ENABLED === 'true') await new Promise(() => {});\n      success = true;",
        )
    elif scenario == "pass":
        replace_once(handler, "const DB_TIMEOUT_MS = 5000;", "const DB_TIMEOUT_MS = 4500;")
        replacements = {
            "five-second deadline": "4.5-second deadline",
            "five-second budget": "4.5-second budget",
            "one total 5-second budget": "one total 4.5-second budget",
            "bounded by 5 seconds": "bounded by 4.5 seconds",
            "tick(4999)": "tick(4499)",
            "tick(1000)": "tick(500)",
            "connectionTimeoutMillis, 5000": "connectionTimeoutMillis, 4500",
            "query_timeout, 5000": "query_timeout, 4500",
            "statement_timeout, 5000": "statement_timeout, 4500",
        }
        content = tests.read_text(encoding="utf-8")
        for old, new in replacements.items():
            if old not in content:
                raise SystemExit(f"Expected baseline text in {tests}: {old!r}")
            content = content.replace(old, new)
        tests.write_text(content, encoding="utf-8")
    else:
        replace_once(
            handler,
            "            Promise.resolve(client.end()).catch(() => {});",
            "            await client.end();",
        )


def main():
    parser = argparse.ArgumentParser(description="Create an unmerged SRE Agent PR-validation sample.")
    parser.add_argument("scenario", choices=("pass", "block"))
    parser.add_argument(
        "--workload-option",
        required=True,
        choices=("app-service", "app-service-postgresql"),
    )
    parser.add_argument("--repo", type=Path, default=Path("ticketingapp-source"))
    args = parser.parse_args()
    repo = args.repo.resolve()
    if not (repo / ".git").exists():
        raise SystemExit(f"Git repository not found: {repo}")
    if run("git", "status", "--porcelain", cwd=repo, capture=True):
        raise SystemExit("The ticketing application worktree must be clean.")

    config = SCENARIOS[(args.workload_option, args.scenario)]
    run("gh", "auth", "status", cwd=repo)
    run("git", "switch", "main", cwd=repo)
    run("git", "pull", "--ff-only", "origin", "main", cwd=repo)
    run("git", "switch", "-c", config["branch"], cwd=repo)
    try:
        apply_scenario(repo, args.workload_option, args.scenario)
        npm = "npm.cmd" if os.name == "nt" else "npm"
        run(npm, "test", cwd=repo / "app")
        run(npm, "run", "check", cwd=repo / "app")
        run("git", "add", "app/handler.js", "app/test/handler.test.js", cwd=repo)
        run("git", "commit", "-m", config["title"], cwd=repo)
        run("git", "push", "--set-upstream", "origin", config["branch"], cwd=repo)
        url = run(
            "gh", "pr", "create",
            "--base", "main",
            "--head", config["branch"],
            "--title", config["title"],
            "--body", config["body"],
            cwd=repo,
            capture=True,
        )
    except Exception:
        print(f"Creation stopped on branch {config['branch']}; no merge or deployment was attempted.")
        raise
    print(f"Created unmerged {args.scenario.upper()} validation PR: {url}")
    print("Leave this PR open and unmerged while reviewing the SRE Agent result.")


if __name__ == "__main__":
    main()