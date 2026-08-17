# Documentation conventions

Four layers carry information about a module:

1. Source code — the `.lua` file. Names and structure say WHAT.
2. `--KIND:` annotations — source-embedded one-liners for
   invariants and contracts not carried by the code. Five kinds:
   `--invariant:`, `--contract:`, `--shape:`, `--emits:`, `--reaper:`.
3. `.map` files — derived semantic outline produced by
   `tools/map_extract.py`. One per `.lua`. Read first; the source
   second.
4. `docs/<file>.md` — prose. WHY only: the model behind the design,
   incidents the shape encodes, cross-cutting invariants worth a
   paragraph rather than a single line.

The doc layer doesn't restate the API surface. Signatures, contracts,
shapes, and signals belong in source + `.map`.

## Shape of a file doc

Thematic prose following `docs/STYLE.md`, with:

- one-line purpose at the top
- the model — identity, persistence, lifecycle, ownership
- the *why* behind any invariant complex enough that the one-line
  `--invariant:` leaves a question.
- concerns that span files (the `time` and `pitch` model in
  `docs/timing.md` and `docs/tuning.md` are the templates)

## Length discipline for annotations

For `--invariant:`, `--contract:`, `--emits:`, `--reaper:`: one line,
≤100 characters, aim for 90.

`--shape:` describes the shape of a table: field names, types, and
nesting, but not prose. These are not length-capped, since a field
list legitimately enumerates more than a rule states.

For specs under `tests/`, the file header and the preamble above each
case are the documentation, and can run as long as they need to.

Other comment runs cap at 2 lines. Anything longer belongs in
`docs/<file>.md` with a one-line pointer at the site (e.g. `-- see
docs/<file>.md § <section>`).

## Shape of a source file

- Single-line header, `-- See docs/<file>.md for the model.`
- `--KIND:` annotations attach to the construct they describe.
- Inline comments only where they encode a non-obvious WHY.
- Section dividers are fine if they aid navigation in a long file. Use
  them to label logical groups of adjacent functions. Two levels,
  stacked by scope:
  - `---------- NAME` — 10 dashes, ALL CAPS. Top-level partitions
    (e.g. `PRIVATE`, `PUBLIC`).
  - `----- Name` — 5 dashes, Title Case. Subsections within a partition
    (e.g. `Swing`, `Update manager`, `Rebuild`, `Transport`, `Mutation`,
    `Lifecycle`).
  Labels are one line, no trailing punctuation, no prose.

## Workflow

1. Source change first. Update or add `--KIND:` annotations alongside.
2. The `.map` file regenerates via the post-edit hook, which rebuilds
   every source newer than its map.
3. If the change touches anything `docs/<file>.md` describes, update
   the doc in the same pass.
