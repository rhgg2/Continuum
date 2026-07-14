# Documentation conventions

Three layers carry information about a module:

1. **Source code** — the `.lua` file. Names and structure say WHAT.
2. **`--KIND:` annotations** — single-line invariants and contracts
   embedded in source, surfacing the WHATs the code can't say plainly.
   Five kinds: `--invariant:`, `--contract:`, `--shape:`,
   `--emits:`, `--reaper:`. A leading `?` (`--?invariant:`) marks
   the line as inferred rather than doc-grounded.
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
  `--invariant:` leaves a question — incidents that motivated it,
  alternatives considered, how it interacts with other modules
- cross-cut concerns that span files (the `time` and `pitch` model in
  `docs/timing.md` and `docs/tuning.md` are the templates)
- wire-format / external-API quirks worth a paragraph

If the only thing a section can say is what a `--KIND:` annotation
already says, drop the section. The `.map` is the API reference.

## The annotation/doc boundary

A non-obvious invariant is itself a kind of WHY, so the same fact has
a plausible home in either layer. They are a **pair, not
alternatives**: the `--KIND:` line *states* the invariant tersely; the
doc explains *why it exists and what breaks without it*. Two tests
settle every borderline case:

- If a doc paragraph collapses to a one-liner with no loss, it was an
  annotation — move it.
- If an annotation isn't believable without a paragraph of
  justification, that justification belongs in the doc — and the
  annotation stays, stating the rule the doc now defends.

The boundary is semantic, not a length test. Never split one fact
across both layers as duplicated prose.

## Length discipline

One line, ≤100 characters, aim for 90. Applies to `--invariant:`,
`--contract:`, `--emits:`, `--reaper:`. `--shape:` is the exception —
shapes are allowed the length needed to state the shape; a field list
legitimately enumerates more than a rule states.

`--shape:` describes the **shape** of a table: field names, types, and
nesting. Nothing else. It is not a place to park rationale, examples,
edge-case notes, or prose that didn't find a home — those go in
`docs/<file>.md`. The length exemption exists because a 30-field record
legitimately needs 30 lines, not because shapes are an escape hatch for
oversized annotations. If a `--shape:` line is doing anything other than
naming a field and its type/sub-shape, move that content to the doc.

Inline comments cap at **2 lines**. A WHY that needs more belongs in
`docs/<file>.md` with a one-line pointer at the site (e.g.
`-- see docs/<file>.md § <section>`).

One test settles every case: if an annotation wants a second line, or
a comment a third, the constraint is either two of them (split) or a
model concern (the doc's job). The `.map` is the API reference; prose
lives in the doc.

Specs under `tests/` are the one exception to the 2-line comment cap.
There the file header and the preamble above each case *are* the
documentation — `map/specs/<spec>.map` is derived from them, and a case
whose intent needs a paragraph should have one. The `--KIND:` length
caps still apply. `tools/comment_hygiene.py` enforces this split.

## `--contract:` discipline

A `--contract:` line states **non-trivial pre- and post-conditions** —
what the caller must guarantee on entry, what the function guarantees
on exit, what it mutates, what it returns when inputs are degenerate.
It is **not** a prose paraphrase of the function's behaviour: the name
and body already say what the function does. If the line reads like an
English restatement of the code ("computes the swung ppq for a row"),
delete it.

Three rules, applied hard:

1. **Pre/post only.** Conditions that hold at the boundary, not a
   walkthrough of the implementation. Good: `caller holds the mm
   lock; returns nil if row is off-grid`. Bad: `iterates channels
   and accumulates onsets`.
2. **Not behaviour-as-prose.** If the contract collapses to "does
   what the name says", there is no contract — drop the annotation.
   A contract earns its line only when something non-obvious binds
   the caller or the result.
3. **Length per § Length discipline.** One line. If it won't fit,
   split or move the model concern to `docs/<file>.md` and leave a
   terse `--contract:` pointing at the rule.

## Shape of the source file

- **Header:** single line, `-- See docs/<file>.md for the model.`
  No docstring essay. No per-function preambles.
- **`--KIND:` annotations:** attach to the construct they describe.
  Five recognised kinds: `--invariant:`, `--contract:`, `--shape:`,
  `--emits:`, `--reaper:`. Prefix with `?` (`--?invariant:`) for
  inferred. See `tools/map_extract.py` for attachment rules.
- **Inline comments:** only where they encode a non-obvious WHY.
  Good: "notation event encodes (chan, pitch) at ppq, so keep it in sync",
  "rescan: step 3 inserted notation events, so uuidIdx values are stale",
  "Writing an empty string effectively removes the extension data".
  Bad: "update the existing note", "get cc events", "create new note".
  Length per § Length discipline: 2-line cap, then relocate to the doc.
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

1. Source change first. Update or add `--KIND:` annotations alongside.
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
- a `--contract:` body changes — `.map` carries it
- pure internal refactors that preserve every documented property
