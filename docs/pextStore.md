# pextStore

The storage + context + undo engine, extracted from `configManager`. It
knows nothing about config keys, tiers, or defaults — it moves blobs to
and from REAPER's persistence backends, owns the bound take/track
context, and runs the watcher that catches undo/redo.

It exists to be written **once** and shared by two faces: `configManager`
(schema, tier merge) today, and `dataStore` (per-key document storage)
next. See `design/archive/persistence.md` for the split and its motivation.

## Why a shared engine

Three facts have to be true across every persisted thing in the project,
and each was previously re-implemented per module:

1. **One bound context.** A take (and the track derived from it) is the
   address for take/track-tier storage. Both faces resolve reads against
   the *same* take, so the take lives here — not laterally in one face
   that the other would have to reach sideways into.
2. **Undo survival.** REAPER's undo/redo rewrites P_EXT directly, behind
   our back. The only signal we get is the project state-change count, so
   the engine polls it once per frame and re-reads watched blobs on a
   tick. This is the crown jewel the redesign consolidates.
3. **Backend dispatch.** take/track P_EXT, project projext, and the
   global disk file are four different REAPER APIs behind one `(scope,
   slot)` address.

## The watcher

`watch(blobs, onDiverge)` registers a *group* of `(scope, slot)` blobs
under one callback. `pollUndo` gates on the state count; on a tick it
drops any stale take/track pointer, re-reads every watched blob, and
fires each group's `onDiverge` **once** with the list of that group's
diverged blobs (empty → not called). Fire-once-per-group is what lets
`configManager` collapse a two-blob divergence into a single reload, and
what will let `dataStore` fire one targeted signal per key.

Baselines are the last-seen raw bytes per watched blob. A **bound** write
(`assign`) refreshes its blob's baseline, so the engine never mistakes
our own write for an external edit. A **foreign** write (`assignAt`) does
not — it targets an arbitrary handle, off the bound context, and leaves
the baseline untouched. That asymmetry is inherited verbatim from the
pre-extraction `configManager` (its foreign-handle writes never touched
`lastTakeRaw`/`lastTrackRaw`); a write to the *bound* handle through the
foreign path therefore still shows up as a divergence on the next poll,
exactly as it did before.

Dropping a stale handle zeroes its watched blobs' baselines to `''`, so
the post-drop read (which returns `''` for a nil handle) doesn't register
as an external diff — matching the old `take, lastTakeRaw = nil, ''`.

## Formats

The engine picks the serialisation format by backend, not by caller: the
global disk file (`continuum-config.lua`, in REAPER's resource dir) is the
human-editable Lua-literal format, read by `load()`; every P_EXT / projext
blob is the compact wire format. The two never interoperate, so neither
constrains the other — see `design/archive/persistence.md` § Disk format.

A global file the sandboxed `load()` can't parse reads as `nil` and **locks
writes** (`globalLocked`): the engine prints the parse error and refuses to
overwrite, so a hand-edit typo can't cost the user their config. The lock
clears the moment the file reads clean (or empty) again.

## The mirror (projext undo)

REAPER undo rewinds take/track P_EXT and the scratch track's chunk, but
projext does not reverse natively. Everything at project scope therefore
used to survive undo — eventMeta's tags being the motivating casualty
(design/projext-undo.md). The engine closes the gap once, at the
`writeRaw` altitude, so every face inherits it without knowing.

**Policy is per key, not per scope.** Faces declare undoable slots at
construction (`declareUndoable`: exact names or prefixes — eventMeta's
slots are dynamic). Undeclared project slots write projext only, exactly
as before; the exclusions stay greppable (dataStore's `PROJECT_PLAIN`).

**Write path.** An undoable write lands in projext AND on the scratch
track's P_EXT (`ctm_ps.s.<slot>`), plus a two-level manifest: a bucket
manifest (`ctm_ps.m.<b>`, `b = hash(slot) % 64`, slot → content hash)
and one root (`ctm_ps.root`, bucket → manifest hash). The manifest
exists so undo detection is one root read per tick and resync cost
tracks divergence, not pool size — a saturated ~12k-slot pool is not
~12k reads per undo. A removal with no scratch minted mirrors nothing:
the engine won't insert a track to record an absence.

**Detection.** pollUndo (state-count gated) compares the root against
the in-memory expected state — seeded once per session from root +
manifests, maintained on every write. Divergence walks only diverged
buckets, then diverged slots, and copies a mirror back into projext only
when it actually differs from projext. `projectRewound` fires after the
copy-back, then the normal watch groups run — so a watched project blob
(cm's `config` tier, ds's project keys) diverges on the same tick and
its face reloads through the existing machinery.

**Guid changes.** A rewound root is one thing; a *different scratch* is
another. The handle is cached, validated per use, and its guid re-checked
even when valid — REAPER reuses freed pointers, so a re-minted scratch
can land at the old address. On a guid change there is no re-mint vs
project-switch discrimination to make: adopt whatever mirror state the
new scratch carries, then replay from projext any known slot it lacks.
projext is the current project's truth, so a genuine switch finds
nothing to replay (absent slots drop out), a re-mint gets the full set
back, and a second engine's earlier partial replay is topped up rather
than trusted. Neither case fires `projectRewound`.

**Two writers.** patternEditor runs its own engine stack over the same
project, so the mirror has two writers with independent expected states.
Manifest and root writes therefore merge-read the current scratch value
before overlaying the slot being written — a blind rewrite from one
writer's view would drop the other's entries. Adopting the merged state
means either engine's poll protects both writers' slots. PE's own engine
is not polled: its checkout pool is dropped at close and re-persisted on
every edit, so staleness self-heals within the gesture.

**Known window, accepted.** A context change (`setTake`) resets the
state-count gate, so an undo landing between a poll and a same-frame
rebind is swallowed for one tick; the root comparison still differs
afterwards, so it resyncs at the next state-count change.

Undo-point bundling and undo-storage weight are design decisions, not
engine mechanics — see design/projext-undo.md § Implications.
