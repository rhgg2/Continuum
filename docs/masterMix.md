# masterMix

**A shared toolbar segment: a master output meter wrapped around a
master volume fader.** It sits immediately right of the page switcher,
on every page.

## Everything comes off the master track

1. Every value the widget shows or writes is read from REAPER's master
   track directly.

1. `Track_GetPeakInfo` supplies the levels: channels 0 and 1 are the
   per-channel peaks, channel 1024 the momentary loudness.

1. The peaks drive each bar's fill, frame-averaged on the way in since
   the raw value is nervy.

1. Each channel's peak in dB is also latched and held for `HOLD_TIME`
   (1.5 s), timed by `time_precise`, then released to the current
   level. The hold is computed locally because REAPER's native
   `Track_GetPeakHoldDB` ages on its own schedule.

1. Loudness is a single K-weighted value for the whole program, drawn
   as one reference line across both bars. The stereo detail lives in
   the per-channel fills and holds.

1. Volume is read from `D_VOL` and written with `CSurf_OnVolumeChange`
   — absolute, undo- and surface-aware.

1. The fader taper is REAPER's own (`DB2SLIDER`/`SLIDER2DB`), so the
   control matches a track fader: −inf … the project fader max
   (default +12 dB).

## The dB axis

1. Both bars span −60 … +6 dB (`METER_MIN`/`METER_MAX`). Peaks, holds
   and loudness are all converted to dB and placed as a fraction along
   that range.

1. The fill changes colour at 0 dB, which sits at a fixed fraction
   along the bar.

## Loudness scale

1. `Track_GetPeakInfo` channel 1024 returns loudness, but the API does
   not state its units. `loudnessDb` treats the return as linear
   amplitude, the same as the peak channels.

1. Every loudness value passes through `loudnessDb`, so the assumption
   lives in one place.

## One-row layout

1. The coordinator fixes the toolbar band's height
   (`docs/coordinator.md § Toolbar band height`), so the widget has
   exactly one row to draw in.

1. The whole rect is the fader's hit target. The L and R bars ride its
   top and bottom edges, with the groove and handle between them.

## Controls

1. A drag anywhere on the control sets the volume.

1. Within ±`DETENT_DB` (0.7 dB) of unity a drag snaps to exactly 0 dB;
   a tick on the groove marks the spot.

1. While a drag is live the dB value reads out just below the handle.
   It goes on the foreground draw list, which clears the toolbar's clip
   rect.

1. A double-click resets to 0 dB. The `suppressDrag` latch then holds
   drag off until the mouse releases, so the reset survives the click
   that is still down.
