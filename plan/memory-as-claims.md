# memory-as-claims — plan

> source: `design/memory-as-claims.md` — synthesis compiled from there;
> don't design here.

## Landed  (newest first; prune below ~4)

(nothing yet)

## Now

(empty — new plan; run /plan-next to promote the first Queued item.)

## Queued (current phase; one-liners)

1. Move the store into the repo — `.claude/agent-memory/` tracked,
   `autoMemoryDirectory` (absolute) in `.claude/settings.local.json`, a
   SessionStart guard asserting `MEMORY.md` resolves — and commit the 24 files
   **unchanged**, so everything after this lands as a diff against originals.
2. Write the world and our-construction claims — duplicate state, vantage isn't
   neutral, absent boundaries (EEL2-scoped), single ownership — folding in the
   files each subsumes, specifics inline, and citing rather than absorbing the
   two-law files.
3. Write the `us` claims: the parent plus its five shapes, provenance by session
   id and date only, no quotation.
4. Rewrite `MEMORY.md` as the claim index — claims grouped by subject, inside
   the 200-line / 25KB load cap.
5. Retire the misfiled ones: `config_schema` and `commandManager_limits` to
   their `docs/` homes, `commit_scope_config` to CLAUDE.md as the convention it
   is; re-frontmatter what remains with `subject` + `standing`.
6. Fold the `wonder` ledger in as `open` claims — settling as part of the work
   whether Continuum-subject curiosities move into the repo store while
   genuinely global ones stay at `~/.claude/wonder/`.
7. Give `us` claims a decay rule (D10): a shape that has stopped firing falls
   back toward `open` rather than sitting at `load-bearing` — measured by counts
   and dates, never by re-extracting text.
