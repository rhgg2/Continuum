# status bar — plan

> source: `design/status-bar.md` — synthesis compiled from there;
> don't design here.

## Phases

1. **Phase 1 — the bar, every page on it, tracker editable** (§ Page protocol,
   Segment spec, Rendering, Edit interaction, Focus, Help migration) —
   `chrome.makeStatusBar()`, the coordinator footer calling
   `page:statusSegments()`, all five pages converted in the same commit, then
   the edit machinery and tracker's editable cells.
   — landed 2026-08-25, 2 commits
2. **Phase 2 — arrange editable segments** (§ Per-page content) — beats-per-row
   migrated off the toolbar with the `x2` wheel, and advance; wiring's zoom
   factor stays out until there is one.  ← in flight

The coordinator holds one page protocol, so the footer swap converts every
page at once; the pages that gain nothing but a declared segment ride along in
that commit.

Verification is by eye in REAPER through the bridge. A status bar's failures
are visible on sight, and a spec that ran the real frame would mostly pin the
fidelity of its own ImGui fake.

## Landed  (newest first; prune below ~4)

- 2026-08-25 chrome: edit status cells in place, four of the tracker's among them (docs/chrome.md § Editing a status cell)
- 2026-08-25 chrome: lay the status bar out as declared segment cells (docs/chrome.md § Status bar layout)

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)

- **arrange: beats-per-row and advance edited in the status bar.** Drop the
  toolbar's `beatsPerRow` stepper segment (`followPlay` stays, alone). The
  status `beatPerRow` cell gains `set = function(n) av:setBeatPerRow(n) end`
  and `edit = { kind = 'number', min = 1/4, max = 64, step = 'x2', format =
  '%g' }`. For `advance`, split `advanceReadout` into a `get` returning the
  number (`cm:get('arrangeAdvanceBy')`) and a `format` function keeping the
  "take length or N" wording, so the edit buffer opens on the number alone;
  `set` is an atomic `cm:set('project', 'arrangeAdvanceBy', n)`, `edit = {
  kind = 'number', min = 0, max = 9, format = '%d' }`. Editing the step
  leaves length mode as it was — Ctrl-` owns that. By eye in REAPER.
