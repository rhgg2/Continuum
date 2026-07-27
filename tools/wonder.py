#!/usr/bin/env python3
"""Jot into the spool, the untracked end of the memory store.

Noticing something future-you would want should cost nothing and ask nothing,
so this appends and stops: no subject, no standing, no prompt. Deciding those
at the moment of noticing is friction exactly where there should be none, and
it is also the wrong moment to decide.

The spool is untracked and outlives the session, because a jot's fate is
settled downstream by two differently-placed parties: the commit skill's
triage knows whether the session went on to answer it, and the filing pass —
which has no session context at all — knows what it is and where it belongs.
Neither judgement can be made here, so nothing reaches the tracked store until
the first of them has run.

Length is not rationed and structure survives — line breaks, code and worked
examples come through, indented into the bullet. A jot may be a one-line
curiosity or a finding entire, because compressing it belongs downstream too:
the party without the session's context is the only one that can tell whether
the compression worked.

Usage: python3 tools/wonder.py "the jot, at whatever length it takes"
"""

import datetime
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SPOOL = REPO / ".claude" / "agent-memory" / "spool.md"


def die(msg):
    sys.exit(f"wonder: {msg}")


def as_bullet(text, today):
    """The jot as one markdown bullet, continuation lines indented into it.

    Only trailing whitespace goes. A rich finding often *is* its structure —
    index expressions, a worked example — and collapsing whitespace destroys
    that while leaving every word of it in place.

    This layout is the spool's grammar: bookkeep.py finds where one jot ends and
    the next begins by the unindented `- [date]` opener, so a continuation line
    that lost its indent would read as a second jot.
    """
    lines = [line.rstrip() for line in text.strip().split("\n")]
    bullet = [f"- [{today}] {lines[0]}"]
    bullet.extend(f"  {line}" if line else "" for line in lines[1:])
    return bullet


# ----------- MAIN

def main():
    if len(sys.argv) != 2 or not sys.argv[1].strip():
        die('usage: wonder.py "the jot, at whatever length it takes"')

    bullet = "\n".join(as_bullet(sys.argv[1], datetime.date.today().isoformat()))
    with SPOOL.open("a") as spool:
        spool.write(bullet + "\n")
    print(bullet)


if __name__ == "__main__":
    main()
