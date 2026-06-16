# Design — Persistence split (config vs document data)

Status: designed, pre-implementation. Decisions settled; key-by-key
migration list and the engine API are the concrete next step.
Scope: separate user-facing **config** from structural **document
data**, both today riding `configManager`. Unify the three duplicated
undo-survival implementations onto one engine. Make the disk-backed
files hand-editable.

## The problem

`configManager` is a schema'd key-value store with five merge tiers
(global → project → track → take → transient), deep-clone boundaries,
and an undo watcher (`pollUndo`) that re-reads the take/track P_EXT
blobs when REAPER's undo/redo rewinds them. That last piece is the
crown jewel — it is why a mirror-group edit survives Ctrl-Z.

Two things are wrong:

1. **The schema is a junk drawer.** Document content — mirror groups,
   sampler slot palettes, arrange slots, CV bindings, per-take length —
   is declared as config keys purely so `pruneUnknown` won't drop it on
   load. These keys never participate in the tier merge; they sit at one
   scope and *are* the document.

2. **Undo survival is implemented three times.** `configManager`
   (state-count poll + raw-string compare), `routingManager` (`metaSeen`
   + scratch-track mirror + `resyncMeta`), and `paramAutomation` (a track
   P_EXT mirror) each solve the same problem independently.

This is hygiene and consolidation, not a bugfix: today's sharing is
correct, just muddled and duplicated.

## Vocabulary

- **Config** — a user-facing setting. Has a schema default; may resolve
  through multiple tiers (a global default overridden at project, track,
  or take). `pbRange`, `noteLayout`, the `palette.*` / `colour.*` atoms.
- **Document data** — structural content of the project. Lives at exactly
  one **scope**, has no meaningful default beyond *absent*, is never
  overridden from a higher tier. `groups`, `arrangeSlots`, `paramAutomation`.
- **The test** — *does the key participate in the tier merge?* If yes,
  config. If it lives at one scope as content, document data. (Edge case
  that proves the rule: `temper` / `swing` are take-tier but genuinely
  seeded from a project-tier value via the merge — so they stay config.)
- **Scope** (document data) vs **tier** (config). Tiers *merge*
  (fallthrough, most-specific wins). Scopes are **independent addresses** —
  no fallthrough. `groups` at take has nothing to do with anything at
  project; they are separate storage locations. The word is chosen to
  avoid implying merge.

## The one decision

Split `configManager` into **two faces over one engine**:

- **`pextStore`** (new, low) — the storage + context + undo machinery,
  extracted unchanged in behaviour. Owns serialise/parse/clone, the
  REAPER P_EXT/projext and disk-file primitives, the bound take/track
  context (`setContext` moves down here — single source of context
  truth), and the state-count watcher over a registered set of
  `(handle, pextKey) → baseline-raw` entries.
- **`configManager`** (kept) — schema, defaults, five-tier merge, the
  global disk file. A face on the engine.
- **`dataStore`** (new) — open, per-key, single-scope storage on the
  same engine. The other face.

Both faces register their blobs with the engine's watcher, so undo
survival is written **once**. `routingManager` and `paramAutomation`'s
bespoke mirrors fold onto the same engine later (see Staging).

## dataStore

Scopes: **global / project / track / take**. No merge across them.

```
ds:get(scope, name)            -- bound context
ds:set(scope, name, value)
ds:remove(scope, name)
ds:getAt(handle, name)         -- replaces cm:readTakeKey / readTrackKey
ds:setAt(handle, name, value)  -- replaces cm:writeTakeKey / writeTrackKey
```

**Registry, not open schema.** `dataStore` keeps a small
`{ name → scope }` table — its own registry, the document-data keys
pulled out of `configManager`'s `declarations`. Typos still raise; the
"unknowns raise" safety is preserved, just owned by the right module.

**Per-key blobs** (for the P_EXT-backed scopes — project/track/take).
Each `(scope, name)` is its own P_EXT key: `P_EXT:ctm_data.groups` on the
take, `P_EXT:ctm_data.arrangeSlots` on the track,
`SetProjExtState(0, 'continuum_data', 'arrangeColours')` for project.
Two wins over one shared data blob:

- **Write isolation.** `cm:set` reserialises the whole cached tier table
  on every write. With one shared blob, editing a CV binding would
  reserialise the large `groups`+`uuids` tree next to it, and every
  in-group note edit would reserialise `paramAutomation`, `noteDelay`,
  `usedSwings`. Per-key, a write serialises only that key.
- **Targeted signals.** A per-key baseline lets the watcher know exactly
  which `(scope, name)` diverged on an undo tick, so it fires
  `dataChanged{scope, name}` — each manager wakes only for its own
  namespace, replacing today's blanket `configChanged` rehydrate.

Cost: `pollUndo` iterates the registry instead of two fixed reads —
~a dozen short P_EXT reads, only on a state-count tick, driven off the
closed registry (no enumeration). In-memory chunk reads; negligible.
Reads stay cache hits: load a scope's registry keys once on context
bind, cache `dataCache[scope][name]`, update one key + one write on set.

The **global scope** is the exception: a single disk-file blob, not
per-key. Its lone resident is small; per-key files there would be
ceremony. Per-key is a property of the P_EXT-backed scopes, not a
universal rule.

### Keys to migrate

Out of `configManager.declarations`, into the `dataStore` registry:

| key | scope | what it is |
|---|---|---|
| `groups` | take | mirror groups |
| `slotEntries` | track | sampler slot palette |
| `arrangeSlots` | track | arrange slot palette |
| `arrangeNaturalLenQN` | take | per-take length |
| `arrangeColours` | project | take → colour map |
| `paramAutomation` | take | CV bindings |
| `noteDelay` | take | per-lane delay |
| `usedSwings` | take | swings used in this take (derived) |
| `extraColumns` | take | per-take display columns |
| `colSwing` | take | per-column swing |
| `mutedChannels` | take | mix state |
| `soloedChannels` | take | mix state |
| `paramFrecency` | **global** | param-palette usage cache |

`paramFrecency` is the one app-global straggler — cross-project, machine-
maintained, not a setting and not document content. The global scope on
`dataStore` is its home, so `configManager` is left holding *only*
user-facing config.

Call sites to update: `groupManager`, `sampleManager`, `arrangeManager`,
`paramAutomation`.

## Disk format — Lua, read by `load()`

The two disk-backed stores — `ctm_cfg.txt` (config global) and the new
`ctm_data.txt` (document global) — must be hand-editable. The compact
`{k=v}` wire format is not. So the disk format is a **Lua table literal**,
and the "parser" is `load()` — no hand-rolled parser at all.

```lua
return {
  pbRange    = 2,
  noteLayout = "colemak",
  ["palette.base.zone0"] = { 0, 0, 0, 1 },   -- dotted keys quoted
  paramFrecency = { ... },
}
```

```lua
local chunk = load(text, '@ctm_cfg', 't', {})   -- 't' = text only; {} = empty env
local ok, tbl = chunk and pcall(chunk)
```

Whitespace, trailing commas, positional arrays, and comments come free
because it is Lua. Precedent exists — `util.instantiate` already loads
module files as chunks.

This keeps the two formats cleanly separated and explains why both exist:

- **P_EXT / projext** (machine, hot path): compact `serialise` /
  `unserialise`, untouched, no `load()` per write. Never hand-edited.
- **Disk files** (human, cold path): `prettySerialise` → Lua literal,
  read by `load()`. Never sits in a P_EXT slot.

They never interoperate, so neither constrains the other.

Four details:

- **Sandbox.** `'t'` mode rejects precompiled bytecode; empty `_ENV`
  means the chunk can build a table and nothing else. On a file the user
  edits on their own machine this is no more privileged than the script
  itself — the standard "Lua as config" pattern.
- **inf / nan.** Not valid bare Lua, but `1/0` / `-1/0` / `0/0` are, and
  need no env. `util.OPEN` (math.huge) round-trips as `1/0`, with a short
  comment in the emitted file.
- **Dotted keys.** Quoted: `["palette.base.zone0"] =`. Bare `name =` only
  when the key matches `^[%a_][%w_]*$`.
- **Don't clobber a broken edit.** `parse` today silently falls to `{}`
  on failure — fine for a machine blob, dangerous for a hand-edited file.
  On `load`/`pcall` failure, print a clear error *and refuse to overwrite*
  on the next save, so a typo doesn't cost the user their file. Caveat to
  accept: an in-*app* save reserialises and drops hand-added comments —
  inherent to any load-then-rewrite round trip.

Bonus: Lua literals are type-unambiguous (`true` vs `"true"` need no
disambiguation), so the disk path sheds the compact format's `\e`
empty-marker hack.

## Staging

Three workstreams. (1) is independent and lands first.

1. **util** — ✅ **done.** `util.prettySerialise` (Lua-literal emitter)
   + `util.prettyUnserialise` (sandboxed `load`, text-only, empty env,
   returns `nil, err` on failure so the store can refuse to overwrite).
   Compact `serialise` / `unserialise` untouched. Pinned by
   `tests/specs/util_pretty_serialise_spec.lua` —
   `prettyUnserialise(prettySerialise(x)) == x` over scalars, nested
   tables, float arrays, edge-whitespace / control strings, dotted and
   keyword keys, sparse integer keys, and inf/nan; the compact
   round-trip stays pinned by `util_serialise_spec.lua`.
2. **pextStore** — 🟡 **extraction done; disk-format switch pending.** The
   storage + context + undo engine is now `pextStore.lua`; `configManager`
   is a schema face over it (a `{ ps }` dep), registering its take/track
   tier blobs with the engine's watcher group. Behaviour-preserving (every
   config / undo / slot / group spec stays green) and pinned in isolation
   by `tests/specs/pext_store_spec.lua`. Storage API is `get` / `assign`
   (+ `At` variants) with scope as a parameter; the context-setter is
   `setTake`. **Commit B (pending):** switch the global disk backend to the
   Lua-literal format + a refuse-to-overwrite guard; until then every scope
   still rides the compact wire format.
3. **dataStore** — per-key blobs over the engine, the registry above,
   the call-site migration. No migration code: pre-beta, persisted shapes
   change freely (see memory `no-legacy-data`).

Later, optional: fold `routingManager`'s meta mirrors and
`paramAutomation`'s track mirror onto the engine — collapsing three
undo implementations into one.

## Decisions settled

- **Module name → `dataStore`.** The storage layer already says "data"
  everywhere it commits to disk or P_EXT — `ctm_data.*`, projext
  `continuum_data`, `ctm_data.txt`, the `dataChanged` signal. Naming the
  module to match makes all of those fall out by consistency, and "data"
  honestly spans both document content and the `paramFrecency` global
  cache — the one resident where "document" is plain wrong. `ds:` survives
  as the receiver abbreviation. (`stateStore` is vaguer; `dataStore`
  mis-describes that global straggler.)

- **Context ownership → `pextStore`.** Bound take/track + the watcher
  baseline live in the engine, single source of truth. Today
  `setContext`/`pollUndo` already co-own `take`/`track` and
  `lastTakeRaw`/`lastTrackRaw`; both faces need that same context. Were
  `configManager` to keep it, `dataStore` would depend *laterally* on the
  other face — the two faces must both depend *down* on the engine, never
  sideways. The lighter `cm:boundTake()`-borrow fork stays rejected.

- **`dataChanged` payload → flat `{scope, name}`, one fire per changed
  key.** Do *not* mirror `configChanged`'s targeted/bulk/reload trio.
  Today `pollUndo` fires a blanket `reload {}` precisely because it diffs
  the whole take/track blob and cannot name the moved key — the per-key
  baseline is the redesign's whole point and *removes* that limitation, so
  importing a reload variant would re-inflict the wound we're healing.
  `ds:set`/`ds:remove` fire one `{scope, name}`; the watcher fires one per
  diverged key on an undo tick. No `bulk` variant — the API surface is all
  single-key (get/set/remove/getAt/setAt), so a batch is just N fires.
  Context rebind is a *separate* signal, not a payload mode: `pextStore`
  emits `contextChanged {}` on setContext/clearTake/setTrack, and both
  faces drop-and-reload their scope caches. Wholesale (`contextChanged`)
  and surgical (`dataChanged`) stay distinct so no subscriber has to
  special-case an empty payload.
