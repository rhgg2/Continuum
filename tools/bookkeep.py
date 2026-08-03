#!/usr/bin/env python3
"""Apply the memory store's mechanical bookkeeping from one manifest.

The commit skill and the filing pass author the content (decision prose,
plan-landing note, jot verdicts, drain verdicts) — this script owns only the
mechanical application: JSON escaping, hanging-indent wrapping, section
splicing, Landed prune, spool drain, unfiled drain. Every
manifest key is optional; contents are computed for all present keys before
any file is written, so a bad manifest or a missing plan file errors before
touching anything.

Usage: python3 tools/bookkeep.py [manifest.json]   # reads stdin when no path
       python3 tools/bookkeep.py --due            # open entries due under the half-life

Manifest:
  {
    "date": "2026-07-22",                       # optional; defaults to today
    "dry": true,                                # optional; compute and report, write nothing
    "decision": "one-or-two-line prose; only for a decision with no design doc",
    "land": {"headline": "...", "ref": "§ 3", "now": "optional; overrides the empty Now"},
    "wonder": ["keep", "drop", "replace: fuller text, under the jot's own date"],
    "drain": ["us", "claim: world_foo.md @ **The remedy.**", "drop: a convention", "keep"]
  }
"""

import datetime
import json
import re
import subprocess
import sys
import textwrap
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
DECISIONS = REPO / "design" / "decisions.md"
PLAN_CURRENT = REPO / "plan" / "CURRENT"
BRIEF = REPO / "plan" / "IMPL.md"
AGENT_MEMORY = REPO / ".claude" / "agent-memory"
OPEN_CLAIMS = AGENT_MEMORY / "open.md"
SPOOL = AGENT_MEMORY / "spool.md"
# Neither is a claim file, and both are written by the drain itself.
RESERVED = {OPEN_CLAIMS.name, SPOOL.name}

DECISION_WIDTH = 100
LANDED_KEEP = 4
PLACEHOLDER = "(nothing unfiled)"
NOW_EMPTY = "(empty — run /plan-next to compile the next brief.)"
REPLACE = "replace:"
CLAIM = "claim:"
DROP = "drop"
ANCHOR = " @ "
SUBJECTS = {"world": "World", "build": "Build", "us": "Us"}
DECAY_HEADING = "**Decay log.**"
HEADLINE_WIDTH = 72
# wonder.py's output format, and what makes a jot's extent unambiguous: the
# opener sits at column 0 where every continuation line is indented under it.
BULLET = re.compile(r"- \[(\d{4}-\d{2}-\d{2})\] ")
DATE = re.compile(r"\d{4}-\d{2}-\d{2}")


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


# ----- unfiled drain

def entry_blocks(body):
    """A section's entries, one list of lines each, in order.

    Same grammar as the spool: an entry opens on an unindented dated bullet
    and runs to the next one. Trailing blanks belong to the boundary between
    entries, not to the entry, so they are trimmed here.
    """
    blocks = []
    for line in body:
        if BULLET.match(line):
            blocks.append([line])
        elif blocks:
            blocks[-1].append(line)
        elif line.strip():
            die(f"text before the section's first entry: {line!r}")
    for block in blocks:
        while block and not block[-1].strip():
            block.pop()
    return blocks


def headline(block):
    """The entry's opening words, with its shared bullet prefix out of the way.

    `- [YYYY-MM-DD] ` is fifteen characters every entry has, so truncating with
    it in place spends a fifth of the width on nothing that tells two entries
    apart — and telling them apart is the whole job of a headline that a human
    reads against a positional verdict list.
    """
    match = BULLET.match(block[0])
    text = block[0][match.end():]
    if len(text) > HEADLINE_WIDTH:
        text = text[:HEADLINE_WIDTH] + "…"
    return f"[{match.group(1)}] {text}"


def splice_into_section(lines, title, added):
    """Append entries at the section's end, one blank line against each heading.

    The trailing blank separates the section from the next heading, so the last
    section in the file must not have one: there is nothing to separate from,
    and the file would grow a blank line at EOF on every pass that filed into
    it.
    """
    start, end = section_bounds(lines, title, OPEN_CLAIMS.name)
    body = lines[start:end]
    while body and not body[0].strip():
        body.pop(0)
    while body and not body[-1].strip():
        body.pop()
    tail = lines[end:]
    return lines[:start] + ["", *body, *added] + ([""] if tail else []) + tail


def claim_append(name, added, anchor=""):
    """The claim file with the entries spliced in, above the line `anchor` names.

    Claims close on synthesis — the general lesson, the remedy, the pointer to
    a kin claim — and a decay log, where present, sits below that again. So
    both landmarks the tool can find unaided put an instance *after* the
    paragraph that concludes the claim, which is why the anchor exists and why
    a miss dies rather than falling back: a silent fallback lands the entry in
    exactly the wrong place, which is the defect being fixed.

    A missing file is created holding the bare entries: frontmatter and body
    are authorship, which is the pass's, so the caller is told to wrap what
    landed rather than the tool guessing at either.
    """
    path = AGENT_MEMORY / name
    if not path.exists():
        if anchor:
            die(f"{name} does not exist, so there is no line for the anchor "
                f"{anchor!r} to sit above")
        return (path, "\n".join(added) + "\n"), (
            f"created {name} with bare instances — wrap them in frontmatter and a body")
    lines = path.read_text().splitlines()
    while lines and not lines[-1].strip():
        lines.pop()
    if anchor:
        hits = [i for i, line in enumerate(lines) if line.startswith(anchor)]
        if len(hits) != 1:
            die(f"anchor {anchor!r} matches {len(hits)} lines in {name} — it must "
                "name exactly one, the line the entries land above; nothing was written")
        cut = hits[0]
    else:
        cut = next((i for i, line in enumerate(lines) if line.startswith(DECAY_HEADING)), None)
    if cut is None:
        merged = lines + [""] + added
    else:
        merged = lines[:cut] + added + [""] + lines[cut:]
    return (path, "\n".join(merged) + "\n"), None


def apply_drain(verdicts):
    """Move Unfiled entries to their verdicts' destinations, verbatim.

    Positional like wonder verdicts, and the mismatch guard matters more here:
    the store has recorded a jot arriving inside the section mid-pass, so the
    count is the check that the pass's snapshot still holds at write time.
    """
    lines = OPEN_CLAIMS.read_text().splitlines()
    start, end = section_bounds(lines, "Unfiled", OPEN_CLAIMS.name)
    blocks = entry_blocks(unfiled_body(lines, start, end))
    if not blocks:
        die("Unfiled is empty — nothing to drain")
    if len(verdicts) != len(blocks):
        die(f"{len(verdicts)} verdicts for {len(blocks)} unfiled entries — re-read "
            "the section and send one verdict per entry, in order; nothing was written")

    kept, by_section, by_claim, summary = [], {}, {}, []
    for verdict, block in zip(verdicts, blocks):
        if verdict == "keep":
            kept.extend(block)
            dest = "kept"
        elif verdict == DROP:
            dest = "dropped"
        elif verdict.startswith(DROP + ":"):
            dest = "dropped — " + verdict[len(DROP) + 1:].strip()
        elif verdict in SUBJECTS:
            by_section.setdefault(SUBJECTS[verdict], []).extend(block)
            dest = "→ " + SUBJECTS[verdict]
        elif verdict.startswith(CLAIM):
            name, _, anchor = verdict[len(CLAIM):].partition(ANCHOR)
            name, anchor = name.strip(), anchor.strip()
            if not name:
                die("a 'claim:' verdict needs a filename after the colon")
            if name in RESERVED:
                die(f"'claim: {name}' names a file the drain is already rewriting, "
                    "so the later write would drop the earlier one")
            slot = by_claim.setdefault(name, {"added": [], "anchor": anchor})
            if slot["anchor"] != anchor:
                die(f"two 'claim: {name}' verdicts give different anchors — one file "
                    "takes one splice point per pass; nothing was written")
            slot["added"].extend(block)
            dest = "→ " + name + (f" above {anchor!r}" if anchor else " (above the decay log)")
        else:
            die(f"verdict must be 'keep', 'drop[: why]', 'world', 'build', 'us' "
                f"or 'claim: <file>[ @ <line prefix>]', got {verdict!r}")
        summary.append(f"{headline(block)}\n    {dest}")

    lines = lines[:start] + ["", *(kept or [PLACEHOLDER]), ""] + lines[end:]
    for title, added in by_section.items():
        lines = splice_into_section(lines, title, added)

    writes = [(OPEN_CLAIMS, "\n".join(lines) + "\n")]
    for name, slot in by_claim.items():
        write, note = claim_append(name, slot["added"], slot["anchor"])
        writes.append(write)
        if note:
            summary.append(note)
    return writes, "\n".join(summary)


# ----- half-life

def pass_dates():
    """Distinct author dates of `memory:` commits, newest first — the pass-days.

    Passes cluster — often several in a day — and entry dates are day-granular,
    so the half-life clock ticks in days a pass ran, never in passes: two
    passes an hour apart give an entry no elapsed opportunity between them.
    """
    log = subprocess.run(["git", "log", "--format=%as%x09%s"],
                         cwd=REPO, capture_output=True, text=True, check=True).stdout
    dates = []
    for line in log.splitlines():
        date, _, subject = line.partition("\t")
        if subject.startswith("memory:") and date not in dates:
            dates.append(date)
    return dates


def report_due():
    """Print entries whose newest dated line predates the pass before last.

    The clock counts elapsed opportunity, not calendar time: a pass is the
    only moment an entry can ripen or be struck against, so nothing comes
    due over a fortnight nobody filed in.
    """
    passes = pass_dates()
    if len(passes) < 2:
        die("fewer than two 'memory:' passes in git history — nothing can be due")
    cutoff = passes[1]

    lines = OPEN_CLAIMS.read_text().splitlines()
    total = 0
    print(f"due — newest dated line predates the {cutoff} pass-day (latest: {passes[0]}):")
    for title in SUBJECTS.values():
        start, end = section_bounds(lines, title, OPEN_CLAIMS.name)
        rows = []
        for block in entry_blocks(lines[start:end]):
            newest = max(DATE.findall("\n".join(block)))
            if newest < cutoff:
                rows.append(f"  {headline(block)}  (newest {newest})")
        if rows:
            print(f"{title}:")
            print("\n".join(rows))
            total += len(rows)
    print(f"{total} due")


# ----------- MAIN

def main():
    if sys.argv[1:] == ["--due"]:
        report_due()
        return
    if len(sys.argv) > 2:
        die("usage: bookkeep.py [manifest.json | --due]   (or pipe the JSON on stdin)")
    source = Path(sys.argv[1]).read_text() if len(sys.argv) == 2 else sys.stdin.read()
    manifest = json.loads(source)
    date = manifest.get("date") or datetime.date.today().isoformat()
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", date):
        die(f"date must be YYYY-MM-DD, got {date!r}")

    if "wonder" in manifest and "drain" in manifest:
        die("drain and wonder cannot share a manifest — each computes a full "
            "open.md from one disk read, so the later write would drop the "
            "earlier one; drain first, then triage the spool")

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
    if "drain" in manifest:
        drain_writes, drain_summary = apply_drain(manifest["drain"])
        writes += drain_writes
        digests.append(drain_summary)
    if not writes:
        die("manifest had none of: decision, land, wonder, drain")

    if manifest.get("dry"):
        for digest in digests:
            print()
            print(digest)
        print()
        print("dry run — nothing written. Would write "
              + ", ".join(str(path.relative_to(REPO)) for path, _ in writes) + ".")
        if retired:
            print("would " + retired.replace("deleted", "delete", 1))
        return

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
