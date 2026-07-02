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

## Implementation

Phased; each phase lands green with its spec, commit between phases.
Decisions settled at planning (2026-07-02):

- **Backstop scope is notes-only.** cc `tokenIdx` overwrites keep
  current semantics — load-dedup covers them, and the verdicts are
  note-intent-specific.
- **No forced rebuild on `collisionsResolved`** — surgical um re-key
  only; a handler-triggered `tm:rebuild` would re-enter `mm:modify`
  mid-unwind. Column geometry trues up at the next natural rebuild,
  fine for a should-never-fire path.
- **Resolution runs before the unwind reindex**, not inside-after-sort
  as sketched above: per-group sorts are self-contained, and a nudge
  can break global order anyway, so the one reindex that follows
  covers compact + sort + re-key.

Phases:

- **Phase 1 — `voicing.lua` extraction (item 1). ✅ landed (2eae410).**
  Pure module alongside `timing`/`tuning`. The verdicts (`redundant`,
  `supersedes`) stayed private — every consumer goes through
  `voicing.resolveGroup(group)`, which sorts the group `(ppq, ppqL)`
  in place (callers can't skip the ordering the policy needs) and
  returns `kills, voiced, onsetOf`. `voicing.nudgeOnsets` is
  `nudgeSamePitchOnsets` moved verbatim (`{evt=...}` wrappers,
  fixed-aware). tm's flush pre-clip consumes `resolveGroup` and keeps
  only the tail-bound loop; reseat + tail walk consume `nudgeOnsets`.
  Existing pre-clip/separation specs pinned the extraction.
- **Phase 2 — mm write-path backstop (item 2).** Detect at note
  filing: `addNote` and `assignNote`'s re-key check `tokenIdx[tok]`
  for a different live occupant before overwriting; on hit record the
  `(chan, pitch)` key plus the verb (provenance). Resolve at the
  outermost unwind (midiManager.lua:694) before the existing
  `rebuild(nil)`: per pending key, gather live same-`(chan, pitch)`
  notes, re-check (mid-batch collisions can be transient), run
  `voicing.resolveGroup`; kills nil their slot + `deleteMetadatum`,
  nudges mutate ppq directly; set `dirty`/`indexStale`. Fire
  `collisionsResolved { events = [{ kind='killed'|'nudged', oldToken,
  token, uuid, chan, pitch, ppq }] }` after the reindex, before
  `flushTake`. tm handler re-keys um surgically (byToken re-key +
  `idxReconcile` for nudges, entry removal for kills). Perf-gated
  provenance print per resolution. **Spec:** a direct `mm:modify`
  collision (bypassing tm) resolves, fires the signal, and is
  idempotent on the next modify.
- **Phase 3 — intent-aware load-dedup (item 3).** Reorder `mm:load`:
  parse → note-sidecar uuid binding + metadata join → note dedup via
  `resolveGroup` → cc dedup → rest unchanged. Binding becomes
  collision-aware: bucket notes AND sidecars by `(ppq, chan, pitch)`
  and pair off in order (the single-slot `notesKeyed` lookup can't
  hold two). Pairing between colliding notes is
  arbitrary-but-deterministic — `(ppqL, detune)` metadata can swap
  between the two voices; accepted: that state only arises when
  something external moved two uuid'd notes into an illegal MIDI
  configuration, and that's on them. Kills keep firing `notesDeduped`;
  nudges fire `collisionsResolved`, slotted before `reload` in the
  load signal order. Foreign MIDI (both `ppqL` nil) degrades to
  today's collapse-to-longer via `redundant`. Verify killed-note
  metadata is dropped from eventMeta now that binding precedes dedup.
  **Spec (red-first):** two raw-colliding notes with distinct
  `(ppqL, detune)` sidecars load as two nudged voices; pin today's
  one-eaten behaviour as the red test first.
- **Phase 4 — serialise assertion (item 4).** `midiBlob.serialise`
  (:173-208) tracks last ppq per `(chan, pitch)` in the note walk;
  an equal onset reports loudly via `util.print` and writes anyway
  (warn-and-write). **Spec:** trips on a hand-built colliding model.
- **Phase 5 — docs (item 5).** Reclassify the three tm sites in
  docs/trackerManager.md § Same-pitch onset separation (load-bearing
  → optimization); backstop + signal prose in docs/midiManager.md;
  annotations per CONVENTIONS. Consider a docs/voicing.md home for
  the model — voicing.lua's header currently points at the tm doc
  section.

## Open questions

- **Does the descending-assign sort dissolve?** Mid-batch token
  aliasing is an *addressing* problem (a staged op resolving to the
  wrong note), distinct from legality; unwind resolution doesn't fix
  it. Keep the sort; revisit only if `tokenIdx` ever buckets during a
  batch.

The rest settled at planning (2026-07-02): the backstop separates
onsets only — tail bounds stay tm's, re-derived by the next tail walk;
a nudged `fixed` external is acceptable on a should-never-fire path
(the tag stays tm-transient); assertion policy is warn-and-write; the
load-path reorder audit folded into Phase 3 — collision-aware binding
is the only pre-join dependency found, with killed-uuid metadata
cleanup flagged for verification.
