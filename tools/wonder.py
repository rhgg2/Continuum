#!/usr/bin/env python3
"""Jot a curiosity into the open end of the memory store.

Noticing something future-you would want should cost nothing and ask nothing,
so this appends and stops: no subject, no standing, no prompt. Deciding those
at the moment of noticing is friction exactly where there should be none, and
it is also the wrong moment to decide — which is why every jot lands in
`## Unfiled` whatever it is about, and the filing pass classifies later.

Usage: python3 tools/wonder.py "the curiosity"
"""

import datetime
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
OPEN_CLAIMS = REPO / ".claude" / "agent-memory" / "open.md"
UNFILED = "## Unfiled"
PLACEHOLDER = "(nothing unfiled)"


def die(msg):
    sys.exit(f"wonder: {msg}")


def unfiled_body(lines):
    """Line numbers of the ## Unfiled section's non-blank lines, in order."""
    if UNFILED not in lines:
        die(f"no {UNFILED!r} heading in {OPEN_CLAIMS}")
    start = lines.index(UNFILED) + 1
    end = start
    while end < len(lines) and not lines[end].startswith("## "):
        end += 1
    return [n for n in range(start, end) if lines[n].strip()], start


# ----------- MAIN

def main():
    if len(sys.argv) != 2 or not sys.argv[1].strip():
        die('usage: wonder.py "the curiosity"')

    today = datetime.date.today().isoformat()
    bullet = f"- [{today}] {' '.join(sys.argv[1].split())}"

    lines = OPEN_CLAIMS.read_text().split("\n")
    body, start = unfiled_body(lines)
    if len(body) == 1 and lines[body[0]].strip() == PLACEHOLDER:
        lines[body[0]] = bullet
    else:
        lines.insert(body[-1] + 1 if body else start, bullet)
    OPEN_CLAIMS.write_text("\n".join(lines))
    print(bullet)


if __name__ == "__main__":
    main()
