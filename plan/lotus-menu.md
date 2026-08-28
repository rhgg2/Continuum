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
2. **Phase 2 — The rest of the surface** (§ The manifest, § Three
   consumers, § The surface) — arrange with its two loop-minted families,
   sampler and wiring; `pageBindings.lua` retired; the cheat-sheet's
   labels read from the entries instead of its own items table. Then the
   declaration becomes ordered and carries its cheat-sheet group, so the
   sheet holds no command list of its own, and the other three pages reach
   it. — landed 2026-08-28, four commits; the model now lives in
   `docs/commandManager.md` §§ Manifest and Surface, and `docs/help.md`
   § A generated family.
3. **Phase 3 — The tree** (§ Fluent and pathed, § The tree, § The top
   level, § What load asserts 2–3) — the tree table with its letters and
   descriptions, a path on every pathed entry across the surface, the
   letter-uniqueness check, and the spec that pins the fluent/pathed
   split. ← in flight
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

- 2026-08-28 help: a generated family reads as one row (§ Fluent and pathed)
- 2026-08-28 help: the cheat-sheet reaches arrange, sampler and wiring (§ Three consumers)
- 2026-08-28 cmgr: declare each entry under its cheat-sheet group (§ Three consumers)
- 2026-08-28 cmgr: declare the manifest as ordered lists of token-keyed entries (§ The manifest)

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)

- cmgr: the menu tree as `manifest.menu`, an ordered list of `item(name,
  letter, desc, ...children)` holding the twelve top-level groups. Install
  resolves each entry's `path` string by walking it, raising on a path
  naming no group and on two groups sharing a letter within a level; the
  model goes to `docs/commandManager.md` § Menu tree.
- cmgr: a path on the global and tracker scopes' deliberate verbs, the
  fluent ones left key-only, with the subgroups the split needs added to
  the tree. A leaf's letter comes from its label, with an entry-level
  `letter` where a level collides, and the collision check covers a
  level's groups and leaves alike.
- cmgr: the same pass over arrange, region, sampler and wiring, with their
  subgroups, finishing the surface.
- cmgr: the fluent roster — a spec naming every key-only command and
  asserting the roster partitions the manifest with the pathed entries, so
  a new command fails the spec until it is classified.
