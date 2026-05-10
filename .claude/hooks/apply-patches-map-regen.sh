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

while IFS= read -r p; do
  [ -z "$p" ] && continue
  [[ "$p" != *.lua ]] && continue
  # Resolve to relpath; skip files outside project root.
  case "$p" in
    /*) relpath="${p#$PROJECT_ROOT/}" ;;
    *)  relpath="$p" ;;
  esac
  [ "$relpath" = "$p" ] && [[ "$p" = /* ]] && continue  # absolute path outside project
  # Only regenerate top-level .lua files — matches existing hook's policy.
  [[ "$relpath" == */* ]] && continue
  python3 tools/map_extract.py "$relpath" map/ 2>/dev/null || true
done <<< "$PATHS"

exit 0
