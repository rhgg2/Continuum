# scratch

**The scratch track is where a REAPER object lives when it has to
exist in the project without appearing in it.** There is one per
project: hidden, muted, minted on first use, and identified by a guid
persisted in projext under `continuum_wiring/scratch`.

## Tenants

1. A **tenant** is a module that keeps something on the track. There
   are four, and their needs have nothing to do with one another:

   - `pextStore` mirrors the project's undoable data — eventMeta tags,
     project-tier config, dataStore's project keys — onto the track's
     `P_EXT`, so that REAPER's undo, which rewinds track chunks but
     not projext, restores it (`docs/pextStore.md`);
   - `wiringManager` mints every FX plugin here, and leaves it here
     while its graph node has no track of its own — a node with
     nothing connected to it, say. The plugin keeps its parameter
     state throughout (`docs/wiringManager.md`);
   - `arrangeManager` moves a palette slot's MIDI item here when its
     last placement in the arrangement is deleted, so that the slot
     and its pooled source outlive their placements
     (`docs/arrangeManager.md` § Parking);
   - `patternEditor` edits a pattern by materialising it onto a take
     here and reading it back on commit, since the tracker stack edits
     takes and nothing else. The take is deleted when the editor
     closes (`docs/patternEditor.md`).

## A module of its own

1. No tenant owns the track. Four modules need the same thing — a
   place in the project for an object that must not appear in it — so
   the track is provided once, here.

1. This module is then the track's sole owner: one guid in projext,
   and one module table shared by every caller. The tenants then agree
   on which track they mean with no coordination necessary.

1. The module itself holds nothing between calls: REAPER invalidates
   track handles freely, so the live track is re-located by guid every
   time.

## Minting on demand

1. `id()` and `track()` mint on first use: minting appends the track,
   names it `continuum: scratch`, hides and mutes it, and persists the
   guid.

1. `peek()` returns the persisted guid and the live handle, or
   nothing, and never mints. This serves `am:isVisibleTrack` and
   `wm:isScratchTrack`, which only ask whether a given track is the
   scratch.

1. The same holds for a write with nothing to preserve. pextStore
   mirrors a removal onto a scratch that already exists, but will not
   mint one to record it; the next genuine write mirrors what is
   missing (`docs/pextStore.md`).

## Hidden and muted

1. Hidden keeps the track out of the mixer and the track control
   panel, so the user never meets it.

1. Muting ensures that parked MIDI items don't sound through parked
   instrument FX.

## Pinned to the top level

1. A track appended while the project ends inside an open folder joins
   that folder, and sends its output to the folder's parent. `mint`
   therefore closes the accumulated folder depth on the last track
   before appending.

1. The ten lines implementing this duplicate `rm:addTrack`, since
   routingManager is a per-stack instance a required module cannot
   reach. A third copy would be worth extracting.
