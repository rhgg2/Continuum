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

# Reclaim the trees of sessions that ended without session-cleanup.sh finishing.
# That hook misses more ends than its header expects: `claude --worktree` deletes
# the worktree, and with it the copy of the hook hosted inside that worktree,
# before SessionEnd can run it; a killed terminal never fires it at all; `resume`
# defers cleanup to a process that may never start; and a run can be cut off
# partway, as one was on 29 Aug, leaving every file removed and every directory
# standing. Eight trees and 110 MB had collected that way.
#
# That header rejects a startup sweep because mtime cannot tell a live spike from
# a dead one, and it is right to. cli.pid can, and it is written just above for
# the test server: a pid that no longer names a claude process is a fact, not a
# guess. A resumed session rewrites it on the way back in, so the lease `resume`
# takes out expires here when it is never taken up.
#
# The same fact answers who holds REAPER, so both questions run off one predicate
# rather than each keeping its own record.
#
# Scope is this repo and its worktrees - one slug per cwd, each of them the main
# tree's path with the separators flattened. A sibling repo sharing our prefix
# keeps its worktrees in a different .git, so the glob names our slug and our
# slug-with-a-suffix rather than our prefix, and the whole sweep is skipped
# outside a repo: `dirname` of the empty string is ".", which would silently
# widen it from our slugs to every project under $root.
# A session dir is held while the pid it recorded still names a claude process.
owned() {
  [ -f "$1/cli.pid" ] || return 1
  case "$(ps -o comm= -p "$(cat "$1/cli.pid")" 2>/dev/null)" in
    *claude) return 0 ;;
  esac
  return 1
}

# Whether anyone is working in a given tree, found through the slug its path
# flattens to. This is the same question the sweep asks, one level up.
watched() {
  for held_dir in "$root/$(printf '%s' "$1" | tr '/' '-')"/*/; do
    held_dir=${held_dir%/}
    [ -d "$held_dir" ] && owned "$held_dir" && return 0
  done
  return 1
}

common_dir=$(git -C "$cwd" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
if [ -n "$common_dir" ]; then
  main_tree=$(dirname "$common_dir")
  main_slug=$(printf '%s' "$main_tree" | tr '/' '-')
  for dead in "$root/$main_slug"/*/ "$root/$main_slug"-*/*/; do
    dead=${dead%/}
    [ -d "$dead" ] || continue
    [ "$dead" = "$root/$slug/$session_id" ] && continue
    owned "$dead" && continue
    # A missing cli.pid is not evidence of death: the walk above writes nothing
    # when it finds no claude ancestor. Only a directory holding neither a spike
    # nor a single file is certainly abandoned, and a live session has the spike.
    if [ ! -f "$dead/cli.pid" ]; then
      [ -d "$dead/scratchpad/spike" ] && continue
      [ -n "$(find "$dead" -type f | head -1)" ] && continue
    fi
    printf '%s\tsweep\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$dead")" >> "$root/session-end.log"
    rm -rf "$dead"
  done

  # With every abandoned tree now gone from disk, prune drops the registrations
  # it could not touch while they stood. This is also what finishes a
  # session-cleanup.sh killed after its rm -rf, which is why that hook deletes
  # before it deregisters.
  git worktree prune 2>/dev/null

  # Hand REAPER back when the tree holding it has no session left. reaper_reload
  # claims the link by pointing it at the claiming tree, and SessionEnd returns
  # it; the ends that hook never sees leave it naming a tree nobody works in.
  # REAPER keeps loading that Continuum, and every other session's requests go to
  # a spool nothing polls - silence that reads as a dead instance until asked.
  #
  # Staged and renamed rather than relinked in place, so the link never names
  # nothing: a running Continuum re-stats it every tick. mv needs -h because the
  # link resolves to a directory, and without it the rename lands *inside* that
  # directory - leaving the link untouched and a stray Continuum.release in
  # somebody's checkout. See docs/bridge.md § Claiming REAPER.
  reaper_link="$HOME/Library/Application Support/REAPER/Scripts/Continuum"
  held=$(readlink "$reaper_link" 2>/dev/null)
  if [ -n "$held" ] && [ "$held" != "$main_tree" ] && ! watched "$held"; then
    if ln -sfn "$main_tree" "$reaper_link.release" 2>/dev/null &&
       mv -fh "$reaper_link.release" "$reaper_link" 2>/dev/null; then
      printf '%s\trelease\t%s\n' "$(date -u +%FT%TZ)" "$held" >> "$root/session-end.log"
    fi
  fi
fi

# A link outlives its target either way round, and a dangling one is no use to
# whoever made it - including the sessions swept above, whose links this session
# has no other way to name.
for stale in "$root"/*; do
  if [ -L "$stale" ] && [ ! -e "$stale" ]; then rm -f "$stale"; fi
done

# A spike worktree, created eagerly rather than on request: the moment a
# hypothesis is worth checking is the moment it feels obvious enough to skip,
# so the tree has to already be a fact about the session rather than a step to
# remember. Detached at HEAD, inside the scratchpad so session-cleanup.sh takes
# it down with everything else at SessionEnd - or failing that, the sweep above
# does, at the next session to start anywhere in this repo.
spike="$scratchpad/spike"
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
