# status bar — plan

> closed 2026-08-25. The model landed in `docs/chrome.md`, `docs/help.md`
> and `coordinator.lua`; this is the record of the work, not a live plan.

## Phases

1. **Phase 1 — the bar, every page on it, tracker editable** (§ Page protocol,
   Segment spec, Rendering, Edit interaction, Focus, Help migration) —
   `chrome.makeStatusBar()`, the coordinator footer calling
   `page:statusSegments()`, all five pages converted in the same commit, then
   the edit machinery and tracker's editable cells.
   — landed 2026-08-25, 2 commits
2. **Phase 2 — arrange editable segments** (§ Per-page content) — beats-per-row
   migrated off the toolbar with the `x2` wheel, and advance; wiring's zoom
   factor stays out until there is one.
   — landed 2026-08-25, 1 commit

The coordinator holds one page protocol, so the footer swap converts every
page at once; the pages that gain nothing but a declared segment ride along in
that commit.

Verification is by eye in REAPER through the bridge. A status bar's failures
are visible on sight, and a spec that ran the real frame would mostly pin the
fidelity of its own ImGui fake.

## Landed  (newest first; prune below ~4)

- 2026-08-25 arrange: edit beats-per-row and advance in the status bar (§ Per-page content)
- 2026-08-25 chrome: edit status cells in place, four of the tracker's among them (docs/chrome.md § Editing a status cell)
- 2026-08-25 chrome: lay the status bar out as declared segment cells (docs/chrome.md § Status bar layout)

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)

(empty)
