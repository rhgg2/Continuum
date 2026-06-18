#!/usr/bin/env bash
# PreToolUse gate: an edit is allowed to reach the approval prompt only if
# .claude/precedent.json carries a citation for every file it touches.
# Missing citation -> deny (reason fed back to the model). Covered -> ask,
# surfacing the cited precedent so the user can eyeball it at the prompt.
set -uo pipefail
input="$(cat)"
dir="${CLAUDE_PROJECT_DIR:-$PWD}"
pfile="$dir/.claude/precedent.json"
. "$dir/.claude/hooks/precedent-lib.sh"

emit() { # $1=decision $2=reason
  jq -n --arg d "$1" --arg r "$2" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:$d,permissionDecisionReason:$r}}'
  exit 0
}

targets="$(precedent_targets "$input")"
[[ -z "$targets" ]] && exit 0
targets_line="$(printf '%s' "$targets" | tr '\n' ' ')"

if [[ ! -f "$pfile" ]]; then
  emit deny "No .claude/precedent.json. Before this edit, write it as {\"citations\":[{\"file\":\"<absolute path>\",\"precedent\":\"<existing call site / --KIND / convention you are following, with file:line>\"}]} covering: ${targets_line}"
fi

missing=""
reasons=""
while IFS= read -r t; do
  [[ -z "$t" ]] && continue
  pr="$(jq -r --arg f "$t" 'first(.citations[]? | select(.file==$f) | .precedent) // ""' "$pfile")"
  if [[ -z "$pr" ]]; then
    missing+="$t "
  else
    reasons+="• $t"$'\n'"    $pr"$'\n'
  fi
done <<< "$targets"

if [[ -n "$missing" ]]; then
  emit deny "precedent.json has no citation for: ${missing}. Add a {file, precedent} entry for each before editing."
fi

emit ask "Eyeball the cited precedent before approving:"$'\n'"$reasons"
