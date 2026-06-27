# masterMix

A shared toolbar segment: a master output meter wrapped around a master
volume fader, sitting immediately right of the page switcher on every
page.

## Data — all native, all the master track

No JSFX, no gmem. REAPER exposes everything the meter needs directly off
the master track:

- **Stereo peak** — `Track_GetPeakInfo(master, 0/1)`, per channel, drives each bar's fill (lightly frame-averaged — the raw value is nervy).
- **Per-channel peak-hold** — computed locally: each channel's peak (dB) is latched and held for `HOLD_TIME` (2 s) via `time_precise`, then released to the current level. REAPER's native `Track_GetPeakHoldDB` ages on its own schedule, hence the local hold.
- **Mono loudness** — `Track_GetPeakInfo(master, 1024)` (momentary): one program-wide value, drawn as a reference line across both bars.
- **Volume** — read `D_VOL`, write `CSurf_OnVolumeChange` (absolute, undo- and surface-aware). The taper is REAPER's own (`DB2SLIDER`/`SLIDER2DB`), so the fader matches a track fader: −inf … the project fader max (default +12 dB).

Loudness is mono by nature (K-weighted across channels), so it cannot
drive two independent bars. The stereo detail lives in the per-channel
peak fills and holds; the loudness in the one shared marker line.

## Loudness scale

`Track_GetPeakInfo` channel 1024 returns loudness, but the API docs do
not state its units. `loudnessDb` currently treats the return as linear
amplitude (the same as the peak channels). If the marker sits wrong
against the −60 … +6 dB axis in REAPER, that one function is where to
fix it.

## One-row layout

The coordinator pins the toolbar band to `lineCount × rowHeight` and does
*not* content-fit (see docs/coordinator.md § Toolbar band height), so a
tall stacked meter would be clipped. The widget is therefore a single
row: the whole rect is the fader's hit target, and the L/R bars ride its
top and bottom edges — "bars above and below the slider" inside one row's
height.

## Controls

- **Drag** anywhere on the control to set volume; the dB value reads out just below the handle while dragging (on the foreground draw list, to clear the toolbar's clip rect).
- **Detent** — a drag snaps to exactly 0 dB within ±`DETENT_DB`; a tick on the groove marks the spot.
- **Double-click** resets to 0 dB. A `suppressDrag` latch holds the drag off until the mouse releases, so the still-held click doesn't immediately pull the fader back off unity.

## Crisp rules

ReaImGui's `DrawList_AddLine`/`AddRect` are anti-aliased with no per-call
toggle, so the frame, the groove, the detent tick and the peak/loudness
ticks are drawn as 1px axis-aligned `AddRectFilled` rects on integer-pixel
coords (`px`/`hrule`/`vrule`) instead — those rasterise crisp. Don't
"simplify" them back to `AddLine`.
