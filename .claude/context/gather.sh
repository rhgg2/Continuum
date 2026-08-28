#!/usr/bin/env bash
# Injected into a skill by the `!`…`` syntax in its SKILL.md: front-loads the
# reads a command opens with, so the skill starts thinking instead of spending
# turns fetching what it always fetches.
#
# Each argument names an emitter; they run in order, separated by a blank line.
# This used to be a hook registered on both UserPromptExpansion and
# PreToolUse(Skill), because a skill can arrive by being typed or by being
# invoked, and the two events name the skill in different fields and want the
# result in different formats. Injection happens downstream of both, so the
# adapter is gone and each skill now names the context it wants.
#
# A non-zero exit aborts the whole skill invocation — Claude never sees the
# content — so this script always exits 0, and grep's empty-match 1 must never
# reach the end.
#
# Output past the Bash tool's inline ceiling arrives as a file path plus a
# preview rather than inline text, so emit digests: a full `git diff` costs the
# skill its context and buys nothing.

set -uo pipefail

repo="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null)}"
[[ -d $repo ]] && cd "$repo" || exit 0

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

  echo "The live plan ($planPath), gathered at invocation — it is current, so don't re-read it:"
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
  echo "The implementation brief ($briefPath), gathered at invocation — it is current,"
  echo "so don't re-read it. The live plan is plan/${name:-(none)}; the brief's own"
  echo "\`plan:\` line should agree, and a disagreement is worth stopping over."
  echo
  cat "$briefPath"
}

emitBriefState() {
  if [[ -f $briefPath ]]; then
    echo "$briefPath exists — an item is in flight and has not landed:"
    grep -m1 '^# ' "$briefPath" || echo "(no title line)"
  else
    echo "$briefPath does not exist — no item in flight."
  fi
}

emitPlanShelf() {
  echo "Plan shelf, gathered at invocation — it is current, so don't re-list these:"
  echo
  echo '$ cat plan/CURRENT   (stack, newest first; the top line is live)'
  [[ -f plan/CURRENT ]] && cat plan/CURRENT || echo '(missing)'
  echo
  echo '$ ls -1 plan plan/archive design'
  ls -1 plan plan/archive design 2>/dev/null
}

# The doc <-> plan link is written by hand at both ends — the plan's `> source:`
# line and the design doc's `status:` line — so it goes stale silently, which is
# how a live doc came to read "parked" after a park-and-revive. Only the
# mechanical half is checked: that the link resolves, and that "in flight" shows
# up in the status of exactly the doc whose plan is live. The prose around it is
# left alone — that vocabulary is deliberately free-form.
emitPlanLinkage() {
  local live plan slug doc status problems=
  live=$(liveplanName)
  for plan in plan/*.md; do
    [[ -f $plan ]] || continue
    slug=${plan#plan/}
    doc=$(sed -n 's/^> source:.*`\(design\/[^`]*\)`.*/\1/p' "$plan" | head -1)
    if [[ -z $doc ]]; then
      problems+="  $plan names no design doc in a \`> source:\` line."$'\n'
      continue
    fi
    if [[ ! -f $doc ]]; then
      problems+="  $plan sources $doc, which does not exist."$'\n'
      continue
    fi
    status=$(grep -m1 'status:' "$doc")
    [[ $status == *"$slug"* ]] ||
      problems+="  $doc's status line does not name $plan."$'\n'
    if [[ $status == *"in flight"* && $slug != "$live" ]]; then
      problems+="  $doc says \"in flight\", but $plan is parked, not live."$'\n'
    elif [[ $status != *"in flight"* && $slug == "$live" ]]; then
      problems+="  $doc does not say \"in flight\", but $plan is the live plan."$'\n'
    fi
  done
  [[ -n $problems ]] || return
  echo "Plan/design linkage, checked at invocation. These are hand-maintained claims,"
  echo "so a disagreement means one end has drifted — fix it or ask before proceeding:"
  echo
  printf '%s' "$problems"
}

# `docs/` is the permanent layer and cites only itself; `design/` is working
# state that gets deleted, so a pointer from one into the other is a dangling
# reference waiting to happen. Scoped to the lines a commit adds — the tree
# carries pre-existing violations, and those are a migration rather than this
# commit's business.
emitDocsCitations() {
  local problems
  problems=$(git diff --no-color -U0 HEAD -- 'docs/*.md' | awk '
    /^\+\+\+ b\// { file = substr($0, 7); next }
    /^\+\+\+/     { file = "";            next }
    /^@@/         { if (match($0, /\+[0-9]+/)) line = substr($0, RSTART + 1, RLENGTH - 1); next }
    /^\+/         { if (file != "" && index($0, "design/"))
                      printf "  %s:%d  %s\n", file, line, substr($0, 2)
                    line++ }
  ')
  [[ -n $problems ]] || return
  echo "Documentation layering, checked at invocation. \`docs/\` cites only \`docs/\` — a"
  echo "pointer into \`design/\` means the substance is in the wrong file:"
  echo
  printf '%s' "$problems"
}

# Code and its documentation are one change, so a commit that moves the model and
# leaves `docs/` behind lands a half-change. Most of `docs/` is named for the
# module it documents, so the doc a change owes is found by name match, with no
# citation needed at the source end. The rest are cross-cutting, no match reaches
# them, and they are few enough to list in full and leave to judgement.
emitDocsOwed() {
  local changed luaStems owed crossCutting stem

  changed=$( { git diff --name-only HEAD
               git status --porcelain | awk '/^\?\?/ { print $2 }'
             } | sort -u )
  grep -q '\.lua$' <<<"$changed" || return

  owed=$(grep '\.lua$' <<<"$changed" | xargs -n1 basename | sed 's/\.lua$//' | sort -u |
         while IFS= read -r stem; do [[ -f docs/$stem.md ]] && echo "$stem"; done)

  luaStems=$(git ls-files '*.lua' | xargs -n1 basename | sed 's/\.lua$//' | sort -u)
  crossCutting=$(for doc in docs/*.md; do
                   stem=$(basename "$doc" .md)
                   grep -qx "$stem" <<<"$luaStems" || printf '%s ' "$stem"
                 done)

  echo "Docs owed, matched at invocation. Code and its documentation are one change, so"
  echo "the commit is not complete while a doc contradicts what you did:"
  echo
  if [[ -n $owed ]]; then
    echo "  Named for a module you changed —"
    # Headings are usually enough to tell whether the model moved, but a wide
    # refactor would blow the output ceiling with them, and wants the docs read
    # whole anyway.
    while IFS= read -r stem; do
      if grep -qx "docs/$stem.md" <<<"$changed"; then
        echo "    docs/$stem.md   (already changed in this commit)"
      elif [[ $(grep -c . <<<"$owed") -gt 6 ]]; then
        echo "    docs/$stem.md"
      else
        echo "    docs/$stem.md"
        grep -m12 '^##' "docs/$stem.md" | sed 's/^/        /'
      fi
    done <<<"$owed"
    echo
  fi
  echo "  No module behind them, so no match reaches them — read the names and judge:"
  echo "    $crossCutting"
}

emitTreeState() {
  echo "Working-tree state, gathered at invocation — it is current, so don't re-run these:"
  echo
  echo '$ git status --porcelain'
  git status --porcelain
  echo
  echo '$ git diff --stat HEAD   (staged and unstaged; untracked show above only)'
  git diff --stat HEAD
}

first=yes
for name in "$@"; do
  [[ $first == yes ]] || echo
  first=no
  case "$name" in
    live-plan)       emitLivePlan ;;
    brief)           emitBrief ;;
    brief-state)     emitBriefState ;;
    plan-shelf)      emitPlanShelf ;;
    plan-linkage)    emitPlanLinkage ;;
    docs-citations)  emitDocsCitations ;;
    docs-owed)       emitDocsOwed ;;
    tree-state)      emitTreeState ;;
    *) echo "gather.sh: no emitter named '$name' — the skill asked for context that"
       echo "does not exist, which is a typo worth reporting rather than working around." ;;
  esac
done

exit 0
