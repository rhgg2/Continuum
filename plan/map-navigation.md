# map navigation — plan

> source: `design/map-navigation.md` — synthesis compiled from there;
> don't design here.

## Phases

1. **Phase 1 — the regeneration gate** (§ Mechanism: park the rewrite)
   — regenerate every map the extractor emits (the 66 modules, the spec
   and harness maps alongside them) and diff against the committed ones
   in one command; `map_extract.py` is one-file-per-call today. Every
   later phase lands behind it, byte-identical first.  ✓ done
2. **Phase 2 — intra-file call edges** (§ Intra-file call edges) — one
   `(caller, callee, line)` list per file, from the `self:` edges
   currently extracted and discarded plus a new bare-`foo(...)` pass
   over masked code; rendered twice, forward on the `@fn` row and
   reverse as a `# Calls (intra-file)` index.  ← in flight
3. **Phase 3 — the luac oracle** (§ Mechanism: park the rewrite) — diff
   phase 2's edges against `luac -p -l -l` across all 66 modules; the
   disagreement rate is what decides whether the cheap pass gets
   upgraded, and it answers the shadowing open question.
4. **Phase 4 — negative results that say why** (§ Vocabulary —
   unsettled) — an empty `map_query` distinguishes *no such thing* from
   *bad regex* from *not indexed*, and names the nearest miss; 380 empty
   results in the corpus were re-asked by hand.
5. **Phase 5 — vocabulary** (§ Vocabulary — unsettled) — synonyms,
   fuzziness or near-misses. Unsettled by design: the phase opens with a
   look, and its answer reopens `design/map-navigation.md` before
   anything is built.

## Landed  (newest first; prune below ~4)

- **one definition of the source set** (design § Mechanism). Both PostToolUse map
  hooks collapsed into a single entry over `.claude/hooks/map-regen.sh`
  (renamed from `patches-map-regen.sh`, which no longer described it),
  running `map_regen.py --write --stale-only` — 0.04s against 1.56s blanket,
  the measurement that settled the flag. The 400-character inline `jq`/`bash`
  dispatch in `settings.json` and the top-level-only `for f in *.lua` recipe
  in `docs/CONVENTIONS.md` are gone, and neither call site swallows stderr
  any more. `--check --stale-only` is refused rather than supported: it would
  pass without reading what it was asked about.
- **`1b569a2` — `tools/map_regen.py`, the regeneration gate.** `SOURCE_SETS`
  is the single definition of the corpus, and `map_regen` drives
  `map_extract` in-process over it: `--check` diffs a fresh regen against
  disk, `--write` rewrites only what changed. Three orphan maps deleted.
- **`c346a69` — `sha=` out of the `.map` header.** It made byte-identity
  unreachable: 125 of 317 maps disagreed with a fresh regen on that field
  alone, by construction and forever. 318 maps regenerated, header lines
  only. Full regen 12s → 1.7s. See design § Mechanism for the reasoning
  and for the content-hash trap.

## Now

(empty — phase 1 is complete. The gate exists, the corpus is byte-identical
to a fresh regen, and one definition of the source set now drives the hooks,
the gate and the documented recipe alike.)

Phase 2, intra-file call edges, is next and has not been split: `/plan-phase`
for commit-sized items, then `/plan-next`.

## Queued (current phase; one-liners)

(empty — phase 2 has not been split yet.)
