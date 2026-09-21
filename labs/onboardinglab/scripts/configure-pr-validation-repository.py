#!/usr/bin/env python3

import argparse
import json
import re
import shutil
import subprocess
from pathlib import Path


WORKFLOW_PATH = Path(".github/workflows/sre-agent-pr-validation.yml")
SECRET_NAME = "SRE_AGENT_WEBHOOK_URL"


def run(*args, cwd, capture=False, input_text=None):
    executable = shutil.which(args[0])
    if not executable:
        raise SystemExit(f"Required command not found: {args[0]}")
    result = subprocess.run(
        (executable, *args[1:]),
        cwd=cwd,
        check=True,
        text=True,
        input=input_text,
        capture_output=capture,
    )
    return result.stdout.strip() if capture else ""


def github_slug(remote_url):
    match = re.fullmatch(
        r"(?:https://github\.com/|git@github\.com:)([^/\s]+)/([^/\s]+?)(?:\.git)?",
        remote_url,
    )
    if not match:
        raise SystemExit("The origin remote must be a GitHub repository URL.")
    return f"{match.group(1)}/{match.group(2)}"


def main():
    parser = argparse.ArgumentParser(
        description="Connect the participant's sre-agent fork to PR validation."
    )
    parser.add_argument("--subscription", required=True)
    parser.add_argument("--agent-name", required=True)
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[3])
    args = parser.parse_args()

    repo = args.repo.resolve()
    if not (repo / ".git").exists():
        raise SystemExit(f"Git repository not found: {repo}")
    if run("git", "status", "--porcelain", cwd=repo, capture=True):
        raise SystemExit("The sre-agent worktree must be clean.")

    source = Path(__file__).resolve().parent.parent / (
        "workflow-templates/http-triggers/github-pr-validation.yml"
    )
    if not source.is_file():
        raise SystemExit(f"Trusted workflow template not found: {source}")

    run("az", "account", "show", "--subscription", args.subscription, cwd=repo, capture=True)
    run("gh", "auth", "status", cwd=repo, capture=True)
    repo_slug = github_slug(run("git", "remote", "get-url", "origin", cwd=repo, capture=True))

    resources = json.loads(run(
        "az", "resource", "list",
        "--subscription", args.subscription,
        "--resource-type", "Microsoft.App/agents",
        "--query", f"[?name=='{args.agent_name}'].{{resourceGroup:resourceGroup}}",
        "--output", "json",
        cwd=repo,
        capture=True,
    ))
    if len(resources) != 1:
        raise SystemExit(f"Expected exactly one SRE Agent named {args.agent_name}.")
    resource_group = resources[0]["resourceGroup"]
    callback_url = run(
        "az", "rest",
        "--method", "POST",
        "--url", (
            f"/subscriptions/{args.subscription}/resourceGroups/{resource_group}"
            f"/providers/Microsoft.Logic/workflows/{args.agent_name}-webhook-bridge"
            "/triggers/incoming_webhook/listCallbackUrl?api-version=2019-05-01"
        ),
        "--query", "value",
        "--output", "tsv",
        cwd=repo,
        capture=True,
    )
    if not callback_url.startswith("https://"):
        raise SystemExit("The Logic App callback URL is unavailable. Install Scenario 3 first.")

    run("git", "switch", "main", cwd=repo)
    run("git", "pull", "--ff-only", "origin", "main", cwd=repo)
    destination = repo / WORKFLOW_PATH
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, destination)
    run("git", "add", str(WORKFLOW_PATH), cwd=repo)
    staged = subprocess.run(
        (shutil.which("git"), "diff", "--cached", "--quiet"), cwd=repo, check=False
    ).returncode
    if staged == 1:
        run("git", "commit", "-m", "Add SRE Agent PR validation workflow", cwd=repo)
        run("git", "push", "origin", "main", cwd=repo)
    elif staged != 0:
        raise SystemExit("Could not inspect the staged workflow change.")

    run("gh", "secret", "set", SECRET_NAME, "--repo", repo_slug, cwd=repo, input_text=callback_url)
    remote_path = run(
        "gh", "api", f"repos/{repo_slug}/contents/{WORKFLOW_PATH.as_posix()}?ref=main",
        "--jq", ".path", cwd=repo, capture=True,
    )
    secrets = json.loads(run(
        "gh", "secret", "list", "--repo", repo_slug, "--json", "name",
        cwd=repo, capture=True,
    ))
    if remote_path != WORKFLOW_PATH.as_posix() or SECRET_NAME not in {item["name"] for item in secrets}:
        raise SystemExit("Repository workflow verification failed.")

    print(f"Configured PR validation for {repo_slug}.")
    print(f"Verified workflow: {WORKFLOW_PATH.as_posix()} on main")
    print(f"Verified Actions secret: {SECRET_NAME}")


if __name__ == "__main__":
    main()