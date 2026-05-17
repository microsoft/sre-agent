#!/usr/bin/env python3
"""render-config.py — substitute {{PLACEHOLDERS}} in sre-config/ → .rendered/.
Cross-platform stand-in for the lab's setup/60-template-skills.ps1.
Used by post-provision hook (windows + posix)."""
import argparse, re, shutil, sys
from pathlib import Path

ap = argparse.ArgumentParser()
ap.add_argument("--src", required=True)
ap.add_argument("--dest", required=True)
ap.add_argument("--vars", action="append", default=[],
                help="KEY=VALUE; pass multiple times")
args = ap.parse_args()

vmap = {}
for pair in args.vars:
    if "=" not in pair:
        sys.exit(f"bad --vars {pair!r}")
    k, v = pair.split("=", 1)
    vmap["{{" + k + "}}"] = v

src = Path(args.src); dest = Path(args.dest)
if dest.exists(): shutil.rmtree(dest)
dest.mkdir(parents=True)

count_files = 0
count_subs = 0
for p in src.rglob("*"):
    rel = p.relative_to(src)
    out = dest / rel
    if p.is_dir():
        out.mkdir(parents=True, exist_ok=True); continue
    out.parent.mkdir(parents=True, exist_ok=True)
    if p.suffix.lower() in (".yaml", ".yml", ".json", ".md"):
        text = p.read_text(encoding="utf-8-sig")
        for k, v in vmap.items():
            n = text.count(k)
            if n: count_subs += n; text = text.replace(k, v)
        # validate no SCREAMING_SNAKE leftovers
        leftover = re.findall(r"\{\{[A-Z][A-Z0-9_]*\}\}", text)
        if leftover:
            sys.exit(f"{rel}: unsubstituted placeholders: {sorted(set(leftover))}")
        out.write_text(text, encoding="utf-8")
    else:
        shutil.copy2(p, out)
    count_files += 1

print(f"  rendered {count_files} files, {count_subs} substitutions")
