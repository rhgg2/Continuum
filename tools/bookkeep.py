#!/usr/bin/env python3
"""Apply commit-time bookkeeping from one manifest.

The commit skill authors the content (decision prose, plan-landing note, jot
verdicts) — this script owns only the mechanical application: JSON escaping,
hanging-indent wrapping, section splicing, Landed prune, spool drain. Every
manifest key is optional; contents are computed for all present keys before
any file is written, so a bad manifest or a missing plan file errors before
touching anything.

Usage: python3 tools/bookkeep.py [manifest.json]   # reads stdin when no path

Manifest:
  {
    "date": "2026-07-22",                       # optional; defaults to today
    "decision": "one-or-two-line prose; only for a decision with no design doc",
    "land": {"headline": "...", "ref": "§ 3", "now": "optional; overrides the empty Now"},
    "wonder": ["keep", "drop", "replace: fuller text, under the jot's own date"]
  }
"""

import datetime
import json
import re
import sys
import textwrap
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
DECISIONS = REPO / "design" / "decisions.md"
PLAN_CURRENT = REPO / "plan" / "CURRENT"
BRIEF = REPO / "plan" / "IMPL.md"
OPEN_CLAIMS = REPO / ".claude" / "agent-memory" / "open.md"
SPOOL = REPO / ".claude" / "agent-memory" / "spool.md"

DECISION_WIDTH = 100
LANDED_KEEP = 4
PLACEHOLDER = "(nothing unfiled)"
NOW_EMPTY = "(empty — run /plan-next to compile the next brief.)"
REPLACE = "replace:"
# wonder.py's output format, and what makes a jot's extent unambiguous: the
# opener sits at column 0 where every continuation line is indented under it.
BULLET = re.compile(r"- \[(\d{4}-\d{2}-\d{2})\] ")


def die(msg):
    sys.exit(f"bookkeep: {msg}")


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

def section_bounds(lines, prefix, where):
    """[start, end) line indices of a `## <prefix>` section body (header excluded)."""
    start = None
    for i, line in enumerate(lines):
        if line.startswith("## " + prefix):
            start = i + 1
            break
    if start is None:
        die(f"{where} has no `## {prefix}` section")
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
    for key in ("headline", "ref"):
        if key not in spec:
            die(f"land needs '{key}'")
    if not PLAN_CURRENT.exists():
        die("plan/CURRENT missing — no live plan to land against")
    # CURRENT is a stack, newest first; the top non-blank line is the live plan.
    name = next((ln.strip() for ln in PLAN_CURRENT.read_text().splitlines() if ln.strip()), "")
    if not name:
        die("plan/CURRENT is empty — no live plan to land against")
    plan_path = REPO / "plan" / name
    if not plan_path.exists():
        die(f"plan/CURRENT points at {name!r}, which does not exist")
    lines = plan_path.read_text().splitlines()

    l_start, l_end = section_bounds(lines, "Landed", name)
    bullet = f"- {date} {spec['headline']} ({spec['ref']})"
    lines = lines[:l_start] + splice_landed(bullet, lines[l_start:l_end]) + lines[l_end:]

    n_start, n_end = section_bounds(lines, "Now", name)
    now = spec.get("now", "").strip() or NOW_EMPTY
    lines = lines[:n_start] + ["", now, ""] + lines[n_end:]

    return plan_path, "\n".join(lines) + "\n"


def landing_digest(content):
    """Echo back the two sections the splice rewrote.

    The land write has no review gate, so this is the caller's only chance to
    see where the new bullet and Now body actually landed.
    """
    lines = content.splitlines()
    landed_start, _ = section_bounds(lines, "Landed", "the plan")
    _, now_end = section_bounds(lines, "Now", "the plan")
    return "\n".join(lines[landed_start - 1:now_end])


def retire_brief():
    """What deleting the in-flight brief would drop, or None if there isn't one.

    The brief is untracked and holds a single item, so it has no history to fall
    back on — the landing says what it removed rather than removing it silently.
    """
    if not BRIEF.exists():
        return None
    title = next((ln for ln in BRIEF.read_text().splitlines() if ln.startswith("# ")), None)
    return f"deleted {BRIEF.relative_to(REPO)} — {title[2:].strip() if title else 'untitled'}"


# ----- jot triage

def spool_blocks():
    """The spooled jots, one list of lines each, in the order they were written.

    A block opens on an unindented bullet and runs to the next one, so a jot's
    own blank lines and worked examples stay inside it rather than splitting it.
    """
    if not SPOOL.exists():
        return []
    blocks = []
    for line in SPOOL.read_text().splitlines():
        if BULLET.match(line):
            blocks.append([line])
        elif blocks:
            blocks[-1].append(line)
        elif line.strip():
            die(f"spool has text before its first jot: {line!r}")
    return blocks


def unfiled_body(lines, start, end):
    """The section's existing jots, outer blanks and the placeholder removed.

    Inner blank lines stay: a jot may run to several paragraphs, and carrying
    its structure intact to the filing pass is the whole point of the spool.
    """
    body = lines[start:end]
    while body and not body[0].strip():
        body.pop(0)
    while body and not body[-1].strip():
        body.pop()
    return [] if len(body) == 1 and body[0].strip() == PLACEHOLDER else body


def rebodied(block, text):
    """The replacement text under the jot's original bullet date.

    open.md dates when noticed, and a replacement completes the thought the jot
    opened rather than starting a new one.
    """
    if not text.strip():
        die("a 'replace:' verdict needs text after the colon")
    date = BULLET.match(block[0]).group(1)
    lines = [line.rstrip() for line in text.strip().split("\n")]
    return [f"- [{date}] {lines[0]}"] + [f"  {line}" if line else "" for line in lines[1:]]


def apply_wonder(verdicts):
    """Triage survivors into `## Unfiled`, and clear the spool behind them.

    The array is positional against the spool, so a length mismatch means a jot
    arrived between the commit skill reading the spool and this running. Dying
    is the point: the alternative clears that jot without anyone having read it.
    """
    blocks = spool_blocks()
    if len(verdicts) != len(blocks):
        die(f"{len(verdicts)} verdicts for {len(blocks)} spooled jots — re-read the "
            "spool and send one verdict per jot, in order; nothing was written")

    kept = []
    for verdict, block in zip(verdicts, blocks):
        if verdict == "keep":
            kept.extend(block)
        elif verdict.startswith(REPLACE):
            kept.extend(rebodied(block, verdict[len(REPLACE):]))
        elif verdict != "drop":
            die(f"verdict must be 'keep', 'drop' or 'replace: <text>', got {verdict!r}")

    lines = OPEN_CLAIMS.read_text().splitlines()
    start, end = section_bounds(lines, "Unfiled", OPEN_CLAIMS.name)
    body = (unfiled_body(lines, start, end) + kept) or [PLACEHOLDER]
    merged = lines[:start] + ["", *body, ""] + lines[end:]
    return (OPEN_CLAIMS, "\n".join(merged) + "\n"), (SPOOL, "")


def unfiled_digest(content):
    """Echo the section the splice rewrote, for landing_digest's reason."""
    lines = content.splitlines()
    start, end = section_bounds(lines, "Unfiled", OPEN_CLAIMS.name)
    return "\n".join(lines[start - 1:end])


# ----------- MAIN

def main():
    if len(sys.argv) > 2:
        die("usage: bookkeep.py [manifest.json]   (or pipe the JSON on stdin)")
    source = Path(sys.argv[1]).read_text() if len(sys.argv) == 2 else sys.stdin.read()
    manifest = json.loads(source)
    date = manifest.get("date") or datetime.date.today().isoformat()
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", date):
        die(f"date must be YYYY-MM-DD, got {date!r}")

    writes, digests, retired = [], [], None
    if "decision" in manifest:
        writes.append(apply_decision(date, manifest["decision"]))
    if "land" in manifest:
        plan_path, content = apply_land(date, manifest["land"])
        writes.append((plan_path, content))
        digests.append(landing_digest(content))
        retired = retire_brief()
    if "wonder" in manifest:
        unfiled, spool = apply_wonder(manifest["wonder"])
        writes += [unfiled, spool]
        digests.append(unfiled_digest(unfiled[1]))
    if not writes:
        die("manifest had none of: decision, land, wonder")

    for path, content in writes:
        path.write_text(content)
        print(f"wrote {path.relative_to(REPO)}")

    if retired:
        BRIEF.unlink()
        print(retired)

    for digest in digests:
        print()
        print(digest)


if __name__ == "__main__":
    main()
