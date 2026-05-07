# configManager

Five-tier config store. Reads merge all tiers (most-specific wins); writes
target a single tier. cm is the sole source of truth for valid keys and
owns every table it hands out.

## Schema

The valid set of keys is declared inline as `declarations`, an ordered
array of `{ key, default }` pairs. The array form lets **declared-but-nil**
coexist with non-nil defaults without ambiguity: presence in the array
marks a key as valid; the default slot being `nil` simply means no initial
value.

Enforcement is split:

- **In-code use is strict.** `get`/`getAt`/`set`/`remove`/`assign` raise on
  any key not in the schema.
- **Persisted data is tolerant.** Unknown keys read back from disk / ext
  state are silently pruned on load, so a renamed key in a stale project
  file doesn't error.

Colour keys are flat and dotted (`colour.bg`, `colour.rowBeat`, …) rather
than nested. This preserves per-colour override semantics across levels —
a track setting `colour.cursor` doesn't wipe the project's other colours.

The colour keyspace is split by purpose. **Atoms** under `palette.*`
(parchment, used by the tracker grid) and `chrome.*` (neutral, used by
toolbar/popups/modals) are the only place RGB values live. **Roles**
under `colour.*` name the *function* a colour plays and resolve to an
atom — or to another role — by full cm key. One-off colours that earn
no good function name live inline at the role.

A role entry takes one of three forms (resolved by trackerPage's
`resolveColour`):

| Form              | Meaning                                       |
|-------------------|-----------------------------------------------|
| `{r,g,b,a}`       | atom — terminal RGBA                          |
| `'fullKey'`       | pure alias — recursive `cm:get`, alpha inherited |
| `{'fullKey', a}`  | alias with alpha override (outermost wins)   |

## Ownership

cm owns its cache tables. Every read deep-clones on the way out; every
write deep-clones on the way in. Callers never alias cm's state, and
never need to clone themselves — mutating the result of `cm:get` has no
effect on cm.

## Levels & merge

```
global  → project → track → take → transient
less specific ──────────────────→ more specific
```

The merged view is built by starting from schema defaults, then layering
each level's cache in order. A key's resolved value is whichever level's
cache last set it (or the default if none did). `getLevel(key)` walks
the same stack from most to least specific and returns the first level
defining the key, or nil.

`take` and `track` levels require a take context (see below). Without
one they contribute nothing to the merge.

`transient` is the most-specific tier and never persists. It is reserved
for view-layer overrides that should auto-vanish when the script
reloads (e.g. `trackerView`'s match-grid-to-cursor frame override). On
`setContext` the transient cache reloads to empty along with the rest.

## Storage backends

| level     | backend                                            |
|-----------|----------------------------------------------------|
| global    | Lua file at `<script-dir>/ctm_cfg.txt`             |
| project   | `SetProjExtState(0, 'rdm', 'config', …)`           |
| track     | track `P_EXT:ctm_config`                           |
| take      | take `P_EXT:ctm_config`                            |
| transient | none — in-memory only, reset to `{}` on reload     |

The four persisted backends use `util.serialise` / `util.unserialise`
(the shared escaped format). Parse failures fall through to an empty
table.

## Context

`cm:setContext(take)` sets the active take and derives its track from
`GetMediaItemTrack`. It refreshes all four cache tiers and fires a
callback. Passing `nil` clears the take/track context — `global` and
`project` remain available; `getAt('track'|'take', …)` returns an empty
table or nil values.

`cm:clearTake()` and `cm:setTrack(track)` exist for sample view, which
is take-independent: the user picks a track explicitly. `clearTake`
drops the take half of the context and empties the take-tier cache,
leaving track/global/project intact. `setTrack` rebinds the track
context to an arbitrary track (independent of any take) and reloads
the track-tier cache from that track's `P_EXT`. Both fire
`configChanged` with an empty payload, like `setContext`.

## Signals

cm fires one signal, `'configChanged'`. Payload shape varies by call site:

- `{ key = <name>, level = <level> }` — targeted writes (`set`, `remove`).
  Consumers can filter on the keys they depend on, and on `level` to
  distinguish their own writes from others' (`trackerView` uses this to
  skip self-release on its own transient-tier writes).
- `{ level = <level> }` — bulk `assign` (keyless).
- `{}` — `setContext` reload. No `level`; treat as "any key may have changed".

## Conventions

- **util.REMOVE** is honoured only inside `assign(level, updates)` as a
  per-key delete sentinel. `set` and `remove` take explicit arguments.
- **Unknown keys raise** from in-code entry points; from persistence
  they're pruned.
- **Caches are lazy.** First read through any getter triggers a full
  refresh; `setContext` refreshes eagerly.
