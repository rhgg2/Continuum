# samplePage / sampleRender

**The sample page loads audio files from disk into the slots of a
track's sampler FX.** A folder tree and file list sit on the left over
a waveform trim strip, with the track's slots down the right.

## The split

1. samplePage builds the stack and hands sampleRender only sampleView.
   sampleManager stays local, so the renderer's slot mutations cannot
   reach a track other than the bound one.

1. sampleRender draws the three panes and the strip, reads keyboard
   and mouse, and owns the `sample` command scope.

1. The `sample` facade carries `setTrack`, which `diveToSampler` uses
   to open the page already bound to a track.

## A bound track may lose its FX

1. A bound track need not carry the sampler FX. The picker lists only
   tracks that do, but the FX can be removed while the page still
   holds the track.

1. `sv:isLive` reports whether it is still there. sampleRender wraps
   the whole body in `chrome.disabledIf(not isLive)`, so the surface
   greys and goes inert for as long as the FX is absent.

## Preview-in-place

1. A preview-in-place auditions a slot replacement without committing
   it.

1. `stageInto` copies the file into the project folder under a
   content-hashed name and points the JSFX slot at it. The slot's
   `slotEntries` entry is untouched, so dataStore still holds the
   committed truth.

1. The preview lasts until any sign of moving on — a browser
   navigation, a slot focus change, a stray click, or unbinding the
   page. `revertPreviewInPlace` then pushes the stored entry back to
   the JSFX. The list is broad because a preview has no explicit
   close.

1. The revert test runs at the end of the body, and skips the frame on
   which the preview was triggered — the click that started the
   preview would otherwise satisfy it at once. `pip.justTriggered`
   marks that frame, and is cleared as it passes.

## The trim strip

1. The trim strip shows the focused slot's file as a waveform, with a
   start handle and an end handle. Dragging them sets the frame range
   the JSFX plays.

1. A live drag overrides the stored start and end locally, so the
   markers track the cursor without a round trip. `setTrim` writes the
   range, and dataStore catches up on the next frame.

1. The write enforces `0 ≤ start ≤ end - 1` and `start + 1 ≤ end ≤
   frames - 2`: the file's last two frames are reserved.

## Peak and duration caches

1. The waveform is one high and low sample value per screen column,
   computed from the file by REAPER.

1. That computation is expensive, so peaks and durations are cached by
   absolute file path, and the entries survive across frames.

1. `PCM_Source_BuildPeaks` completes over several frames, so a peak
   entry starts partly built and is finished in a later frame.

1. The column count is part of the entry, because
   `PCM_Source_GetPeaks` does the reduction from samples to columns
   itself: values built for one strip width are the wrong shape at
   another. Resizing the window drops the entry and rebuilds it.

1. An unreadable file caches `false`, so the failure is not retried
   every frame.

## Trim drag stickiness

1. A drag on the trim strip moves one handle, start or end. Which one
   is chosen on the drag's first frame, by proximity to the mouse.

1. That choice holds until release. The cursor crossing the other
   handle does not change it.

1. The drag is keyed by slot, so changing the focused slot mid-drag
   ends it: the live-drag test no longer matches.

## sampleRender holds nothing durable

1. Its own state is the peak and duration caches, the live drag, and a
   rename in progress. All of it rebuilds from the layers below, and
   none survives a reload.

1. Every durable fact lives beneath it; `docs/sampleView.md §
   Transient and durable` says where.
