#!/usr/bin/env python3
"""
Zava Learning — SRE Agent demo simulator.

Story-driven CLI: narrates the business context, injects a real fault into the
deployed Azure resources, then live-monitors the platform's health while it polls
for the Azure Monitor alert, the PagerDuty incident, and the SRE Agent's response —
finally reporting recovery. Inspired by the zavapl-lab intelligent simulator.

Usage:
    python demo.py                 # interactive menu
    python demo.py --scenario nsg  # run a specific scenario
    python demo.py --status        # one-shot health probe
"""
from __future__ import annotations
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time
import traceback
from collections import deque
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone, timedelta
from pathlib import Path


def _ensure_deps():
    try:
        import rich  # noqa
        import requests  # noqa
    except ImportError:
        print("Installing simulator dependencies (rich, requests)...")
        subprocess.run([sys.executable, "-m", "pip", "install", "-q",
                        "rich>=13.0", "requests>=2.31"], check=True)


_ensure_deps()
import requests  # noqa: E402
from rich.console import Console  # noqa: E402
from rich.panel import Panel  # noqa: E402
from rich.table import Table  # noqa: E402
from rich.live import Live  # noqa: E402
from rich.text import Text  # noqa: E402
from rich import box  # noqa: E402

console = Console()
HERE = Path(__file__).resolve().parent
REPO = HERE.parent
CONFIG_PATH = HERE / "config.json"
LOG_DIR = HERE / "logs"

# When a scenario runs in its own terminal/tab (launched by "run ALL"), a crash used to
# close the tab instantly and the error was lost. We now tee everything to a per-lane log
# file so the cause of any crash survives, even if the window disappears.
_LOGFH = None


def _open_log(name: str) -> Path:
    """Open a fresh per-run log file and make it the active tee target."""
    global _LOGFH
    LOG_DIR.mkdir(exist_ok=True)
    ts = datetime.now().strftime("%Y%m%d-%H%M%S")
    path = LOG_DIR / f"{name}-{ts}.log"
    try:
        _LOGFH = open(path, "a", encoding="utf-8", buffering=1)
        _log(f"=== {name} run started {datetime.now().isoformat()} (pid {os.getpid()}) ===")
    except OSError:
        _LOGFH = None
    return path


def _log(text: str) -> None:
    """Append a line to the active log file, if any. Never raises."""
    if _LOGFH is None:
        return
    try:
        _LOGFH.write(text.rstrip("\n") + "\n")
        _LOGFH.flush()
    except OSError:
        pass

# ── Scenario catalogue ──────────────────────────────────────────────
# Note: scenarios are keyed by the FAULT for the operator running the demo, but the
# student-facing symptom (and the alert) never names the cause — that is what the
# SRE Agent must diagnose.
SCENARIOS = {
    "nsg": {
        "emoji": "🚧",
        "title": "Quizzes won't launch (connectivity)",
        "backstory": (
            "It's midterms week. Thousands of students open Zava Learning to take timed\n"
            "quizzes. Suddenly the portal loads but every 'Launch quiz' click spins and\n"
            "fails. Nothing was deployed today — so what changed at the network layer?"),
        "break_script": "chaos/break-nsg.ps1",
        "fix_script": "chaos/fix-nsg.ps1",
        "impact": "Students click 'Launch quiz' and it just spins, then fails — nobody can start a quiz.",
        "cause": "A network firewall rule now blocks the web front door from reaching the quiz service.",
        "flow": "Students  ──▶  Front door  ──✖ blocked ✖──  Quiz service",
        "break_steps": [
            "Commit a bad release to GitHub that adds an old 'segmentation' firewall rule.",
            "Deploy it to Azure — the rule goes live on the quiz services' network.",
            "That rule silently blocks the web gateway from reaching the quiz services.",
            "Start a synthetic 'student' check that notices the outage and pages on-call.",
        ],
        "symptom_alert": "Zava-quiz-launch-failing",
        "probe_path": "/quiz/BIO-101",
        "agent": "connectivity-triage-agent",
        "pd_title": "Zava quiz launches failing — students cannot start quizzes",
        "lane_port": 8081,
    },
    "appgw": {
        "emoji": "🌐",
        "title": "Portal returns errors (front door)",
        "backstory": (
            "Students report the portal is throwing errors on every page. The apps appear\n"
            "to be running, yet the public endpoint keeps returning 502s. The edge tier is\n"
            "no longer routing traffic to a healthy backend."),
        "break_script": "chaos/break-appgw.ps1",
        "fix_script": "chaos/fix-appgw.ps1",
        "impact": "Every page of the portal shows an error — to students the whole site looks down.",
        "cause": "The front door's health check points at a missing page, so it marks every quiz service 'unhealthy' and stops sending traffic.",
        "flow": "Students  ──✖──  Front door  ──  (sees no healthy quiz service)",
        "break_steps": [
            "Commit a bad release that points the gateway's health check at a missing page.",
            "Deploy it to Azure — the gateway now marks every backend 'unhealthy'.",
            "With no healthy backend, the public portal returns 502 errors to students.",
            "Start a synthetic 'student' check that notices the errors and pages on-call.",
        ],
        "symptom_alert": "Zava-portal-5xx-elevated",
        "probe_path": "/quiz/BIO-101",
        "agent": "connectivity-triage-agent",
        "pd_title": "Zava portal returning 502s — students see errors",
        "lane_port": 8082,
    },
    "app": {
        "emoji": "📋",
        "title": "Quizzes won't launch (application)",
        "backstory": (
            "Quiz launches are failing again — but the network looks clean this time. The\n"
            "assessment service that serves quiz content appears to have no healthy\n"
            "instances answering requests."),
        "break_script": "chaos/break-app.ps1",
        "fix_script": "chaos/fix-app.ps1",
        "impact": "Students try to launch a quiz and get errors — the quiz service isn't answering at all.",
        "cause": "We removed the quiz service's scale floor and took its running release down to zero copies, so nothing is left to serve quizzes.",
        "flow": "Students  ──▶  Front door  ──▶  Quiz service (0 running) ✖",
        "break_steps": [
            "Commit a bad release that drops the quiz service's scale floor to zero instances.",
            "Take the live quiz release down to zero copies — nothing is left to serve quiz content.",
            "Students' quiz launches start failing with errors.",
            "A monitor notices the failures and pages on-call.",
        ],
        "symptom_alert": "Zava-quiz-launch-failing",
        "probe_path": "/quiz/BIO-101",
        "agent": "performance-agent",
        "pd_title": "Zava quiz service unavailable — launches failing",
        "lane_port": 8083,
    },
    "perf": {
        "emoji": "🐌",
        "title": "Quizzes are slow (after an app update)",
        "backstory": (
            "A routine release shipped this morning. Since then, students complain that\n"
            "launching a quiz takes several seconds — it eventually loads, but it's painfully\n"
            "slow. The network and gateway look clean; latency climbed right after the deploy."),
        "break_script": "chaos/break-perf.ps1",
        "fix_script": "chaos/fix-perf.ps1",
        "impact": "Quizzes still open, but they're painfully slow — a few seconds for every launch.",
        "cause": "A new release added heavy crypto work on the hot quiz path, so each request crawls.",
        "flow": "Students  ──▶  Quiz service 🐌 (slow new code)  ──▶  Database",
        "break_steps": [
            "Commit a code change that adds heavy crypto work to the hot quiz path.",
            "Build the new image and roll it out to the assessment service.",
            "Quiz launches still work but crawl — a few ms becomes 1–2 seconds.",
            "The latency monitor flags the slowdown and pages on-call.",
        ],
        "symptom_alert": "Zava-quiz-api-latency-elevated",
        "probe_path": "/quiz/BIO-101",
        "agent": "performance-agent",
        "slow_threshold_ms": 800,
        "pd_title": "Zava quiz launches slow — elevated latency",
        "lane_port": 8084,
    },
    "query": {
        "emoji": "🗃️",
        "title": "Quizzes are slow (database search)",
        "backstory": (
            "Students report that opening a quiz takes several seconds since this morning.\n"
            "The app servers look healthy and the recent app release was clean — but the\n"
            "database is suddenly doing far more work to answer the same quiz request."),
        "break_script": "chaos/break-query.ps1",
        "fix_script": "chaos/fix-query.ps1",
        "impact": "Quizzes still open, but they're slow — several seconds to load since this morning.",
        "cause": "A database index is damaged, so every quiz lookup now scans all 3 million rows.",
        "flow": "Students  ──▶  Quiz service  ──▶  🐌 Database (scanning everything)",
        "break_steps": [
            "An index on the question bank becomes corrupt and unusable.",
            "The planner can no longer use it, so the quiz query full-scans 3 million rows.",
            "Quiz launches still work but crawl as the database churns on every request.",
            "The latency monitor flags the slowdown and pages on-call.",
        ],
        "symptom_alert": "Zava-quiz-api-latency-elevated",
        "probe_path": "/quiz/BIO-101",
        "agent": "performance-agent",
        "slow_threshold_ms": 800,
        "pd_title": "Zava quiz loading slowly — elevated latency",
        "lane_port": 8085,
    },
    "pool": {
        "emoji": "🔌",
        "title": "Quizzes fail under load (database connections)",
        "backstory": (
            "Under exam-day load, a fraction of students get errors launching quizzes while\n"
            "others succeed. The app is up and the database is up — but requests intermittently\n"
            "fail to get a database connection and time out."),
        "break_script": "chaos/break-pool.ps1",
        "fix_script": "chaos/fix-pool.ps1",
        "impact": "Under exam-day load, some students get errors launching quizzes while others are fine.",
        "cause": "A database setting now allows too few connections at once, so requests run out and time out.",
        "flow": "Students  ──▶  Quiz service  ──✖ out of DB connections ✖──  Database",
        "break_steps": [
            "A database role change clamps how many connections the quiz service may open.",
            "Under concurrent load the service runs out of connections almost immediately.",
            "Some students' quiz launches fail with 500s while the rest still work.",
            "A monitor notices the error spike and pages on-call.",
        ],
        "symptom_alert": "Zava-quiz-errors-elevated",
        "probe_path": "/quiz/BIO-101",
        "agent": "performance-agent",
        "concurrent_probe": 8,
        "pd_title": "Zava quiz errors under load — intermittent failures",
        "lane_port": 8086,
    },
    "secret": {
        "emoji": "🔑",
        "title": "Quizzes fail completely (credentials)",
        "backstory": (
            "Every quiz launch on this service suddenly fails. Nothing was deployed — but the\n"
            "service can no longer reach its database, as if its stored credential stopped\n"
            "working overnight."),
        "break_script": "chaos/break-secret.ps1",
        "fix_script": "chaos/fix-secret.ps1",
        "impact": "Every student on this quiz service fails to launch — it's completely down for them.",
        "cause": "The saved database password was changed to a wrong value, so the service can't reach its database.",
        "flow": "Quiz service  ──✖ wrong password ✖──  Database",
        "break_steps": [
            "A stored database credential is rotated to a value that no longer works.",
            "The quiz service picks up the bad credential and can't reach the database.",
            "Quiz launches fail for every student on this service.",
            "A monitor notices the failures and pages on-call.",
        ],
        "symptom_alert": "Zava-quiz-launch-failing",
        "probe_path": "/quiz/BIO-101",
        "agent": "connectivity-triage-agent",
        "pd_title": "Zava quiz service failing — authentication errors",
        "lane_port": 8087,
    },
    "disk": {
        "emoji": "💽",
        "title": "Nightly grade exports are failing (reporting worker)",
        "backstory": (
            "The nightly grade-export job on the reporting worker has started failing.\n"
            "Instructors aren't getting their grade-export files. The student-facing site is\n"
            "completely healthy — this is a back-office batch job running on its own VM."),
        "break_script": "chaos/break-disk.ps1",
        "fix_script": "chaos/fix-disk.ps1",
        "impact": "The student site is fine, but teachers aren't getting their nightly grade-export files.",
        "cause": "The reporting server's disk filled up, so the nightly grade-export job can't write its file.",
        "flow": "Reporting VM 💽 disk full ✖  ──  no grade exports for teachers",
        "break_steps": [
            "Export backlog accumulates on the reporting worker's data disk until it is full.",
            "The next grade-export run can't write its file and fails on the worker.",
            "Each subsequent run keeps failing while the disk stays full.",
            "The export-health monitor notices the failures and pages on-call.",
        ],
        "symptom_alert": "Zava-grade-exports-failing",
        "pd_title": "Zava reporting — nightly grade exports are failing",
        "agent": "performance-agent",
        "web_health": False,
        "healthy_text": "the nightly grade exports are running",
        "impacted_text": "the nightly grade exports are failing",
        "recovered_text": "Recovered — nightly grade exports are succeeding again.",
    },
}


# ── Config ──────────────────────────────────────────────────────────
def _load_dotenv() -> None:
    """Best-effort load of the gitignored sre-config/.env so secrets (e.g. PAGERDUTY_API_TOKEN)
    are available to the simulator without a manual export. Real environment variables win."""
    env_file = HERE.parent / "sre-config" / ".env"
    if not env_file.exists():
        return
    for line in env_file.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, val = line.partition("=")
        key, val = key.strip(), val.strip()
        if key and key not in os.environ:
            os.environ[key] = val


def _pick(cfg_val: str, env_key: str, default: str = "") -> str:
    """Prefer a non-empty config.json value; otherwise fall back to the env var, then default.
    (A blank string in config.json counts as unset, so env overrides still work.)"""
    if isinstance(cfg_val, str) and cfg_val.strip():
        return cfg_val
    return os.environ.get(env_key) or default


def load_config() -> dict:
    _load_dotenv()
    cfg = {}
    if CONFIG_PATH.exists():
        cfg = json.loads(CONFIG_PATH.read_text())
    # A blank/missing value falls back to the env var, so secrets like the PD token can stay in
    # sre-config/.env instead of config.json (handy before post-provision writes config.json).
    cfg["appgw_url"] = _pick(cfg.get("appgw_url", ""), "ZAVA_APPGW_URL")
    cfg["resource_group"] = _pick(cfg.get("resource_group", ""), "ZAVA_RG", "rg-zava-learning-demo")
    cfg["subscription"] = _pick(cfg.get("subscription", ""), "ZAVA_SUBSCRIPTION")
    cfg["agent_name"] = _pick(cfg.get("agent_name", ""), "ZAVA_AGENT")
    pd = cfg.setdefault("pagerduty", {})
    pd["api_token"] = _pick(pd.get("api_token", ""), "PAGERDUTY_API_TOKEN")
    pd["service_id"] = _pick(pd.get("service_id", ""), "PAGERDUTY_SERVICE_ID")
    return cfg


# ── HTTP / health ───────────────────────────────────────────────────
def lane_url(appgw_url: str, lane_port) -> str:
    """Build the per-lane base URL. Every lane is fronted by the SAME App Gateway public
    address on its own frontend port, so we keep the host and swap in the lane's port."""
    if not appgw_url or not lane_port:
        return appgw_url
    scheme, _, rest = appgw_url.partition("//")
    host = rest.split("/")[0].split(":")[0]
    return f"{scheme}//{host}:{lane_port}"


def probe(url: str, path: str = "/", timeout: float = 6.0):
    """Return (ok, status_code, elapsed_ms) for a GET against the public endpoint."""
    if not url:
        return (False, 0, 0.0)
    full = url.rstrip("/") + path
    t0 = time.monotonic()
    try:
        r = requests.get(full, timeout=timeout)
        ms = (time.monotonic() - t0) * 1000.0
        return (200 <= r.status_code < 400, r.status_code, ms)
    except requests.RequestException:
        ms = (time.monotonic() - t0) * 1000.0
        return (False, 0, ms)


def probe_burst(url: str, path: str, n: int, timeout: float = 6.0, fail_ratio: float = 0.25):
    """Fire n concurrent GETs and judge health from the failure rate.

    The pool lane's fault (a clamped Postgres role CONNECTION LIMIT) only manifests under
    CONCURRENT load — a single 1/sec request always gets its one connection and succeeds, so the
    ordinary single-stream probe would never see it. We fire a small burst and treat the lane as
    impacted when a meaningful fraction of the burst fails to get a DB connection (500s).

    Returns (healthy, status_repr, elapsed_ms, failed, n)."""
    if not url:
        return (False, "no-url", 0.0, n, n)
    full = url.rstrip("/") + path

    def _one(_):
        try:
            r = requests.get(full, timeout=timeout)
            return 200 <= r.status_code < 400
        except requests.RequestException:
            return False

    t0 = time.monotonic()
    with ThreadPoolExecutor(max_workers=n) as ex:
        results = list(ex.map(_one, range(n)))
    ms = (time.monotonic() - t0) * 1000.0
    failed = sum(1 for ok in results if not ok)
    healthy = (failed / n) < fail_ratio
    return (healthy, f"{n - failed}/{n} ok", ms, failed, n)


# ── Azure Monitor / PagerDuty / SRE Agent polling ───────────────────
def _az(cmd: str):
    try:
        out = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=60)
        if out.returncode != 0:
            return None
        return out.stdout
    except Exception:
        return None


def poll_azmon_alert(sub: str, rule_name: str, since: datetime) -> bool:
    """True if an Azure Monitor alert for rule_name has fired since `since`."""
    if not sub:
        return False
    url = (f"https://management.azure.com/subscriptions/{sub}/providers/"
           f"Microsoft.AlertsManagement/alerts?api-version=2019-05-05-preview"
           f"&timeRange=1h")
    out = _az(f'az rest --method GET --url "{url}"')
    if not out:
        return False
    try:
        for a in json.loads(out).get("value", []):
            props = a.get("properties", {}).get("essentials", {})
            name = props.get("alertRule", "") or a.get("name", "")
            if rule_name.lower() in name.lower() and props.get("monitorCondition") == "Fired":
                return True
    except Exception:
        return False
    return False


def poll_pagerduty_incident(pd: dict, since: datetime, match_title: str | None = None):
    """Return the open PagerDuty incident dict for the scenario under test, or None.

    Used as the primary detection signal for the synthetic-monitor scenarios (nsg/appgw),
    where Azure Monitor is intentionally blind to the blackhole and the chaos synthetic
    monitor pages PagerDuty directly.

    When `match_title` is given, return the newest open incident whose title matches it
    exactly. Each scenario's break script pages with a distinct title, so this pins the
    detection (and the downstream agent-thread deep link) to THIS scenario's incident —
    otherwise a different scenario's still-open incident could be picked up by mistake."""
    token = pd.get("api_token")
    if not token:
        return None
    headers = {"Authorization": f"Token token={token}", "Accept": "application/json"}
    # Small grace window so clock skew between this machine and PagerDuty doesn't drop a
    # just-created incident. (reset.ps1 resolves stale incidents, so the slate is clean.)
    since_eff = since - timedelta(minutes=5)
    params = {"since": since_eff.astimezone(timezone.utc).isoformat(),
              "statuses[]": ["triggered", "acknowledged"], "limit": 25,
              "sort_by": "created_at:desc"}
    if pd.get("service_id"):
        params["service_ids[]"] = [pd["service_id"]]
    try:
        r = requests.get("https://api.pagerduty.com/incidents", headers=headers,
                         params=params, timeout=10)
        if r.status_code == 200:
            incidents = r.json().get("incidents", [])
            if match_title:
                for inc in incidents:  # already newest-first
                    if (inc.get("title") or "").strip() == match_title.strip():
                        return inc
                return None
            return incidents[0] if incidents else None
    except requests.RequestException:
        pass
    return None


def get_pagerduty_incident(pd: dict, incident_id: str):
    """Fetch a single PagerDuty incident by id (any status), so we can watch its lifecycle
    triggered -> acknowledged (agent engaged) -> resolved (agent closed it out)."""
    token = pd.get("api_token")
    if not token or not incident_id:
        return None
    headers = {"Authorization": f"Token token={token}", "Accept": "application/json"}
    try:
        r = requests.get(f"https://api.pagerduty.com/incidents/{incident_id}",
                         headers=headers, timeout=10)
        if r.status_code == 200:
            return r.json().get("incident")
    except requests.RequestException:
        pass
    return None


def poll_agent_thread(keyword: str, since: datetime) -> bool:
    """True if the SRE Agent has a recent thread matching keyword (best effort)."""
    out = _az("srectl thread list --quiet")
    if not out:
        return False
    return keyword.lower() in out.lower()


# ── SRE Agent thread deep-linking ───────────────────────────────────
# The portal renders a thread at this URL; we resolve the live thread id from the
# agent's data-plane API and correlate it to the PagerDuty incident we're tracking.
_AGENT_ENDPOINT_CACHE: dict = {}


def _agent_dataplane_endpoint(cfg: dict):
    """Resolve the agent's data-plane endpoint via ARM (authoritative; the cached
    ~/.sreagent/config.json can be stale). Memoised for the life of the process."""
    if "endpoint" in _AGENT_ENDPOINT_CACHE:
        return _AGENT_ENDPOINT_CACHE["endpoint"]
    sub, rg, name = cfg.get("subscription"), cfg.get("resource_group"), cfg.get("agent_name")
    ep = None
    if sub and rg and name:
        arm = (f"https://management.azure.com/subscriptions/{sub}/resourceGroups/{rg}"
               f"/providers/Microsoft.App/agents/{name}?api-version=2025-05-01-preview")
        out = _az(f'az rest --method GET --url "{arm}"')
        if out:
            try:
                ep = json.loads(out).get("properties", {}).get("agentEndpoint")
            except Exception:
                ep = None
    _AGENT_ENDPOINT_CACHE["endpoint"] = ep
    return ep


def _dataplane_token():
    out = _az("az account get-access-token --scope https://azuresre.dev/.default "
              "--query accessToken -o tsv")
    return out.strip() if out else None


def agent_thread_url(cfg: dict, thread_id: str) -> str:
    """Build the Azure portal deep link to a specific SRE Agent thread."""
    return ("https://sre.azure.com/agents/subscriptions/"
            f"{cfg.get('subscription')}/resourceGroups/{cfg.get('resource_group')}"
            f"/providers/Microsoft.App/agents/{cfg.get('agent_name')}"
            f"/views/thread/{thread_id}")


# ── On-demand governance audits (run the existing weekly tasks now) ──
# The three audits already exist as weekly SRE-Agent scheduled tasks (Mon/Tue/Wed 08:00). For a
# live demo we don't wait for the calendar — we invoke each EXISTING task immediately via its
# /execute endpoint, which runs the very same audit out-of-band and returns the agent thread it
# created. Nothing is created or deleted; the weekly schedules are left exactly as they are.
def _dp_list_tasks(ep: str, tok: str) -> list:
    """Return the agent's scheduled tasks (the API returns a bare array)."""
    try:
        r = requests.get(f"{ep}/api/v1/scheduledtasks",
                         headers={"Authorization": f"Bearer {tok}"}, timeout=20)
        if r.status_code == 200:
            data = r.json()
            return data if isinstance(data, list) else data.get("value", [])
    except requests.RequestException:
        pass
    return []


def _dp_execute_task(ep: str, tok: str, task_id: str):
    """Run an existing scheduled task now (out-of-band). Returns the new thread id, or None."""
    try:
        r = requests.post(f"{ep}/api/v1/scheduledtasks/{task_id}/execute",
                          headers={"Authorization": f"Bearer {tok}", "Content-Type": "application/json"},
                          data="{}", timeout=60)
        if r.status_code == 200:
            execu = (r.json() or {}).get("execution") or {}
            if execu.get("success") or execu.get("threadId"):
                return execu.get("threadId")
    except requests.RequestException:
        pass
    return None


def _dp_thread_messages(ep: str, tok: str, thread_id: str) -> list:
    try:
        r = requests.get(f"{ep}/api/v1/threads/{thread_id}/messages",
                         headers={"Authorization": f"Bearer {tok}"}, timeout=20)
        if r.status_code == 200:
            data = r.json()
            return data if isinstance(data, list) else data.get("value", [])
    except requests.RequestException:
        pass
    return []


# Matches the audit deck's closing posture line in either form the agent emits, e.g.
# "## Overall Posture: **NEEDS ATTENTION**" or "… | **Posture: NEEDS ATTENTION**". The
# end-of-line anchor + known-phrase whitelist keep it from matching the skill's templated example
# line ("Overall posture: NEEDS ATTENTION — {sev_counts}…"), which is followed by other text.
_POSTURE_RE = re.compile(
    r"Posture:?\s*\**\s*(HEALTHY|AT RISK|NEEDS ATTENTION|ATTENTION REQUIRED|ACTION REQUIRED)\s*\**\s*$",
    re.IGNORECASE | re.MULTILINE)


def _extract_posture(messages: list):
    """Best-effort: the final posture word (AT RISK / NEEDS ATTENTION / HEALTHY) once posted."""
    posture = None
    for m in messages:
        for mt in _POSTURE_RE.finditer(m.get("text") or ""):
            cand = mt.group(1).strip().upper()
            if cand:
                posture = cand
    return posture


def resolve_incident_thread(cfg: dict, since: datetime, incident_id: str | None = None,
                            expected_title: str | None = None):
    """Return the SRE Agent thread id for the incident under test, or None.

    Correlation, strongest first:
      1) exact match on the PagerDuty incident id embedded in the thread's incidentSource;
      2) exact match on the scenario's incident title (each scenario pages with a distinct
         title) among threads created during this sim run;
      3) only when we have NO title to disambiguate, the newest incident thread in window.
    Steps 1–2 pin the link to THIS scenario's thread; step 3 is a last resort that is
    deliberately skipped when a title is known, so we never deep-link another scenario's
    thread."""
    ep = _agent_dataplane_endpoint(cfg)
    if not ep:
        return None
    tok = _dataplane_token()
    if not tok:
        return None
    try:
        # Newest-first: the threads API returns oldest-first by default, so a plain $top=N
        # page keeps the OLDEST N and drops freshly-created threads once enough incidents
        # accumulate — which is why the just-routed thread was missing from the deep link.
        r = requests.get(f"{ep}/api/v1/threads",
                         params={"$top": 20, "$orderby": "createdTimestamp desc"},
                         headers={"Authorization": f"Bearer {tok}"}, timeout=15)
        if r.status_code != 200:
            return None
        threads = r.json().get("value", [])
    except requests.RequestException:
        return None

    def _created(t):
        raw = (t.get("createdTimestamp") or "").replace("Z", "+00:00")
        try:
            return datetime.fromisoformat(raw)
        except Exception:
            return None

    incident_threads = [t for t in threads if (t.get("source") == "Incident")]
    # 1) Exact correlation to the PagerDuty incident we're tracking.
    if incident_id:
        for t in incident_threads:
            src = t.get("incidentSource") or {}
            if str(src.get("incidentId", "")) == str(incident_id):
                return t.get("id")
    # 2) Exact correlation to this scenario's distinct incident title (newest matching).
    if expected_title:
        titled = [(c, t) for t in incident_threads
                  if (det := t.get("incidentDetails") or {})
                  and (det.get("incidentTitle") or "").strip() == expected_title.strip()
                  and (c := _created(t)) is not None and c >= since - timedelta(minutes=2)]
        if titled:
            titled.sort(key=lambda x: x[0], reverse=True)
            return titled[0][1].get("id")
        # A distinct title was expected but none matched yet — don't guess another scenario's
        # thread; report none so the caller keeps polling for the right one to appear.
        return None
    # 3) Last resort (no title to disambiguate): newest incident thread in this sim run.
    fresh = [(c, t) for t in incident_threads
             if (c := _created(t)) is not None and c >= since - timedelta(minutes=2)]
    if fresh:
        fresh.sort(key=lambda x: x[0], reverse=True)
        return fresh[0][1].get("id")
    return None


# ── Timeline ────────────────────────────────────────────────────────
class EventTimeline:
    def __init__(self):
        self.events = []

    def add(self, text: str, style: str = "white", link: str = None):
        ts = datetime.now().strftime("%H:%M:%S")
        self.events.append((ts, text, style, link))

    def render(self) -> Panel:
        body = Text()
        for ts, text, style, link in self.events[-12:]:
            body.append(f"  {ts}  ", style="dim")
            body.append(text, style=style)
            if link:
                # Short clickable (OSC-8) anchor — never embed the raw ~180-char URL here, or
                # Rich crops it with an ellipsis inside the fixed-width panel. The full URL is
                # printed (copy/pasteable) in the end-of-run summary.
                body.append("  ")
                body.append("open thread ↗", style=f"link {link}")
            body.append("\n")
        if not self.events:
            body.append("  waiting...\n", style="dim")
        return Panel(body, title="Event timeline", border_style="cyan")


def _pd_incident_panel(inc: dict) -> Panel:
    """Render the live PagerDuty incident with its number, title, status, and a clickable link."""
    status = (inc.get("status") or "").lower()
    status_style = {"triggered": "bold red", "acknowledged": "yellow", "resolved": "green"}.get(status, "white")
    num = inc.get("incident_number")
    url = inc.get("html_url") or ""
    body = Text()
    body.append("Incident  ", style="dim")
    body.append(f"#{num}", style="bold")
    body.append("    status  ", style="dim")
    body.append(status or "—", style=status_style)
    body.append("\n")
    body.append("Title     ", style="dim")
    body.append((inc.get("title") or "").strip() + "\n", style="white")
    if url:
        body.append("Link      ", style="dim")
        # Rich renders an OSC-8 hyperlink in terminals that support it; the URL is also visible.
        body.append(url, style=f"link {url} cyan underline")
    return Panel(body, title="🔔  PagerDuty", border_style="red", padding=(0, 1))


def _clock(dt: datetime) -> str:
    return dt.astimezone().strftime("%H:%M:%S")


def _dur(seconds: float) -> str:
    seconds = max(int(seconds), 0)
    m, s = divmod(seconds, 60)
    return f"{m}m {s:02d}s" if m else f"{s}s"


def render_health_timeline(sim_start: datetime, broke_at, fixed_at, now: datetime,
                           width: int = 62):
    """A fixed (non-rolling) phase timeline that PINS the moments that matter:
    WORKING → ⚠ break → BROKEN → ✅ fix → RECOVERED. Unlike a live sparkline, the
    break and fix points never scroll off-screen — they stay anchored with their
    timestamps so the room can see exactly when the outage began and ended.
    Returns (bar, marker_or_None, legend)."""
    GREEN, RED = "▇", "▁"
    # Phase 0: the fault hasn't reached students yet — calm healthy baseline.
    if broke_at is None:
        return Text(GREEN * width, style="green"), None, \
            Text("● monitoring students — all healthy", style="green")

    end_broken = fixed_at if fixed_at else now
    secs = [max((broke_at - sim_start).total_seconds(), 1),   # working
            max((end_broken - broke_at).total_seconds(), 1)]  # broken
    if fixed_at:
        secs.append(max((now - fixed_at).total_seconds(), 1))  # recovered tail
    styles = ["green", "red", "green"][:len(secs)]
    chars = [GREEN, RED, GREEN][:len(secs)]

    # Proportional widths, but every present phase stays visible (a minimum width).
    min_w = 6
    total = sum(secs)
    widths = [max(min_w, int(round(sec / total * width))) for sec in secs]
    widths[widths.index(max(widths))] += width - sum(widths)  # absorb rounding drift

    bar = Text()
    seams = []            # column where each later phase starts (the break / fix points)
    col = 0
    for i in range(len(secs)):
        if i > 0:
            seams.append(col)
        bar.append(chars[i] * widths[i], style=f"bold {styles[i]}")
        col += widths[i]

    # Caret row: ▲ anchored exactly under the break seam (amber) and fix seam (green).
    cells = [" "] * width
    cell_style = {}
    cells[seams[0]] = "▲"; cell_style[seams[0]] = "bold yellow"
    if len(seams) > 1:
        cells[seams[1]] = "▲"; cell_style[seams[1]] = "bold green"
    marker = Text()
    for i, c in enumerate(cells):
        marker.append(c, style=cell_style.get(i))

    legend = Text()
    legend.append("⚠ broke ", style="bold yellow")
    legend.append(_clock(broke_at), style="yellow")
    if fixed_at:
        legend.append("    ✅ fixed ", style="bold green")
        legend.append(_clock(fixed_at), style="green")
        legend.append(f"    ⏱ down {_dur((fixed_at - broke_at).total_seconds())}", style="dim")
    else:
        legend.append(f"    ⏳ down {_dur((now - broke_at).total_seconds())} and counting…",
                      style="dim")
    return bar, marker, legend


# ── Narrative helpers ───────────────────────────────────────────────
def show_backstory(sc: dict, key: str = ""):
    console.clear()
    # 1) The business story — what's happening and who feels it.
    console.print(Panel(
        Text(sc["backstory"], style="white"),
        title=f"{sc['emoji']}  {sc['title']}",
        subtitle="[dim]the student-facing symptom — the cause is for the SRE Agent to find[/]",
        border_style="yellow", padding=(1, 2)))
    console.print()
    # 2) A plain, audience-ready explainer: what users feel + what we broke (+ an optional
    #    one-line flow showing where it breaks). This is what you read out to the room.
    body = Text()
    body.append("👀  What the audience sees\n", style="bold cyan")
    body.append(f"    {sc.get('impact', '')}\n\n", style="white")
    body.append("🔧  What we broke behind the scenes\n", style="bold cyan")
    body.append(f"    {sc.get('cause', '')}", style="white")
    flow = sc.get("flow")
    if flow:
        body.append(f"\n\n    {flow}", style="bold")
    console.print(Panel(body, title="🎤  Explain it to the room",
                        border_style="cyan", padding=(1, 2)))
    console.print()
    console.print("[dim]Injecting the fault and starting the lab…[/]")
    time.sleep(2)


def _steps_text(steps: list) -> Text:
    t = Text()
    for i, s in enumerate(steps, 1):
        t.append(f"  {i}. ", style="bold yellow")
        t.append(s + "\n", style="white")
    return t


def _stream_pwsh(cmd: list, status_msg: str) -> bool:
    """Run a PowerShell command, streaming its stdout live (dimmed) under a spinner so the
    audience sees progress during multi-minute Azure operations. Returns True on exit code 0."""
    _log(f"$ {' '.join(str(c) for c in cmd)}")
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True, bufsize=1)
    with console.status(status_msg, spinner="dots"):
        if proc.stdout is not None:
            for line in proc.stdout:
                line = line.rstrip()
                if line:
                    console.print(f"    [dim]{line}[/]")
                    _log(line)
        proc.wait()
    if proc.returncode != 0:
        console.print(f"[red]script failed (exit {proc.returncode}).[/]")
        _log(f"script failed (exit {proc.returncode})")
        return False
    return True


def run_chaos(script_rel: str, rg: str, stream: bool = False) -> bool:
    script = REPO / script_rel
    cmd = ["pwsh", "-NoProfile", "-File", str(script), "-ResourceGroup", rg]
    if not stream:
        _log(f"$ {' '.join(str(c) for c in cmd)}")
        res = subprocess.run(cmd, capture_output=True, text=True)
        if res.returncode != 0:
            err = res.stderr.strip() or res.stdout.strip()
            console.print(f"[red]chaos script failed:[/] {err}")
            _log(f"chaos script failed (exit {res.returncode}):\n{res.stdout}\n{res.stderr}")
            return False
        return True
    # Streamed: surface the script's own progress live so the audience isn't staring at a
    # frozen screen while a multi-minute Azure deployment runs.
    return _stream_pwsh(cmd, "[yellow]Applying the change in Azure…[/]")


def inject_fault(sc: dict, cfg: dict) -> bool:
    console.print(Panel(
        _steps_text(sc["break_steps"]),
        title="🔧  Injecting the fault — what's happening behind the scenes",
        border_style="yellow", padding=(1, 2)))
    console.print("[dim]This makes a real change to Azure and usually takes 1–3 minutes.[/]\n")
    ok = run_chaos(sc["break_script"], cfg["resource_group"], stream=True)
    if ok:
        console.print("\n[bold green]✔ The fault is now live.[/] "
                      "Students are starting to feel it — watch the live response below.\n")
        time.sleep(1.5)
    return ok


RESET_TARGETS = ["nsg", "appgw", "app", "perf", "query", "pool", "secret", "disk", "all"]


def run_reset(cfg: dict, scenario: str | None = None) -> None:
    """Restore the lab to baseline by running chaos/reset.ps1 for one scenario (or all).

    reset.ps1 reverts the infra source + redeploys clean, and resolves any open PagerDuty
    incidents — giving a clean slate for the next demo."""
    if scenario is None:
        opts = "  ".join(f"[bold]{i}[/]={t}" for i, t in enumerate(RESET_TARGETS, 1))
        console.print(Panel(
            Text("Restore the platform and infra-as-code to a known-good baseline, and clear any\n"
                 "open PagerDuty incidents. Pick one scenario to reset, or 'all'.", style="white"),
            title="♻️  Reset to baseline", border_style="green", padding=(1, 2)))
        console.print(f"  {opts}")
        scenario = console.input(
            "[bold]Which scenario to reset?[/] [dim](number or name, default all)[/]: "
        ).strip().lower() or "all"
    if scenario.isdigit() and 1 <= int(scenario) <= len(RESET_TARGETS):
        scenario = RESET_TARGETS[int(scenario) - 1]
    if scenario not in RESET_TARGETS:
        console.print(f"[red]Unknown reset target '{scenario}'. Choose one of: {', '.join(RESET_TARGETS)}.[/]")
        return
    console.print(f"\n[green]Restoring baseline[/] [bold]({scenario})[/] — reverts infra, redeploys "
                  "clean, and resolves open PagerDuty incidents. This can take a few minutes.\n")
    cmd = ["pwsh", "-NoProfile", "-File", str(REPO / "chaos" / "reset.ps1"),
           "-Scenario", scenario, "-ResourceGroup", cfg["resource_group"]]
    if _stream_pwsh(cmd, "[green]Resetting the lab to baseline…[/]"):
        console.print("\n[bold green]✔ Baseline restored.[/] The platform is healthy and PagerDuty "
                      "is clean — ready for the next demo.\n")
    else:
        console.print("\n[red]Reset did not complete cleanly — check the output above.[/]\n")


# ── Main monitor loop ───────────────────────────────────────────────
def monitor(cfg: dict, sc: dict, auto_fix: bool):
    timeline = EventTimeline()
    web_health = sc.get("web_health", True)
    url = lane_url(cfg["appgw_url"], sc.get("lane_port")) if web_health else None
    sub = cfg["subscription"]
    samples: deque = deque([None] * 60, maxlen=60)

    sim_start = datetime.now(timezone.utc)
    alert_fired = pd_created = agent_seen = recovered = False
    agent_resolved = False
    fault_cleared = False
    impacted_seen = False          # did students ever actually feel the fault?
    # Slow faults take real wall-clock time to surface to students: an App Gateway probe break
    # needs ~3 failed probes × 30s (~150-165s) before the backend is marked unhealthy, and the
    # secret lane needs a new revision to roll + the gateway to mark it down (~155-165s). Gate the
    # "fault never manifested" bail on ELAPSED WALL-CLOCK SECONDS (not tick count, whose wall time
    # varies with API latency) so we never declare a real-but-slow fault dead just before it lands.
    manifest_grace_s = 300         # 5 min — comfortably past appgw/secret (~165s) manifestation
    broke_at = None                # pinned: the moment the outage began
    fixed_at = None                # pinned: the moment service recovered
    # The demo is only "successful" once the SRE Agent has actually CLOSED the loop:
    # PagerDuty resolved + agent run completed. When a live agent + PagerDuty are wired up
    # (the real lab), service-health recovery alone is NOT success — we wait for the agent
    # to resolve the incident. auto_fix is the dev stand-in (no live agent), so it falls back
    # to service recovery as the success signal.
    require_agent = bool(cfg.get("agent_name")) and bool(cfg["pagerduty"].get("api_token")) \
        and not auto_fix
    completed_at = None            # when the success criteria were first met (for the tail hold)
    pd_incident = None
    thread_url = None
    last_alert = last_pd = last_agent = datetime.min.replace(tzinfo=timezone.utc)
    healthy_streak = 0
    slow_thr = sc.get("slow_threshold_ms")
    slow_noted = False
    probe_timeout = 12.0 if slow_thr else 6.0

    healthy_label = sc.get("healthy_text", "students can launch quizzes")
    impacted_label = sc.get("impacted_text", "quiz launches are failing for students")

    host = url.split("//")[-1].split("/")[0] if url else "the reporting worker"
    timeline.add("Fault is live — the platform is now degraded.", "red")
    if web_health:
        timeline.add(f"Simulating real students using the site ({host}), one check per second…", "cyan")
    else:
        timeline.add("Watching the nightly grade-export job on the reporting worker…", "cyan")

    def status_word(done: bool, tracked: bool = True, pending: str = "in progress…") -> Text:
        if done:
            return Text("✅ done", style="green")
        if not tracked:
            return Text("— not tracked", style="dim")
        return Text(f"⏳ {pending}", style="yellow")

    def build():
        cur = samples[-1]
        if cur is None:
            status_line = Text("…  starting health checks", style="dim")
            head = "starting…"
        elif cur:
            status_line = Text(f"🟢  HEALTHY — {healthy_label}", style="bold green")
            head = "[green]HEALTHY[/]"
        else:
            status_line = Text(f"🔴  IMPACTED — {impacted_label}", style="bold red")
            head = "[red]IMPACTED[/]"

        health = Table.grid(padding=(0, 1))
        health.add_row(status_line)
        bar, marker, tl_legend = render_health_timeline(
            sim_start, broke_at, fixed_at, datetime.now(timezone.utc))
        health.add_row(bar)
        if marker is not None:
            health.add_row(marker)
        health.add_row(tl_legend)
        health.add_row(Text("▇ working   ▁ broken   ▲ pinned key moments", style="dim"))

        steps = Table.grid(padding=(0, 2))
        steps.add_row(Text("1. Outage detected, on-call alerted"), status_word(alert_fired))
        steps.add_row(Text("2. PagerDuty incident raised"),
                      status_word(pd_created, tracked=bool(cfg["pagerduty"].get("api_token"))))
        steps.add_row(Text("3. SRE Agent engaged & diagnosing"),
                      status_word(agent_seen, tracked=bool(cfg.get("agent_name"))))
        steps.add_row(Text("4. Service recovered"), status_word(recovered, pending="not yet"))
        steps.add_row(Text("5. SRE Agent resolved the incident"),
                      status_word(agent_resolved, tracked=require_agent, pending="closing out…"))

        outer = Table.grid(padding=(1, 0))
        outer.add_row(Panel(health, title=f"{sc['emoji']}  {sc['title']}",
                            subtitle=head, border_style="blue"))
        outer.add_row(Panel(steps, title="Incident response — the automated workflow",
                            subtitle="✅ done    ⏳ in progress    — not tracked in this run",
                            border_style="magenta"))
        if pd_incident:
            outer.add_row(_pd_incident_panel(pd_incident))
        outer.add_row(timeline.render())
        return outer

    with Live(build(), console=console, refresh_per_second=4, screen=False) as live:
        for tick in range(900):  # ~15 min max
            now = datetime.now(timezone.utc)
            if web_health:
                burst = sc.get("concurrent_probe")
                if burst:
                    # Pool lane: the clamped DB connection limit only fails under concurrency.
                    healthy, _code, ms, failed, total = probe_burst(
                        url, sc["probe_path"], burst, timeout=probe_timeout)
                    if not healthy and not slow_noted:
                        slow_noted = True
                        timeline.add(f"Some students' quiz launches are failing under load "
                                     f"(~{failed}/{total} erroring).", "yellow")
                else:
                    ok, code, ms = probe(url, sc["probe_path"], timeout=probe_timeout)
                    # For a latency regression the endpoint still returns 200 — treat a
                    # response slower than the scenario threshold as "impacted".
                    healthy = ok and (slow_thr is None or ms < slow_thr)
                    if slow_thr and ok and not healthy and not slow_noted:
                        slow_noted = True
                        timeline.add(f"Quiz launches are slow for students (~{ms:.0f} ms).", "yellow")
            else:
                # No web endpoint to probe (back-office batch job). Health is driven by the
                # fault lifecycle: impacted until the disk is freed (auto-fix) or the SRE Agent
                # resolves the incident.
                healthy = fault_cleared
            samples.append(healthy)

            if healthy:
                healthy_streak += 1
            else:
                healthy_streak = 0
                impacted_seen = True   # we have now actually seen students feel the fault
                if broke_at is None:
                    broke_at = now     # pin the moment the outage began

            # Detection signal #1: Azure Monitor alert (fires for the app/perf scenarios,
            # which emit real logs). For nsg/appgw the blackhole is invisible to Azure Monitor.
            if not alert_fired and (now - last_alert).total_seconds() >= 15:
                last_alert = now
                if poll_azmon_alert(sub, sc["symptom_alert"], sim_start):
                    alert_fired = True
                    timeline.add("Outage detected by monitoring — on-call has been alerted.", "yellow")

            # Detection signal #2: PagerDuty incident lifecycle. For nsg/appgw the chaos synthetic
            # monitor pages PagerDuty directly, so poll it INDEPENDENTLY of the Azure Monitor alert.
            # Once we know the incident we refresh it by id to watch the agent work it:
            #   triggered -> acknowledged (agent picked it up) -> resolved (agent closed it out).
            if cfg["pagerduty"].get("api_token") and (now - last_pd).total_seconds() >= 10:
                last_pd = now
                if pd_incident is None:
                    inc = poll_pagerduty_incident(cfg["pagerduty"], sim_start,
                                                  sc.get("pd_title"))
                else:
                    inc = get_pagerduty_incident(cfg["pagerduty"], pd_incident.get("id")) or pd_incident
                if inc:
                    if not pd_created:
                        pd_created = True
                        timeline.add(f"PagerDuty incident #{inc.get('incident_number')} opened — "
                                     "on-call is paged.", "yellow")
                        if not alert_fired:
                            alert_fired = True  # the synthetic page is how this outage was detected
                    pd_incident = inc
                    st = (inc.get("status") or "").lower()
                    # The agent acknowledges the incident first thing (runbook step 0).
                    if st in ("acknowledged", "resolved") and not agent_seen:
                        agent_seen = True
                        timeline.add("SRE Agent acknowledged the incident and is diagnosing.", "green")
                    # Surface a clickable deep link to the agent's thread as soon as the incident
                    # has been routed and a correlated thread exists — do NOT wait for the agent to
                    # acknowledge. The thread is created at routing time (before ack), and the agent
                    # may ack→fix→resolve between two PagerDuty polls (or fix the probe before the
                    # backend ever goes unhealthy), so gating on agent_seen can miss the link entirely.
                    if thread_url is None:
                        tid = resolve_incident_thread(cfg, sim_start,
                                                      incident_id=inc.get("id"),
                                                      expected_title=sc.get("pd_title"))
                        if tid:
                            thread_url = agent_thread_url(cfg, tid)
                            timeline.add("🔗 View the SRE Agent's investigation", "cyan",
                                         link=thread_url)
                    # The agent resolves the incident at the end, after verifying recovery (step 9).
                    if st == "resolved" and not agent_resolved:
                        agent_resolved = True
                        timeline.add("SRE Agent resolved the PagerDuty incident.", "green")
                        if not web_health:
                            # No endpoint to prove recovery; the agent resolving the incident
                            # (after freeing the disk) is our recovery signal.
                            fault_cleared = True

            # Fallback agent-engaged signal when PagerDuty is not configured: look for the thread.
            if (alert_fired or pd_created) and not agent_seen and cfg.get("agent_name") \
                    and not cfg["pagerduty"].get("api_token") \
                    and (now - last_agent).total_seconds() >= 20:
                last_agent = now
                if poll_agent_thread(sc["agent"], sim_start):
                    agent_seen = True
                    timeline.add("SRE Agent picked up the incident and is investigating.", "green")
                    if thread_url is None:
                        tid = resolve_incident_thread(cfg, sim_start,
                                                      expected_title=sc.get("pd_title"))
                        if tid:
                            thread_url = agent_thread_url(cfg, tid)
                            timeline.add("🔗 View the SRE Agent's investigation", "cyan",
                                         link=thread_url)

            # Recovery is proven by the student journey itself: the public endpoint must be healthy
            # for several consecutive checks, AND we must have actually OBSERVED the fault hit
            # students first (impacted_seen). Without the impact gate a fault that never went live
            # — e.g. an App Gateway probe break whose live update silently failed — would be
            # declared "recovered" within seconds, before any agent could even engage.
            if not recovered and impacted_seen and healthy_streak >= 4 \
                    and (alert_fired or agent_seen or agent_resolved or auto_fix):
                recovered = True
                # Pin the fix at the first healthy sample of the recovering streak.
                fixed_at = now - timedelta(seconds=healthy_streak)
                if broke_at and fixed_at < broke_at:
                    fixed_at = broke_at
                timeline.add(sc.get("recovered_text",
                                    "Recovered — students can launch quizzes again."), "green")

            # Slow- or non-manifesting fault guard: if students never actually felt the fault
            # within the grace window, the break almost certainly didn't take effect (e.g. a live
            # App Gateway probe update that failed). Surface that honestly instead of a false
            # "recovered" with "agent never engaged".
            if not impacted_seen and not recovered \
                    and (now - sim_start).total_seconds() >= manifest_grace_s:
                timeline.add("The fault never reached students — the break did not take effect "
                             "(check the chaos break output and the live resource).", "red")
                if thread_url is None and cfg.get("agent_name"):
                    tid = resolve_incident_thread(cfg, sim_start,
                                                  incident_id=(pd_incident or {}).get("id"),
                                                  expected_title=sc.get("pd_title"))
                    if tid:
                        thread_url = agent_thread_url(cfg, tid)
                        timeline.add("🔗 View the SRE Agent's investigation", "cyan",
                                     link=thread_url)
                live.update(build())
                time.sleep(2)
                break

            if auto_fix and alert_fired and not recovered and healthy_streak == 0:
                # Stand-in for the SRE Agent when no live agent is wired up yet.
                timeline.add("Applying remediation (stand-in for the SRE Agent)…", "cyan")
                run_chaos(sc["fix_script"], cfg["resource_group"])
                if not web_health:
                    fault_cleared = True

            live.update(build())
            # Success = the SRE Agent CLOSED the loop (PagerDuty resolved + run complete).
            # We keep monitoring past service-health recovery until the agent resolves the
            # incident, so a lab that recovers the symptom but never gets the agent to close
            # the incident does NOT get reported as successful. (Dev/no-agent runs fall back
            # to service recovery.) Hold a few seconds after success for the graph tail.
            success = agent_resolved if require_agent else recovered
            if success:
                if completed_at is None:
                    completed_at = datetime.now(timezone.utc)
                if (datetime.now(timezone.utc) - completed_at).total_seconds() >= 6:
                    break
            time.sleep(1)

    success = agent_resolved if require_agent else recovered
    _report(sc, alert_fired, pd_created, agent_seen, recovered, agent_resolved,
            require_agent, success, pd_incident, thread_url)


def _report(sc, alert_fired, pd_created, agent_seen, recovered, agent_resolved,
            require_agent, success, pd_incident=None, thread_url=None):
    lines = [
        ("Symptom alert fired", alert_fired),
        ("PagerDuty incident raised", pd_created),
        ("SRE Agent engaged", agent_seen),
        ("Service recovered", recovered),
        ("SRE Agent resolved the incident", agent_resolved),
    ]
    t = Table(title=f"{sc['emoji']} Scenario report — {sc['title']}", show_header=False)
    for label, done in lines:
        t.add_row(label, "[green]yes[/]" if done else "[dim]no[/]")
    console.print()
    console.print(t)
    if pd_incident:
        num = pd_incident.get("incident_number")
        url = pd_incident.get("html_url") or ""
        console.print(f"[dim]PagerDuty incident[/] [bold]#{num}[/] — {url}")
    if thread_url:
        console.print(f"[dim]SRE Agent thread[/] [cyan][link={thread_url}]{thread_url}[/link][/]",
                      soft_wrap=True)
    if success and require_agent:
        console.print("[bold green]✔ Demo successful — the SRE Agent diagnosed, remediated, and "
                      "resolved the incident (PagerDuty closed).[/]")
    elif success:
        console.print("[green]✔ Service recovered (dev stand-in mode — no live SRE Agent / "
                      "PagerDuty in this run).[/]")
    elif require_agent and recovered and not agent_resolved:
        console.print("[yellow]⚠ Service recovered, but the SRE Agent has not resolved the "
                      "PagerDuty incident — NOT marking this demo successful. Check the agent "
                      "thread.[/]")
    else:
        console.print("[yellow]⚠ Monitoring window ended before the incident was closed — check "
                      "the agent / fix scripts.[/]")


# ── Preflight + menu ────────────────────────────────────────────────
def preflight(cfg: dict) -> bool:
    console.print("[bold]Pre-flight checks[/]")
    ok = True
    if not cfg.get("appgw_url"):
        console.print("  [red]✗ No public endpoint configured (set ZAVA_APPGW_URL or run post-provision).[/]")
        ok = False
    else:
        up, code, _ = probe(cfg["appgw_url"], "/")
        console.print(f"  {'✅' if up else '⚠️ '} portal endpoint {cfg['appgw_url']} (HTTP {code})")
    if _az("az account show") is None:
        console.print("  [red]✗ Not logged into Azure CLI (run: az login).[/]")
        ok = False
    else:
        console.print("  ✅ Azure CLI logged in")
    console.print(f"  {'✅' if cfg.get('pagerduty',{}).get('api_token') else '—'} PagerDuty polling "
                  f"{'enabled' if cfg.get('pagerduty',{}).get('api_token') else 'disabled (optional)'}")
    console.print(f"  {'✅' if cfg.get('agent_name') else '—'} SRE Agent polling "
                  f"{'enabled' if cfg.get('agent_name') else 'disabled (optional)'}")
    return ok


# ── On-demand governance audits ─────────────────────────────────────
# These run the EXISTING weekly SRE-Agent scheduled tasks immediately (out-of-band) — nothing is
# created or deleted. `task` is the name of the weekly scheduled task to invoke.
AUDITS = [
    {
        "key": "nsg", "emoji": "🛡️", "task": "zava-nsg-weekly-audit",
        "title": "Network Security Group audit",
        "finds": "overly-permissive, shadowed, legacy & orphaned NSG rules across the network path",
    },
    {
        "key": "rbac", "emoji": "🔐", "task": "zava-rbac-weekly-audit",
        "title": "RBAC / least-privilege audit",
        "finds": "over-privileged, directly-assigned, guest & stale role assignments",
    },
    {
        "key": "cost", "emoji": "💰", "task": "zava-cost-weekly-analysis",
        "title": "Cloud-cost analysis",
        "finds": "top cost drivers, week-over-week trend & idle / oversized / orphaned resources",
    },
]


def run_audits(cfg: dict) -> None:
    """Run all three weekly governance audits (NSG, RBAC, cost) on demand and live-watch them.

    Invokes each EXISTING weekly scheduled task immediately via its /execute endpoint (which
    returns the agent thread it spawned), then polls those threads until each posts its posture
    summary + branded deck. Nothing is created or deleted — the weekly schedules are untouched."""
    console.clear()
    intro = Text()
    intro.append("The SRE Agent runs three governance audits every week — ", style="white")
    intro.append("network security, access (RBAC), and cloud cost.\n\n", style="bold white")
    for a in AUDITS:
        intro.append(f"  {a['emoji']}  ", style="white")
        intro.append(f"{a['title']}", style="bold white")
        intro.append(f" — finds {a['finds']}.\n", style="dim")
    intro.append("\nThis runs all three existing weekly tasks right now instead of waiting for their "
                 "schedule. Each runs read-only against this subscription and produces a branded Zava "
                 "PowerPoint with prioritised, least-privilege/secure-by-default recommendations.", style="white")
    console.print(Panel(intro, title="🧭  On-demand governance audits",
                        subtitle="[dim]read-only — the agent recommends, it never changes anything[/]",
                        border_style="blue", padding=(1, 2)))
    console.print()

    ep = _agent_dataplane_endpoint(cfg)
    tok = _dataplane_token()
    if not ep or not tok:
        console.print("[red]Could not reach the SRE Agent data plane.[/] Make sure you're signed in with "
                      "[bold]az login[/] and that config.json points at the Zava agent.")
        return

    tasks_by_name = {t.get("name"): t for t in _dp_list_tasks(ep, tok)}
    runs = []
    with console.status("[yellow]Asking the SRE Agent to run all three weekly audits now…[/]", spinner="dots"):
        for a in AUDITS:
            task = tasks_by_name.get(a["task"])
            if not task:
                console.print(f"[yellow]⚠ Scheduled task '{a['task']}' not found on the agent — skipping. "
                              f"Available: {', '.join(sorted(tasks_by_name)) or '(none)'}[/]")
            thread_id = _dp_execute_task(ep, tok, task["id"]) if task else None
            runs.append({"audit": a, "thread_id": thread_id, "posture": None,
                         "state": "running" if thread_id else "failed"})

    started = [r for r in runs if r["thread_id"]]
    if not started:
        console.print("[red]None of the weekly audit tasks could be started.[/] Confirm the three weekly "
                      "scheduled tasks exist on the agent and that you have access to run them.")
        return
    console.print(f"[green]✔ Started {len(started)} weekly audit(s) now.[/] A full audit usually takes "
                  "5–10 minutes.\n")

    def render() -> Table:
        t = Table(show_header=True, header_style="bold dim", box=box.SIMPLE_HEAD, pad_edge=False)
        t.add_column("Audit", no_wrap=True)
        t.add_column("Status", no_wrap=True)
        t.add_column("Posture", no_wrap=True)
        t.add_column("Watch the agent work", style="dim", overflow="fold")
        badges = {"running": "[cyan]◐ diagnosing…[/]", "done": "[green]✔ done[/]",
                  "failed": "[red]✖ could not start[/]"}
        for r in runs:
            a = r["audit"]
            pcolor = {"AT RISK": "red", "NEEDS ATTENTION": "red", "ATTENTION REQUIRED": "red",
                      "ACTION REQUIRED": "red", "HEALTHY": "green"}.get((r["posture"] or "").upper(), "yellow")
            posture = f"[{pcolor}]{r['posture']}[/]" if r["posture"] else "[dim]—[/]"
            # Short clickable anchor (OSC-8 hyperlink) so the long thread URL is never truncated to
            # an ellipsis inside the table cell; the full URLs are also listed below for copy/paste.
            link = (f"[link={agent_thread_url(cfg, r['thread_id'])}]🔗 open thread ↗[/link]"
                    if r["thread_id"] else "[dim]—[/]")
            t.add_row(f"{a['emoji']} [bold]{a['title']}[/]", badges.get(r["state"], r["state"]), posture, link)
        return t

    deadline = time.monotonic() + 12 * 60   # cap the live watch at 12 minutes
    with Live(render(), console=console, refresh_per_second=4) as live:
        while time.monotonic() < deadline:
            time.sleep(8)
            for r in started:
                if r["state"] == "done":
                    continue
                posture = _extract_posture(_dp_thread_messages(ep, tok, r["thread_id"]))
                if posture:
                    r["posture"], r["state"] = posture, "done"
            live.update(render())
            if all(r["state"] in ("done", "failed") for r in started):
                break

    console.print()
    # Always print the full, untruncated thread URLs so they can be copied even on terminals
    # that don't render OSC-8 hyperlinks (soft_wrap keeps Rich from cropping the long URL).
    console.print("[bold]Audit threads[/] [dim](open in the Azure SRE portal):[/]")
    for r in started:
        a = r["audit"]
        url = agent_thread_url(cfg, r["thread_id"])
        console.print(f"  {a['emoji']} {a['title']}: [link={url}]{url}[/link]", soft_wrap=True)
    console.print()
    done = [r for r in started if r["state"] == "done"]
    if len(done) == len(started):
        console.print(f"[bold green]✔ All {len(done)} audits finished.[/] Open each thread above to read the "
                      "findings and download its Zava PowerPoint deck.")
    else:
        console.print(f"[yellow]{len(done)}/{len(started)} audits finished within the watch window.[/] "
                      "The rest are still running — follow their thread links above to watch them in the portal.")


def launch_scenarios_parallel(keys: list[str]) -> None:
    """Open a separate terminal tab per selected key, each running non-interactively.

    Works for a single selection or many. The pseudo-key '__audits__' launches the
    governance-audits tab (`--audits`); every other key launches that scenario
    (`--scenario <key>`). Prefers Windows Terminal (one window, a tab per lab);
    otherwise falls back to a standalone console window per lab."""
    if not keys:
        return
    py = sys.executable
    script = str(Path(__file__).resolve())

    def title_for(k: str) -> str:
        return "🧭 audits" if k == "__audits__" else f"{SCENARIOS[k]['emoji']} {k}"

    def flags_for(k: str) -> list[str]:
        return ["--audits"] if k == "__audits__" else ["--scenario", k]

    wt = shutil.which("wt")
    if wt:
        args = [wt]
        for i, k in enumerate(keys):
            if i:
                args.append(";")
            args += ["new-tab", "--title", title_for(k), py, script] + flags_for(k)
        subprocess.Popen(args)
        how = "Windows Terminal (one tab per lab)"
    else:
        for k in keys:
            label = "audits" if k == "__audits__" else k
            flag = "--audits" if k == "__audits__" else f"--scenario {k}"
            subprocess.Popen(f'start "Zava {label}" "{py}" "{script}" {flag}', shell=True)
        how = "separate console windows"

    n_labs = sum(1 for k in keys if k != "__audits__")
    parts = []
    if n_labs:
        parts.append(f"{n_labs} scenario" + ("s" if n_labs != 1 else ""))
    if "__audits__" in keys:
        parts.append("governance audits")
    console.print(f"[green]▶ Launched {' + '.join(parts)} in parallel[/] — {how}.")
    console.print(f"[dim]Each lab writes a log to {LOG_DIR}\\<scenario>-<time>.log, and its window now "
                  "stays open (even on a crash) so you can read what happened.[/]")
    if len(keys) > 1:
        console.print("[yellow]Note:[/] all labs share one Azure environment, so their faults and "
                      "recoveries will overlap. Use separate environments for fully independent runs.")


def launch_all_parallel() -> None:
    """Open every scenario plus the governance audits, one terminal tab each."""
    launch_scenarios_parallel(list(SCENARIOS.keys()) + ["__audits__"])


def menu() -> str:
    console.print(Panel("[bold]Zava Learning — SRE Agent demo[/]\n"
                        "[dim]Each scenario plants ONE real, symptom-only fault for the SRE Agent to "
                        "detect, diagnose, and remediate.[/]", border_style="blue"))

    # Scenarios grouped by the layer the fault lives in. Numbering runs sequentially down the
    # table; `ordered` is the source of truth that maps the printed number back to a key.
    groups = [
        ("Network & edge", [
            ("nsg",   "A firewall rule is blocking the front door from reaching the apps"),
            ("appgw", "The front door is sending visitors to an app address that no longer exists"),
        ]),
        ("Compute & app", [
            ("app",   "The quiz app was turned down to zero copies, so nothing is running"),
            ("perf",  "A new version of the quiz app was released that runs much slower"),
        ]),
        ("Database", [
            ("query",  "A database index is damaged, so each search reads all 3 million rows"),
            ("pool",   "The database ran out of allowed simultaneous connections"),
            ("secret", "The saved database password was changed to a wrong value"),
        ]),
        ("Infra / VM", [
            ("disk",   "The reporting server's disk filled up, leaving no room to save files"),
        ]),
    ]
    ordered = [k for _, items in groups for k, _ in items]
    leftovers = [k for k in SCENARIOS if k not in ordered]
    if leftovers:
        groups.append(("Other", [(k, "") for k in leftovers]))
        ordered += leftovers
    # Governance audits are a numbered entry too — selecting it triggers all three weekly audits.
    groups.append(("Weekly governance audits", [
        ("__audits__", "Read-only NSG · RBAC · cost review — each ships a branded PowerPoint")]))
    ordered.append("__audits__")

    tbl = Table(show_header=True, header_style="bold dim", box=box.SIMPLE_HEAD, pad_edge=False)
    tbl.add_column("#", justify="right", style="bold cyan", no_wrap=True)
    tbl.add_column("Scenario", no_wrap=True)
    tbl.add_column("Student symptom", style="white", no_wrap=True)
    tbl.add_column("What actually broke", style="dim")
    tbl.add_column("Target", justify="right", style="dim", no_wrap=True)

    n = 0
    for gi, (gtitle, items) in enumerate(groups):
        if gi:
            tbl.add_section()
        tbl.add_row("", f"[bold yellow]{gtitle}[/]", "", "", "")
        for key, fault in items:
            n += 1
            if key == "__audits__":
                tbl.add_row(str(n), "  🧭 [bold]audits[/]", "All three weekly governance audits",
                            fault, "SRE Agent")
                continue
            sc = SCENARIOS[key]
            port = sc.get("lane_port")
            target = f":{port}" if port else ("VM" if sc.get("web_health") is False else "—")
            tbl.add_row(str(n), f"  {sc['emoji']} [bold]{key}[/]", sc["title"], fault, target)
    console.print(tbl)

    console.print("\n[bold]a[/]. ▶  run ALL labs + audits in parallel (a terminal each)   "
                  "[bold]r[/]. ♻️  reset to baseline   [bold]q[/]. quit")
    console.print("[dim]Tip: pick one (e.g. [/][bold]3[/][dim]), a list ([/][bold]1,5,6[/][dim]), or a "
                  "range ([/][bold]1-5[/][dim]) — each opens in its own tab.[/]")
    choice = console.input("\nSelect scenario(s) [dim](number, name, list, or range)[/]: ").strip().lower()
    if choice in ("q", "quit"):
        return ""
    if choice in ("a", "all"):
        return list(SCENARIOS.keys()) + ["__audits__"]
    if choice in ("r", "reset"):
        return "__reset__"
    return _parse_selection(choice, ordered)


def _parse_selection(choice: str, ordered: list[str]):
    """Resolve a menu choice into an ordered, de-duplicated list of scenario keys.

    Accepts a single number or name, a comma-separated list (``1,5,6`` or ``nsg,disk``),
    inclusive ranges (``1-5``), and any mix (``1,3-5,disk``). The pseudo-key
    ``__audits__`` is selectable by its number or by name (audits/governance).
    Returns ``[]`` when nothing valid was selected."""
    out: list[str] = []

    def add(k: str) -> None:
        if k and k not in out:
            out.append(k)

    for tok in choice.replace(" ", "").split(","):
        if not tok:
            continue
        if tok in ("audit", "audits", "governance", "g"):
            add("__audits__")
            continue
        m = re.fullmatch(r"(\d+)-(\d+)", tok)
        if m:
            lo, hi = int(m.group(1)), int(m.group(2))
            if lo > hi:
                lo, hi = hi, lo
            for num in range(lo, hi + 1):
                if 1 <= num <= len(ordered):
                    add(ordered[num - 1])
            continue
        if tok.isdigit():
            num = int(tok)
            if 1 <= num <= len(ordered):
                add(ordered[num - 1])
            continue
        if tok in SCENARIOS:
            add(tok)
    return out


def run_scenario(key: str, cfg: dict, auto_fix: bool):
    sc = SCENARIOS[key]
    show_backstory(sc, key)
    if not inject_fault(sc, cfg):
        console.print("[red]Could not inject the fault. Aborting scenario.[/]")
        return
    monitor(cfg, sc, auto_fix)


def run_lane_standalone(key: str, cfg: dict, auto_fix: bool) -> None:
    """Run one scenario in its own terminal (used by 'run ALL'). Everything is teed to a log
    file, any crash is captured with a full traceback, and the window is held open at the end
    so the operator can always see why a lab stopped — it never just vanishes."""
    log_path = _open_log(key)
    console.clear()
    console.print(f"[dim]Logging this lab to {log_path}[/]\n")
    try:
        if not preflight(cfg):
            console.print("\n[red]Pre-flight failed — see the issues above.[/]")
            _log("preflight failed")
        else:
            console.print()
            run_scenario(key, cfg, auto_fix)
    except Exception:
        _log("UNHANDLED EXCEPTION:\n" + traceback.format_exc())
        console.print("\n[bold red]This lab crashed:[/]")
        console.print_exception()
        console.print(f"\n[yellow]Full crash details saved to:[/] {log_path}")
    finally:
        _log("=== run ended ===")
        try:
            console.input("\n[dim]Press Enter to close this window…[/]")
        except (EOFError, KeyboardInterrupt):
            pass


def main():
    ap = argparse.ArgumentParser(description="Zava Learning SRE Agent demo simulator")
    ap.add_argument("--scenario", choices=list(SCENARIOS.keys()))
    ap.add_argument("--reset", nargs="?", const="all", choices=RESET_TARGETS,
                    metavar="SCENARIO",
                    help="restore baseline (nsg|appgw|app|perf|query|pool|secret|disk|all) and exit; default all")
    ap.add_argument("--status", action="store_true", help="one-shot health probe and exit")
    ap.add_argument("--all", action="store_true",
                    help="launch every scenario in its own terminal and exit")
    ap.add_argument("--audits", action="store_true",
                    help="trigger the three weekly governance audits (NSG, RBAC, cost) now and exit")
    ap.add_argument("--auto-fix", action="store_true",
                    help="apply the fix script as an SRE Agent stand-in (for dry runs)")
    args = ap.parse_args()

    cfg = load_config()

    if args.status:
        up, code, ms = probe(cfg["appgw_url"], "/")
        console.print(f"portal {cfg['appgw_url']} -> HTTP {code} ({'up' if up else 'down'}, {ms:.0f} ms)")
        return

    if args.reset:
        run_reset(cfg, args.reset)
        return

    if args.all:
        launch_all_parallel()
        return

    if args.audits:
        run_audits(cfg)
        # When spawned in its own window (e.g. by "run ALL"), hold it open so the summary stays.
        try:
            console.input("\n[dim]Press Enter to close this window…[/]")
        except (EOFError, KeyboardInterrupt):
            pass
        return

    # A scenario launched in its own terminal (e.g. by "run ALL") owns its full lifecycle:
    # it logs to a file, captures any crash, and holds the window open at the end.
    if args.scenario:
        run_lane_standalone(args.scenario, cfg, args.auto_fix)
        return

    console.clear()
    if not preflight(cfg):
        console.print("\n[red]Pre-flight failed. Fix the issues above and retry.[/]")
        return
    console.print()

    first = True
    while True:
        if not first:
            console.clear()
            preflight(cfg)
            console.print()
        first = False
        key = menu()
        if key == "":
            break
        if key == "__reset__":
            run_reset(cfg)
            console.input("\n[dim]Press Enter to return to the menu...[/]")
            continue
        if not key:
            console.print("[yellow]No valid scenario selected — try a number, name, list "
                          "(1,5,6), or range (1-5).[/]")
            console.input("\n[dim]Press Enter to return to the menu...[/]")
            continue
        # Any scenario selection (single, list, or range) opens each lab in its own tab.
        launch_scenarios_parallel(key)
        console.input("\n[dim]Press Enter to return to the menu...[/]")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        console.print("\n[dim]Interrupted.[/]")
