"""Zava Unlimited platform — lab manifest helpers.

Used by labs/lab.ps1 (launcher) and labs/sim.ps1 (meta-sim) via subprocess.
Outputs JSON on stdout for the pwsh callers to consume.

Commands:
  python manifest.py list <labs-dir>            # list discovered labs (json)
  python manifest.py read <lab-dir>             # read & validate one manifest (json)
  python manifest.py deployed <labs-dir>        # list .deployed/ entries (json)
  python manifest.py validate <manifest-path>   # exit 0 if valid, prints errors
"""
import json, sys, os, glob, re
from pathlib import Path

try:
    import yaml
except ImportError:
    print(json.dumps({"error": "PyYAML not installed. Run: pip install pyyaml"}))
    sys.exit(2)

SCHEMA_PATH = Path(__file__).parent.parent / "schema" / "lab.schema.json"


def _load_yaml(p: Path):
    with p.open(encoding="utf-8-sig") as f:
        return yaml.safe_load(f)


def _validate(manifest: dict, schema: dict) -> list[str]:
    """Lightweight validator (avoids jsonschema dependency).
    Catches the cases that matter for our use case."""
    errs = []
    req = schema.get("required", [])
    for k in req:
        if k not in manifest:
            errs.append(f"missing required field: {k}")
    name = manifest.get("name", "")
    if name and not re.match(r"^[a-z][a-z0-9-]+$", name):
        errs.append(f"name '{name}' must be kebab-case")
    for p in manifest.get("prompts", []):
        n = p.get("name", "")
        if n and not re.match(r"^[A-Z][A-Z0-9_]+$", n):
            errs.append(f"prompt name '{n}' must be SCREAMING_SNAKE")
        if "text" not in p:
            errs.append(f"prompt {n!r} missing 'text'")
    for s in manifest.get("scenarios", []):
        for f in ("id", "label"):
            if f not in s:
                errs.append(f"scenario missing '{f}'")
    sim = manifest.get("sim")
    if sim is not None:
        for f in ("command", "args"):
            if f not in sim:
                errs.append(f"sim missing '{f}'")
    return errs


def _read_one(lab_dir: Path) -> dict | None:
    """Read a lab's manifest. Returns None for legacy labs without lab.yaml."""
    mf = lab_dir / "lab.yaml"
    if not mf.exists():
        # Legacy fallback: use azure.yaml + README first line
        az = lab_dir / "azure.yaml"
        if not az.exists():
            return None
        readme = lab_dir / "README.md"
        desc = ""
        if readme.exists():
            for line in readme.read_text(encoding="utf-8-sig").splitlines()[:6]:
                if line.strip() and not line.startswith("#"):
                    desc = line.strip()
                    break
        return {
            "name": lab_dir.name,
            "displayName": lab_dir.name,
            "description": desc or "(no manifest — legacy lab)",
            "_legacy": True,
            "_path": str(lab_dir),
        }
    try:
        m = _load_yaml(mf) or {}
    except Exception as e:
        return {"name": lab_dir.name, "_path": str(lab_dir), "_error": f"yaml parse: {e}"}
    schema = json.loads(SCHEMA_PATH.read_text())
    errs = _validate(m, schema)
    if errs:
        m["_validationErrors"] = errs
    m["_path"] = str(lab_dir)
    m["_legacy"] = False
    return m


def cmd_list(labs_dir: str):
    base = Path(labs_dir)
    out = []
    for d in sorted(base.iterdir()):
        if not d.is_dir() or d.name.startswith(("_", ".")):
            continue
        m = _read_one(d)
        if m:
            out.append(m)
    print(json.dumps(out, indent=2))


def cmd_read(lab_dir: str):
    m = _read_one(Path(lab_dir))
    print(json.dumps(m or {}, indent=2))


def cmd_deployed(labs_dir: str):
    deployed_dir = Path(labs_dir) / ".deployed"
    out = []
    if deployed_dir.exists():
        for f in sorted(deployed_dir.glob("*.json")):
            try:
                out.append(json.loads(f.read_text(encoding="utf-8-sig")))
            except Exception as e:
                out.append({"_file": str(f), "_error": str(e)})
    print(json.dumps(out, indent=2))


def cmd_validate(mf_path: str):
    p = Path(mf_path)
    if not p.exists():
        print(f"FAIL: {p} not found"); sys.exit(1)
    try:
        m = _load_yaml(p) or {}
    except Exception as e:
        print(f"FAIL: yaml parse: {e}"); sys.exit(1)
    schema = json.loads(SCHEMA_PATH.read_text())
    errs = _validate(m, schema)
    if errs:
        print(f"FAIL: {len(errs)} validation error(s):")
        for e in errs:
            print(f"  - {e}")
        sys.exit(1)
    print(f"OK: {p.name} is valid (name={m.get('name')}, scenarios={len(m.get('scenarios', []))})")


if __name__ == "__main__":
    if len(sys.argv) < 3:
        print(__doc__); sys.exit(2)
    cmd, arg = sys.argv[1], sys.argv[2]
    {
        "list":      cmd_list,
        "read":      cmd_read,
        "deployed":  cmd_deployed,
        "validate":  cmd_validate,
    }[cmd](arg)
