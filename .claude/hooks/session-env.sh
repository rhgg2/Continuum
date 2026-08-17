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

jq -n --arg ctx "$ctx" \
  '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
