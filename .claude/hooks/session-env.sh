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
ctx="Scratchpad directory for this session — use it for all temporary files instead of /tmp: $scratchpad"

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
# remember. Detached at HEAD, inside the scratchpad so it is swept along with
# everything else. Prune first, because a swept scratchpad leaves the admin
# data behind in .git/worktrees.
spike="$scratchpad/spike"
git -C "$project" worktree prune 2>/dev/null
if [ -d "$spike" ] || git -C "$project" worktree add --detach "$spike" HEAD >/dev/null 2>&1; then
  ctx="$ctx

Spike worktree for this session, detached at HEAD — for testing a hypothesis empirically before writing it into a design doc: $spike
It does not carry uncommitted changes from the main tree. \`lua tests/run.lua\` works there; REAPER and the .map/lint hooks do not. Spike only, never implementation — see CLAUDE.md § Programme plans."
else
  ctx="$ctx

SPIKE WORKTREE UNAVAILABLE: git worktree add failed for $spike. Nothing is broken, but the surface for checking a hypothesis is missing this session — say so rather than letting an unchecked hypothesis read as a checked one."
fi

jq -n --arg ctx "$ctx" \
  '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
