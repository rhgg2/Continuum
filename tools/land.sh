#!/bin/sh
# Land this worktree's branch on the main tree's, leaving no merge commit.
#
# Two refs have to move for that: this branch up onto the main tree's, then that
# one up onto this branch. A single operation moves a single ref, and the two
# branches are checked out in different worktrees, so by hand it is two magit
# buffers and a context switch. Neither move calls for a decision, so neither is
# worth making twice.
set -e

fail() { printf 'land: %s\n' "$1" >&2; exit 1; }

# A `!` git alias runs with GIT_DIR exported, and -C sets only the working
# directory. Every `git -C <the other tree>` below would otherwise keep using the
# invoking worktree's git dir while reading the other tree's files, and report
# the difference between the two as uncommitted changes. Discovery from the
# working directory is what this script wants at every step.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_PREFIX

main_tree=$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")
here=$(git rev-parse --show-toplevel)
branch=$(git rev-parse --abbrev-ref HEAD)
target=$(git -C "$main_tree" rev-parse --abbrev-ref HEAD)

if [ "$here" = "$main_tree" ]; then fail "run this from a worktree, not the main tree"; fi
if [ "$branch" = HEAD ]; then fail "detached HEAD here, so there is no branch to land"; fi
if [ "$target" = HEAD ]; then fail "$main_tree is on a detached HEAD, so there is nothing to land onto"; fi

# The rebase rewrites this tree and the fast-forward moves files under the main
# one. Uncommitted work in either would be caught in the middle of that, and in
# the main tree's case somewhere nobody is looking.
#
# Tracked changes only. An untracked file is no hazard to either move, and both
# trees collect them -- a machine-local settings file, a scratch note -- so
# counting them would block every landing for a reason that never applies.
dirty() { [ -n "$(git -C "$1" status --porcelain --untracked-files=no)" ]; }
if dirty "$here"; then fail "$here has uncommitted changes"; fi
if dirty "$main_tree"; then fail "$main_tree has uncommitted changes"; fi

if [ "$(git rev-list --count "$target".."$branch")" = 0 ]; then
  fail "$branch holds nothing $target lacks"
fi

# Rebase first, because a rebase that stops leaves the main tree untouched: the
# repo is then in one recoverable state instead of half-landed. Resolve it,
# finish the rebase by hand, and run this again.
if ! git rebase "$target"; then
  fail "rebase stopped; resolve it, 'git rebase --continue', then run this again"
fi

git -C "$main_tree" merge --ff-only "$branch"
printf 'land: %s is now at %s\n' "$target" "$(git rev-parse --short "$branch")"
