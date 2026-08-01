#!/bin/bash
# PostToolUse hook for every tool that can write a .lua: Edit, Write, and
# mcp__patches__apply_patches / __retry_patches.
#
# Staleness-based rather than path-based on purpose: retry_patches reports no
# file paths in either its input or its response (the touched paths live only
# in the server's stored batch), so the only reliable signal is which sources
# are now newer than their map. That serves the path-carrying tools equally
# well, which is why all four callers share one command.
#
# map_regen owns which sources have maps and where those maps go; this script
# must not re-derive it. It also renders the batch in one process, which is
# what removed the race this comment used to warn about -- concurrent
# map_extract runs shelled out and shared state, silently dropping some
# regenerations.
#
# Orphan .map cleanup (after a delete) stays out of scope: map_regen reports
# orphans and deletes none.
#
# stderr is deliberately not swallowed, and the exit code is map_regen's own.
# Per-file render errors are caught in there, so anything surfacing here means
# the generator itself is broken -- the one failure that must not be silent.

set -u
cat >/dev/null   # drain the hook payload; we key off mtimes, not its contents

PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
cd "$PROJECT_ROOT" || exit 1

exec python3 tools/map_regen.py --write --stale-only
