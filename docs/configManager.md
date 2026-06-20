# configManager

Five-tier config store. Reads merge all tiers (most-specific wins); writes
target a single tier. cm is the sole source of truth for valid keys and
owns every table it hands out.

Structural **document data** — keys that live at one scope as content
rather than settings — moved out to `dataStore`; cm now holds only
user-facing config, and the foreign-handle bypass reads/writes
(`readTakeKey`/`writeTrackKey` &c.) moved to `ds:getAt`/`ds:assignAt`. See
`docs/dataStore.md` and `design/archive/persistence.md`.

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

## Colour

**Atoms** are the only RGB values, all under `palette.*`: two tonal ramps
(`base` parchment, `alt` blue, `zone0..zone10`) plus nine flat accents —
the eight solarized hues (`yellow … green`) and a `salmon` regularised to
`alt.zone6`'s chroma+lightness. Nothing else holds an `{r,g,b,a}`.

**Roles** under `colour.*` name the *function* a colour plays and resolve
to an atom — or to another role. Roles are namespaced by audience:
`colour.global.*` (shared), one bucket per page (`colour.tracker.*`,
`colour.sampler.*`, `colour.wiring.*`, `colour.arrange.*`), and
`colour.chrome.*` (toolbar/statusbar/modal/help/editor). Keys stay flat
and dotted so per-key override semantics survive across tiers — a track
setting `colour.tracker.cursor` doesn't wipe the project's other colours.

A role value is `'ref'` or `{'ref', alpha}` (outermost alpha wins). A
`ref` is a palette atom or another role's full key. A bare ref — no
`colour.`/`palette.` prefix — is atom shorthand: `'green'` expands to
`palette.green`, `'base.zone8'` to `palette.base.zone8`. configManager
expands and validates at load; a role holding a raw `{r,g,b,a}` raises.

**Page scoping is enforced, not conventional.** A page role may resolve
only through `palette.*`, `colour.global.*`, or its own page — a
cross-page ref raises at declaration load. The call layer enforces the
same: `chrome.colour(name, scope)` binds a bare name to the painter's
page first, then global; `painter.new(ctx, chrome, transform, page)`
carries that page so call sites pass bare names (`'cursor'`, `'rowBeat'`)
and can't reach another page's roles. Direct `chrome.colour` callers
default `scope` to `chrome`. A name already carrying a namespace
(`'wiring.tooltip.bg'`) passes through verbatim. Resolution walks aliases
in chrome's `resolve`; the golden-section slot hues are the one sanctioned
exception (minted as opaque tokens by `painter.hue`, no name).

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
| global    | Lua literal at `<resource-dir>/continuum-config.lua` |
| project   | `SetProjExtState(0, 'rdm', 'config', …)`           |
| track     | track `P_EXT:ctm_config`                           |
| take      | take `P_EXT:ctm_config`                            |
| transient | none — in-memory only, reset to `{}` on reload     |

The four persisted backends are `pextStore` blobs, addressed `(scope,
slot)` — take/track keyed `ctm_config`, project keyed `config`, global
the disk file. The engine (de)serialises and runs the undo watcher; cm
stays the schema face that prunes unknown keys on load and merges tiers.
See `docs/pextStore.md`.

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
