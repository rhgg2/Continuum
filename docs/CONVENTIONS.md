# Documentation conventions

Three layers carry information about a module:

1. **Source code** — the `.lua` file. Names and structure say WHAT.
2. **`--@map:` annotations** — single-line invariants and contracts
   embedded in source, surfacing the WHATs the code can't say plainly.
3. **`.map` files** — derived semantic outline produced by
   `tools/map_extract.py`. One per `.lua`. Read first; the source second.
4. **`docs/<file>.md`** — prose. WHY only: the model behind the design,
   incidents the shape encodes, cross-cutting invariants worth a
   paragraph rather than a single line.

The doc layer never repeats the API surface. Signatures, contracts,
shapes, and signals belong in source + `.map`.

## Audience

Reads Lua and understands local code. Doesn't need to be told what a
function does if its name says it. Does need the WHYs that aren't visible
from any single call site — model, history, and cross-file constraints.

## Shape of a file doc

Thematic prose, nothing else. Include only what applies:

- one-line purpose at the top
- the model — identity, persistence, lifecycle, ownership
- mutation/locking contract, if there is one
- the *why* behind any invariant complex enough that the one-line
  `--@map:invariant` leaves a question — incidents that motivated it,
  alternatives considered, how it interacts with other modules
- cross-cut concerns that span files (the `time` and `pitch` model in
  `docs/timing.md` and `docs/tuning.md` are the templates)
- wire-format / external-API quirks worth a paragraph

If the only thing a section can say is what a `--@map:` annotation
already says, drop the section. The `.map` is the API reference.

## Shape of the source file

- **Header:** single line, `-- See docs/<file>.md for the model.`
  No docstring essay. No per-function preambles.
- **`--@map:` annotations:** attach to the construct they describe.
  See `tools/map_extract.py` for the recognised kinds (`:invariant`,
  `:contract`, `:shape`, `:emits`; `?:` variant for inferred).
- **Inline comments:** only where they encode a non-obvious WHY.
  Good: "notation event encodes (chan, pitch) at ppq, so keep it in sync",
  "rescan: step 3 inserted notation events, so uuidIdx values are stale",
  "Writing an empty string effectively removes the extension data".
  Bad: "update the existing note", "get cc events", "create new note".
- **Section dividers** are fine if they aid navigation in a long file; drop
  them if the function names make them redundant. Use them to label *logical
  groups* of adjacent functions, not to decorate single functions. Two
  levels, stacked by scope — dash counts are exact, casing is load-bearing:
  - `---------- NAME` — 10 dashes, ALL CAPS. Top-level partitions
    (e.g. `PRIVATE`, `PUBLIC`).
  - `----- Name` — 5 dashes, Title Case. Subsections within a partition
    (e.g. `Swing`, `Update manager`, `Rebuild`, `Transport`, `Mutation`,
    `Lifecycle`).
  Labels are one line, no trailing punctuation, no prose.
- Single-word comments restating the next line's effect are always out.

## Workflow

1. Source change first. Update or add `--@map:` annotations alongside.
2. The `.map` file regenerates via the post-edit hook.
3. If the change touches anything `docs/<file>.md` describes, update the
   doc in the same pass.

## Keeping docs in sync

Doc updates are required when:

- a cross-cut invariant that a reader couldn't reconstruct from one
  function changes — update the prose
- the *model* shifts (a new tier, a new lifecycle stage, a renamed
  concept) — update the prose

Doc updates are **not** required when:

- a public method is added, removed, or renamed — `.map` carries it
- a `--@map:contract` body changes — `.map` carries it
- pure internal refactors that preserve every documented property
