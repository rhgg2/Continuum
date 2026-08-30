#!/usr/bin/env python3
"""Report which docs and specs have gone stale since they were audited.

A ledger records, for each file that has passed a review, the blob hash
of the file at that moment and the commit HEAD was on. Everything else
-- which files exist, how big they are, which have never been audited
-- is read off the tree, so a ledger only ever carries facts a human
established.

For a doc the question is whether its subject moved without it, so the
commits since the pass are split by which side of the pair they
touched:

  the module but not the doc    the doc is behind its subject
  the doc but not the module    a prose pass, no subject change
  both at once                  kept in step, nothing to see

A spec has no single subject -- each exercises a swathe of core
modules, so nearly every commit touches one -- and the audit is about
the spec's own text: honest names, no vacuous assertions, a header
that pins a model. So a spec goes stale when the spec itself moves,
and the report says by how much.

  tools/audit.py docs                     report on docs/
  tools/audit.py specs                    report on tests/specs/
  tools/audit.py docs pass timing.md      stamp, at the current content
  tools/audit.py specs pass am_spec.lua     and HEAD
"""

import glob
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

ROW = re.compile(r"^\|\s*([^|\s]+)\s*\|\s*([0-9a-f]+)\s*\|\s*([0-9a-f]+)\s*\|")
EXCLUDED = re.compile(r"^-\s+`([^`]+)`")
ASSERT = re.compile(r"\bt\.(eq|deepEq|bagEq|truthy|falsy|eventsMatch)\b")
CASE = re.compile(r"^\s*name\s*=")


def git(*args):
    done = subprocess.run(
        ["git", "-C", ROOT, *args], capture_output=True, text=True)
    return done.stdout.strip() if done.returncode == 0 else None


def readLedger(audit):
    """Return (passes, excluded) parsed out of the ledger's markdown."""
    passes, excluded = {}, set()
    with open(os.path.join(ROOT, audit["ledger"])) as handle:
        for line in handle:
            row = ROW.match(line)
            if row:
                passes[row.group(1)] = (row.group(2), row.group(3))
                continue
            skip = EXCLUDED.match(line)
            if skip:
                excluded.add(skip.group(1))
    return passes, excluded


def items(audit):
    """The files this audit covers, less any the ledger excludes."""
    _, excluded = readLedger(audit)
    return sorted(name for name in os.listdir(os.path.join(ROOT, audit["dir"]))
                  if name.endswith(audit["suffix"]) and name not in excluded)


def commitsSince(since, *paths):
    """Commits since a pass, as (subject line, files touched) pairs."""
    log = git("log", "--format=%h %s", "--name-only", f"{since}..HEAD",
              "--", *paths)
    found, header, files = [], None, set()
    for line in (log or "").splitlines():
        if not line:
            continue
        if re.match(r"^[0-9a-f]{7,} ", line) and "/" not in line.split()[0]:
            if header:
                found.append((header, files))
            header, files = line, set()
        else:
            files.add(line)
    if header:
        found.append((header, files))
    return found


# ---------- docs


def moduleOf(doc):
    """The .lua a doc is named after, if there is one. Module names are unique
    across src/, so the first hit is the only one -- but the path is which stack
    directory holds it, and git names the module by that path."""
    found = glob.glob(os.path.join(ROOT, "src", "**", doc[:-3] + ".lua"),
                      recursive=True)
    return os.path.relpath(found[0], ROOT) if found else None


def surveyDocs(audit):
    passes, _ = readLedger(audit)
    rows = []
    for doc in items(audit):
        path = os.path.join("docs", doc)
        size = os.path.getsize(os.path.join(ROOT, path))
        row = dict(name=doc, sort=size, cols=f"{size:>7}", why=[])
        if doc not in passes:
            rows.append(dict(row, state="unaudited"))
            continue
        blob, since = passes[doc]
        module = moduleOf(doc)
        behind, prose = [], []
        for header, files in commitsSince(since, path, *([module] if module else [])):
            if module in files and path not in files:
                behind.append(header)
            elif path in files and module not in files:
                prose.append(header)
        if git("hash-object", path) != git("rev-parse", f"HEAD:{path}"):
            prose.append("uncommitted edits in the working tree")
        state = "behind" if behind else "prose" if prose else "current"
        rows.append(dict(row, state=state, why=behind or prose))
    return rows


# ---------- specs


def specShape(spec):
    """Lines, cases and assertions, for choosing what to audit next."""
    with open(os.path.join(ROOT, "tests/specs", spec)) as handle:
        text = handle.read()
    mapPath = os.path.join(ROOT, "map/specs", spec[:-4] + ".map")
    cases = len(CASE.findall(text))
    if os.path.exists(mapPath):
        with open(mapPath) as handle:
            declared = re.search(r"cases=(\d+)", handle.readline())
        cases = int(declared.group(1)) if declared else cases
    return text.count("\n") + 1, cases, len(ASSERT.findall(text))


def surveySpecs(audit):
    passes, _ = readLedger(audit)
    rows = []
    for spec in items(audit):
        path = os.path.join("tests/specs", spec)
        lines, cases, asserts = specShape(spec)
        row = dict(name=spec[:-4], sort=lines, why=[],
                   cols=f"{lines:>6} {cases:>5} {asserts:>6}")
        if spec not in passes:
            rows.append(dict(row, state="unaudited"))
            continue
        blob, since = passes[spec]
        current = git("hash-object", path)
        if current == blob or current.startswith(blob):
            rows.append(dict(row, state="current"))
            continue
        why = [line for line, _ in commitsSince(since, path)]
        churn = git("diff", "--numstat", blob, current)
        if churn:
            added, removed = churn.split("	")[:2]
            why.insert(0, f"+{added} -{removed} lines since the pass")
        rows.append(dict(row, state="drifted", why=why))
    return rows


AUDITS = {
    "docs": dict(ledger="docs-audit.md", dir="docs", suffix=".md",
                 survey=surveyDocs, descending=False, heading="  bytes  doc",
                 buckets=[("behind -- the module moved without the doc", "behind"),
                          ("prose only -- the doc moved without the module", "prose"),
                          ("current", "current"),
                          ("never audited", "unaudited")]),
    "specs": dict(ledger="specs-audit.md", dir="tests/specs", suffix="_spec.lua",
                  survey=surveySpecs, descending=True,
                  heading=" lines cases assert  spec",
                  buckets=[("drifted -- the spec moved since it passed", "drifted"),
                           ("current", "current"),
                           ("never audited", "unaudited")]),
}


def report(audit):
    rows = audit["survey"](audit)
    for title, state in audit["buckets"]:
        here = [row for row in rows if row["state"] == state]
        if not here:
            continue
        print(f"\n## {title} ({len(here)})\n")
        print(f" {audit['heading']}")
        for row in sorted(here, key=lambda r: r["sort"],
                          reverse=audit["descending"]):
            print(f" {row['cols']}  {row['name']}")
            indent = " " * (len(row["cols"]) + 3)
            for line in row["why"][:5]:
                print(indent + line)
            if len(row["why"]) > 5:
                print(indent + f"... and {len(row['why']) - 5} more")
    print()


def stamp(audit, names):
    """Record each file as passed at its current content and HEAD."""
    passes, _ = readLedger(audit)
    head = git("rev-parse", "--short=8", "HEAD")
    width = max(len(name) for name in list(passes) + names)
    for name in names:
        path = os.path.join(audit["dir"], name)
        if not os.path.exists(os.path.join(ROOT, path)):
            sys.exit(f"no such file: {path}")
        passes[name] = (git("hash-object", path)[:12], head)
        print(f"passed {name} at {passes[name][0]} / {head}")

    table = "".join(f"| {name:<{width}} | {blob} | {commit} |\n"
                    for name, (blob, commit) in sorted(passes.items()))
    ledger = os.path.join(ROOT, audit["ledger"])
    with open(ledger) as handle:
        text = handle.read()
    block = re.compile(r"(^\|\s*\w+\s*\|.*\n\|[-: |]+\n)(?:\|.*\n)*", re.M)
    if not block.search(text):
        sys.exit(f"no ledger table found in {audit['ledger']}")
    with open(ledger, "w") as handle:
        handle.write(block.sub(lambda m: m.group(1) + table, text, count=1))


if __name__ == "__main__":
    if len(sys.argv) < 2 or sys.argv[1] not in AUDITS:
        sys.exit(f"usage: {sys.argv[0]} [{'|'.join(AUDITS)}] [pass <file>...]")
    chosen = AUDITS[sys.argv[1]]
    if len(sys.argv) > 2 and sys.argv[2] == "pass":
        stamp(chosen, sys.argv[3:])
    else:
        report(chosen)
