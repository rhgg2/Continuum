# memory-as-claims — plan

> source: `design/memory-as-claims.md` — synthesis compiled from there;
> don't design here.

## Landed  (newest first; prune below ~4)

(nothing yet)

## Now

**Move the auto-memory store into the repo, content unchanged.** D9: the store
becomes `.claude/agent-memory/`, tracked, with `autoMemoryDirectory` pointing at
it from git-ignored local settings. Every file is committed **as found, before
any fold**, so the whole compression that follows lands as a diff against its own
originals — git replaces the archive step outright. Nothing about the claims
changes here.

*Not red-spec-first: no Lua, no production behaviour. The evidence is the guard
and the next session's injected context.*

### What is being moved

Source `~/.claude/projects/-Users-rgarner-Documents-Code-Continuum/memory/`,
**29 `.md` files** — `MEMORY.md` plus 28 topic files. Skip `.DS_Store` (already
gitignored). D9 says "the 24 files"; since it was written the five claim files of
Queued item 2 (`world_duplicate_state`, `world_vantage_not_neutral`,
`world_jsfx_absent_boundaries`, `build_single_ownership`,
`us_reconstruction_vs_retrieval`) have been drafted into the live store and
`MEMORY.md` re-headed with a load-bearing section. The 23 pre-existing topic
files are untouched, so D9's diff-against-originals property holds where it
matters; only `MEMORY.md`'s pre-claims form is unrecoverable, and item 4 rewrites
it wholesale regardless. Commit all 29 as found.

### Order (the commit comes before the config)

1. Copy the 29 `.md` files to `.claude/agent-memory/`; `diff` the two
   directories (excluding `.DS_Store`) and require empty output before going on.
2. Commit — `config: move agent memory into the repo`. This is the baseline the
   fold diffs against, so it lands before any setting changes.
3. Add top-level `"autoMemoryDirectory":
   "/Users/rgarner/Documents/Code/Continuum/.claude/agent-memory"` to
   `.claude/settings.local.json`. Confirmed absolute paths and `~/` are accepted
   and that project-local settings honour the key. That file is ignored by
   `~/.config/git/ignore:1` (`**/.claude/settings.local.json`), so the
   machine-specific path never reaches a commit — re-check with `git
   check-ignore -v` after editing.
4. Repoint `.claude/system-prompt.md:41-42` at the new location. Leave the
   frontmatter block below it alone — the `type:` taxonomy is item 5's job.
5. Add the guard to `.claude/hooks/session-env.sh`.
6. Rename the old store to `memory.moved-2026-07-27` rather than deleting it:
   reversible, and it makes a silent fallback visibly empty instead of quietly
   working. Delete once a later session has confirmed the new path is live.

### The guard

D9 asks for it because a misresolved path fails silently. It goes in the
existing `SessionStart` hook (`.claude/hooks/session-env.sh:1-13`, whole file —
`#!/bin/sh`, reads the payload's `session_id`/`cwd`, emits one
`additionalContext` string via `jq -n`). The memory slug is the same `cwd | tr
'/' '-'` the scratchpad path already computes, so hoist it into `slug` and reuse
it. Two checks, both appending a loud line to the context string:

- `autoMemoryDirectory` unset in `${CLAUDE_PROJECT_DIR:-$cwd}/.claude/settings.local.json`,
  or `$dir/MEMORY.md` unreadable → the store is not resolving.
- `$HOME/.claude/projects/$slug/memory/` exists again → the override is *not*
  applying and Claude Code has recreated the untracked default; writes are going
  there. This is the precise silent failure, and the rename in step 6 is what
  makes it detectable.

`bash -n` the hook before trusting it (bash 3.2 on this machine parses some
constructs surprisingly).

### Known unknown

The docs do not say whether `autoMemoryDirectory` is used **directly** as the
memory directory or has a project-slug subdirectory appended beneath it. If the
next session's guard fires with an empty new store, that is the first suspect —
relayout as `.claude/agent-memory/<slug>/memory/`. Second suspect: project-local
settings are honoured only after the workspace-trust dialog, which this
long-used workspace should already have passed.

### Done looks like

- `git show --stat HEAD` lists 29 added files under `.claude/agent-memory/`, and
  the pre-commit `diff` against the source directory was empty.
- `.claude/settings.local.json` still reports as ignored via `git check-ignore -v`.
- `bash -n .claude/hooks/session-env.sh` clean; run by hand with a synthetic
  payload it emits the scratchpad line and no warning.
- Old store renamed, not deleted.
- Next session's injected context carries the `MEMORY.md` index and the guard is
  silent. Test suite is not involved.

## Queued (current phase; one-liners)

1. Write the world and our-construction claims — duplicate state, vantage isn't
   neutral, absent boundaries (EEL2-scoped), single ownership — folding in the
   files each subsumes, specifics inline, and citing rather than absorbing the
   two-law files.
2. Write the `us` claims: the parent plus its five shapes, provenance by session
   id and date only, no quotation.
3. Rewrite `MEMORY.md` as the claim index — claims grouped by subject, inside
   the 200-line / 25KB load cap.
4. Retire the misfiled ones: `config_schema` and `commandManager_limits` to
   their `docs/` homes, `commit_scope_config` to CLAUDE.md as the convention it
   is — joined there by the headline-only commit rule (no body, no
   `Co-Authored-By`, no tagline), which today lives only at
   `.claude/commands/commit.md:33`, where a hand-commit never reads it and the
   global system prompt says the opposite; re-frontmatter what remains with
   `subject` + `standing`.
5. Fold the `wonder` ledger in as `open` claims — settling as part of the work
   whether Continuum-subject curiosities move into the repo store while
   genuinely global ones stay at `~/.claude/wonder/`.
6. Give `us` claims a decay rule (D10): a shape that has stopped firing falls
   back toward `open` rather than sitting at `load-bearing` — measured by counts
   and dates, never by re-extracting text.
