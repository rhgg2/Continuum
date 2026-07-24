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
tier** — see `docs/decisions.md` § 2026-07-24 for why this replaced an
earlier live-factory-tier model. `seedIfEmpty` stocks an empty library tier
from it once, at startup; `reloadFactory` (via `reloadPlan`) re-imports it on
demand, so a fresh project never resolves against factory directly and a
stale library copy only picks up factory changes when asked.

## Synthetic floor

`synthetic` names a per-key floor (e.g. `{ identity = true }` for swings,
`{ ['12EDO'] = true }` for tempers) that always resolves but is never listed,
localized, published, or deleted — it exists so a library can never be
degenerate even before it has been seeded or authored into.
