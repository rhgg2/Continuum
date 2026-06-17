# dataStore

Per-key **document-data** storage — the second face over `pextStore`,
beside `configManager`. Where cm holds user-facing *settings* (schema,
five-tier merge, defaults), ds holds the project's structural *content*:
mirror groups, sampler/arrange slot palettes, CV bindings, the swing map,
per-take display columns, mix state. See `design/archive/persistence.md` for why
the two were split.

## Document data is not config

A config key resolves through tiers — a global default a project/track/
take can override — and always has a meaningful default. Document data
lives at exactly **one scope** (take, track, project, or global), has no
default beyond *absent*, and is never overridden from a higher tier. The
word is **scope**, not tier, on purpose: scopes are independent addresses,
not a merge stack. `groups` on this take has nothing to do with `groups`
anywhere else.

Before the split these keys rode cm's schema purely so `pruneUnknown`
wouldn't drop them on load — a junk drawer. They never participated in the
merge. ds gives them a home that matches what they are.

## Registry, not open schema

The `registry` (`name → scope`) is the sole truth for valid data keys and
where each lives. Typos raise on every entry point, exactly as cm's schema
does for config — the "unknowns raise" safety is preserved, just owned by
the right module now. It is a closed table: adding a document-data key
means adding a registry line.

## Per-key blobs

Each take/track `(scope, name)` is its own P_EXT key (`ctm_data.<name>`),
not a slice of one shared blob. Two reasons, both load-bearing:

- **Write isolation.** A write serialises only its own key. One shared
  blob would reserialise the large `groups` tree every time a CV binding
  moved.
- **Targeted signals.** A per-key undo baseline lets the watcher name
  exactly which key an undo tick rewound, so it fires `dataChanged{scope,
  name}` — each manager wakes only for its own namespace.

`project` reuses the engine's projext section, slot = name. `global` is the
exception: one disk file (`continuum-data.lua`), since its lone resident
(`paramFrecency`) is small and per-key files there would be ceremony.

## Signals

ds fires one signal, `dataChanged`, with a flat `{ scope, name }` payload —
one fire per changed key, never a blanket reload. This is deliberate (see
`design/archive/persistence.md` § Decisions): cm's `configChanged{}` reload exists
only because `pollUndo` couldn't name the moved key; the per-key baseline
removes that limitation, so importing a reload variant would re-inflict the
wound. An undo tick adds `invalidate = true` to each rewound key's fire, so
subscribers can tell a rewind from a live edit.

Context rebind is a *separate* signal: `pextStore` emits `contextChanged`,
and ds drops its take/track caches so the next read reloads against the new
take/track. `project` and `global` are context-free and survive untouched.

## Foreign-handle access

`getAt(handle, name)` / `assignAt(handle, name, value)` read and write an
arbitrary take/track off the bound context — how `arrangeManager`,
`sampleManager`, and `paramAutomation` reach every project take/track
without rebinding (and firing reload churn). A foreign **write** refreshes
the cache and fires `dataChanged` *only* when it lands on the bound handle,
so a write aimed at another take never disturbs the current view. These
replace cm's old `readTakeKey`/`readTrackKey`/`writeTakeKey`/`writeTrackKey`
bypass seams, now removed.
