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
#
# Owning the teardown is necessary and not sufficient. A `claude --worktree`
# session deletes the worktree hosting this script before SessionEnd can run it,
# so the ends this hook cannot witness include some perfectly ordinary ones. The
# sweep in session-env.sh reclaims whatever this misses, keyed on a recorded pid
# rather than the mtime the paragraph above rightly refuses to guess from.
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

# REAPER loads Continuum through one symlink, claimed by whichever session last
# called reaper_reload (see .claude/mcp/reaper/server.py). Hand it back to the main
# tree on the way out -- but only if this session still holds it, or the session
# that happens to finish first takes REAPER from one still using it. A failed
# relink costs nothing: the next reload claims the link regardless.
link="$HOME/Library/Application Support/REAPER/Scripts/Continuum"
main=$(dirname "$(git -C "$project" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)")
# Staged and renamed, not relinked in place: a running Continuum re-stats this
# link every tick, so it must never name nothing. Same reason _claim uses a
# rename, and the sweep in session-env.sh the same again. -h keeps the rename
# from following the link into the directory it names.
if [ "$(readlink "$link")" = "$cwd" ] && [ "$cwd" != "$main" ]; then
  ln -sfn "$main" "$link.release" && mv -fh "$link.release" "$link"
fi

# Delete first, deregister second, because this hook does get cut off partway:
# a run on 29 Aug left every file removed and every directory still standing.
# With the tree already gone, `prune` alone finishes the job, and session-env.sh
# runs it again at the next start. With the tree still standing, nothing
# finishes it - prune only drops registrations whose directory has vanished, so
# a spike left on disk goes on looking healthy to it forever.
rm -rf "$root/$slug/${session_id}"
rm -f "$root/$(basename "$cwd")-$(printf '%s' "$session_id" | cut -c1-8)"
git -C "$project" worktree prune 2>/dev/null
