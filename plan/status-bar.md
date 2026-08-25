# status bar — plan

> source: `design/status-bar.md` — synthesis compiled from there;
> don't design here.

## Phases

1. **Phase 1 — the bar, every page on it, tracker editable** (§ Page protocol,
   Segment spec, Rendering, Edit interaction, Focus, Help migration) —
   `chrome.makeStatusBar()`, the coordinator footer calling
   `page:statusSegments()`, all five pages converted in the same commit, then
   the edit machinery and tracker's editable cells.  ← in flight
2. **Phase 2 — arrange editable segments** (§ Per-page content) — beats-per-row
   migrated off the toolbar with the `x2` wheel, and advance; wiring's zoom
   factor stays out until there is one.

The coordinator holds one page protocol, so the footer swap converts every
page at once; the pages that gain nothing but a declared segment ride along in
that commit.

Verification is by eye in REAPER through the bridge. A status bar's failures
are visible on sight, and a spec that ran the real frame would mostly pin the
fidelity of its own ImGui fake.

## Landed  (newest first; prune below ~4)

- 2026-08-25 chrome: lay the status bar out as declared segment cells (§ Page protocol, § Rendering)

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)

2. **Edit interaction.** A `set` closure makes a cell editable. `kind='number'`
   renders as text until clicked, then an `InputText` sized to the cell, opened
   selected via `chrome.selectTo`; Enter commits through `set` clamped to
   min/max, Esc cancels. The wheel over a cell steps without entering edit — by
   ±`step`, or double/halve when `step='x2'` (min ¼, `%g` display).
   `kind='pick'` opens `chrome.drawPicker` with `items()`. `chrome.statusEditActive()`
   reports the edit state, sibling of `pickerIsActive()`.
3. **Tracker's editable cells, and the help pins.** Octave, advance and rpb
   become number cells, dropping the `rowsPerBeat` toolbar segment
   (`trackerRender.lua:133`); sample becomes a `pick` cell, dropping the toolbar
   `sample` segment and `drawSampleDropdown`. `tr:focusState()` folds
   `chrome.statusEditActive()` in beside `pickerIsActive()`. `help.lua`'s
   `rectFor` (`help.lua:59`) grows the `status.<id>` family next to
   `toolbar.<id>`, and the tracker manifest's two pins move to `status.rpb` and
   `status.sample`.
