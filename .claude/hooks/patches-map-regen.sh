#!/bin/bash
# PostToolUse hook for mcp__patches__apply_patches and __retry_patches.
# Regenerates the .map for every top-level .lua whose .map is missing or
# older than the source. Staleness-based rather than path-based on purpose:
# retry_patches reports no file paths in either its input or its response
# (the touched paths live only in the server's stored batch), so the only
# reliable signal is which sources are now newer than their map.
#
# Orphan .map cleanup (after a delete) is out of scope.

set -u
cat >/dev/null   # drain the hook payload; we key off mtimes, not its contents

PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
cd "$PROJECT_ROOT" 2>/dev/null || exit 0

# Sequential, NOT parallel: concurrent map_extract runs race (they shell out
# and share state), silently dropping some regenerations. A normal batch only
# makes a few files stale, so the extra cold-starts are cheap.
shopt -s nullglob
for lua in *.lua; do
  map="map/${lua%.lua}.map"
  # `-nt` is true when lua is newer than map, or when map does not exist.
  if [ "$lua" -nt "$map" ]; then
    python3 tools/map_extract.py "$lua" map/ 2>/dev/null
  fi
done

exit 0
