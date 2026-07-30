#!/usr/bin/env python3
"""SessionStart hook: report the last full test run.

The suite is deterministic and takes ~20s, so a session opening on an untouched
tree can take the previous run's result instead of re-running to learn the same
thing. The record is written by the continuum_tests MCP server, unfiltered runs only.

The staleness check is the whole job. The baseline holds exactly when no file the
suite reads has been touched since the run *started*, so anything that stops that
check from running reports STALE and never green: a false green buys a skipped run
with a wrong belief, which is worse than having no baseline at all.

Python rather than find(1) on purpose. BSD find — what a hook actually gets —
cannot parse `-newermt @epoch`; it errors and returns nothing, which is
indistinguishable from "nothing changed". The first draft of this hook shipped
that bug and reported green unconditionally. Note also that the Bash tool's shell
shims `find` to `bfs`, which *does* accept @epoch, so testing the shell form
interactively will not reproduce what the hook sees.
"""

import json
import os
import sys
import time

REPO = os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()
BASELINE = os.path.join(REPO, ".claude", "test-baseline.json")
TESTS = os.path.join(REPO, "tests")
SKIP_DIRS = {".git", ".claude", "node_modules", "__pycache__"}


def emit(context):
    json.dump(
        {"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": context}},
        sys.stdout,
    )
    sys.stdout.write("\n")


def changed_since(ts):
    """Paths the suite reads that are newer than ts: any *.lua, plus all of tests/.

    Deliberately over-inclusive — a false STALE costs one 20s run, a false green
    costs the trust that makes the baseline worth having.
    """
    changed = []
    for dirpath, dirnames, filenames in os.walk(REPO):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        under_tests = dirpath == TESTS or dirpath.startswith(TESTS + os.sep)
        for name in filenames:
            if not under_tests and not name.endswith(".lua"):
                continue
            path = os.path.join(dirpath, name)
            try:
                if os.stat(path).st_mtime > ts:
                    changed.append(os.path.relpath(path, REPO))
            except OSError:
                continue
    return sorted(changed)


def main():
    try:
        with open(BASELINE, encoding="utf-8") as fh:
            record = json.load(fh)
        ts = float(record["ts"])
        passed, failed = int(record["passed"]), int(record["failed"])
    except (OSError, ValueError, KeyError, TypeError):
        return

    when = time.strftime("%H:%M on %d %b", time.localtime(ts))
    commit = record.get("commit") or ""
    if commit:
        when = "{}, commit {}".format(when, commit)

    if failed:
        names = "; ".join(record.get("failures") or []) or "names not recorded"
        head = "Test baseline: {} passed, {} FAILED at {} — {}.".format(passed, failed, when, names)
    else:
        head = "Test baseline: {} passed, 0 failed at {}.".format(passed, when)

    try:
        changed = changed_since(ts)
    except OSError as err:
        emit("{} The staleness check could not run ({}), so treat this as STALE and "
             "run the suite if you need a green starting point.".format(head, err))
        return

    if not changed:
        if failed:
            body = ("Nothing the suite reads has changed since, so this tree is still red "
                    "as it stands.")
        else:
            body = ("Nothing the suite reads has changed since, so the suite is green on this "
                    "tree as it stands — you do not need to run it to establish a baseline.")
    else:
        shown = ", ".join(changed[:3])
        if len(changed) > 3:
            shown += ", +{} more".format(len(changed) - 3)
        body = ("STALE: {} file(s) changed since ({}). The baseline does not cover them — "
                "run the suite if you need a green starting point.".format(len(changed), shown))

    emit("{} {}".format(head, body))


if __name__ == "__main__":
    main()
