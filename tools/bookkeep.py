#!/usr/bin/env python3
"""Apply commit-time bookkeeping from one manifest.

The commit skill authors the content (feedback score+comment, decision prose,
plan-landing note) — this script owns only the mechanical application: JSON
escaping, hanging-indent wrapping, section splicing, Landed prune. Every
manifest key is optional; contents are computed for all present keys before
any file is written, so a bad manifest or a missing plan file errors before
touching anything.

Usage: python3 tools/bookkeep.py <manifest.json>

Manifest:
  {
    "date": "2026-07-22",                       # optional; defaults to today
    "feedback": {"score": 4|null, "used": [...], "comment": "..."},  # comment optional
    "decision": "one-or-two-line decision prose",
    "land": {"headline": "...", "ref": "§ 3", "now": "replacement Now body"}
  }
"""

import datetime
import json
import re
import sys
import textwrap
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
FEEDBACK = REPO / "map" / "feedback.jsonl"
DECISIONS = REPO / "docs" / "decisions.md"
PLAN_CURRENT = REPO / "plan" / "CURRENT"

DECISION_WIDTH = 100
LANDED_KEEP = 4


def die(msg):
    sys.exit(f"bookkeep: {msg}")


# ----- feedback

def apply_feedback(date, spec):
    """Append one JSONL line: date, score, used, comment (comment omitted when absent)."""
    if "score" not in spec:
        die("feedback needs a score (int 1-5 or null)")
    entry = {"date": date, "score": spec["score"], "used": spec.get("used", [])}
    if spec.get("comment"):
        entry["comment"] = spec["comment"]
    line = json.dumps(entry, ensure_ascii=False, separators=(",", ":"))

    existing = FEEDBACK.read_text() if FEEDBACK.exists() else ""
    if existing and not existing.endswith("\n"):
        existing += "\n"
    return FEEDBACK, existing + line + "\n"


# ----- decision

def apply_decision(date, text):
    """Prepend `- **DATE** — text`, wrapped, before the first existing entry."""
    body = " ".join(text.split())
    block = textwrap.fill(
        f"- **{date}** — {body}",
        width=DECISION_WIDTH,
        subsequent_indent="  ",
        break_long_words=False,
        break_on_hyphens=False,
    ).splitlines()

    lines = DECISIONS.read_text().splitlines()
    for i, line in enumerate(lines):
        if line.startswith("- **"):
            merged = lines[:i] + block + [""] + lines[i:]
            return DECISIONS, "\n".join(merged) + "\n"
    die("decisions.md has no existing `- **` entry to prepend before")


# ----- plan landing

def section_bounds(lines, prefix):
    """[start, end) line indices of a `## <prefix>` section body (header excluded)."""
    start = None
    for i, line in enumerate(lines):
        if line.startswith("## " + prefix):
            start = i + 1
            break
    if start is None:
        die(f"plan file has no `## {prefix}` section")
    end = start
    while end < len(lines) and not lines[end].startswith("## "):
        end += 1
    return start, end


def splice_landed(new_bullet, body_lines):
    """Prepend new_bullet, keep the newest LANDED_KEEP bullets, one trailing gap."""
    lead = body_lines[:1] if (body_lines and body_lines[0].strip() == "") else []
    kept = [new_bullet]
    for line in body_lines:
        if line.startswith("- "):
            if len(kept) >= LANDED_KEEP:
                break
            kept.append(line)
    return lead + kept + [""]


def apply_land(date, spec):
    for key in ("headline", "ref", "now"):
        if key not in spec:
            die(f"land needs '{key}'")
    if not PLAN_CURRENT.exists():
        die("plan/CURRENT missing — no live plan to land against")
    name = PLAN_CURRENT.read_text().strip()
    plan_path = REPO / "plan" / name
    if not plan_path.exists():
        die(f"plan/CURRENT points at {name!r}, which does not exist")
    lines = plan_path.read_text().splitlines()

    l_start, l_end = section_bounds(lines, "Landed")
    bullet = f"- {date} {spec['headline']} ({spec['ref']})"
    lines = lines[:l_start] + splice_landed(bullet, lines[l_start:l_end]) + lines[l_end:]

    n_start, n_end = section_bounds(lines, "Now")
    lines = lines[:n_start] + ["", spec["now"].rstrip("\n"), ""] + lines[n_end:]

    return plan_path, "\n".join(lines) + "\n"


# ----------- MAIN

def main():
    if len(sys.argv) != 2:
        die("usage: bookkeep.py <manifest.json>")
    manifest = json.loads(Path(sys.argv[1]).read_text())
    date = manifest.get("date") or datetime.date.today().isoformat()
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", date):
        die(f"date must be YYYY-MM-DD, got {date!r}")

    writes = []
    if "feedback" in manifest:
        writes.append(apply_feedback(date, manifest["feedback"]))
    if "decision" in manifest:
        writes.append(apply_decision(date, manifest["decision"]))
    if "land" in manifest:
        writes.append(apply_land(date, manifest["land"]))
    if not writes:
        die("manifest had none of: feedback, decision, land")

    for path, content in writes:
        path.write_text(content)
        print(f"wrote {path.relative_to(REPO)}")


if __name__ == "__main__":
    main()
