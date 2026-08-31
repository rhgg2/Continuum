# Documentation conventions

**Four layers carry information about a module.**

1. Source code — the `.lua` file. Names and structure say *what*.
2. `--KIND:` annotations — one-liners embedded in the source, stating
   claims the code does not carry. Seven kinds: `--pre:`, `--post:`,
   `--invariant:`, `--shape:`, `--emits:`, `--reaper:`, and the legacy
   `--contract:` that pre and post replace.
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

## Contract annotations

1. Three kinds state code contracts on callables.

   - `--pre:` states predicates that a caller is obliged to satisfy
     before calling.
     
   - `--post:` states predicates the callee guarantees to satisfy,
     given the pre.
     
   - `--invariant:` states predicates that the callee expects to hold,
     and guarantees to preserve.

1. A predicate is something which has a clear truth-value; if it
   doesn't, it's not a predicate.

1. Use Boolean operators correctly. "iff", "if" and "only if" have
   precise meanings; reason it through to determine which expresses
   the predicate correctly.

1. A list reproducing an expression from the body describes rather than
   constrains, whichever kind it is written as.

1. There is no `--pre: none`. An absent obligation is not an obligation.

1. Contract annotations don't restate the call graph or module
   dependencies, which are derivable from `.map`.

1. They also do not restate the code, so that they hold tautologically
   under the callee's current implementation, but fail under any
   rewrite.

1. Rather, they state non-local or caller-facing constraints: an
   ownership tag, a copy made somewhere else, a silent no-op the
   caller cannot see happen, a promise that binds the next edit.

1. A post states its own callable's guarantee. A property of the system
   around it is a module invariant, however apt the site.

1. A module may also carry `invariant` annotations, which state
   predicates guaranteed to be preserved throughout the module.
   
1. `--contract:` is a legacy annotation type, and not used in new
   code.

## Predicate notation

1. `result` names the return, `result.field` its parts. An iterator is
   `result = (…) iterator`, and an ownership word there qualifies what
   it yields rather than the iterator itself.

1. A table result declares its ownership. `fresh result` promises to
   alias no callee state, and is wholly owned by the caller. `live
   result` signals mutable, aliasing access to live state. `unsafe
   result` may be read on return and nothing else — writing to it
   corrupts its owner, and retaining it outlives its validity.

1. Change of state is an assignment: `project[name] := library[name]`.
   Names on the right denote entry values and on the left exit values,
   so an increment reads `row := row + cm.advanceBy`.

1. The inert case leads: `no-op iff <condition>; else <assignment>`. A
   compound antecedent takes parentheses: `(t has no non-structural
   key) → msg.plain := true`.

1. A post gives its condition and its consequence and stops. A further
   consequence that belongs to another callable is that callable's
   post, not a tail on this one.

1. A boolean result is an equation, `result = (P)`.

1. Ordinary mathematical notation carries the rest — `iff`, `→`, `∈`,
   `∉`, `≠`, `\`, `sorted(…)`, `{ n ∈ S : P }`. A line may bind a name
   for the line below it, as `S = factory(key) \ synthetic(key)`.

1. One claim per line. Several lines is fine

## Length discipline for comments

1. A `--pre:`, `--post:`, `--invariant:`, `--contract:`, `--emits:` or
   `--reaper:` line is one line of ≤100 characters; aim for 90.

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
