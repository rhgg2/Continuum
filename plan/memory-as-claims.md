# memory-as-claims — plan

> source: `design/memory-as-claims.md` — synthesis compiled from there;
> don't design here.

## Landed  (newest first; prune below ~4)

- 2026-07-27 config: retire misfiled memory to docs and CLAUDE.md (D6)
- **2026-07-27 · `48c1abf`** — the move completed: `autoMemoryDirectory` in
- **2026-07-27 · `3a0dd7e`** — 29 `.md` files committed as found under

## Now

(empty — the four misfiled files are retired; run /plan-next to promote the fold and index rewrite)

## Prefix capture

Prefix-argument entry is digit-only and gated. The dispatcher feeds
`'0'..'9'` and `'/'` into `appendPrefix` only while `isPrefixActive()`
is true, and the sole `beginPrefix` binding is Super+U (continuum.lua).
Bare digit keys therefore stay free for ordinary commands in any scope;
they collide with prefix entry only just after Super-U. There is no
letter-chord support — vim-style two-key entry (`gr`, `gg`) would need
new machinery.
```

**3. `feedback_commit_scope_config.md` → new `## Commits` section in CLAUDE.md**,
between the end of `## How to work - tests` (`:151`) and `## Coding style`
(`:152`). It carries two conventions. The second currently lives only at
`.claude/commands/commit.md:33`, inside the subagent prompt — so a hand-commit
never reads it, and the global system prompt says the opposite (it asks for a
`Co-Authored-By` trailer and a tagline). That contradiction is why it is worth
writing down where both of us will see it.

```markdown
## Commits

- **Headline only.** `git commit -m "<headline>"` and nothing else: no
  body, no `Co-Authored-By`, no generated-with tagline. This overrides
  the global default, which asks for the trailer.
- **`config:` is the scope for Claude Code's own machinery** — skills,
  hooks, settings, agents, and tools whose only consumer is a skill
  (e.g. `tools/comment_hygiene.py`). They belong to no product
  subsystem, so a subsystem scope misreads. When a change also touches
  product code, scope by the product and mention the config knock-on.
```

**4. `feedback_command_table_tidy.md` → one bullet in `## Coding style`**, after
the `local fn do ... end` line (`:165`):

```markdown
- Registry tables stay one line per entry. The `registerAll{...}`
  command table is a scannable verb → `{fn, undoDesc}` map, so extract a
  multi-line body to a named `local function` rather than inlining a
  closure that breaks the alignment.
```

Then delete all four from `.claude/agent-memory/` and their four index lines
from `MEMORY.md` (`:13` config schema, `:21` cmgr limits, `:22` command table,
`:23` commit scope). Touch nothing else in `MEMORY.md` — the claim index is the
next item's job.

Commit: `config: retire misfiled memory to docs and CLAUDE.md`.

### Done looks like

- Four files gone from `.claude/agent-memory/`; 25 remain. Four lines gone from
  `MEMORY.md`, its structure otherwise untouched.
- `docs/commandManager.md` has a `## Prefix capture` section;
  `docs/configManager.md` is **unchanged** — if this item edited it, the delta
  check above was wrong and wants redoing.
- CLAUDE.md has a `## Commits` section and one new Coding style bullet.
- Nothing that lived only in the store now lives nowhere: prefix capture was the
  single such case, and it moved.
- Test suite is not involved.

## Queued (current phase; one-liners)

1. Complete the fold and rewrite `MEMORY.md` as the claim index — delete the 16
   files the five claims subsume, drop the now-dangling `Instances:` lines, keep
   the four genuine singletons (`no_legacy_data`, `pcm_getpeaks_layout`,
   `reaimgui_two_input_streams`, `hook_context_injection`) and re-frontmatter
   them with `subject` + `standing`, and bring `.claude/system-prompt.md`'s
   `type:` taxonomy block into line. Index grouped by subject, inside the
   200-line / 25KB load cap.
2. Fold the `wonder` ledger in as `open` claims — settling as part of the work
   whether Continuum-subject curiosities move into the repo store while
   genuinely global ones stay at `~/.claude/wonder/`.
3. Give the store a decay rule (D10): a `us` shape that has stopped firing falls
   back toward `open` rather than sitting at `load-bearing` — measured by counts
   and dates, never by re-extracting text. `us_reconstruction_vs_retrieval.md`
   already states its own decay in prose; this generalises it to the store's
   documented conventions.
