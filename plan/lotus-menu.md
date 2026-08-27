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
   the entries instead of its own items table.  ← in flight
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

- 2026-08-27 cmgr: declare the tracker and region scopes in a manifest (§ The manifest)
- 2026-08-27 cmgr: declare the global scope's commands in a manifest (§ The manifest)

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)

- **arrange's manifest.** `manifest.arrange` takes all 112 registered
  names with labels: the 37 of arrangeView's `registerAll`
  (arrangeView.lua:954), the 3 of arrangeRender's (arrangeRender.lua:1042),
  and the two families minted in the manifest's own loops —
  `drop0`–`dropZ` over `util.toBase62` with `placeKey`, and
  `arrangeAdvanceBy0`–`9`. Keys come across from `pageBindings.arrange`
  unchanged; `arrange:bindAll` (arrangeRender.lua:1054) and
  `pageBindings.arrange` go. arrangeView's `replaceCmds` loop mints
  redirects, not registrations, and stays put. Spec: `arrange_page_spec`
  gains the tracker commit's assertion — a representative chord resolves
  through the installed keymap.

- **Sampler and wiring, and `pageBindings.lua` retired.**
  `manifest.sample` (6 entries, sampleRender.lua:595) and
  `manifest.wiring` (2, wiringRender.lua:2806) with labels; both
  `bindAll` calls and the file itself go. With no scope left undeclared,
  `auditManifests` turns strict: a scope that registers a command but
  declares no manifest raises, which is § What load asserts 1 read whole.
  Docs lose the "one at a time" clause. Spec: `cmgr_manifest_spec` pins
  the new raise.

- **The cheat-sheet reads labels from the entries.** cmgr grows a label
  lookup over the installed manifests; help's items collapse from
  `{cmd, label}` to `{cmd}` across trackerRender.lua:718-848, and
  `cmdLabel` (help.lua:213) becomes that lookup, losing its
  bare-command-name fallback for a command on another scope.
  `insertRowCol` and `deleteRowCol` shorten to `Insert row` /
  `Delete row` in the manifest, the `(all columns)` pair keeping the
  fuller labels. `docs/help.md` § What's where stops calling the help
  registration a manifest. Spec: every help `cmd` resolves to an entry.
