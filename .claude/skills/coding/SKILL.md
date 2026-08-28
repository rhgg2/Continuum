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

Section banners: `----- Name`. Major: `----------- PUBLIC`.

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

A good test fails if and only if the thing it names breaks. One which
cannot fail is **tautological**, and a false green, and one which
fails for unrelated reasons is **brittle**, and leads to test churn.

To avoid tautology:

1. Guard against vacuous tests. An assertion over a batch may be
   tautological if the batch is empty, and a comparison tautological
   when both sides are nil. Guard against this by asserting the
   non-triviality as a precondition.

1. Perturbation-test. A single test may not catch every mode of
   failure; a well-designed spec group will.
   `mcp__continuum_perturb__spec_perturb` gives you a precise answer.

To avoid brittleness:

1. Prefer second computations to literals. A constant in an assertion
   is brittle. If the expected value can be produced by another route,
   use that as an oracle.

1. Compare under the coarsest relation the contract fixes. A `deepEq`
   against a whole record is brittle if only one field is relevant.
   Tolerances or predicates may do the same work, and also help to
   clarify what the test contract actually is.

1. Seed through the production path. For example, add notes via
   `tm:addEvent`, which follows the production representation when it
   moves and applies the correct substrate.

1. Perturbation-test. Change constants or literals which should have
   no bearing on the property under test, and check nothing goes red.
   Again, apply `mcp__continuum_perturb__spec_perturb`.

Sometimes, brittleness is unavoidable: the real behaviour is the only
oracle. Best practice in this case is to ensure that the test includes
the mechanism for regenerating its ground truth, so that hand-patching
is not necessary.
