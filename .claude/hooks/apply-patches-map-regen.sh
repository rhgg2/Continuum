#!/bin/bash
# PostToolUse hook for mcp__apply_patches__apply_patches.
# Regenerates .map files for every project-root .lua path touched by the batch.
# Mirrors the inline hook used for Edit|Write|MultiEdit, but iterates over
# tool_input.edits[].path and tool_input.creates[].path (apply_patches has no
# single .file_path field).
#
# Skips dry_run calls — nothing was actually written.

set -u
INPUT=$(cat)

DRY=$(printf '%s' "$INPUT" | jq -r '.tool_input.dry_run // false')
[ "$DRY" = "true" ] && exit 0

PROJECT_ROOT="/Users/rgarner/Documents/Code/Readium"
cd "$PROJECT_ROOT" 2>/dev/null || exit 0

# Gather every path from edits[] and creates[]. Deletes are skipped — source
# is gone so map_extract has nothing to do (orphan .map cleanup is out of
# scope here).
PATHS=$(printf '%s' "$INPUT" | jq -r '
  ((.tool_input.edits // []) | map(.path)) +
  ((.tool_input.creates // []) | map(.path)) | .[]'
)

# Resolve every input path to a top-level relpath, then dedupe — a batch of
# 20 edits often hits the same handful of files, and each python3 cold-start
# costs ~hundreds of ms. Without dedupe we'd run map_extract once per edit.
RELPATHS=$(while IFS= read -r p; do
  [ -z "$p" ] && continue
  [[ "$p" != *.lua ]] && continue
  # macOS bash 3.2 mis-parses `case` inside $(...) — use [[ ]] instead.
  if [[ "$p" == /* ]]; then
    relpath="${p#$PROJECT_ROOT/}"
    [ "$relpath" = "$p" ] && continue                   # absolute path outside project
  else
    relpath="$p"
  fi
  [[ "$relpath" == */* ]] && continue                   # only top-level .lua files
  printf '%s\n' "$relpath"
done <<< "$PATHS" | sort -u)

# Run regenerations in parallel. Sequential cost was ~Nfiles × cold-start;
# parallel collapses that to roughly one cold-start of wall time.
while IFS= read -r relpath; do
  [ -z "$relpath" ] && continue
  python3 tools/map_extract.py "$relpath" map/ 2>/dev/null &
done <<< "$RELPATHS"
wait

exit 0
