# sampleView

Take-independent view rendered when `cm:get('viewMode') == 'sample'`. Owns
the file browser + slot list UI but no persistent state of its own —
selection lives in transient locals, sample assignments live in the
sampler JSFX (driven via gmem mailboxes).

## Identity model

Sample mode keys against a **REAPER track**, not a take. The track is
chosen explicitly through the toolbar picker, whose list comes from
`sv:listTracks()` → `sm:listTracks()` (tracks carrying the Continuum
Sampler FX). `samplePage:bind` seeds a default track on first entry —
the parent track of the last-active take — then drops the take context
so take-tier reads stop resolving against it.

`sv:setTrack(track)` is the single rebind path. It calls
`cm:setTrack(track)` and clears the transient `currentSample` override
so the merged read falls back to the new track's stored slot (or the
schema default). Test seams construct sv with `cm = nil`, exercising
the local field only.

## gmem boundary

The view never speaks gmem or REAPER directly — it holds `sm` (the
`sampleManager`, built and injected by `samplePage`) and routes every
side-effect through it: `sm:assign`, `sm:previewSlot`, `sm:previewPath`,
`sm:clearSlot`, `sm:stopPreview`, `sm:listTracks`. The view passes its
own bound track into each call, so the manager's track-first signatures
stay uniform. Holding the manager (rather than a bag of injected
closures) keeps sv testable in the pure-Lua harness, where a
call-recording fake `sm` stands in. Preview semantics — slot vs.
hidden-path audition, the `bounds` flag — live on `sampleManager`.

## Layout

Three side-by-side `BeginChild` panes inside the body region:

1. **Folder tree** (left) — recursive `TreeNode` walk rooted at
   `cm:get('sampleBrowserRoot')` (or `$HOME` if unset). Clicking a node
   updates `currentFolder`.
2. **Audio files** (middle) — `[▶][filename]` rows for `currentFolder`.
   Play icon → `auditionPath(full)`. Selectable single-click → select.
   Selectable double-click → `loadSelectedIntoCurrent()`.
3. **Slots** (right) — `[▶][NN name]` rows for slots 0..N_SLOTS-1. Play
   icon → `auditionSlot(idx)`. Selectable click → `currentSample = idx`.

The `##` label suffixes on `SmallButton` give every play icon a unique
ImGui ID (full path for files, slot index for slots) so identical
filenames in different folders don't collide.
