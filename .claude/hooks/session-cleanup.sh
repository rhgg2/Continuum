#!/bin/sh
# SessionEnd hook: tear down this session's scratchpad, its spike worktree and
# its alias link. The counterpart to session-env.sh, and deliberately owned by
# the session itself - the alternative was a sweep at startup guessing from
# mtime which *other* sessions had finished, and a second session in the same
# repo is normal, so that guess could delete a live spike tree. A session
# knows it is ending; nobody else can infer it.
#
# Why this exists at all: the layout was assumed to be swept by the OS, and it
# is not. Left alone it reached 138 session dirs, 104 registered worktrees and
# 1.25 GB, which also made `git worktree list` useless.
input=$(cat)
session_id=$(printf '%s' "$input" | jq -r '.session_id')
cwd=$(printf '%s' "$input" | jq -r '.cwd')
reason=$(printf '%s' "$input" | jq -r '.reason // "unset"')
slug=$(printf '%s' "$cwd" | tr '/' '-')
root="/private/tmp/claude-$(id -u)"
project="${CLAUDE_PROJECT_DIR:-$cwd}"

# One line per end, whatever the reason. This is the witness that the hook runs
# at all: silent accumulation is precisely how the 1.25 GB went unnoticed, and
# without a record, "fired and had nothing to do" and "never fired" look the
# same from the outside.
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$reason" "$session_id" >> "$root/session-end.log"

# The test is whether context survives the end, not whether the session_id
# does. `clear` discards the conversation, so nothing is left to hold an
# expectation about the scratchpad and it goes. `resume` continues the same
# conversation in a new process with its history intact, so the scratchpad it
# was told about must still be there.
case "$reason" in
  resume) exit 0 ;;
esac

scratchpad="$root/$slug/${session_id}/scratchpad"
git -C "$project" worktree remove --force "$scratchpad/spike" 2>/dev/null
rm -rf "$root/$slug/${session_id}"
rm -f "$root/$(basename "$cwd")-$(printf '%s' "$session_id" | cut -c1-8)"
git -C "$project" worktree prune 2>/dev/null
