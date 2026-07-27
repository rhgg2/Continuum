# memory-as-claims — plan

> source: `design/memory-as-claims.md` — synthesis compiled from there;
> don't design here.

## Landed  (newest first; prune below ~4)

- 2026-07-27 config: fold the store to ten claims, MEMORY.md as the claim index
- 2026-07-27 config: retire misfiled memory to docs and CLAUDE.md (D6)
- **2026-07-27 · `48c1abf`** — the move completed: `autoMemoryDirectory` in
- **2026-07-27 · `3a0dd7e`** — 29 `.md` files committed as found under

## Now

(empty — the fold is complete; run /plan-next to promote the `wonder` ledger)

## Queued (current phase; one-liners)

1. Fold the `wonder` ledger in as `open` claims — settling as part of the work
   whether Continuum-subject curiosities move into the repo store while
   genuinely global ones stay at `~/.claude/wonder/`.
2. Give the store a decay rule (D10): a `us` shape that has stopped firing falls
   back toward `open` rather than sitting at `load-bearing` — measured by counts
   and dates, never by re-extracting text. `us_reconstruction_vs_retrieval.md`
   already states its own decay in prose; this generalises it to the store's
   documented conventions.
