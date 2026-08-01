# map navigation — plan

> source: `design/map-navigation.md` — synthesis compiled from there;
> don't design here.

## Phases

1. **Phase 1 — the regeneration gate** (§ Mechanism: park the rewrite)
   — regenerate every map the extractor emits (the 66 modules, the spec
   and harness maps alongside them) and diff against the committed ones
   in one command; `map_extract.py` is one-file-per-call today. Every
   later phase lands behind it, byte-identical first.  ← in flight
2. **Phase 2 — intra-file call edges** (§ Intra-file call edges) — one
   `(caller, callee, line)` list per file, from the `self:` edges
   currently extracted and discarded plus a new bare-`foo(...)` pass
   over masked code; rendered twice, forward on the `@fn` row and
   reverse as a `# Calls (intra-file)` index.
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

- **`c346a69` — `sha=` out of the `.map` header.** It made byte-identity
  unreachable: 125 of 317 maps disagreed with a fresh regen on that field
  alone, by construction and forever. 318 maps regenerated, header lines
  only. Full regen 12s → 1.7s. See design § Mechanism for the reasoning
  and for the content-hash trap.

## Now

Phase 1's remaining two commits, bundled into one brief by agreement.
The corpus is now byte-identical to a fresh regen, so the gate below has
something to assert.

**Commit A — `tools/map_regen.py`, the gate. ✓ done, awaiting commit.**
`SOURCE_SETS` is now the single definition of the corpus, and `map_regen`
drives `map_extract` in-process over it — `--check` (default) diffs a
fresh regen against disk, `--write` rewrites what changed. `map_extract`'s
own CLI is untouched. A clean tree reports `318 sources, 318 maps on disk
-- all current`, exit 0, 1.6s. The three orphans (`map/intervals.map`,
`map/specs/intervals_spec.map`, `map/glasswork_dense.map`) are deleted.

All four perturbations moved the verdict and named the right map: content
edit → `differs`, deleted map → `missing`, sourceless `.map` → `orphan`,
clean tree → zero and exit 0 (re-confirmed after restoring). `--write` was
exercised the same way: no-op on a clean tree, repairs a damaged map to
byte-identity, reports an orphan without deleting it.

Two things the brief left open, settled in the code:

- **`--write` exits 0 on orphans**, non-zero only on a render error;
  `--check` still fails on them. A hook regenerating one edited file
  shouldn't fail because of a stale map nobody touched.
- **`--write` skips maps whose content is unchanged**, so mtimes stay put.
  This half-consumes commit B's stated reason for `--stale-only` — see
  there.

Also in the code, unasked-for and a line each: a render failure is caught
per file, so one unmappable source can't blind the gate to the other 317;
and two sources claiming one `.map` (possible, since `map/` is flat over
both the root and `tests/`) aborts rather than silently letting one
overwrite the other. No collision exists today.

**Commit B — one definition of the source set.** That mapping is
currently written three times, and the third is wrong:
`.claude/settings.json:61` (inline bash, PostToolUse),
`.claude/hooks/patches-map-regen.sh:21-42` (mtime loop), and
`docs/CONVENTIONS.md:146`, which tells the reader to regenerate with `for
f in *.lua; do …; done` — top-level only, silently missing every spec and
harness map. Point both hooks at `map_regen.py`; replace the CONVENTIONS
recipe with the real command.

- The hooks are incremental (mtime-driven) and the gate is not, so this
  wants `--write --stale-only` or equivalent, not a blanket rewrite: the
  post-edit hook must stay fast and must not rewrite 318 files per edit.
  **Half of that is now already true**: `--write` writes only what changed,
  so a blanket run touches no mtime it needn't. What survives is the time —
  1.6s of parsing per edit against ~5ms for the one file that changed — so
  `--stale-only` is a speed argument alone now, and the open question is
  whether 1.6s in a PostToolUse hook is worth the machinery to avoid.
- `patches-map-regen.sh:17-19` warns that concurrent `map_extract` runs
  race. One in-process batch removes the race by construction — say so
  there rather than deleting the warning silently.
- A broken hook fails **silently**: both call sites swallow stderr with
  `2>/dev/null`. Verify by editing a real `.lua` and confirming its map
  regenerates, not by reading the script.

Done when `--check` exits 0 on a clean tree, all four perturbations move
it, and a live edit still regenerates its map through the hook.

## Queued (current phase; one-liners)

(empty — the Now brief covers what remains of phase 1.)
