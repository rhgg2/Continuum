# Lotus menu — plan

> source: `design/lotus-menu.md` — synthesis compiled from there;
> don't design here.

## Phases

1. **Phase 1 — The entry** (§ The manifest, § What load asserts 1) — the
   entry shape declared per scope in `manifest.lua`, the keymap installed
   from it, the every-command-resolves check at load, and the global,
   tracker and region scopes moved across from `pageBindings`. — landed
   2026-08-27, two commits; the model now lives in
   `docs/commandManager.md` § Manifest.
2. **Phase 2 — The rest of the surface** (§ The manifest 4, § Three
   consumers) — arrange with its two loop-minted families, sampler and
   wiring; `pageBindings.lua` retired; the cheat-sheet's labels read from
   the entries instead of its own items table. Then the declaration
   becomes ordered and carries its cheat-sheet group, so the sheet holds
   no command list of its own, and the other three pages reach it.
   ← in flight
3. **Phase 3 — The tree** (§ Fluent and pathed, § The surface, § The tree,
   § The top level, § What load asserts 2–3) — the group table with its
   letters and descriptions, a path on every pathed entry, the surface as
   the union of the reachable scopes, the letter-uniqueness check, and the
   spec that pins the fluent/pathed split.
4. **Phase 4 — The walk** (§ Walking a path, § What stays live) — the menu
   as a modal scope (cmgr's first production use of `modal`/`passthrough`),
   `/` to open, a letter to descend or invoke, Esc to unwind, arrows and
   Enter for the highlight, transport passed through, prefix surviving.
5. **Phase 5 — The row** (§ Where it draws) — the menu row over the body's
   last row, the lookahead panel drawn upward from the highlight on the
   cheat-sheet's box renderer, and what a thin page or a narrow window does.
6. **Phase 6 — Both routes** (§ Both routes on the cheat-sheet) — a pathed
   command's path as a chip beside its key chips, rendered from the entry
   and the group letters.

## Landed  (newest first; prune below ~4)

- 2026-08-28 cmgr: declare each entry under its cheat-sheet group (§ Three consumers)
- 2026-08-28 cmgr: declare the manifest as ordered lists of token-keyed entries (§ The manifest)
- 2026-08-27 cmgr: the cheat-sheet reads its labels from the entries (§ Three consumers)
- 2026-08-27 cmgr: declare the sampler and wiring scopes, retire pageBindings (§ The manifest)

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)

- **The cheat-sheet reaches the other pages.** `arrangeRender`,
  `sampleRender` and `wiringRender` take `help`, anchor their body rect
  and place the groups worth pinning; arrange and wiring gain tracker's
  `wasOpenAtFrameStart` guard over the mouse reads that bypass
  dispatch. With grouping declared, no page writes a command list.

- **A generated family renders as one row.** `drop0`–`dropZ` and
  `advBy0`–`advBy9` collapse to one row showing the first and last
  chords. A rebind there captures a single chord and rewrites the
  family from its modifier mask, so the family's key is customisable
  without ten edits.
