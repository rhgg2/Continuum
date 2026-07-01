# same-pitch enforcement — mm owns its collision invariant

> Working design doc. Companion to `incremental-pbs.md` and
> `deferred-reindex.md`: same programme (`incremental-rebuild.md`),
> correctness slice. The
> same-pitch invariant is mm's, but its enforcement is tm's, smeared
> across three call sites. Move enforcement to where the invariant
> lives, so the incremental slices can miss a dirty source without
> corrupting the take.

## Problem

mm forbids two notes sharing `(ppq, chan, pitch)`: `tokenIdx` keys on
exactly those fields (midiManager.lua:897-899), and load-dedup kills
collisions on read (:427). But on the write path the invariant is
upheld *by convention*: every tm path that could stage a colliding raw
must remember to separate first. Three sites carry that obligation
(docs/trackerManager.md § Same-pitch onset separation):

- **internals reseat** (trackerManager.lua:1197) — reswing collapse;
- **flush pre-clip scan** (:657-726) — edit lands on a peer;
- **tail walk** (:1973) — real notes + predicted fxNotes.

A miss is *silent*: `tokenIdx[newTok] = note` overwrites the peer's
entry (add :771, assign re-key :745-748, cc :840-843), one voice
becomes unaddressable, and the next load-dedup eats it. The
descending-target-ppq sort at flush (:732-736) exists to sequence
around the same aliasing mid-batch.

This is tolerable while the write paths are few and wholesale. The
incremental-rebuild programme breaks that assumption: `incremental-pbs`
stage 2 and the walk-stage slices (`dirty-channels.md`) multiply gated
paths, and the
failure mode of a missed dirty source is precisely "a collision nobody
separated". Enforcement must stop being a caller obligation.

## Direction decided against: dedup in midiBlob

The kill-vs-nudge decision needs intent — `ppqL`, `detune`, `derived`
— which exists only after sidecar binding. At blob level only
exact-byte dedup is possible, which mm already does better with
context. And a serialise-time dedup is actively dangerous: every layer
upstream believes the pre-dedup state, so the codec editorializing
means model ↔ take divergence. midiBlob stays a pure bijection. It
gets one thing: an **assertion** (item 4).

## Scheme

1. **Shared verdict module.** The policy exists twice today with
   different fidelity: the pre-clip scan's `redundant`/`supersedes`
   (:671-679; derived loses, same `(ppqL, detune)` collapses to longer,
   distinct voices nudge) and load-dedup's blind longest-`endppq`
   (:437). Hoist the verdicts plus the sorted-group separation walk
   into a pure module (`voicing.lua`, alongside `timing`/`tuning`);
   `nudgeSamePitchOnsets` (trackerManager.lua:1137) becomes its
   geometry half. mm and tm both consume it — three real occurrences,
   one policy.

2. **mm write-path backstop.** Detection is free: filing `tokenIdx`
   already *is* the collision check — an occupied slot at add/re-key
   time is the illegality manifesting. Record collisions as they file;
   **resolve at the outermost `modify` unwind**, on the settled model,
   via the shared verdicts (kill duplicates, nudge distinct voices,
   set `dirty` so `flushTake` writes the resolved state). Unwind, not
   verb-time: mid-batch collisions can be transient (the vacate/occupy
   sequences the descending sort orders around), and resolving early
   would nudge a note a later verb was about to move. Fires
   `collisionsResolved { events }` before `reload` (mirrors
   `notesDeduped`, :637) so um can `idxReconcile` the re-keyed tokens;
   the rebuild that follows every dirty modify picks up the geometry.

   In steady state the backstop finds **nothing** — the tm sites
   already separated. Its cost is the occupancy checks (O(1) per verb)
   plus an empty pending list at unwind.

3. **Intent-aware load-dedup.** Load currently dedups (:427) *before*
   the metadata join (inside `rebuild(metadata)`, :627), so it cannot
   see `ppqL`/`detune` and must kill blindly — the reason the reseat
   site pre-separates ("so mm's reload-dedup never eats a voice",
   :1190). Move the sidecar join ahead of dedup, then route dedup
   through the shared verdicts: an external edit (Ctrl-Z, foreign
   script) that collapses two distinct voices onto one raw now nudges
   them apart instead of destroying one. Needs an order audit of the
   load path's dedup/unify/reconcile sequence, deferred-reindex-style.

4. **midiBlob serialise assertion.** During the serialise walk, track
   last ppq per `(chan, pitch)`; an equal onset is an upstream bug —
   report loudly. Defence in depth only; no dedup, no nudge, no policy.

5. **tm sites stay, reclassified.** All three separation sites remain:
   they keep tm's live clones (column events, um entries) coherent with
   what mm will hold, and the pre-clip scan's kill/update routing
   through um verbs (:720-725) carries semantics mm shouldn't own (PA
   culling, detune-aware resize). Their status changes from
   load-bearing to optimization: a missed collision is now caught and
   resolved by mm, visibly, instead of corrupting the take silently.

## Relation to the siblings

- **deferred-reindex**: the backstop's resolution wants compact+sorted
  arrays; run it inside the unwind slim reindex, after compact+sort,
  before `flushMetadata`/`flushTake`. Not a hard dependency — without
  deferral it runs at each dirty `rebuild(nil)` — but the unwind is its
  natural home and makes resolution once-per-flush.
- **incremental-pbs** (and every later gated slice): this is the safety
  net those migrations run under. Shadow-compare detects a wrong
  *derivation*; the backstop detects and repairs a missed *separation*.
  Land this before the walk-stage slices.

## Validation

- **Spec: backstop resolves.** An `mm:modify` staging a raw collision
  directly (bypassing tm) leaves the model separated per the verdicts,
  fires `collisionsResolved`, and is idempotent on the next modify.
- **Spec: load preserves voices.** A take whose sidecars carry distinct
  `(ppqL, detune)` for two raw-colliding notes loads with both voices,
  nudged — the pre-change behaviour (one eaten) pinned as the red test.
- **Spec: serialise assertion** trips on a hand-built colliding model.
- **Provenance logging (dev, perf-gated).** Every backstop action logs
  the colliding tokens and the staged-op provenance. On today's paths
  it should never fire; during the incremental migration each firing
  is a found bug in a dirty-source table.
- Existing pre-clip and separation specs pass unchanged.

## Expected effect

Not a perf slice — steady-state cost is near zero. The win is the
correctness surface: the invariant is enforced at the layer that owns
it, every current and future write path inherits the guarantee, and
external collapse stops eating voices. The incremental programme's
riskiest failure mode (silent take corruption from a missed dirty
source) becomes a logged, self-repairing event.

## Open questions

- **Does the descending-assign sort dissolve?** Mid-batch token
  aliasing is an *addressing* problem (a staged op resolving to the
  wrong note), distinct from legality; unwind resolution doesn't fix
  it. Keep the sort; revisit only if `tokenIdx` ever buckets during a
  batch.
- **Backstop tail clipping.** The pre-clip scan also bounds `endppq` to
  the next onset (:712). Should the backstop clip survivors' tails in
  the same pass, or leave overlaps to the next rebuild's tail walk?
  Leaning minimal: onsets only.
- **`fixed` externals.** The frozen-onset tag is a tm-transient on the
  column clone; mm never sees it. The backstop would nudge by sort
  order, possibly moving an external tm would have frozen. Acceptable
  for a should-never-fire path, or worth persisting the tag?
- **Assertion failure policy.** Warn-and-write (model state is no worse
  than what produced it) vs refuse-and-keep-old-blob (take diverges
  from model until the next clean flush). Leaning warn-and-write.
- **Load-path join reorder** (item 3): does anything in
  dedup → unify → uuid-reassign rely on running pre-join? Audit before
  moving.
