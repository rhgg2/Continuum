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

The repo is closures-over-state, not objects-with-methods, and it has
no OO furniture: no underscore-prefixed "private" names, no
`setmetatable` inheritance or metatable-as-class, no `ClassName`
UpperCamelCase for modules or constructors.

Things are scoped tightly, with private helpers wrapped in `local fn
do ... end`.

Registry tables are one line per entry. The `registerAll{...}` command
table is a scannable verb → `{fn, undoDesc}` map, so multi-line bodies
are extracted to a named `local function` rather than inlining a
closure that breaks the alignment.

Tables crossing a pass boundary get role-named fields (`xLo`/`xHi`,
`chanLeft`, `pitchWidth`, `viewRows`) rather than bare coordinates.

Section banners: `----- Name`. Major: `---------- PUBLIC`.

## Comments

1. `--KIND:` annotations in source carry single-line invariants,
   contracts, shapes, emitted signals and REAPER touchpoints. 

1. `--invariant:`, `--contract:`, `--emits:`, `--reaper:`: one line,
   capped at 100 chars, aim for 90.

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

`mcp__continuum_tests__lua_test_run`. Specs live in `tests/specs/` and
register in `tests/run.lua`. `docs/tests.md` holds the mechanism —
what the harness builds, what fakeReaper guarantees, where the seams
are.

Bugfixes go red-first; refactors pin the invariant. For a new feature,
stub the function so the red comes from an assertion rather than a nil
call — an unstubbed red aborts every test before any assertion runs,
so it tells you nothing about what they check.

## Writing good tests

A test enforces the model — what `docs/` states and `--contract:`/
`--invariant:` annotate — not its realisation in code. Every test
should pin a sentence of the model; if no such sentence exists, either
the model is under-documented or you are about to pin the
implementation. This is checkable before writing anything.

A good test fails iff the sentence it pins breaks. Each direction has
a failure mode: a test that cannot fail is **tautological** (a false
green); one that fails for unrelated reasons is **brittle** (test
churn). Both mean the test is coupled to something other than the
model.

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
