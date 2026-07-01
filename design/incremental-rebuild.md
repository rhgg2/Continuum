# incremental rebuild — programme overview & sequencing

> Master doc. The slices live in their own working docs
> (`deferred-reindex.md`, `same-pitch-enforcement.md`,
> `incremental-pbs.md`, `dirty-channels.md`); this one carries the
> shared model, the cross-slice dependencies, and the order of work.

## Goal & baseline

One edit on a large take (3070 notes, 6219 ccs, 9212 texts) costs
~100ms at flush. The money is in four buckets:

| bucket | ~ms | attacked by |
|---|---|---|
| mm whole-model reindexes (2–3 per flush) | 21–32 | `deferred-reindex` |
| pbs derivation (absorber reconciliation) | 16 | `incremental-pbs` |
| walk stages (internals, ccs, projLogical, tails, fx, park) | ~33 | `dirty-channels` phase A/B |
| write side (serialise, meta, sidecars, setEvts) | ~27 | out of scope (future: per-event serialise memoisation) |

Bind-time cost — a full derivation pass over an unchanged take — is a
fifth target (`dirty-channels` take-hash gate). `same-pitch-enforcement`
buys no time; it is the correctness net the others run under.

## Shared model

**Two axes of dirt.** Rebuild does two jobs and they invalidate
independently. *Materialisation* (columns, um index) is keyed by
object identity — mm's `wholesale` bit. *Derivation* (reconcile,
synthesise, write back) is keyed by content: a per-channel dirty set,
fed by edit verbs and config, zeroed by a take-hash match. The old
three "levels" of rebuild are just cardinalities of that set.

**I8 is the soundness oracle.** Rebuild converges in one pass (flush →
rebuild → flush is a fixpoint), so "no dirty source fired" ⟹
re-deriving stages nothing ⟹ skipping is pure savings. Every gate in
the programme leans on this argument.

**Channel granularity is closure-free.** Every blast-radius rule
(tail clip/regrow, same-pitch nudges, absorbers, PC streams, fx
windows) is intra-channel, so a whole dirty channel over-approximates
the closure without fixpoint computation. Verified stage-by-stage in
`dirty-channels.md`.

**Shadow-compare is the migration pattern.** Each gated slice runs the
full path in shadow and asserts zero staged writes + identical output
for skipped work — the pattern that carried the um-index migration.
Scaffolding strips once parity holds; one rich-fixture gated-vs-full
spec stays permanently.

**The residual risk is a missed dirty source**, and its failure mode is
silent take corruption (an unseparated same-pitch collision). Hence
the net: mm enforces its own collision invariant at the modify unwind,
turning the worst case into a logged, self-repairing event.

## Sequencing

1. **`deferred-reindex`.** First: independent of everything, the order
   audit is already done (2026-07-02), biggest standalone number, and
   its unwind is where the same-pitch backstop naturally lives.
   Includes the hole-tolerant iterators and tm order self-sufficiency.
2. **`same-pitch-enforcement`.** Before any gating lands: converts the
   programme's riskiest failure into a visible self-repair. Its
   backstop slots into (1)'s unwind reindex; the provenance log then
   audits every later slice for free.
3. **`incremental-pbs` stage 1** (+ its orthogonal `streamValue` merge
   win). The first gated slice: proves the clean-path argument, the
   dirty-source table, and the shadow harness on the biggest stage.
4. **`dirty-channels` spine + phase A.** Generalise (3)'s seed into
   mm's `reload` payload; gate ccs/tails/fx/park/pcs derivation;
   apply the ds-key merge discipline at all four persist sites.
5. **Take-hash gate.** Cheap once the spine exists — a hash-matched
   rebind is just "wholesale, empty dirty set", a path (4) already
   built. Stash `(hash, configGen)` at flush; compare in `mm:load`
   before parse.
6. **Re-profile, then choose:**
   - `incremental-pbs` stage 2 (seat windows) — only if dense-pb
     channels still hurt;
   - `dirty-channels` phase B (`channels[]` retention) — removes the
     materialisation floor; tv contract change; only after phase A's
     shadow has been quiet in real use;
   - write-side memoisation — a new programme; by this point it
     dominates the flush.

Gates between steps: a slice's shadow scaffolding strips only after
parity on the rich fixture; phase B does not start until phase A's
shadow is silent in daily use; pbs stage 2 needs the sub-timer
evidence called for in its doc.

## Expected trajectory

Steady-state single-channel edit, cumulative:

| after | ~ms/flush |
|---|---|
| baseline | 100 |
| deferred-reindex | ~85 |
| + incremental-pbs stage 1 | ~60 (clean flushes skip the unwind reindex too) |
| + phase A walk gating | ~50 |
| + phase B retention | ~30 — write-side floor |

Rebind of a converged take: roughly halved by the hash gate (parse +
projection remain). Numbers are directional; re-profile after each
slice against the same fixture take.
