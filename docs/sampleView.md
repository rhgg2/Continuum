# sampleView

**The sample page's transient state, and the renderer's only route to
the sampler.** Nothing sampleView holds is persisted; every durable
fact lives elsewhere.

## Keyed to a track

1. Sample mode keys configManager to a REAPER track; the tracker stack
   keys it to a take. The track comes from the toolbar picker, which
   lists the tracks carrying the Continuum Sampler FX.

1. `samplePage:bind` seeds the first one — the parent of the
   last-active take — and re-asserts the page's track at every later
   activation, since whichever page is active re-keys the shared
   configManager.

1. `sv:setTrack` is the single rebind path. Rebinding drops the
   transient `currentSample` override, so the slot number falls back
   to the one the new track stores, or to the schema default.

## Transient and durable

1. sampleView's locals are the bound track, the current folder, the
   highlighted browser row, the selected file, the preview source, and
   the set of expanded folder subtrees. A reload starts from none of
   them.

1. The durable facts sit elsewhere: `sampleBrowserRoot`,
   `currentSample`, `advanceOnLoad` and `previewInPlace` are
   configManager keys; `slotEntries` is track-tier dataStore data; the
   audio itself belongs to the JSFX, reached through sampleManager.

1. The browse root shows the split: it persists at the global tier,
   while the current folder it seeds does not. Setting a root
   therefore clears the folder, which puts the new one on screen.

## Where the audition points

1. One audition key serves both panes, so sampleView records which
   pane the user last touched. `previewSource` is `'file'` or
   `'slot'`: highlighting a file in the browser sets the first,
   `setSlotFocus` sets the second, and `auditionCurrent` dispatches on
   it.

1. `setBrowserItem` records the highlighted row.
   `selectedFile` mirrors it for a file and is nulled for a folder, so
   neither audition nor load can fire on a directory.

## The sampleManager boundary

1. Everything beyond sampleView's own locals — the sampler JSFX, and
   the project's tracks — is reached through the injected
   sampleManager, which holds the preview semantics
   (`docs/sampleManager.md`).

1. sampleView passes its bound track into each sampleManager call,
   which keeps the track-first signatures uniform. `sv:syncSlot` is
   the exception: its caller supplies the track, since a
   preview-in-place revert restores the one captured when the preview
   was triggered, which need not still be bound.

1. sampleRender is handed sampleView alone and never sampleManager
   (`docs/samplePage.md`), so a JSFX-side edit cannot reach a track
   other than the bound one.

## Loading advances the slot

1. A load assigns the selected file to the current slot and, under
   `advanceOnLoad`, moves the current slot to the next empty one above
   it. Filling a row of slots from a folder is then one keypress per
   file.
