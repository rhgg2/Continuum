---
name: coding
description: House dialect and test design. Dropped in by hand when discussion turns into code.
disable-model-invocation: true
allowed-tools: Bash(python3 ${CLAUDE_PROJECT_DIR}/.claude/context/test-baseline.py)
---

!`python3 ${CLAUDE_PROJECT_DIR}/.claude/context/test-baseline.py`

"The time for talking is over: now is the time to code" - and these
are the house guidelines for doing so.

## Dialect

1. The repo is closures-over-state, not objects-with-methods, and it
   has no OO furniture: no underscore-prefixed "private" names, no
   `setmetatable` inheritance or metatable-as-class, no `ClassName`
   UpperCamelCase for modules or constructors.

1. Things are scoped tightly, with private helpers wrapped in `local
   fn do ... end`.

1. Registry tables are one line per entry. The `registerAll{...}`
   command table is a scannable verb → `{fn, undoDesc}` map, so
   multi-line bodies are extracted to a named `local function` rather
   than inlining a closure that breaks the alignment.

1. Tables crossing a pass boundary get role-named fields (`xLo`/`xHi`,
   `chanLeft`, `pitchWidth`, `viewRows`) rather than bare coordinates.

1. Section banners: `----- Name`. Major: `---------- PUBLIC`.

## Comments

1. `--KIND:` annotations in source carry single-line claims about the
   construct they sit above. `docs/CONVENTIONS.md` has the full rules;
   these are the operative ones.

1. `--pre:` states what the caller is obliged to satisfy before
   calling, `--post:` what the callee guarantees given the pre, and
   `--invariant:` what the callee expects to hold and guarantees to
   preserve. Each states its claim alone, with no commentary.

1. Each states a predicate with a non-trivial truth-value. One that
   does not constrain behaviour belongs in `--shape:` or `docs/`. Note
   that `none` is a predicate with a *trivial* truth value.
   
1. Use Boolean operators, but carefully. "iff", "if" and "only if"
   have precise meanings; use reason to determine which the predicate
   needs. Parenthesise to avoid ambiguity. 

1. The predicates do not restate the call graph or module
   dependencies, which `.map` derives. Nor do they restate the code,
   holding tautologically under the callee's current implementation
   but failing under any rewrite.

1. Rather they state non-local or caller-facing constraints: an
   ownership tag, a copy made somewhere else, a silent no-op the
   caller cannot see happen, a promise that binds the next edit.

1. `pre` and `post` want a callable to attach to; a module
   takes only `invariant`.

1. A post states its own callable's guarantee. A property of the system
   around it is a module invariant, however apt the site.

1. `result` names the return, an iterator being `result = (…)
   iterator` with the ownership word on what it yields. `fresh result`
   aliases no callee state and is the caller's; `live result` is
   aliased and safely mutable; `unsafe result` is aliased, read-only
   and of ephemeral validity.
   
1. State change is assignment, `t[k] := v`, right-hand names being
   entry values. A conditional post is `(C) → consequence`, and the
   inert case leads, `no-op iff C; else …`. A boolean is `result =
   (P)`. One claim per line.

1. `--contract:` is the legacy kind pre/post replace. Convert one when
   you touch it; don't write new ones.

1. `--pre:`, `--post:`, `--invariant:`, `--contract:`, `--emits:`,
   `--reaper:`: one line, capped at 100 chars, aim for 90.

1. `--shape:` describes the shape of a table: field names, types, and
   nesting, but not prose; capped at 400 chars.

1. For specs under `tests/`, the file header and the preamble above each
   case are the documentation, and can run as long as they need to.

1. Other comment runs cap at 2 lines. Anything longer belongs in
   `docs/<file>.md` with a one-line pointer at the site (`-- see
   docs/<file>.md § <section>`).

## util.lua

The idioms that recur in the code.

- `util.add(t, v)` for `t[#t+1] = v`
- `util.bucket(t, k, v)` appends `v` to a table under `t[k]`, creating
  it if `nil`.
- `util.assign(t1, t2)` merges keys of `t2` into `t1`; clear a key with
  the sentinel `util.REMOVE`.
- `util.clone(src, exclude)` (shallow) and `util.deepClone` (deep).
- `util.deepEq(t1, t2)`.
- `util.key(...)` builds an opaque NUL-joined compound key; also
  `util.keys(t)` for the key list of a table.
- For ppq-sorted dense tables: `util.seek` for the event before/after a
  ppq, `util.between` for a half-open window, `util.insertSorted` to
  splice without a re-sort.
- `util.isNote(e)` is the note/CC test.
- Scalars: `util.clamp`, `util.round(n, to)`.
- `util.installHooks(owner)` installs the subscribe/unsubscribe/forward
  protocol on `owner` and returns its `fire`.
- `util.atomic(label, fn)` wraps a call as one REAPER undo block.
- `util.instantiate(name, deps)` runs a factory module, and is the test
  seam via `util._stubs`.
- Persistence: `util.serialise`/`unserialise` for the escaped P_EXT wire
  form, `util.prettySerialise`/`prettyUnserialise` for a hand-editable
  Lua literal.

## Tests

1. `mcp__continuum_tests__lua_test_run`. Specs live in `tests/specs/`
   and register in `tests/run.lua`. `docs/tests.md` holds the
   mechanism — what the harness builds, what fakeReaper guarantees,
   where the seams are.

1. Bugfixes go red-first; refactors pin the invariant. For a new
   feature, stub the function so the red comes from an assertion
   rather than a nil call — an unstubbed red aborts every test before
   any assertion runs, so it tells you nothing about what they check.

## Writing good tests

1. A test enforces the model — what `docs/` states and
   `--pre:`/`--post:`/ `--invariant:` annotate — not its realisation
   in code. Every test should pin a sentence of the model; if no such
   sentence exists, either the model is under-documented or you are
   about to pin the implementation. This is checkable before writing
   anything.

1. A good test fails iff the sentence it pins breaks. Each direction
   has a failure mode: a test that cannot fail is **tautological** (a
   false green); one that fails for unrelated reasons is **brittle**
   (test churn). Both mean the test is coupled to something other than
   the model.

Against tautology:

1. Guard non-triviality. An assertion over a batch is vacuous when the
   batch is empty; a comparison, when both sides are nil. Assert the
   precondition.

1. Produce expected values by independent means, and not by restating
   the module's constants or logic.

Against brittleness:

1. Assert the coarsest relation the contract fixes: containment,
   order, invariance, the difference between two runs. A whole-record
   `deepEq` is brittle when one field matters. Geometry, layout and
   formatting almost always yield to relations.

1. Seed through the production path (`tm:addEvent`, not hand-built
   tables), so fixtures move when the representation does.

Perturbation probes both directions at once: vary what should not
matter and expect green; break what should and expect red.
`mcp__continuum_perturb__spec_perturb` automates this. No single test
catches every failure mode — a well-designed spec group does.

Sometimes brittleness is unavoidable because the real behaviour is the
only oracle. Then the test must carry the mechanism for regenerating
its ground truth, so a legitimate change never means hand-patching.
