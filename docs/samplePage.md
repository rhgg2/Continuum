# samplePage / sampleRender

The sample page is split in two, mirroring the tracker, arrange, and
wiring stacks:

- **samplePage** is the controller — the object `coordinator` drives. It
  constructs the stack (`sm` stays local, only `sv` leaves), owns the
  page lifecycle (`bind`/`setTrack`/`unbind`/`tick`), publishes the
  `sample` facade, and delegates every render call to the renderer.
- **sampleRender** draws the three-pane browser+slots and the trim
  strip, reads keyboard and mouse, and owns the `sample` command scope.
  It is handed sampleView only and never reaches sampleManager, so the
  slot mutations it issues (`setTrim`/`setName`/`stageInto`/`syncSlot`)
  can reach no track but the bound one.

A bound track need not carry the sampler FX: the picker lists only
tracks that do, but the FX can be removed while the page holds the
track. `sv:isLive` reports whether it is still there, and sampleRender
wraps the whole body in `chrome.disabledIf(not isLive)` — the surface
greys and stops responding, so no edit is aimed at a JSFX that is not
there.

## Where state lives

sampleRender is render-only. Every persistent fact lives elsewhere:

- **sampleView** — browser selection, current folder, bound track.
- **configManager** — `currentSample`, `previewInPlace`, `advanceOnLoad`.
- **dataStore** — `slotEntries`, at the track tier.
- **sampleManager** — JSFX-side slot truth, audio bytes.

sampleRender holds only frame-local caches (peaks, durations) and
ephemeral interaction state (drag handle, in-flight rename, preview-in-
place breadcrumb). All of it is reconstructible from the layers below;
none of it survives a reload.

## Preview-in-place

Auditioning a slot replacement without committing. The JSFX slot is
staged to a transient file while `cm:slotEntries` stays untouched. The
preview lives until the user does anything that implies they've moved
on — a browser navigation, a slot focus change, or a stray click — at
which point `revertPreviewInPlace` pushes cm's truth back to the JSFX.

The trigger frame is consumed (`pip.justTriggered=true`) so the same
input that started the preview doesn't immediately revert it. After
that frame the auto-revert is armed.

This is "modal without modality": the user gets the preview/commit
discipline of a modal dialog without the dialog. The cost is that the
revert criterion has to be liberal — anything that looks like a
context shift counts — because there's no explicit close.

## Peak / duration cache

File-path-keyed and survives across frames because `BuildPeaks` is a
multi-frame op and the strip would flicker if we recomputed each draw.

Cache entries are width-keyed too: a peak histogram computed for N
columns can't be reused at M, because `GetPeaks` reduces frames to
columns inside REAPER and a foreign width gives the wrong shape. So
window resize drops the cache for the visible strip and rebuilds.

## Drag handle stickiness

Which handle (start vs end) the user is dragging is decided on the
first active frame by mouse proximity, then held until release. The
choice never switches mid-drag, even if the cursor crosses the other
handle, because handle-flipping under the cursor is unusable.

The `drag` table is keyed by slot; switching to a different slot
mid-drag implicitly drops the drag (the liveDrag check fails).
