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
   split. — landed 2026-08-28, four commits; the model now lives in
   `docs/commandManager.md` §§ Menu tree and The top level.
4. **Phase 4 — The walk** (§ Walking a path, § What stays live) — the menu
   as a modal scope (cmgr's first production use of `modal`/`passthrough`),
   `/` to open, a letter to descend or invoke, Esc to unwind, arrows and
   Enter for the highlight, transport passed through, prefix surviving.
   ← in flight
5. **Phase 5 — The row** (§ Where it draws) — the menu row over the body's
   last row, the lookahead panel drawn upward from the highlight on the
   cheat-sheet's box renderer, and what a thin page or a narrow window does.
6. **Phase 6 — Both routes** (§ Both routes on the cheat-sheet) — a pathed
   command's path as a chip beside its key chips, rendered from the entry
   and the group letters.

## Landed  (newest first; prune below ~4)

- 2026-08-28 cmgr: pin the fluent/pathed split with a roster spec (§ Fluent and pathed)
- 2026-08-28 cmgr: a path on every deliberate arrange, sampler and wiring verb (§ Fluent and pathed)
- 2026-08-28 cmgr: a path on every deliberate global and tracker verb (§ Fluent and pathed)
- 2026-08-28 cmgr: declare the menu tree and check it at load (§ The tree)

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)

1. **The scope and the open verb.** `menu.lua` owns a cmgr scope with
   `modal = true` — cmgr's first — whose passthrough set is every entry
   declared under a `Transport` group on the stack, so playPause and stop
   stay live. `openMenu` is bound to `/` in global and `closeMenu` to Esc;
   the menu holds its own path, empty here. Coordinator constructs it
   beside `help` and it exposes `isOpen()`; nothing draws yet. Spec: the
   scope pushes and pops, a tracker key is blocked while it is open, and a
   transport key is not.
2. **The live level.** `menu:level()` returns the members of the node the
   path names, ordered: the node's child nodes from `cmgr.tree`, and the
   entries of `cmgr:surface()` whose stamped `node` is that node. Each
   member carries its letter, its title, and a group's description or a
   leaf's label. The empty path gives the top level. Spec: the tracker's
   top level holds Grid but not Sample, the sampler's the reverse, and
   pushing region mode changes what a level holds.
3. **Letters walk it.** A letter is captured in `keyDispatch` ahead of the
   keychain walk, as prefix digits already are, and only while the menu is
   open. A group's letter descends, a leaf's invokes the command and closes
   the menu, Esc pops one level and closes from the top, and an unmatched
   letter is consumed and ignored. Spec: `/GQ` from the tracker invokes
   quantize and closes; `/G` then Esc twice is closed again.
4. **The prefix survives.** `/` with a prefix pending appends to the buffer
   as today and opens the menu; the next key resolves which it was — a
   digit continues the rational and closes the menu, a letter drops the
   trailing slash, finishes the prefix and walks. Opening the menu neither
   freezes nor clears the prefix, and the leaf's invoke consumes it as a
   chord's would. Spec: `⌘U 3 / 2` still reaches `prefixRational`, and
   `⌘U 4 /VRS` invokes setRPB with 4.
5. **The highlight.** The menu holds a highlight index into the current
   level, reset on every descent and unwind. Up and Down move it, Enter
   takes it — descending on a group, invoking on a leaf — and Left is Esc's
   unwind. It is the field Phase 5's lookahead panel reads. Spec: the
   highlight wraps within a level, and Enter on a leaf invokes what its
   letter would.
