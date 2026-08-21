# library

Shared project/library tier logic over a configManager handle. `library.lua`
is instantiated once per named library (`'swings'`, `'tempers'`) and exposes
the same small API — names, get, modified, localize, publish, revert,
seed/reload — over whichever cm tier pair backs that library.

## Tiers

Two tiers back every named library: project (`cm:getAt('project', key)`) and
library (`cm:getAt('global', key)`). Resolution is project over library;
`mergeTiers` floors realisation on the schema defaults beneath both.

The factory catalogue (`cm:defaultFor`) is a **seed source, not a resolution
tier**. `seedIfEmpty` stocks an empty library tier from it once, at startup;
`reloadFactory` (via `reloadPlan`) re-imports it on demand, so a fresh project
never resolves against factory directly and a stale library copy only picks up
factory changes when asked.

## Editing invariant

Every editing write lands at the project tier. Selecting a library row and
touching anything forks it to project first — `forkToProject` is `localize`
plus a handle on the fresh project copy — inside the edit's own undo point,
then writes there. Accidental library edits are structurally impossible
rather than merely discouraged: the library changes only through the explicit
publish / import / delete verbs.

## Verbs

One vocabulary across every named library, so the swing and temper editors
share it:

- **save** (`save`) — author a name into the project tier, overwriting any
  project copy standing under it and leaving the library copy it shadows
  alone. The only verb here that *creates*: every other one moves a name that
  already exists. Synthetic names never author.
- **localize** (`localize`, `forkToProject`) — copy-on-use: picking an entry
  for a take or channel copies it into project if absent. A synthetic name or
  an existing project copy is a no-op.
- **publish** (`publish`) — project copy → library, in the library form of that
  copy. `publishOverwrites` reports when it would clobber a *divergent* library
  copy so the editor can confirm first; a fresh name or an identical copy
  publishes silently.
- **revert** (`revert`) — library copy → project, whole, discarding project
  drift and any project-tier-only state the copy carried. No-op when there is
  no library copy to fall back to.
- **tidy** (`tidy`) — drop project entries that deep-equal their library
  source and aren't in the passed `inUse` set, in one undo entry; returns the
  names removed. It compares whole, since it destroys a project copy: identity,
  not identity of the library form.
- **delete** (`delete`) — remove a name from the `project` or `global`
  (library) tier. Synthetic names never delete.
- **import** (`importFactory`, `reloadPlan`, `factoryOverwrites`) — copy
  factory entries into the *library*, never straight to project. `reloadPlan`
  splits the catalogue into `add` (missing) and `overwrite` (present but
  divergent) so the editor lands the additions silently and confirms each
  overwrite.

## Modified badge

`modified` is true when a project copy exists, shadows a same-named library
source, and differs from it (`util.deepEq`). Divergence is measured between the
library *forms* of the two copies, not the copies: a key may carry
project-tier-only state — a temper's root places a scale, and placing it is not
drifting from it. The form is injected per key as `libraryForm`, so the library
never learns what the state means. Reducing the library copy too is not
symmetry for its own sake: for tempers the form re-derives, which is what lets
a copy stored before a derived field existed, or stored at a coarser float
precision, still read as the same scale. Both copies are local, so it is computed on demand — no
provenance metadata, no hashes. The tree and pickers
render it as a dirty marker on the project row.

## Synthetic floor

`synthetic` names a per-key floor (e.g. `{ identity = true }` for swings,
`{ ['12EDO'] = true }` for tempers) that always resolves but is never listed,
localized, published, or deleted — it exists so a library can never be
degenerate even before it has been seeded or authored into.
