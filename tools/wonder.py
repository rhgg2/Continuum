#!/usr/bin/env python3
"""Jot into the open end of the memory store.

Noticing something future-you would want should cost nothing and ask nothing,
so this appends and stops: no subject, no standing, no prompt. Deciding those
at the moment of noticing is friction exactly where there should be none, and
it is also the wrong moment to decide — which is why every jot lands in
`## Unfiled` whatever it is about, and the filing pass classifies later.

Length is not rationed and structure survives — line breaks, code and worked
examples come through, indented into the bullet. A jot may be a one-line
curiosity or a finding entire, because compressing it belongs to the filing
pass: that pass is the party without the session's context, so it is the only
one that can tell whether the compression worked.

Usage: python3 tools/wonder.py "the jot, at whatever length it takes"
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


def as_bullet(text, today):
    """The jot as one markdown bullet, continuation lines indented into it.

    Only trailing whitespace goes. A rich finding often *is* its structure —
    index expressions, a worked example — and collapsing whitespace destroys
    that while leaving every word of it in place.
    """
    lines = [line.rstrip() for line in text.strip().split("\n")]
    bullet = [f"- [{today}] {lines[0]}"]
    bullet.extend(f"  {line}" if line else "" for line in lines[1:])
    return bullet


# ----------- MAIN

def main():
    if len(sys.argv) != 2 or not sys.argv[1].strip():
        die('usage: wonder.py "the jot, at whatever length it takes"')

    bullet = as_bullet(sys.argv[1], datetime.date.today().isoformat())

    lines = OPEN_CLAIMS.read_text().split("\n")
    body, start = unfiled_body(lines)
    if len(body) == 1 and lines[body[0]].strip() == PLACEHOLDER:
        lines[body[0] : body[0] + 1] = bullet
    else:
        at = body[-1] + 1 if body else start
        lines[at:at] = bullet
    OPEN_CLAIMS.write_text("\n".join(lines))
    print("\n".join(bullet))


if __name__ == "__main__":
    main()
