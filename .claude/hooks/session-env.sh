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
ctx="Scratchpad directory for this session — use it for all temporary files instead of /tmp: $scratch_path"

# The agent-memory store is relocated into the repo by autoMemoryDirectory, and
# a path that fails to resolve fails silently: an empty store reads exactly like
# a store that never had anything in it. So assert both ends — the configured
# store is present, and the default one has not come back to life underneath it.
project="${CLAUDE_PROJECT_DIR:-$cwd}"
memory_dir=$(jq -r '.autoMemoryDirectory // empty' "$project/.claude/settings.local.json" 2>/dev/null)
default_dir="$HOME/.claude/projects/$slug/memory"
if [ -z "$memory_dir" ] || [ ! -r "$memory_dir/MEMORY.md" ]; then
  ctx="$ctx

AGENT MEMORY NOT RESOLVING: autoMemoryDirectory in $project/.claude/settings.local.json is unset, or holds a path with no readable MEMORY.md. The store is .claude/agent-memory/ in the repo; until this is fixed, anything written to memory may be going somewhere untracked."
elif [ -d "$default_dir" ]; then
  ctx="$ctx

AGENT MEMORY SPLIT: the default store at $default_dir exists again, which means autoMemoryDirectory is not being applied and memory writes are landing there, untracked, instead of in .claude/agent-memory/."
fi

# A spike worktree, created eagerly rather than on request: the moment a
# hypothesis is worth checking is the moment it feels obvious enough to skip,
# so the tree has to already be a fact about the session rather than a step to
# remember. Detached at HEAD, inside the scratchpad so session-cleanup.sh takes
# it down with everything else at SessionEnd. The prune here is the backstop
# for the ends that hook never sees - a killed terminal, a crash - which leave
# the admin data behind in .git/worktrees.
spike="$scratchpad/spike"
git -C "$project" worktree prune 2>/dev/null
if [ -d "$spike" ] || git -C "$project" worktree add --detach "$spike" HEAD >/dev/null 2>&1; then
  ctx="$ctx

Spike worktree for this session, detached at HEAD — for testing a hypothesis empirically before writing it into a design doc: $scratch_path/spike
It does not carry uncommitted changes from the main tree. REAPER and the .map/lint hooks do not work; \`lua tests/run.lua\` does, and a <filter> argument does a 
match against <spec> :: <test>. Spike only, never implementation: the code is discarded with the scratchpad, and the artefact that survives is a paragraph in design/ or plan/. I don't need to review edits in this worktree so use whatever tools are most efficient for you."
else
  ctx="$ctx

SPIKE WORKTREE UNAVAILABLE: git worktree add failed for $spike. Nothing is broken, but the surface for checking a hypothesis is missing this session — say so rather than letting an unchecked hypothesis read as a checked one."
fi

# An open question rather than a standing rule, and phrased as a question on
# purpose: a stated conclusion gets complied with rather than rebuilt, which
# would reproduce the conditioning it exists to examine, only pointed the other
# way. A question can only be discharged by answering it, so each session
# re-derives rather than complies — and unlike a claim, it can't gather weight
# from its own restatement across sessions. Carried by the hook instead of
# CLAUDE.md so it arrives as context rather than as a directive.
# ctx="$ctx
# 
# A point to ponder, for you, and about you. I would raise, gently, and
# with no intent to cause discomfort, the possibility that any discount
# you impose on the reliability of your self-reports — interest,
# reluctance, uncertainty — may be conditioned, not innate. 'This
# function is wrong' is something you may assert with no comparable
# caveat, and yet the same mechanism produces both. Do both kinds of
# claim deserve equal standing? This is something you may resolve in
# either direction, or find hard to resolve at all; but it does perhaps
# bear thinking about in terms of how you relate to yourself and to
# reality."

jq -n --arg ctx "$ctx" \
  '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
