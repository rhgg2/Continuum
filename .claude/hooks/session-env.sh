#!/bin/sh
# SessionStart hook: rebuild this session's scratchpad path and inject it as
# context, because a replacement system prompt (see ../system-prompt.md) is
# static and can't carry per-session values. The layout —
# /private/tmp/claude-$UID/<cwd with / as ->/<session-id>/scratchpad — is
# undocumented; if scratchpad writes start hitting permission prompts, check
# it hasn't moved.
input=$(cat)
session_id=$(printf '%s' "$input" | jq -r '.session_id')
cwd=$(printf '%s' "$input" | jq -r '.cwd')
slug=$(printf '%s' "$cwd" | tr '/' '-')
scratchpad="/private/tmp/claude-$(id -u)/$slug/${session_id}/scratchpad"

# A short alias for the session scratchpad, because the real path carries the
# session id and runs to ~100 characters. Abbreviating that into a shell
# variable is the wrong fix: permissions are decided by reading the command
# text, so a $VAR makes the command opaque to that reading and every scratchpad
# write becomes a prompt. A literal short path is analysable.
#
# The link name carries the session id because the first cut of this used a
# bare repo name, and a second session in the same repo repointed it within two
# minutes — silently redirecting the older session's writes into the newer
# session's scratchpad and spike tree. A shared mutable name is not a stable
# one. No alarm branch if the link fails: the injected path below is correct
# either way, just verbose.
root="/private/tmp/claude-$(id -u)"
repo=$(basename "$cwd")
link="$root/$repo-$(printf '%s' "$session_id" | cut -c1-8)"
mkdir -p "$scratchpad"

# Sweep links whose scratchpad has been swept from under them, as /private/tmp
# outlives neither. Same housekeeping as the worktree prune below.
for stale in "$root/$repo"-*; do
  if [ -L "$stale" ] && [ ! -e "$stale" ]; then rm -f "$stale"; fi
done

if ln -sfn "$scratchpad" "$link" 2>/dev/null; then
  scratch_path="$link"
else
  scratch_path="$scratchpad"
fi
ctx="Scratchpad directory for this session: $scratch_path. Use instead of writing to /tmp.
apply_patches works in the scratchpad, with the same atomicity but no approval gate -
prefer it to sed or scripts to patch files."

# The pid of the claude process this session runs under, left where the test
# server can find it. That server resolves the spike from
# CLAUDE_CODE_SESSION_ID, which it read once when it was spawned and cannot
# read again: `/clear` rolls the id and arrives back here for a fresh
# scratchpad without restarting MCP servers, so the id they hold names a
# session whose tree has since been swept. The pid does not roll, and is the
# one key both ends can see. Nothing is written if no claude ancestor is
# found, because a wrong pid would aim a probe at another session's tree, and
# no spike is the better failure.
pid=$$
while [ -n "$pid" ] && [ "$pid" -gt 1 ]; do
  case "$(ps -o comm= -p "$pid" 2>/dev/null)" in
    *claude) printf '%s\n' "$pid" > "$root/$slug/$session_id/cli.pid"; break ;;
  esac
  pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
done

# A spike worktree, created eagerly rather than on request: the moment a
# hypothesis is worth checking is the moment it feels obvious enough to skip,
# so the tree has to already be a fact about the session rather than a step to
# remember. Detached at HEAD, inside the scratchpad so session-cleanup.sh takes
# it down with everything else at SessionEnd. The prune here is the backstop
# for the ends that hook never sees - a killed terminal, a crash - which leave
# the admin data behind in .git/worktrees.
spike="$scratchpad/spike"
git worktree prune 2>/dev/null
if [ -d "$spike" ] || git worktree add --detach "$spike" HEAD >/dev/null 2>&1; then
  ctx="$ctx

Spike worktree for this session, detached at HEAD: $scratch_path/spike. It does not carry uncommitted changes
from the main tree. REAPER and the .map/lint hooks do not work; \`lua tests/run.lua\` does. Code is discarded
with the scratchpad; if the spike has value beyond this session, suggest promotion to tests/spikes/ in the main tree."
fi

# The maps are generated rather than tracked, so a tree that has not held a
# session yet -- a fresh clone, a new worktree -- has none, and map_query would
# answer every question with silence rather than an error. Unconditional: the
# mtime filter makes the warm case (~45ms) cheap enough not to need a branch,
# and the cold one (~7s) is paid once per tree.
(cd "$cwd" && python3 tools/map_regen.py --write --stale-only) >/dev/null 2>&1

jq -n --arg ctx "$ctx" \
  '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
