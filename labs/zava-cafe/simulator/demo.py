#!/usr/bin/env python3
"""
╔══════════════════════════════════════════════════════════════╗
║   ZAVA DEMO SIMULATOR — Zava Café SRE Agent Lab         ║
╚══════════════════════════════════════════════════════════════╝

A beautiful CLI simulator for demonstrating Azure SRE Agent
capabilities during the Zava Café recording.

Scenarios:
  1. Slow Query (Missing Index)  — Performance degradation
  2. Blocking Chain              — Transaction blocking
  3. Bad Deployment              — App health failure
  4. ServiceNow Integration      — Incident management
  5. Reset All                   — Clean up demo environment

Usage:
  python simulator/demo.py
"""

import sys
import os
import time
import json
import threading
import random
import subprocess
from datetime import datetime

# ── Auto-install dependencies ───────────────────────────────
def _ensure_deps():
    missing = []
    for pkg in ("rich", "requests", "pymssql"):
        try:
            __import__(pkg)
        except ImportError:
            missing.append(pkg)
    if missing:
        print(f"Installing: {', '.join(missing)} ...")
        os.system(f'"{sys.executable}" -m pip install {" ".join(missing)} --quiet')
        print("Done.\n")

_ensure_deps()

from rich.console import Console
from rich.panel import Panel
from rich.table import Table
from rich.live import Live
from rich.text import Text
from rich.align import Align
from rich import box
import requests as req

try:
    import pymssql
    HAS_PYMSSQL = True
except ImportError:
    HAS_PYMSSQL = False

if sys.platform == "win32":
    import msvcrt

# ── Config (override with env vars) ────────────────────────
SQL_SERVER   = os.environ.get("ZAVA_SQL_SERVER",   "sql-zava.database.windows.net")
SQL_DATABASE = os.environ.get("ZAVA_SQL_DATABASE", "sqldb-zava")
SQL_USER     = os.environ.get("ZAVA_SQL_USER",     "<SQL_ADMIN_USER>")
SQL_PASSWORD = os.environ.get("ZAVA_SQL_PASSWORD", "<SQL_PASSWORD>")

APP_URL      = os.environ.get("ZAVA_APP_URL",      "https://app-zava.azurewebsites.net")
HEALTH_URL   = f"{APP_URL}/health"

# SRE Agent HTTP trigger URL — populated by `azd hooks run postprovision`
# (see labs/zava-cafe/scripts/post-provision.sh → Step 3.5).
# To override / set manually: `azd env set ZAVA_HTTP_TRIGGER_URL <url>`.
ZAVA_HTTP_TRIGGER_URL = os.environ.get("ZAVA_HTTP_TRIGGER_URL", "")
SRE_AGENT_ENDPOINT    = os.environ.get("SRE_AGENT_ENDPOINT", "")
SRE_AGENT_THREAD_BASE = os.environ.get("SRE_AGENT_THREAD_BASE", "https://sre.azure.com/threads")

console = Console()

# ── Helpers ─────────────────────────────────────────────────

def check_key():
    """Non-blocking keypress check (Windows)."""
    if sys.platform != "win32":
        return None
    if msvcrt.kbhit():
        ch = msvcrt.getch()
        if ch in (b"\x00", b"\xe0"):
            msvcrt.getch()  # consume second byte of special key
            return None
        try:
            return ch.decode("utf-8").lower()
        except Exception:
            return None
    return None


def get_sql_connection(login_timeout=10):
    """Return a pymssql connection or None."""
    if not HAS_PYMSSQL:
        console.print("[red]pymssql not installed. Run: pip install pymssql[/]")
        return None
    try:
        return pymssql.connect(
            server=SQL_SERVER,
            user=SQL_USER,
            password=SQL_PASSWORD,
            database=SQL_DATABASE,
            login_timeout=login_timeout,
            timeout=120,
        )
    except Exception as e:
        console.print(f"[red]SQL Connection Error:[/] {e}")
        return None


def _color(ms):
    if ms < 100:
        return "green"
    if ms < 500:
        return "yellow"
    return "red"


def _bar(ms, max_ms=2000, width=30):
    filled = min(int((ms / max(max_ms, 1)) * width), width)
    c = _color(ms)
    return f"[{c}]{'█' * filled}{'░' * (width - filled)}[/]"


def _status(ms):
    if ms < 100:
        return "[green bold]⚡ FAST[/]"


def _check_alert_fired(since_time=None):
    """Check DTU alert status. Returns (condition, start_time) or (None, None)."""
    try:
        import subprocess
        sub = os.environ.get("ZAVA_SUBSCRIPTION_ID", "<SUBSCRIPTION_ID>")
        result = subprocess.run(
            f'az rest --method GET --url "https://management.azure.com/subscriptions/{sub}/providers/Microsoft.AlertsManagement/alerts?api-version=2019-03-01&targetResourceGroup=rg-zava" -o json',
            capture_output=True, text=True, timeout=20, shell=True
        )
        if result.returncode == 0 and result.stdout.strip():
            data = json.loads(result.stdout)
            for alert in data.get("value", []):
                props = alert.get("properties", {}).get("essentials", {})
                rule = props.get("alertRule", "")
                condition = props.get("monitorCondition", "")
                start_str = props.get("startDateTime", "")
                if "alert-zava-dtu-high" not in rule:
                    continue
                if condition not in ("Fired", "Resolved"):
                    continue
                if since_time and start_str:
                    try:
                        clean = start_str.split("+")[0].rstrip("Z")
                        if "." in clean:
                            parts = clean.split(".")
                            clean = parts[0] + "." + parts[1][:6]
                        for fmt in ("%Y-%m-%dT%H:%M:%S.%f", "%Y-%m-%dT%H:%M:%S", "%m/%d/%Y %H:%M:%S"):
                            try:
                                alert_time = datetime.strptime(clean, fmt)
                                break
                            except ValueError:
                                continue
                        else:
                            continue
                        if alert_time < since_time:
                            continue
                    except Exception:
                        continue
                return condition, start_str
        return None, None
    except Exception:
        return None, None


class EventTimeline:
    """Tracks key events with timestamps for display."""
    def __init__(self):
        self.events = []
        self.start_time = datetime.now()

    def add(self, event, style="white"):
        self.events.append({
            "ts": datetime.now().strftime("%H:%M:%S"),
            "elapsed": f"+{(datetime.now() - self.start_time).seconds}s",
            "event": event,
            "style": style,
        })

    def to_table(self):
        t = Table(
            title="[bold]Event Timeline[/]",
            box=box.ROUNDED, border_style="blue", show_lines=False,
            width=74,
        )
        t.add_column("Time", style="dim", width=10)
        t.add_column("Elapsed", style="dim", width=8)
        t.add_column("Event", width=50)
        for e in self.events[-5:]:
            t.add_row(e["ts"], e["elapsed"], f"[{e['style']}]{e['event']}[/]")
        return t


class PerfGraph:
    """Rolling ASCII performance graph showing query durations over time."""

    GRAPH_WIDTH = 50
    GRAPH_HEIGHT = 8
    BLOCKS = " ▁▂▃▄▅▆▇█"

    def __init__(self):
        self.all_durations = []  # (timestamp, ms, had_index)
        self.index_created_at = None

    def add(self, ms, has_index=False):
        self.all_durations.append((datetime.now(), ms, has_index))
        if has_index and self.index_created_at is None:
            self.index_created_at = len(self.all_durations) - 1

    def to_panel(self):
        if len(self.all_durations) < 2:
            return Panel("[dim]Collecting data...[/]", title="[bold]Performance Graph[/]", border_style="magenta", width=76)

        # Only show the snapshot graph AFTER index is created
        if self.index_created_at is None:
            # Show a simple live indicator instead
            recent = [s[1] for s in self.all_durations[-30:]]
            avg = sum(recent) / len(recent)
            sparkline = ""
            for ms in self.all_durations[-50:]:
                m = ms[1]
                if m > 1000: sparkline += "[red]█[/]"
                elif m > 500: sparkline += "[yellow]▆[/]"
                elif m > 200: sparkline += "[yellow]▃[/]"
                else: sparkline += "[green]▁[/]"
            return Panel(
                f"  Live: {sparkline}\n  Avg: [{_color(avg)}]{avg:.0f}ms[/]  |  Samples: {len(self.all_durations)}  |  Waiting for SRE Agent to fix...",
                title="[bold magenta]📊 Live Performance[/]",
                border_style="magenta", width=76,
            )

        # === SNAPSHOT: 1 min before and after the fix ===
        fix_time = self.all_durations[self.index_created_at][0]
        before = [(t, ms, idx) for t, ms, idx in self.all_durations
                  if (fix_time - t).total_seconds() <= 60 and (fix_time - t).total_seconds() >= 0 and not idx][-20:]
        after = [(t, ms, idx) for t, ms, idx in self.all_durations
                 if (t - fix_time).total_seconds() >= 0 and (t - fix_time).total_seconds() <= 60 and idx][:20]
        samples = before + after

        if not samples:
            return Panel("[dim]Building snapshot...[/]", title="[bold]Performance Graph[/]", border_style="magenta", width=76)

        durations = [s[1] for s in samples]
        has_idx = [s[2] for s in samples]
        max_ms = max(max(durations), 100)
        if max_ms > 2000: max_ms = ((int(max_ms) // 500) + 1) * 500
        elif max_ms > 500: max_ms = ((int(max_ms) // 200) + 1) * 200
        else: max_ms = ((int(max_ms) // 100) + 1) * 100

        before_avg = sum(s[1] for s in before) / max(len(before), 1)
        after_avg = sum(s[1] for s in after) / max(len(after), 1)
        improvement = ((before_avg - after_avg) / max(before_avg, 1)) * 100

        lines = []
        for row in range(self.GRAPH_HEIGHT, 0, -1):
            threshold = (row / self.GRAPH_HEIGHT) * max_ms
            label = f"{int(threshold):>5}ms │"
            bar = ""
            for i, ms in enumerate(durations):
                if ms >= threshold:
                    bar += "[red]█[/]" if not has_idx[i] else "[green]█[/]"
                else:
                    lower = ((row - 1) / self.GRAPH_HEIGHT) * max_ms
                    if ms > lower:
                        frac = (ms - lower) / (threshold - lower)
                        bi = min(int(frac * (len(self.BLOCKS) - 1)), len(self.BLOCKS) - 1)
                        char = self.BLOCKS[bi]
                        bar += f"[red]{char}[/]" if not has_idx[i] else f"[green]{char}[/]"
                    else:
                        bar += " "
            lines.append(f"{label}{bar}")

        lines.append(f"    0ms │{'─' * len(durations)}")
        fix_offset = len(before)
        pointer = " " * 8 + " " * fix_offset + "[green bold]▼ SRE Agent fixed it here[/]"
        stats = f"\n  [red]██ BEFORE[/] avg: [red bold]{before_avg:.0f}ms[/]    [green]██ AFTER[/] avg: [green bold]{after_avg:.0f}ms[/]    [cyan bold]⚡ {improvement:.0f}% faster[/]"

        return Panel(
            "\n".join(lines) + f"\n{pointer}" + stats,
            title="[bold magenta]📊 Before / After — SRE Agent Fix[/]",
            border_style="green", width=76,
        )
        fix_time = self.all_durations[self.index_created_at][0]

        # Get samples from 60s before fix
        before = [(t, ms, idx) for t, ms, idx in self.all_durations
                  if (fix_time - t).total_seconds() <= 60 and (fix_time - t).total_seconds() >= 0 and not idx]
        # Get samples from 60s after fix
        after = [(t, ms, idx) for t, ms, idx in self.all_durations
                 if (t - fix_time).total_seconds() >= 0 and (t - fix_time).total_seconds() <= 60 and idx]

        # Take up to 20 samples each
        before = before[-20:]
        after = after[:20]
        samples = before + after

        if not samples:
            return Panel("[dim]Building snapshot...[/]", title="[bold]Performance Graph[/]", border_style="magenta", width=76)

        durations = [s[1] for s in samples]
        has_idx = [s[2] for s in samples]

        max_ms = max(max(durations), 100)
        if max_ms > 2000: max_ms = ((int(max_ms) // 500) + 1) * 500
        elif max_ms > 500: max_ms = ((int(max_ms) // 200) + 1) * 200
        else: max_ms = ((int(max_ms) // 100) + 1) * 100

        # Calculate before/after averages
        before_avg = sum(s[1] for s in before) / max(len(before), 1)
        after_avg = sum(s[1] for s in after) / max(len(after), 1)
        improvement = ((before_avg - after_avg) / max(before_avg, 1)) * 100

        lines = []
        for row in range(self.GRAPH_HEIGHT, 0, -1):
            threshold = (row / self.GRAPH_HEIGHT) * max_ms
            label = f"{int(threshold):>5}ms │"
            bar = ""
            for i, ms in enumerate(durations):
                if ms >= threshold:
                    bar += "[red]█[/]" if not has_idx[i] else "[green]█[/]"
                else:
                    lower = ((row - 1) / self.GRAPH_HEIGHT) * max_ms
                    if ms > lower:
                        frac = (ms - lower) / (threshold - lower)
                        idx = min(int(frac * (len(self.BLOCKS) - 1)), len(self.BLOCKS) - 1)
                        char = self.BLOCKS[idx]
                        bar += f"[red]{char}[/]" if not has_idx[i] else f"[green]{char}[/]"
                    else:
                        bar += " "
            lines.append(f"{label}{bar}")

        lines.append(f"    0ms │{'─' * len(durations)}")

        # Marker at the fix point
        fix_offset = len(before)
        pointer_line = " " * 8 + " " * fix_offset + "[green bold]▼ SRE Agent fixed it here[/]"

        # Stats
        stats = f"\n  [red]██ BEFORE[/] avg: [red bold]{before_avg:.0f}ms[/]    [green]██ AFTER[/] avg: [green bold]{after_avg:.0f}ms[/]    [cyan bold]⚡ {improvement:.0f}% faster[/]"

        graph_text = "\n".join(lines) + f"\n{pointer_line}" + stats

        return Panel(
            graph_text,
            title="[bold magenta]📊 Before / After — SRE Agent Fix[/]",
            border_style="green",
            width=76,
        )


def _status(ms):
    if ms < 100:
        return "[green bold]⚡ FAST[/]"
    if ms < 500:
        return "[yellow bold]⏱  OK[/]"
    return "[red bold]🐌 SLOW[/]"


def health_check():
    """Poll the /health endpoint. Returns (status_code, latency_ms, body)."""
    try:
        r = req.get(HEALTH_URL, timeout=5)
        return r.status_code, r.elapsed.total_seconds() * 1000, r.text[:200]
    except Exception as e:
        return 0, 0, str(e)[:200]


def _wait_key():
    """Block until any key is pressed (Windows)."""
    if sys.platform == "win32":
        msvcrt.getch()
    else:
        input()

# ── Banner & Menu ───────────────────────────────────────────

BANNER = r"""[bold cyan]
  ███████╗ █████╗ ██╗   ██╗ █████╗
  ╚══███╔╝██╔══██╗██║   ██║██╔══██╗
    ███╔╝ ███████║██║   ██║███████║
   ███╔╝  ██╔══██║╚██╗ ██╔╝██╔══██║
  ███████╗██║  ██║ ╚████╔╝ ██║  ██║
  ╚══════╝╚═╝  ╚═╝  ╚═══╝  ╚═╝  ╚═╝
  [bold white]Zava Café — SRE Agent Demo Simulator[/bold white][/bold cyan]
"""


def show_menu():
    console.clear()
    console.print(BANNER)

    tbl = Table(
        title="[bold]Demo Scenarios[/]",
        box=box.DOUBLE_EDGE,
        border_style="cyan",
        title_style="bold white",
        show_lines=True,
        padding=(0, 2),
    )
    tbl.add_column("#", style="bold cyan", width=4, justify="center")
    tbl.add_column("Scenario", style="bold white", width=28)
    tbl.add_column("Description", style="dim white", width=52)

    tbl.add_row(
        "1", "🐌  Slow Query",
        "Missing index → slow queries on Products.\n"
        "SRE Agent detects & creates the index.",
    )
    tbl.add_row(
        "2", "🔒  Blocking Chain",
        "Transaction holds locks, blocking other sessions.\n"
        "SRE Agent detects & kills the blocker.",
    )
    tbl.add_row(
        "3", "🚀  GH Actions Deployment",
        "Bad config via GitHub Actions workflow.\n"
        "SRE Agent validates, rollbacks, creates GH Issue.",
    )
    tbl.add_row(
        "5", "📡  Simulate HTTP Trigger",
        "Inject bad config + fire HTTP trigger.\n"
        "SRE Agent detects & restores config.",
    )
    tbl.add_row(
        "6", "🎯  Simulate All",
        "Launch scenarios 1 and 3 in separate\n"
        "terminals simultaneously.",
    )
    tbl.add_row(
        "7", "🧹  Reset All",
        "Drop indexes, kill blockers, restore config.\n"
        "Returns environment to baseline.",
    )
    tbl.add_row("Q", "🚪  Quit", "Exit the simulator.")

    console.print(Align.center(tbl))
    console.print()

    # Quick status
    lines = []
    try:
        r = req.get(HEALTH_URL, timeout=3)
        h = "[green]● Healthy[/]" if r.status_code == 200 else f"[red]● Down ({r.status_code})[/]"
    except Exception:
        h = "[red]● Unreachable[/]"
    lines.append(f"  App Health:  {h}")
    lines.append(f"  SQL Server:  [dim]{SQL_SERVER}[/]")
    lines.append(f"  Database:    [dim]{SQL_DATABASE}[/]")
    lines.append(f"  pymssql:     {'[green]● Installed[/]' if HAS_PYMSSQL else '[red]● Missing[/]'}")

    console.print(Align.center(
        Panel("\n".join(lines), title="[bold]System Status[/]", border_style="dim", width=62)
    ))
    console.print()


# ═══════════════════════════════════════════════════════════
# SCENARIO 1 — Slow Query (Missing Index)
# ═══════════════════════════════════════════════════════════

def scenario_slow_query():
    console.clear()
    console.print(Panel(
        "[bold]Scenario 1 — Slow Query (Missing Index)[/]\n\n"
        "Runs repeated queries on [cyan]Products.Category[/].\n"
        "Without an index the DB does a table scan (slow).\n"
        "SRE Agent should detect this and create an index.\n\n"
        "[dim]Controls:  q = quit   r/d = drop index (reset)[/]",
        title="[cyan bold]🐌 SLOW QUERY SIMULATOR[/]",
        border_style="cyan", width=76,
    ))

    conn = get_sql_connection()
    if not conn:
        console.print("[dim]Press any key…[/]"); _wait_key(); return

    cur = conn.cursor()
    categories = [
        "Espresso", "Brewed Coffee", "Pastries",
        "Merch",
    ]
    log = []
    index_found = False
    index_banner_shown = False

    def _has_index():
        try:
            cur.execute("""
                SELECT COUNT(*)
                FROM   sys.indexes i
                JOIN   sys.index_columns ic
                       ON i.object_id = ic.object_id AND i.index_id = ic.index_id
                JOIN   sys.columns c
                       ON ic.object_id = c.object_id AND ic.column_id = c.column_id
                WHERE  i.object_id = OBJECT_ID('Products')
                  AND  c.name = 'Category'
                  AND  i.type > 0
            """)
            row = cur.fetchone()
            return (row[0] > 0) if row else False
        except Exception:
            return False

    def _drop_idx():
        try:
            cur.execute("""
                DECLARE @sql NVARCHAR(MAX) = '';
                SELECT @sql += 'DROP INDEX ' + QUOTENAME(i.name) + ' ON Products; '
                FROM   sys.indexes i
                JOIN   sys.index_columns ic
                       ON i.object_id = ic.object_id AND i.index_id = ic.index_id
                JOIN   sys.columns c
                       ON ic.object_id = c.object_id AND ic.column_id = c.column_id
                WHERE  i.object_id = OBJECT_ID('Products')
                  AND  c.name = 'Category'
                  AND  i.type > 0
                  AND  i.is_primary_key = 0;
                IF @sql <> '' EXEC sp_executesql @sql;
            """)
            conn.commit()
        except Exception as e:
            console.print(f"[yellow]drop-index warning: {e}[/]")

    def _flush_cache():
        """Clear SQL plan cache so recompiles pick up index changes."""
        try:
            cur.execute("DBCC FREEPROCCACHE")
            conn.commit()
            console.print("[green]  ✅ Plan cache cleared[/]")
        except Exception as e:
            console.print(f"[yellow]  ⚠  Cache clear skipped: {e}[/]")

    def _ensure_data_volume(target=2_000_000):
        """One-time expansion so full table scans are genuinely slow."""
        try:
            cur.execute("SELECT COUNT(*) FROM Products")
            current = cur.fetchone()[0]
            if current >= target:
                console.print(f"[green]  ✅ Data volume OK ({current:,} rows)[/]")
                return
            needed = target - current
            console.print(
                f"[yellow]  ⏳ Expanding data: {current:,} → ~{target:,} rows "
                f"(one-time setup, a few minutes)…[/]"
            )
            batch_size = 50_000
            num_cats = 50
            inserted = 0
            cat_idx = 1
            while inserted < needed:
                batch = min(batch_size, needed - inserted)
                cat_label = f"Filler_{cat_idx:03d}"
                cur.execute(
                    f"INSERT INTO Products (Name, Category, Price) "
                    f"SELECT TOP {batch} "
                    f"'P-' + CAST(ABS(CHECKSUM(NEWID())) AS VARCHAR(10)), "
                    f"'{cat_label}', "
                    f"CAST(RAND(CHECKSUM(NEWID())) * 490 + 10 AS DECIMAL(10,2)) "
                    f"FROM sys.all_objects a CROSS JOIN sys.all_objects b"
                )
                conn.commit()
                inserted += batch
                cat_idx = (cat_idx % num_cats) + 1
                pct = min(100, inserted / needed * 100)
                console.print(f"    [dim]{pct:.0f}% ({current + inserted:,} rows)[/]")
            console.print(f"[green]  ✅ Data expanded to {current + inserted:,} rows[/]")
        except Exception as e:
            console.print(f"[yellow]  ⚠ Data expansion failed: {e}[/]")

    console.print("[yellow]Dropping existing Category index…[/]")
    _drop_idx()
    console.print("[yellow]Clearing plan cache…[/]")
    _flush_cache()
    console.print("[yellow]Checking data volume…[/]")
    _ensure_data_volume()
    console.print("[green]Starting query loop …[/]\n")
    time.sleep(0.5)

    timeline = EventTimeline()
    timeline.add("Simulation started — index dropped, cache cleared", "cyan")
    perf_graph = PerfGraph()
    first_slow_logged = False
    alert_detected_time = None
    alert_resolved = False
    index_created_time = None
    sim_start_utc = datetime.utcnow()

    iteration = 0
    try:
        with Live(console=console, refresh_per_second=4) as live:
            while True:
                key = check_key()
                if key == "q":
                    break
                if key in ("r", "d"):
                    timeline.add("⌨️  Key [r] pressed — resetting...", "yellow bold")
                    live.update(Panel("[yellow bold]⏳ Dropping index and clearing cache... please wait[/]", border_style="yellow", width=76))
                    _drop_idx()
                    _flush_cache()
                    index_found = False
                    index_banner_shown = False
                    first_slow_logged = False
                    log.clear()
                    perf_graph = PerfGraph()
                    timeline.add("Reset — index dropped, cache cleared", "yellow")
                    continue

                cat = random.choice(categories)

                t0 = time.time()
                try:
                    cur.execute(
                        "SELECT COUNT(*) "
                        "FROM Products WHERE Category = %s "
                        "OPTION (MAXDOP 1, RECOMPILE)",
                        (cat,),
                    )
                    row = cur.fetchone()
                    ms = (time.time() - t0) * 1000
                    cnt = row[0] if row else 0
                except Exception:
                    ms = (time.time() - t0) * 1000
                    cnt = -1

                log.append({
                    "ts": datetime.now().strftime("%H:%M:%S.%f")[:-3],
                    "cat": cat,
                    "ms": ms,
                    "cnt": cnt,
                })
                perf_graph.add(ms, has_index=index_found)
                if len(log) > 20:
                    log.pop(0)

                # Track events
                if ms > 500 and not first_slow_logged:
                    first_slow_logged = True
                    timeline.add(f"First slow query detected: {ms:.0f}ms", "red")

                iteration += 1
                if iteration % 5 == 0:
                    prev = index_found
                    index_found = _has_index()
                    if index_found and not prev:
                        index_banner_shown = False
                        index_created_time = datetime.now().strftime("%H:%M:%S")
                        timeline.add("🎉 INDEX CREATED by SRE Agent!", "green bold")
                        if first_slow_logged:
                            timeline.add(f"Issue resolved — queries should be fast now", "green")

                # Check alert state every 5 iterations
                if iteration % 5 == 0:
                    alert_condition, alert_start = _check_alert_fired(since_time=sim_start_utc)
                    if alert_condition == "Fired" and alert_detected_time is None:
                        alert_detected_time = datetime.now().strftime("%H:%M:%S")
                        timeline.add(f"🚨 ALERT CREATED — Azure Monitor DTU alert fired", "red bold")
                    if alert_condition == "Resolved" and alert_detected_time and not alert_resolved:
                        if index_found:
                            timeline.add(f"✅ ALERT RESOLVED — DTU back to normal", "green bold")
                        else:
                            timeline.add(f"⚠️  ALERT RESOLVED — DTU dropped (may re-fire)", "yellow")
                        alert_resolved = True

                # ── build display ──
                grid = Table.grid(padding=1)
                grid.add_column()

                grid.add_row(Panel(
                    "[bold cyan]🐌 SLOW QUERY SIMULATOR[/]  —  "
                    "querying [bold]Products[/] by [bold]Category[/]\n"
                    "[dim]q = quit   r/d = drop index[/]",
                    border_style="cyan",
                ))

                # index celebration / status
                if index_found and not index_banner_shown:
                    index_banner_shown = True
                    grid.add_row(Panel(
                        "[bold green]🎉🎉🎉  INDEX CREATED!  🎉🎉🎉[/]\n\n"
                        "[green]The SRE Agent detected the missing index and created it!\n"
                        "Watch query times drop dramatically.[/]",
                        border_style="green bold",
                        title="[green bold]✅ INDEX DETECTED[/]",
                    ))
                elif index_found:
                    grid.add_row(Text(
                        "  ✅ Index Status: PRESENT — queries should be fast!",
                        style="green bold",
                    ))
                else:
                    grid.add_row(Text(
                        "  ❌ Index Status: MISSING — full table scan!",
                        style="red bold",
                    ))

                # stats
                if log:
                    durs = [e["ms"] for e in log]
                    avg = sum(durs) / len(durs)
                    last = durs[-1]
                    stbl = Table(box=box.SIMPLE, show_header=False, padding=(0, 2))
                    stbl.add_column("L", style="dim")
                    stbl.add_column("V", style="bold")
                    stbl.add_row("Queries", str(len(log)))
                    stbl.add_row("Last",    f"[{_color(last)}]{last:.1f} ms[/]")
                    stbl.add_row("Avg",     f"[{_color(avg)}]{avg:.1f} ms[/]")
                    stbl.add_row("Min/Max", f"{min(durs):.1f} / {max(durs):.1f} ms")
                    grid.add_row(stbl)

                # query table
                qt = Table(
                    title="[bold]Recent Queries[/]",
                    box=box.ROUNDED, border_style="dim", show_lines=False,
                )
                qt.add_column("Time",     style="dim",  width=14)
                qt.add_column("Category",              width=18)
                qt.add_column("Duration",              width=12, justify="right")
                qt.add_column("Bar",                   width=32)
                qt.add_column("Status",                width=12, justify="center")
                qt.add_column("Rows",                  width=8,  justify="right")
                for e in log[-6:]:
                    m = e["ms"]
                    qt.add_row(
                        e["ts"], e["cat"],
                        f"[{_color(m)}]{m:.1f} ms[/]",
                        _bar(m),
                        _status(m),
                        str(e["cnt"]) if e["cnt"] >= 0 else "[red]ERR[/]",
                    )
                grid.add_row(qt)
                grid.add_row(perf_graph.to_panel())
                grid.add_row(timeline.to_table())
                live.update(grid)
                time.sleep(0.5)
    except KeyboardInterrupt:
        pass
    finally:
        try:
            cur.close(); conn.close()
        except Exception:
            pass


# ═══════════════════════════════════════════════════════════
# SCENARIO 2 — Blocking Chain
# ═══════════════════════════════════════════════════════════

def scenario_blocking():
    console.clear()
    console.print(Panel(
        "[bold]Scenario 2 — Blocking Chain[/]\n\n"
        "Opens a transaction that holds an exclusive lock on Products,\n"
        "then a second session tries to read and gets blocked.\n"
        "SRE Agent should kill the head blocker.\n\n"
        "[dim]Controls:  q = quit   r = recreate   c = commit (release)[/]",
        title="[cyan bold]🔒 BLOCKING CHAIN SIMULATOR[/]",
        border_style="cyan", width=76,
    ))

    blocker_conn = get_sql_connection()
    monitor_conn = get_sql_connection()
    if not blocker_conn or not monitor_conn:
        console.print("[dim]Press any key…[/]"); _wait_key(); return

    bcur = blocker_conn.cursor()
    mcur = monitor_conn.cursor()
    blocked = False
    blocker_spid = None
    block_start = None
    victim_resolved = threading.Event()

    def _create_block():
        nonlocal blocked, blocker_spid, block_start
        try:
            bcur.execute("SELECT @@SPID")
            blocker_spid = bcur.fetchone()[0]
            bcur.execute("BEGIN TRANSACTION")
            bcur.execute(
                "UPDATE Products SET Price = Price WHERE Category = 'Espresso'"
            )
            blocked = True
            block_start = time.time()
            return True
        except Exception as e:
            console.print(f"[red]block error: {e}[/]")
            return False

    def _victim():
        vc = get_sql_connection()
        if not vc:
            victim_resolved.set(); return
        try:
            c = vc.cursor()
            c.execute(
                "SELECT COUNT(*) FROM Products WHERE Category = 'Espresso'"
            )
            c.fetchone()
        except Exception:
            pass
        victim_resolved.set()
        try:
            vc.close()
        except Exception:
            pass

    console.print("[yellow]Creating blocking transaction…[/]")
    if not _create_block():
        return
    console.print(f"[green]Blocker SPID [bold]{blocker_spid}[/bold] — lock held.[/]")
    console.print("[yellow]Starting victim query (will block)…[/]")
    victim_resolved.clear()
    threading.Thread(target=_victim, daemon=True).start()
    time.sleep(2)

    try:
        with Live(console=console, refresh_per_second=2) as live:
            while True:
                key = check_key()
                if key == "q":
                    break
                if key == "c":
                    try:
                        bcur.execute("IF @@TRANCOUNT > 0 COMMIT")
                    except Exception:
                        pass
                    blocked = False
                if key == "r":
                    try:
                        bcur.execute("IF @@TRANCOUNT > 0 COMMIT")
                    except Exception:
                        pass
                    victim_resolved.clear()
                    _create_block()
                    threading.Thread(target=_victim, daemon=True).start()
                    time.sleep(1)

                # query DMV for blocking info
                binfo = []
                try:
                    mcur.execute("""
                        SELECT r.session_id,
                               r.blocking_session_id,
                               r.wait_type,
                               r.wait_time / 1000.0,
                               r.status
                        FROM   sys.dm_exec_requests r
                        WHERE  r.blocking_session_id > 0
                          AND  r.database_id = DB_ID(%s)
                    """, (SQL_DATABASE,))
                    for row in mcur:
                        binfo.append({
                            "victim": row[0],
                            "blocker": row[1],
                            "wait": row[2],
                            "secs": row[3],
                            "status": row[4],
                        })
                except Exception:
                    pass

                blocker_alive = False
                try:
                    mcur.execute(
                        "SELECT COUNT(*) FROM sys.dm_exec_sessions WHERE session_id = %s",
                        (blocker_spid,),
                    )
                    r = mcur.fetchone()
                    blocker_alive = (r[0] > 0) if r else False
                except Exception:
                    pass

                # ── display ──
                grid = Table.grid(padding=1)
                grid.add_column()
                grid.add_row(Panel(
                    "[bold cyan]🔒 BLOCKING CHAIN SIMULATOR[/]\n"
                    "[dim]q = quit   r = recreate   c = commit[/]",
                    border_style="cyan",
                ))

                if blocker_alive and blocked:
                    wait = time.time() - block_start if block_start else 0
                    grid.add_row(Panel(
                        f"[red bold]⚠  ACTIVE BLOCKER[/]\n\n"
                        f"  Blocker SPID:    [bold]{blocker_spid}[/]\n"
                        f"  Status:          [red bold]HOLDING LOCK[/]\n"
                        f"  Duration:        [yellow]{wait:.1f}s[/]\n"
                        f"  Table:           Products\n"
                        f"  Blocked queries: [red]{len(binfo)}[/]",
                        title="[red bold]🔒 HEAD BLOCKER[/]",
                        border_style="red",
                    ))
                elif victim_resolved.is_set() or not blocker_alive:
                    blocked = False
                    grid.add_row(Panel(
                        "[bold green]🎉🎉🎉  BLOCKER KILLED!  🎉🎉🎉[/]\n\n"
                        "[green]The SRE Agent detected the blocking chain\n"
                        "and terminated the head blocker.[/]\n\n"
                        f"[dim]SPID {blocker_spid} removed.[/]",
                        border_style="green bold",
                        title="[green bold]✅ RESOLVED[/]",
                    ))

                if binfo:
                    bt = Table(
                        title="[bold red]Blocked Sessions[/]",
                        box=box.ROUNDED, border_style="red",
                    )
                    bt.add_column("Victim", justify="center")
                    bt.add_column("Blocked By", justify="center")
                    bt.add_column("Wait Type")
                    bt.add_column("Wait (s)", justify="right")
                    bt.add_column("Status")
                    for b in binfo:
                        bt.add_row(
                            str(b["victim"]),
                            f"[red bold]{b['blocker']}[/]",
                            b["wait"] or "",
                            f"[yellow]{b['secs']:.1f}[/]",
                            b["status"] or "",
                        )
                    grid.add_row(bt)
                elif blocked:
                    grid.add_row(Text(
                        "  ⏳ Waiting for victim to appear in DMV…",
                        style="yellow",
                    ))

                live.update(grid)
                time.sleep(1)
    except KeyboardInterrupt:
        pass
    finally:
        try:
            bcur.execute("IF @@TRANCOUNT > 0 COMMIT")
        except Exception:
            pass
        for c in (bcur, mcur):
            try:
                c.close()
            except Exception:
                pass
        for c in (blocker_conn, monitor_conn):
            try:
                c.close()
            except Exception:
                pass


# ═══════════════════════════════════════════════════════════
# SCENARIO 3 — Bad Deployment
# ═══════════════════════════════════════════════════════════

_AZ_CONN_CMD_GOOD = (
    'az webapp config connection-string set '
    '--name app-zava --resource-group rg-zava '
    '--connection-string-type SQLAzure '
    '--settings "DefaultConnection=Server=sql-zava.database.windows.net;'
    'Database=sqldb-zava;User Id=<SQL_ADMIN_USER>;Password=<SQL_PASSWORD>;'
    'Encrypt=True;TrustServerCertificate=True;" '
    '-o none 2>&1'
)

_AZ_CONN_CMD_BAD = (
    'az webapp config connection-string set '
    '--name app-zava --resource-group rg-zava '
    '--connection-string-type SQLAzure '
    '--settings "DefaultConnection=Server=sql-zava-WRONG.database.windows.net;'
    'Database=sqldb-zava;User Id=<SQL_ADMIN_USER>;Password=<SQL_PASSWORD>;'
    'Encrypt=True;TrustServerCertificate=True;" '
    '-o none 2>&1'
)

# Bad-deployment scenario trigger — populated from azd env (ZAVA_HTTP_TRIGGER_URL).
_WEBHOOK_URL = ZAVA_HTTP_TRIGGER_URL


def scenario_bad_deployment():
    console.clear()
    console.print(Panel(
        "[bold]Scenario 3 — Bad Deployment[/]\n\n"
        "Simulates a bad config deployment:\n"
        "  1. First ensures the app is HEALTHY\n"
        "  2. Press [b] to inject a bad DB connection string\n"
        "  3. Fires HTTP trigger to notify SRE Agent\n"
        "  4. Monitors /health until SRE Agent fixes it\n\n"
        "[dim]Controls:  q = quit   b = break (deploy bad config)   f = fix manually[/]",
        title="[cyan bold]💥 BAD DEPLOYMENT SIMULATOR[/]",
        border_style="cyan", width=76,
    ))

    hlog = []
    timeline = EventTimeline()
    broken = False
    was_broken = False
    seen_down = False

    # Ensure app is healthy first
    console.print("[yellow]Ensuring app is healthy before simulation...[/]")
    os.system(_AZ_CONN_CMD_GOOD)
    time.sleep(3)
    code, ms, body = health_check()
    if code == 200:
        console.print("[green]  ✅ App is healthy — ready to simulate[/]")
        timeline.add("App confirmed healthy — ready for simulation", "green")
    else:
        console.print(f"[yellow]  ⚠ App returned {code} — may need a moment to start[/]")
        timeline.add(f"App returned {code} — waiting for startup", "yellow")
    time.sleep(1)

    try:
        with Live(console=console, refresh_per_second=1) as live:
            while True:
                key = check_key()
                if key == "q":
                    break
                if key == "b" and not broken:
                    timeline.add("⌨️  Key [b] pressed — deploying bad config...", "yellow bold")
                    live.update(Panel("[yellow bold]⏳ Deploying bad config... please wait[/]", border_style="yellow", width=76))
                    os.system(_AZ_CONN_CMD_BAD)
                    broken = True
                    was_broken = True
                    seen_down = False
                    timeline.add("⏳ Waiting for bad config to take effect...", "yellow")
                    # Wait for app to actually go down before firing webhook
                    for _ in range(10):
                        time.sleep(3)
                        c, _, _ = health_check()
                        if c != 200:
                            seen_down = True
                            timeline.add(f"❌ App is DOWN ({c}) — bad config confirmed", "red")
                            break
                    if not seen_down:
                        timeline.add("⚠ App still responding 200 — restarting to force config reload", "yellow")
                        os.system("az webapp restart --name app-zava --resource-group rg-zava -o none 2>&1")
                        time.sleep(10)

                    timeline.add("📡 Firing HTTP trigger to SRE Agent...", "cyan")
                    # Fire webhook with auth token
                    if not _WEBHOOK_URL:
                        timeline.add(
                            "⚠ ZAVA_HTTP_TRIGGER_URL not set — run `azd hooks run postprovision` "
                            "to register the trigger, or `azd env set ZAVA_HTTP_TRIGGER_URL <url>`.",
                            "red",
                        )
                    else:
                        try:
                            import subprocess
                            token = subprocess.run(
                                'az account get-access-token --resource "https://azuresre.ai" --query accessToken -o tsv',
                                capture_output=True, text=True, timeout=15, shell=True
                            ).stdout.strip()
                            payload = {
                                "source": "simulator",
                                "event": "deployment_completed",
                                "repo": "<GH_USER>/Zava",
                                "app_name": "app-zava",
                                "app_url": APP_URL,
                                "health_endpoint": HEALTH_URL,
                                "status": "deployed",
                                "message": "Bad config deployed — DB connection string changed to sql-zava-WRONG. Health check is failing. Please investigate and fix.",
                            }
                            headers = {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}
                            r = req.post(_WEBHOOK_URL, json=payload, headers=headers, timeout=15)
                            timeline.add(f"SRE Agent notified (HTTP {r.status_code})", "cyan")
                            # Extract threadId from response — same shape as zava-power sim
                            try:
                                resp = r.json() if r.status_code in (200, 201, 202) else {}
                            except Exception:
                                resp = {}
                            thread_id = (resp.get("threadId") or resp.get("execution", {}).get("threadId") or "")
                            if thread_id:
                                thread_url = f"{SRE_AGENT_THREAD_BASE}/{thread_id}"
                                timeline.add(f"🔗 Agent thread: {thread_url}", "cyan")
                        except Exception as e:
                            timeline.add(f"Webhook failed: {str(e)[:80]}", "red")

                if key == "f":
                    timeline.add("⌨️  Key [f] pressed — restoring good config...", "yellow bold")
                    live.update(Panel("[yellow bold]⏳ Restoring good config... please wait[/]", border_style="yellow", width=76))
                    os.system(_AZ_CONN_CMD_GOOD)

                code, ms, body = health_check()
                healthy = code == 200
                hlog.append({
                    "ts": datetime.now().strftime("%H:%M:%S"),
                    "code": code, "ms": ms,
                    "ok": healthy, "body": body[:100],
                })
                if len(hlog) > 30:
                    hlog.pop(0)

                # Detect recovery — only if we confirmed it was DOWN first
                if broken and healthy and seen_down:
                    broken = False
                    timeline.add("🎉 APP RECOVERED — SRE Agent fixed the config!", "green bold")

                # ── display ──
                grid = Table.grid(padding=1)
                grid.add_column()
                grid.add_row(Panel(
                    "[bold cyan]💥 BAD DEPLOYMENT SIMULATOR[/]\n"
                    "[dim]q = quit   b = break (deploy bad config)   f = fix manually[/]",
                    border_style="cyan",
                ))

                if was_broken and not broken and healthy:
                    grid.add_row(Panel(
                        "[bold green]🎉🎉🎉  APP RECOVERED!  🎉🎉🎉[/]\n\n"
                        "[green]SRE Agent detected the bad deployment\n"
                        "and restored the correct connection string![/]",
                        border_style="green bold",
                        title="[green bold]✅ RECOVERED[/]",
                    ))
                elif healthy:
                    grid.add_row(Panel(
                        f"[green bold]●  HEALTHY[/]   Status: [green]{code}[/]   Latency: [green]{ms:.0f}ms[/]   Endpoint: {HEALTH_URL}",
                        border_style="green", title="[green]App Health[/]",
                    ))
                else:
                    grid.add_row(Panel(
                        f"[red bold]●  DOWN[/]   Status: [red]{code}[/]   Error: [red]{body[:60]}[/]",
                        border_style="red bold", title="[red]⚠  App Health[/]",
                    ))

                ht = Table(
                    title="[bold]Health History[/]",
                    box=box.ROUNDED, border_style="dim",
                )
                ht.add_column("Time",    width=10)
                ht.add_column("Status",  width=8, justify="center")
                ht.add_column("Code",    width=6, justify="center")
                ht.add_column("Latency", width=10, justify="right")
                for e in hlog[-8:]:
                    ht.add_row(
                        e["ts"],
                        "[green]✅ UP[/]" if e["ok"] else "[red]❌ DN[/]",
                        str(e["code"]),
                        f"{e['ms']:.0f} ms",
                    )
                grid.add_row(ht)
                grid.add_row(timeline.to_table())
                live.update(grid)
                time.sleep(2)
    except KeyboardInterrupt:
        pass



# ═══════════════════════════════════════════════════════════
# SCENARIO 5 — Reset All
# ═══════════════════════════════════════════════════════════

def scenario_reset():
    console.clear()
    console.print(Panel(
        "[bold]Reset All[/]\n\n"
        "Returns the demo environment to its baseline state.",
        title="[cyan bold]🧹  RESET ALL[/]",
        border_style="cyan", width=76,
    ))
    console.print()

    steps = [
        ("Drop indexes on Products",            "idx"),
        ("Clear SQL cache",                     "cache"),
        ("Kill blocking sessions",              "kill"),
        ("Restore app connection string",       "conn"),
        ("Restart app service",                 "restart"),
        ("Verify app health",                   "health"),
    ]

    for desc, tag in steps:
        console.print(f"  [yellow]⏳ {desc}…[/]", end="")
        try:
            if tag == "idx":
                conn = get_sql_connection()
                if conn:
                    c = conn.cursor()
                    c.execute("""
                        DECLARE @sql NVARCHAR(MAX) = '';
                        SELECT @sql += 'DROP INDEX ' + QUOTENAME(i.name)
                                      + ' ON Products; '
                        FROM   sys.indexes i
                        JOIN   sys.index_columns ic
                               ON i.object_id = ic.object_id
                              AND i.index_id  = ic.index_id
                        JOIN   sys.columns col
                               ON ic.object_id  = col.object_id
                              AND ic.column_id  = col.column_id
                        WHERE  i.object_id     = OBJECT_ID('Products')
                          AND  col.name        = 'Category'
                          AND  i.type          > 0
                          AND  i.is_primary_key = 0;
                        IF @sql <> '' EXEC sp_executesql @sql;
                    """)
                    conn.commit(); c.close(); conn.close()
                    console.print(" [green]✅[/]")
                else:
                    console.print(" [red]❌ no connection[/]")

            elif tag == "cache":
                conn = get_sql_connection()
                if conn:
                    c = conn.cursor()
                    try:
                        c.execute("DBCC FREEPROCCACHE")
                        c.execute("DBCC DROPCLEANBUFFERS")
                        conn.commit()
                        console.print(" [green]✅[/]")
                    except Exception:
                        console.print(" [yellow]⚠ needs sysadmin[/]")
                    c.close(); conn.close()
                else:
                    console.print(" [red]❌ no connection[/]")

            elif tag == "kill":
                conn = get_sql_connection()
                if conn:
                    c = conn.cursor()
                    c.execute("""
                        SELECT DISTINCT blocking_session_id
                        FROM   sys.dm_exec_requests
                        WHERE  blocking_session_id > 0
                          AND  database_id = DB_ID(%s)
                    """, (SQL_DATABASE,))
                    spids = [r[0] for r in c.fetchall()]
                    for s in spids:
                        try:
                            c.execute(f"KILL {s}")
                        except Exception:
                            pass
                    c.close(); conn.close()
                    console.print(
                        f" [green]✅ killed {len(spids)}[/]"
                        if spids else " [green]✅ none found[/]"
                    )
                else:
                    console.print(" [red]❌ no connection[/]")

            elif tag == "conn":
                rc = os.system(_AZ_CONN_CMD_GOOD)
                console.print(
                    " [green]✅[/]" if rc == 0 else " [yellow]⚠ check az cli[/]"
                )

            elif tag == "restart":
                os.system("az webapp restart --name app-zava --resource-group rg-zava -o none 2>&1")
                console.print(" [green]✅[/]")

            elif tag == "health":
                time.sleep(10)
                code, ms, _ = health_check()
                if code == 200:
                    console.print(f" [green]✅ healthy ({ms:.0f} ms)[/]")
                else:
                    console.print(f" [yellow]⚠ status {code}[/]")

        except Exception as e:
            console.print(f" [red]❌ {e}[/]")

    console.print()
    console.print(Panel("[green bold]🧹  Reset complete![/]", border_style="green"))
    console.print("\n[dim]Press any key to return…[/]")
    _wait_key()


def scenario_all():
    console.print(Panel(
        "[bold]Launching all scenarios in separate terminals...[/]\n\n"
        "  Terminal 1: 🐌 Slow Query (Scenario 1)\n"
        "  Terminal 2: 📡 HTTP Trigger (Scenario 5)\n\n"
        "[dim]Each scenario runs in its own window.[/]",
        title="[cyan bold]🚀 SIMULATE ALL[/]",
        border_style="cyan", width=76,
    ))

    script = os.path.abspath(__file__)

    subprocess.Popen(f'start "Zava - Slow Query" cmd /k python {script} 1', shell=True)
    time.sleep(1)
    subprocess.Popen(f'start "Zava - HTTP Trigger" cmd /k python {script} 5', shell=True)

    console.print("[green]✅ All terminals launched![/]")
    console.print("[dim]Press any key to return to menu...[/]")
    _wait_key()


# ═══════════════════════════════════════════════════════════
# SCENARIO 6 — GitHub Actions Deployment
# ═══════════════════════════════════════════════════════════

# GitHub-deploy scenario trigger — same backend trigger, kept as a separate
# constant so it can be split later if we register a per-event trigger.
_GH_WEBHOOK_URL = ZAVA_HTTP_TRIGGER_URL

_GH_REPO = "meetshamir/ZavaCafe-SREAgent"
_GH_TOKEN = os.environ.get("ZAVA_GH_TOKEN", "")


def scenario_gh_deployment():
    console.clear()
    console.print(Panel(
        "[bold]Scenario 3 — GitHub Actions Bad Deployment[/]\n\n"
        "Simulates a bad deployment via real GitHub Actions:\n"
        "  1. Ensures app is HEALTHY\n"
        "  2. Press [b] to push a bad commit to appsettings.json\n"
        "  3. GitHub Actions builds + deploys the bad config\n"
        "  4. GH Actions fires HTTP trigger to SRE Agent\n"
        "  5. Monitors /health until SRE Agent fixes it\n\n"
        "[dim]Controls:  q = quit   b = break (push bad commit)   f = fix manually[/]",
        title="[cyan bold]🚀 GH ACTIONS DEPLOYMENT[/]",
        border_style="cyan", width=76,
    ))

    hlog = []
    timeline = EventTimeline()
    broken = False
    was_broken = False
    seen_down = False

    # Ensure healthy first — restore good appsettings and push
    console.print("[yellow]Ensuring app has good config...[/]")
    _restore_good_config()
    time.sleep(3)
    code, ms, body = health_check()
    if code == 200:
        console.print("[green]  ✅ App is healthy — ready to simulate[/]")
        timeline.add("App confirmed healthy", "green")
    else:
        console.print(f"[yellow]  ⚠ App returned {code} — may need a moment[/]")
        timeline.add(f"App returned {code}", "yellow")
    time.sleep(1)

    try:
        with Live(console=console, refresh_per_second=1) as live:
            while True:
                key = check_key()
                if key == "q":
                    break
                if key == "b" and not broken:
                    timeline.add("⌨️  Key [b] — pushing bad commit...", "yellow bold")
                    live.update(Panel("[yellow bold]⏳ Pushing bad appsettings.json to GitHub...[/]", border_style="yellow", width=76))

                    # Push bad appsettings.json
                    _push_bad_config()
                    broken = True
                    was_broken = True
                    timeline.add("💥 Bad commit pushed — GH Actions will build + deploy", "red bold")
                    timeline.add("⏳ Monitoring GH Actions workflow...", "yellow")
                    gh_run_url = None

                    # Monitor GH Actions run
                    gh_headers = {"Authorization": f"token {_GH_TOKEN}", "Accept": "application/vnd.github.v3+json"} if _GH_TOKEN else {"Accept": "application/vnd.github.v3+json"}
                    for attempt in range(60):  # wait up to 5 mins
                        time.sleep(5)
                        try:
                            r = req.get(f"https://api.github.com/repos/{_GH_REPO}/actions/runs?per_page=1", headers=gh_headers, timeout=10)
                            if r.status_code == 200:
                                runs = r.json().get("workflow_runs", [])
                                if runs:
                                    run = runs[0]
                                    status = run.get("status", "")
                                    conclusion = run.get("conclusion", "")
                                    gh_run_url = run.get("html_url", "")
                                    if status == "completed":
                                        timeline.add(f"🏁 GH Actions: {conclusion} — {gh_run_url}", "cyan" if conclusion == "success" else "red")
                                        break
                                    elif attempt % 6 == 0:  # log every 30s
                                        timeline.add(f"⏳ GH Actions: {status}...", "yellow")
                        except Exception:
                            pass

                    # Wait for health to go down after deploy
                    timeline.add("⏳ Waiting for bad deploy to take effect...", "yellow")
                    for _ in range(20):
                        time.sleep(3)
                        c, _, _ = health_check()
                        if c != 200:
                            seen_down = True
                            timeline.add(f"❌ App is DOWN ({c}) — bad deploy confirmed", "red")
                            break

                    # Fire authenticated webhook to SRE Agent
                    timeline.add("📡 Firing HTTP trigger to SRE Agent...", "cyan bold")
                    if not _GH_WEBHOOK_URL:
                        timeline.add(
                            "⚠ ZAVA_HTTP_TRIGGER_URL not set — run `azd hooks run postprovision` "
                            "to register the trigger.",
                            "red",
                        )
                    else:
                        try:
                            token = subprocess.run(
                                'az account get-access-token --resource "https://azuresre.ai" --query accessToken -o tsv',
                                capture_output=True, text=True, timeout=15, shell=True
                            ).stdout.strip()
                            payload = {
                                "source": "github-actions",
                                "event": "deployment_completed",
                                "repo": _GH_REPO,
                                "commit_sha": "bad-config-commit",
                                "commit_message": "Update database connection string",
                                "branch": "main",
                                "actor": "meetshamir",
                                "app_name": "app-zava",
                                "app_url": APP_URL,
                                "health_endpoint": HEALTH_URL,
                                "run_url": gh_run_url or f"https://github.com/{_GH_REPO}/actions",
                                "status": "success",
                                "message": "Deployment succeeded but app health is failing. Investigate the latest commit.",
                            }
                            headers = {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}
                            r = req.post(_GH_WEBHOOK_URL, json=payload, headers=headers, timeout=15)
                            timeline.add(f"✅ SRE Agent notified (HTTP {r.status_code})", "cyan")
                            try:
                                resp = r.json() if r.status_code in (200, 201, 202) else {}
                            except Exception:
                                resp = {}
                            thread_id = (resp.get("threadId") or resp.get("execution", {}).get("threadId") or "")
                            if thread_id:
                                timeline.add(f"🔗 Agent thread: {SRE_AGENT_THREAD_BASE}/{thread_id}", "cyan")
                        except Exception as e:
                            timeline.add(f"Webhook failed: {str(e)[:80]}", "red")

                if key == "f":
                    timeline.add("⌨️  Key [f] — restoring good config...", "yellow bold")
                    _restore_good_config()

                # Poll health
                code, ms, body = health_check()
                healthy = code == 200
                hlog.append({
                    "ts": datetime.now().strftime("%H:%M:%S"),
                    "code": code, "ms": ms, "ok": healthy,
                })
                if len(hlog) > 30:
                    hlog.pop(0)

                # Detect app going down
                if broken and not seen_down and not healthy:
                    seen_down = True
                    timeline.add(f"❌ App is DOWN ({code}) — bad deploy confirmed", "red")

                # Detect recovery
                if broken and healthy and seen_down:
                    broken = False
                    timeline.add("🎉 APP RECOVERED — SRE Agent fixed it!", "green bold")

                # Display
                grid = Table.grid(padding=1)
                grid.add_column()
                grid.add_row(Panel(
                    "[bold cyan]🚀 GH ACTIONS DEPLOYMENT[/]  —  deployment-validator-gh\n"
                    "[dim]q = quit   b = push bad commit   f = fix manually[/]",
                    border_style="cyan",
                ))

                if was_broken and not broken and healthy:
                    grid.add_row(Panel(
                        "[bold green]🎉🎉🎉  APP RECOVERED!  🎉🎉🎉[/]\n\n"
                        "[green]SRE Agent detected the bad deployment, rolled back,\n"
                        "and created a GitHub Issue with the RCA![/]",
                        border_style="green bold",
                        title="[green bold]✅ RECOVERED[/]",
                    ))
                elif healthy:
                    grid.add_row(Panel(
                        f"[green bold]●  HEALTHY[/]   Status: [green]{code}[/]   Latency: [green]{ms:.0f}ms[/]",
                        border_style="green", title="[green]App Health[/]",
                    ))
                else:
                    grid.add_row(Panel(
                        f"[red bold]●  DOWN[/]   Status: [red]{code}[/]   Error: [red]{body[:60]}[/]",
                        border_style="red bold", title="[red]⚠  App Health[/]",
                    ))

                ht = Table(title="[bold]Health History[/]", box=box.ROUNDED, border_style="dim")
                ht.add_column("Time", width=10)
                ht.add_column("Status", width=8, justify="center")
                ht.add_column("Code", width=6, justify="center")
                ht.add_column("Latency", width=10, justify="right")
                for e in hlog[-6:]:
                    ht.add_row(
                        e["ts"],
                        "[green]✅ UP[/]" if e["ok"] else "[red]❌ DN[/]",
                        str(e["code"]),
                        f"{e['ms']:.0f} ms",
                    )
                grid.add_row(ht)
                grid.add_row(timeline.to_table())
                live.update(grid)
                time.sleep(2)
    except KeyboardInterrupt:
        pass


def _push_bad_config():
    """Push a bad appsettings.json via GitHub API."""
    if not _GH_TOKEN:
        console.print("[red]Set ZAVA_GH_TOKEN env var to push commits[/]")
        return
    headers = {"Authorization": f"token {_GH_TOKEN}", "Accept": "application/vnd.github.v3+json"}
    bad_config = json.dumps({
        "ConnectionStrings": {"DefaultConnection": "Server=sql-zava-WRONG.database.windows.net;Database=sqldb-zava;User Id=<SQL_ADMIN_USER>;Password=<SQL_PASSWORD>;Encrypt=True;TrustServerCertificate=True;"},
        "ApplicationInsights": {"ConnectionString": ""},
        "Logging": {"LogLevel": {"Default": "Information", "Microsoft.AspNetCore": "Warning"}},
        "AllowedHosts": "*"
    }, indent=2)
    import base64
    content = base64.b64encode(bad_config.encode()).decode()
    try:
        existing = req.get(f"https://api.github.com/repos/{_GH_REPO}/contents/src/appsettings.json", headers=headers, timeout=10).json()
        body = {"message": "Update database connection string", "content": content, "sha": existing["sha"]}
        r = req.put(f"https://api.github.com/repos/{_GH_REPO}/contents/src/appsettings.json", headers=headers, json=body, timeout=10)
        if r.status_code in (200, 201):
            console.print("[green]  ✅ Bad commit pushed to GitHub[/]")
        else:
            console.print(f"[red]  ❌ Push failed: {r.status_code}[/]")
    except Exception as e:
        console.print(f"[red]  ❌ Push error: {e}[/]")


def _restore_good_config():
    """Restore good appsettings.json via GitHub API."""
    if not _GH_TOKEN:
        console.print("[red]Set ZAVA_GH_TOKEN env var[/]")
        return
    headers = {"Authorization": f"token {_GH_TOKEN}", "Accept": "application/vnd.github.v3+json"}
    good_config = json.dumps({
        "ConnectionStrings": {"DefaultConnection": "Server=sql-zava.database.windows.net;Database=sqldb-zava;User Id=<SQL_ADMIN_USER>;Password=<SQL_PASSWORD>;Encrypt=True;TrustServerCertificate=True;"},
        "ApplicationInsights": {"ConnectionString": ""},
        "Logging": {"LogLevel": {"Default": "Information", "Microsoft.AspNetCore": "Warning"}},
        "AllowedHosts": "*"
    }, indent=2)
    import base64
    content = base64.b64encode(good_config.encode()).decode()
    try:
        existing = req.get(f"https://api.github.com/repos/{_GH_REPO}/contents/src/appsettings.json", headers=headers, timeout=10).json()
        body = {"message": "Restore correct database connection string", "content": content, "sha": existing["sha"]}
        r = req.put(f"https://api.github.com/repos/{_GH_REPO}/contents/src/appsettings.json", headers=headers, json=body, timeout=10)
    except Exception:
        pass


# ═══════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════

SCENARIOS = {
    "1": ("Slow Query",            scenario_slow_query),
    "2": ("Blocking Chain",        scenario_blocking),
    "3": ("GH Actions Deploy",     scenario_gh_deployment),
    "5": ("HTTP Trigger",          scenario_bad_deployment),
    "6": ("Simulate All",          scenario_all),
    "7": ("Reset All",             scenario_reset),
}


def main():
    while True:
        show_menu()
        choice = console.input(
            "[bold cyan]Select scenario (1-7, q=quit): [/]"
        ).strip().lower()

        if choice in ("q", "quit", "exit"):
            console.print("\n[cyan]👋  Goodbye — happy demo-ing![/]\n")
            break

        if choice in SCENARIOS:
            name, fn = SCENARIOS[choice]
            console.print(f"\n[cyan]Launching {name}…[/]\n")
            try:
                fn()
            except KeyboardInterrupt:
                pass
            except Exception as e:
                console.print(f"\n[red]Error: {e}[/]")
                console.print("[dim]Press any key…[/]")
                _wait_key()
        else:
            console.print("[red]Invalid choice.[/]")
            time.sleep(1)


if __name__ == "__main__":
    # Allow direct scenario launch: python demo.py 1
    if len(sys.argv) > 1:
        scenario = sys.argv[1].strip().lower()
        scenario_map = {
            "1": scenario_slow_query,
            "slow": scenario_slow_query,
            "2": scenario_blocking,
            "block": scenario_blocking,
            "3": scenario_gh_deployment,
            "gh": scenario_gh_deployment,
            "5": scenario_bad_deployment,
            "http": scenario_bad_deployment,
            "6": scenario_all,
            "all": scenario_all,
            "7": scenario_reset,
            "reset": scenario_reset,
        }
        fn = scenario_map.get(scenario)
        if fn:
            try:
                fn()
            except KeyboardInterrupt:
                console.print("\n[cyan]👋  Interrupted. Goodbye![/]\n")
        else:
            console.print(f"[red]Unknown scenario: {scenario}[/]")
            console.print("[dim]Usage: python demo.py [1|2|3|4|5|6|slow|block|deploy|sn|reset|all][/]")
        sys.exit(0)

    try:
        main()
    except KeyboardInterrupt:
        console.print("\n[cyan]👋  Interrupted. Goodbye![/]\n")
        sys.exit(0)
