# Shared by precedent-gate.sh and precedent-consume.sh.
# Emits one absolute target path per line for the tool call whose full
# hook-stdin JSON is passed as $1. Covers Edit/Write (file_path) and the
# patches tools (edits[].path, creates[].path, deletes[]), resolving
# relatives against tool_input.cwd or the project dir. Paths under any
# .claude/ directory are dropped: the gate must never block writing
# precedent.json itself or the user's ~/.claude memory.
precedent_targets() {
  local input="$1" cwd p abs
  cwd="$(jq -r '.tool_input.cwd // empty' <<<"$input")"
  [[ -z "$cwd" ]] && cwd="${CLAUDE_PROJECT_DIR:-$PWD}"
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    if [[ "$p" = /* ]]; then abs="$p"; else abs="$cwd/$p"; fi
    [[ "$abs" == */.claude/* ]] && continue
    printf '%s\n' "$abs"
  done < <(jq -r '
    .tool_input as $i
    | ([$i.file_path] + ($i.edits//[]|map(.path)) + ($i.creates//[]|map(.path)) + ($i.deletes//[]))
    | map(select(. != null and . != "")) | .[]' <<<"$input")
}
