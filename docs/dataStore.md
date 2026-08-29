# dataStore

**Per-key storage for document data.** Document data is persisted data
that the code writes so that its own structures survive the session, by
contrast with config, the parameters a user sets. dataStore is the
second face over pextStore, beside configManager (`docs/pextStore.md`).

## Registry

1. Each document-data key lives at exactly one **scope** — take,
   track, project or global.

1. The **registry** maps each name to its scope, and is the sole truth
   for which names exist. It is closed: a new document-data key is a
   new registry line.

1. An unknown name raises at every entry point.

1. The global file is the exception. It holds every global key in one
   table, so it can carry a name absent from the registry. Such a name
   is silently dropped on load.

## Per-key blobs

1. Each take or track key is its own `P_EXT` blob, named
   `ctm_data.<name>`.

1. The take it sits on is the one pextStore holds **bound**, and the
   track is the one that take is on (`docs/pextStore.md`).

1. A write therefore serialises only its own key. An undo baseline is
   likewise per key, so the watcher can name the key a rewind touched (§
   Signals).

1. A project key is a slot in the engine's projext section. Global is
   one disk file, `continuum-data.lua`.

## Signals

1. dataStore fires one signal, `dataChanged`, carrying `{ scope, name }`,
   once per changed key. A subscriber wakes only for its own keys.

1. An undo tick adds `invalidate = true` to each rewound key's fire, so
   a subscriber can tell a rewind from a live edit.

1. Take and track keys ride pextStore's undo watcher, as do project
   keys, except those in `PROJECT_PLAIN`: `guardedTrack` follows live
   flags and would desync if rewound. Global stays outside undo.

## Caches

1. dataStore holds one lazily loaded cache per scope, and deep-clones
   on the way in and out, so no caller aliases its state.

1. pextStore's `contextChanged` drops the take and track caches, and
   the next read reloads against the new take or track. Project and
   global are context-free and survive.

## Foreign-handle access

1. `getAt` and `assignAt` address a take or track other than the bound
   one, so arrangeManager, sampleManager and paramAutomation can reach
   every take and track in the project without rebinding.

1. A foreign write refreshes the cache and fires `dataChanged` only
   when the handle is the bound one, so a write aimed elsewhere leaves
   the current view alone.
