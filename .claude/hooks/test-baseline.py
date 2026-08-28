#!/usr/bin/env python3
"""PreToolUse(Skill) hook: establish a fresh test baseline when coding begins.

Fires for the `coding` skill alone — the moment discussion turns into code, and
the one moment a baseline is worth its fifteen seconds. Every other skill exits
silently.

The suite is run, not remembered. This hook used to open the session by reading
a record of the last run and deciding, from mtimes, whether the tree had moved
underneath it. That comparison cannot separate an edit in progress from a commit
landing, so it would report a file as changed and invite the reader to infer
uncommitted work that was not there. Running asks the only question that matters
— is this tree green now — and so needs no record, no staleness walk, and no
trust in either.

Failures are named, and capped: additionalContext is capped at 10k chars, and a
wholesale red would otherwise spend the budget on a list nobody reads. A session
opening on a red tree has to know which tests were already failing, or it will
read them as a regression it introduced.
"""

import json
import os
import re
import subprocess
import sys
import time

SKILL = "coding"
TIMEOUT = 60
MAX_NAMES = 15

REPO = os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()

SUMMARY = re.compile(r"^(\d+) passed, (\d+) failed", re.MULTILINE)
FAIL_LINE = re.compile(r"^  FAIL  (.+)$", re.MULTILINE)


def emit(context):
    json.dump(
        {"hookSpecificOutput": {"hookEventName": "PreToolUse", "additionalContext": context}},
        sys.stdout,
    )
    sys.stdout.write("\n")


def headCommit():
    try:
        return subprocess.run(
            ["git", "rev-parse", "--short", "HEAD"],
            cwd=REPO,
            capture_output=True,
            text=True,
            timeout=5,
        ).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return ""


def failureNames(stdout):
    names = FAIL_LINE.findall(stdout)
    if not names:
        return "names not recorded"
    shown = "; ".join(names[:MAX_NAMES])
    if len(names) > MAX_NAMES:
        shown += "; +{} more".format(len(names) - MAX_NAMES)
    return shown


def main():
    try:
        payload = json.load(sys.stdin)
    except ValueError:
        return
    if payload.get("tool_input", {}).get("skill") != SKILL:
        return

    started = time.time()
    try:
        proc = subprocess.run(
            ["lua", "tests/run.lua"],
            cwd=REPO,
            capture_output=True,
            text=True,
            timeout=TIMEOUT,
        )
    except subprocess.TimeoutExpired:
        emit("Test baseline: the suite did not finish within {}s, so this session has "
             "no baseline. Run it yourself before reading any red as your own.".format(TIMEOUT))
        return
    except OSError as err:
        emit("Test baseline: the suite could not be run ({}), so this session has no "
             "baseline.".format(err))
        return

    elapsed = time.time() - started
    summary = SUMMARY.search(proc.stdout)
    if not summary:
        emit("Test baseline: the runner produced no summary (exit {}), so this session "
             "has no baseline.".format(proc.returncode))
        return

    passed, failed = int(summary.group(1)), int(summary.group(2))
    commit = headCommit()
    stamp = "just now{} in {:.0f}s".format(" on commit " + commit if commit else "", elapsed)

    if failed:
        emit("Test baseline: {} passed, {} FAILED, {} — {}. These were red before you "
             "started, so do not read them as your own.".format(
                 passed, failed, stamp, failureNames(proc.stdout)))
    else:
        emit("Test baseline: {} passed, 0 failed, {}. This tree is green as it stands, "
             "so a red from here is yours.".format(passed, stamp))


if __name__ == "__main__":
    main()
