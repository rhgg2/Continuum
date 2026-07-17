#!/bin/bash
# PostToolUse hook: luacheck the .lua file(s) an edit just touched.
#
# Path-based, NOT staleness-based (unlike patches-map-regen.sh): we only nag
# about files THIS edit changed, never whatever WIP is loose in the tree —
# Richard edits continuously while the agent works, and a per-edit lint of the
# whole modified set would flag warnings unrelated to the action that fired it.
#
# Fires at the zero baseline the lint programme reached 2026-07-17: any warning
# here is a regression the edit just introduced. Paths are normalised to
# project-relative before luacheck sees them so .luacheckrc's files[] overrides
# and exclude_files patterns (keyed relative to its own location) still match.
#
# retry_patches reports no paths (they live in the server's stored batch) and so
# lints nothing; the next full edit or the commit gate catches it.

set -u
PAYLOAD=$(cat)

PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
cd "$PROJECT_ROOT" 2>/dev/null || exit 0

# Absent linter degrades to silence, not an error on every edit.
command -v luacheck >/dev/null 2>&1 || exit 0

# Touched paths across the tool shapes we fire on:
#   Edit / Write    -> .tool_input.file_path (absolute)
#   apply_patches   -> .tool_input.edits[].path, .tool_input.creates[].path
raw=$(printf '%s' "$PAYLOAD" | jq -r '
  [ .tool_input.file_path?,
    (.tool_input.edits[]?.path),
    (.tool_input.creates[]?.path) ]
  | map(select(. != null)) | .[]' 2>/dev/null)

targets=()
while IFS= read -r path; do
  [ -z "$path" ] && continue
  [[ "$path" == *.lua ]] || continue
  rel="${path#"$PROJECT_ROOT"/}"          # absolute under root -> relative; else unchanged
  [ -f "$rel" ] || continue
  targets+=("$rel")
done <<< "$raw"

[ ${#targets[@]} -eq 0 ] && exit 0

report=$(luacheck "${targets[@]}" --codes --no-color 2>&1)
[ $? -eq 0 ] && exit 0

# Exit 2: stderr is fed back to the agent as feedback. The edit already applied;
# this asks the agent to fix the warning it just introduced.
{
  echo "luacheck flagged the file(s) you just edited (repo baseline is zero warnings):"
  echo "$report"
} >&2
exit 2
