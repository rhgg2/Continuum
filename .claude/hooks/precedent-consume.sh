#!/usr/bin/env bash
# PostToolUse: the edit landed, so spend its citations. Drop every consumed
# file from precedent.json -> re-editing the same file needs a fresh cite.
# Only fires on success, so a rejected ask or aborted patch keeps its cite.
set -uo pipefail
input="$(cat)"
dir="${CLAUDE_PROJECT_DIR:-$PWD}"
pfile="$dir/.claude/precedent.json"
[[ -f "$pfile" ]] || exit 0
. "$dir/.claude/hooks/precedent-lib.sh"

targets="$(precedent_targets "$input")"
[[ -z "$targets" ]] && exit 0

tjson="$(printf '%s\n' "$targets" | jq -R . | jq -s 'map(select(. != ""))')"
tmp="$(mktemp)"
if jq --argjson t "$tjson" '.citations |= map(select(.file as $f | ($t|index($f))|not))' "$pfile" > "$tmp"; then
  mv "$tmp" "$pfile"
else
  rm -f "$tmp"
fi
