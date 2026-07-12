# projext undo — project scope rides REAPER undo

> Split from design/fx-freeze.md after the 2026-07-12 round: F2's
> "one undo reverts wholly" cannot hold while per-event metadata
> lives in storage undo does not rewind. The bug class predates
> freeze — undo across any derived-note edit already loses
> eventMeta entries.

## Status at a glance

**Open**
- [ ] the mirror: undoable project slots mirrored to scratch under a
      two-level hash manifest; resync cost ∝ divergence
- [ ] rewound signal → mm metadata reload + full-dirty rebuild
- [ ] per-key undoable policy (§ Policy) + util.atomic audit of the
      pure-project edit sites (§ Implications)

**Pinned (later, not gating)**
- [ ] migrate rm's private fxMeta/busMeta mirror onto this and
      delete rm:pollUndo/resyncMeta
- [ ] docs: eventMeta.md claims "the engine's projext and undo
      machinery carry it" — wrong today; rewrite when this lands

## The problem

REAPER undo rewinds take/track P_EXT and MIDI, but projext does not
reverse natively (docs/scratch.md). pextStore's watcher therefore
watches take/track scope only (dataStore.lua:117). Everything at
project scope silently survives undo:

- **eventMeta** — ALL per-event metadata (detune, lane, ppqL,
  `derived`, delay, sample), pool-guid-keyed. Undo across an edit
  that cleared or deleted metadata leaves the take MIDI restored but
  the tags gone. Freeze's failure mode: region + stash rewind over
  untagged output notes → the next rebuild re-emits a fresh derived
  set and parks the originals as bogus authored members.
- **ds project keys** and **cm's project tier** — never rewind.
  Which of them should is a per-key question, not a per-scope one —
  see § Policy.

rm solved this privately for its two fx-meta blobs: write-through
mirror onto the scratch track's chunk (track P_EXT rides undo
natively), per-frame raw compare, copy-back on divergence
(routingManager.lua:556-600, :847-868). Right mechanism, wrong
altitude — a third face (eventMeta) was about to re-implement it.

## Decision

Solve once in pextStore: `writeRaw`/`readRaw` is the universal
projext gate, so the mirror lives inside it and every face —
eventMeta, dataStore's project keys, configManager's project tier —
inherits without knowing.

## Policy — undoable is per key, not per scope

Project scope holds three semantic classes; only two rewind. Faces
declare undoable vs plain when they register slots, so the
exclusions stay greppable rather than folklore.

- **Document data — in.** eventMeta (the motivating bug — it rode
  undo as take ext-data; the pool-guid move silently dropped that).
  fxPatterns — rewinding is *more* consistent than today: a pattern
  edit re-realises consumers into take MIDI, which already rewinds;
  mirrored, library and realisation rewind together and the
  dataChanged → full-dirty rebuild converges.
- **Config — in, for uniformity.** cm's project tier: the current
  split (take/track tiers rewind because they're P_EXT, project
  doesn't because it's projext) is a storage accident, not a design.
  arrangeColours likewise — harmless, and no exception to carve.
  Global stays disk, outside undo, by design.
- **Runtime bookkeeping — out.** guardedTrack records what Continuum
  did to a live track (I_PERFFLAGS + original); rewinding the record
  out of sync with the actual flags loses the restore value or
  "restores" flags we never set. scratch's own guid key and the
  mirror/manifest slots themselves: excluded by construction. rm's
  fxMeta/busMeta stay on rm's private mirror until the pinned
  migration.

## Design

- **Write path.** An *undoable* project-scope write lands in projext
  AND on the scratch track's P_EXT under the same slot name; plain
  slots write projext only, exactly as today.
- **Two-level hash manifest.** A per-slot compare would need a slot
  enumeration projext/P_EXT lack, and chunk-parsing scratch is out —
  wm parks FX there and GetTrackStateChunk is the known ~80ms trap:
  - bucket = hash(slot) % 64 — face-agnostic slot-space bucketing.
  - per bucket, one scratch manifest blob { slot → hash(raw) }; a
    write rewrites only its bucket's manifest (the eventMeta
    kb-bucket lesson: one flat manifest = reserialise-the-world per
    keystroke).
  - one root blob { bucket → hash(manifest) } — the watermark.
- **Detection.** pollUndo (already state-count gated) reads the root
  once per tick against the in-memory expected root.
- **Resync.** Root diff → diverged buckets → their manifests →
  per-slot hash diff → copy back only the rewound slots; then fall
  through to the normal watch-group comparison, so project blobs
  become watchable exactly like take/track. Undo cost ∝ divergence,
  not pool size — a saturated ~12k-slot pool no longer means ~12k
  reads per undo tick.
- **Expected state.** pextStore is the sole session writer: it keeps
  slot→hash + the expected root in memory as it writes; seeded once
  per session from root + manifests (~65 small reads), never from
  the slots themselves.
- **Rewound hook.** fire('projectRewound', divergedSlots) after
  resync. mm/tm subscribe: metadata reload (skipped when no diverged
  slot belongs to the bound pool) + full-dirty rebuild — needed
  because a freeze writes ~no MIDI, so the take-hash watcher won't
  fire on its undo.
- **Hash.** Cheap string hash in util (FNV-1a, length folded in). A
  collision = a rewound slot silently not copied back; negligible at
  these sizes, accepted deliberately.
- **Edges.** Scratch track deleted → resync no-ops; the next write
  re-mints scratch and remirrors from projext. Project/context
  switch resets the expected root — a swap must not read as a
  rewind.
- **Cost.** ~3 track P_EXT writes per project-scope assign (slot,
  its bucket manifest, root). Bucket count tunable if the manifest
  string turns out heavy.

## Implications (regardless of which keys opt in)

- **Undo-point bundling.** projext writes never create undo points;
  the mirror makes a slot revert when an undo *crosses* it, bundled
  into whatever undo point formed next. For metadata riding a MIDI
  edit that is exactly right. A *pure* project-scope edit with no
  take write (a pattern-library commit, a project-tier config
  change) would rewind silently as a passenger on an unrelated undo
  — so user-facing pure-project edits wrap in `util.atomic` to mint
  their own undo point. Audit the call sites when this lands.
- **Undo storage weight.** Each undo point captures the scratch
  track's chunk, mirror included. Typical pools (hundreds of
  metadata entries → tens of KB) are nothing; a saturated ~12k-slot
  pool is ~1MB per undo point, which eats REAPER's undo-storage
  budget and can evict history depth. Not a blocker — the honest
  cost of chunk-based mirroring, recorded so it's recognised if it
  bites.

## Tests

Red-first: undo restores an undoable project slot (harness rewinds
the scratch mirror; projext converges and the slot's watch group
fires); a plain slot (guardedTrack) never rewinds; resync copies
only the diverged slots; own writes never trigger; a project switch
never triggers; freeze's derived-clear round-trips — undo restores
the tag and the next rebuild is duplicate-free; an eventMeta value
edit + undo restores detune.
