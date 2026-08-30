#!/usr/bin/env python3
"""Report which docs have gone stale since they were last audited.

The ledger in docs-audit.md records, for each doc that has passed a
review, the blob hash of the doc at that moment and the commit HEAD
was on. Staleness is then read off the commits since that pass, and
what matters is which side of the pair a commit touched:

  the module but not the doc    the doc is behind its subject
  the doc but not the module    a prose pass, no subject change
  both at once                  kept in step, nothing to see

Everything else -- which docs exist, how big they are, which have
never been audited -- is read off the tree, so the ledger only ever
carries facts a human established.

  tools/docs_audit.py             report
  tools/docs_audit.py pass X.md   stamp X.md as passed at the current
                                  content and HEAD
"""

import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LEDGER = os.path.join(ROOT, "docs-audit.md")
DOCS = os.path.join(ROOT, "docs")

ROW = re.compile(r"^\|\s*([^|\s]+\.md)\s*\|\s*([0-9a-f]+)\s*\|\s*([0-9a-f]+)\s*\|")
EXCLUDED = re.compile(r"^-\s+`([^`]+)`")


def git(*args):
    done = subprocess.run(
        ["git", "-C", ROOT, *args], capture_output=True, text=True)
    return done.stdout.strip() if done.returncode == 0 else None


def readLedger():
    """Return (passes, excluded) parsed out of the ledger's markdown."""
    passes, excluded = {}, set()
    with open(LEDGER) as handle:
        for line in handle:
            row = ROW.match(line)
            if row:
                passes[row.group(1)] = (row.group(2), row.group(3))
                continue
            skip = EXCLUDED.match(line)
            if skip:
                excluded.add(skip.group(1))
    return passes, excluded


def moduleOf(doc):
    """The .lua a doc is named after, if there is one."""
    stem = doc[:-3]
    for candidate in (stem + ".lua", os.path.join("sampler", stem + ".lua")):
        if os.path.exists(os.path.join(ROOT, candidate)):
            return candidate
    return None


def unaccompanied(docPath, module, since):
    """Commits since the pass that moved one side of the pair alone.

    Returns (behind, prose): those touching the module without the doc,
    and those touching the doc without the module. A commit that
    touched both kept the two in step and appears in neither.
    """
    log = git("log", "--format=%h %s", "--name-only", f"{since}..HEAD",
              "--", docPath, *( [module] if module else [] ))
    behind, prose = [], []
    header, files = None, set()

    def settle():
        if not header:
            return
        if module in files and docPath not in files:
            behind.append(header)
        elif docPath in files and module not in files:
            prose.append(header)

    for line in (log or "").splitlines():
        if not line:
            continue
        if re.match(r"^[0-9a-f]{7,} ", line) and "/" not in line.split()[0]:
            settle()
            header, files = line, set()
        else:
            files.add(line)
    settle()
    return behind, prose


def survey():
    passes, excluded = readLedger()
    docs = sorted(name for name in os.listdir(DOCS)
                  if name.endswith(".md") and name not in excluded)
    rows = []
    for doc in docs:
        size = os.path.getsize(os.path.join(DOCS, doc))
        if doc not in passes:
            rows.append(dict(doc=doc, size=size, state="unaudited", why=[]))
            continue
        blob, since = passes[doc]
        docPath = os.path.join("docs", doc)
        behind, prose = unaccompanied(docPath, moduleOf(doc), since)
        if git("hash-object", os.path.join(DOCS, doc)) \
                != git("rev-parse", f"HEAD:{docPath}"):
            prose = prose + ["uncommitted edits in the working tree"]
        state = "behind" if behind else "prose" if prose else "current"
        rows.append(dict(doc=doc, size=size, state=state,
                         why=behind if behind else prose))
    return rows


def report():
    rows = survey()
    buckets = [
        ("behind -- the module moved without the doc", "behind"),
        ("prose only -- the doc moved without the module", "prose"),
        ("current", "current"),
        ("never audited", "unaudited"),
    ]
    for title, state in buckets:
        here = [row for row in rows if row["state"] == state]
        if not here:
            continue
        print(f"\n## {title} ({len(here)})\n")
        for row in sorted(here, key=lambda r: r["size"]):
            print(f"  {row['size']:>7}  {row['doc']}")
            for line in row["why"][:5]:
                print(f"             {line}")
            if len(row["why"]) > 5:
                print(f"             ... and {len(row['why']) - 5} more")
    print()


def stamp(docs):
    """Record each doc as passed at its current content and HEAD."""
    passes, _ = readLedger()
    head = git("rev-parse", "--short=8", "HEAD")
    for doc in docs:
        path = os.path.join(DOCS, doc)
        if not os.path.exists(path):
            sys.exit(f"no such doc: {doc}")
        passes[doc] = (git("hash-object", path)[:12], head)
        print(f"passed {doc} at {passes[doc][0]} / {head}")

    table = "".join(f"| {doc:<22} | {blob} | {commit} |\n"
                    for doc, (blob, commit) in sorted(passes.items()))
    with open(LEDGER) as handle:
        text = handle.read()
    block = re.compile(r"(^\|\s*doc\s*\|.*\n\|[-: |]+\n)(?:\|.*\n)*", re.M)
    if not block.search(text):
        sys.exit("no ledger table found in docs-audit.md")
    with open(LEDGER, "w") as handle:
        handle.write(block.sub(lambda m: m.group(1) + table, text, count=1))


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "pass":
        stamp(sys.argv[2:])
    else:
        report()
