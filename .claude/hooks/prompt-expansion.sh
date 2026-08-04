#!/usr/bin/env bash
# UserPromptExpansion / PreToolUse(Skill): front-load the reads a command opens
# with, so the skill starts thinking instead of spending turns fetching what it
# always fetches.
#
# The text becomes additionalContext. Claude Code caps that at 10k chars and
# spills the overflow to a file, so only ever emit digests here — a full
# `git diff` blows the cap and buys nothing.

set -uo pipefail

repo="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null)}"
[[ -d $repo ]] && cd "$repo" || exit 0

# Two events reach this script: UserPromptExpansion when the command is typed as
# a slash command, and PreToolUse when Claude invokes the same skill himself.
# They name the skill in different fields and want the result in different
# formats; everything between is common, so read stdin once and branch at the
# ends.
payload=$(cat)
eventName=$(jq -r '.hook_event_name // empty' <<<"$payload" 2>/dev/null)
commandName=$(jq -r '.command_name // .tool_input.skill // empty' <<<"$payload" 2>/dev/null)

# plan/CURRENT is a stack, newest first: the top line is the live plan and the
# lines under it are parked, waiting for a /plan-close to pop back to them.
liveplanName() { grep -m1 -v '^[[:space:]]*$' plan/CURRENT 2>/dev/null | tr -d '[:space:]'; }

emitLivePlan() {
  local name planPath
  [[ -f plan/CURRENT ]] || { echo "plan/CURRENT is missing — there is no live plan."; return; }
  name=$(liveplanName)
  [[ -n $name ]] || { echo "plan/CURRENT is empty — there is no live plan."; return; }
  planPath="plan/$name"
  [[ -f $planPath ]] || { echo "plan/CURRENT names $name, which does not exist."; return; }

  echo "The live plan ($planPath), injected by hook — it is current, so don't re-read it:"
  echo
  cat "$planPath"
}

# The in-flight implementation brief: untracked, one item, written by /plan-next
# and deleted by the landing bookkeeping — so its existence is the signal that an
# item has been compiled and hasn't landed.
briefPath=plan/IMPL.md

emitBrief() {
  local name
  [[ -f $briefPath ]] || { echo "$briefPath is missing — no brief has been compiled."; return; }
  name=$(liveplanName)
  echo "The implementation brief ($briefPath), injected by hook — it is current, so"
  echo "don't re-read it. The live plan is plan/${name:-(none)}; the brief's own"
  echo "\`plan:\` line should agree, and a disagreement is worth stopping over."
  echo
  cat "$briefPath"
}

emitBriefState() {
  echo
  if [[ -f $briefPath ]]; then
    echo "$briefPath exists — an item is in flight and has not landed:"
    grep -m1 '^# ' "$briefPath" || echo "(no title line)"
  else
    echo "$briefPath does not exist — no item in flight."
  fi
}

emitPlanShelf() {
  echo "Plan shelf, injected by hook — it is current, so don't re-list these:"
  echo
  echo '$ cat plan/CURRENT   (stack, newest first; the top line is live)'
  [[ -f plan/CURRENT ]] && cat plan/CURRENT || echo '(missing)'
  echo
  echo '$ ls -1 plan plan/archive design'
  ls -1 plan plan/archive design 2>/dev/null
}

emitTreeState() {
  echo "Working-tree state, injected by hook — it is current, so don't re-run these:"
  echo
  echo '$ git status --porcelain'
  git status --porcelain
  echo
  echo '$ git diff --stat HEAD   (staged and unstaged; untracked show above only)'
  git diff --stat HEAD
}

# Kept a function rather than inlined into the $( ) below: macOS ships bash 3.2,
# whose parser reads a case pattern's `)` as closing the command substitution.
emitContext() {
  case "$commandName" in
    plan-next|plan-phase) emitLivePlan; emitBriefState ;;
    implement-next)       emitBrief ;;
    plan-new)             emitPlanShelf ;;
    plan-close)           emitLivePlan; emitBriefState; echo; emitPlanShelf ;;
    commit)               emitTreeState ;;
  esac
}

context=$(emitContext)
[[ -n $context ]] || exit 0

# UserPromptExpansion takes plain stdout as context; PreToolUse ignores plain
# stdout and reads JSON only.
if [[ $eventName == PreToolUse ]]; then
  jq -n --arg ctx "$context" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", additionalContext: $ctx}}'
else
  printf '%s\n' "$context"
fi

exit 0
