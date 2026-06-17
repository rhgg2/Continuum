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
