#!/usr/bin/env bash
# UserPromptExpansion: front-load the reads a command opens with, so the skill
# starts thinking instead of spending turns fetching what it always fetches.
#
# stdout becomes additionalContext. Claude Code caps that at 10k chars and
# spills the overflow to a file, so only ever emit digests here — a full
# `git diff` blows the cap and buys nothing.

set -uo pipefail

repo="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null)}"
[[ -d $repo ]] && cd "$repo" || exit 0

commandName=$(jq -r '.command_name // empty' 2>/dev/null)

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

case "$commandName" in
  plan-next|implement-next|plan-phase) emitLivePlan ;;
  plan-new)                            emitPlanShelf ;;
  plan-close)                          emitLivePlan; echo; emitPlanShelf ;;
  commit)                              emitTreeState ;;
esac

exit 0
