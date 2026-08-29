# Documentation conventions

**Four layers carry information about a module.**

1. Source code — the `.lua` file. Names and structure say *what*.
2. `--KIND:` annotations — one-liners embedded in the source, for
   invariants and contracts the code does not carry. Five kinds:
   `--invariant:`, `--contract:`, `--shape:`, `--emits:`, `--reaper:`.
3. `.map` files — a semantic outline derived by
   `tools/map_extract.py`, one per `.lua`. Read the map first, the
   source second.
4. `docs/<file>.md` — ahistorical prose in the register of
   `docs/STYLE.md`: the model behind the design, and the non-local
   rationale for *why* the code has to be as it is.

## Shape of a file doc

1. A file doc carries what the source and its annotations cannot.

1. It opens with a one-line purpose, then states the model — identity,
   persistence, lifecycle, ownership.

1. Beyond that it gives the *why* behind any invariant complex enough
   that the one-line `--invariant:` leaves a question.

1. A concern spanning several files gets its own doc, which every file
   doc it touches cites. Time and pitch are the templates:
   `docs/timing.md` and `docs/tuning.md`.

## Length discipline for comments

1. An `--invariant:`, `--contract:`, `--emits:` or `--reaper:` line is
   one line of ≤100 characters; aim for 90.

1. `--shape:` describes a table — field names, types and nesting, and
   no prose. Its cap is 400 characters, since a field list
   legitimately enumerates more than a rule states.

1. Other comment runs cap at 2 lines. Anything longer belongs in
   `docs/<file>.md`, with a one-line pointer at the site (for example
   `-- see docs/<file>.md § <section>`).

1. A pointer names `docs/`, not `design/`, since the doc layer is the
   one that persists. A live plan's design doc is the exception: its
   model has nowhere else to be yet.

1. Specs under `tests/` are exempt from the run cap. A spec's file
   header and the preamble above each case are its documentation, and
   run as long as they need. The `--KIND:` caps still apply there.

## Shape of a source file

1. The file opens with a single-line header, `-- See docs/<file>.md
   for the model.`

1. `--KIND:` annotations attach to the construct they describe.

1. Inline comments appear only where they encode a non-obvious *why*.

1. Section dividers label logical groups of adjacent functions in a
   long file. There are two levels, stacked by scope:

   - `---------- NAME` — 10 dashes, all caps, for top-level partitions
     such as `PRIVATE` and `PUBLIC`.
   - `----- Name` — 5 dashes, for subsections within a partition, such
     as `Swing`, `Rebuild` or `Lifecycle`.

1. A divider may sit indented inside a long function or table, where it
   labels a group of statements or of cases.

1. A divider label is capitalised on the same rule as a heading
   (`docs/STYLE.md` § Structure), so one that begins with an identifier
   keeps its spelling — `----- wm pass-through`, `----- fxNote
   reconciliation`, and `manifest.lua`'s `----- tracker` for the scope
   key.

1. A divider label is one line, with no trailing punctuation. It may
   carry a single clause after an em-dash or a colon, saying what the
   group holds or why it exists.

1. A divider never spans two lines. Prose that long is a *why*-comment,
   or belongs in `docs/`.

## Workflow

1. The source changes first, with its `--KIND:` annotations updated or
   added alongside.

1. A post-edit hook regenerates the `.map`, rebuilding every source
   newer than its map.

1. Where the change touches anything `docs/<file>.md` describes, the
   doc is updated in the same pass.

1. `tools/comment_hygiene.py` checks the caps above against the diff,
   at session start and as a commit is drafted.
