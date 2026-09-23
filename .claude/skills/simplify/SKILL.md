---
name: simplify
description: Simplify a system's architecture
disable-model-invocation: true
---

Survey a subsystem for potential simplifications that improve clarity.
The scope will be handed to you by the invocation.

## 1. Research

Read the given scope. If you do not have line numbers, dispatch an
Explore agent whose only purpose is to return tight line ranges. 

## 2. The state

The goal of this first step is to determine:

1. The inputs, the working state and the outputs.
1. Who owns each of these data.

If the same data is collated several times in slightly different
forms, or spread over a long chain of indirections, that is a problem
to be solved.

## 3. The control flow

The goal here is to determine, at a high level:

1. What each function in the subsystem does
1. Whether it merits being a function of its own

A function that's called exactly once is not necessarily helpful,
unless it does something easily describable.

## 4. Local shape

Within each function, look for:

1. **Closures that capture little.** A nested function reading only a
   couple of its parent's locals lifts to module level, those locals
   becoming parameters; the parent shrinks and the dependencies show.
1. **Helpers that don't earn a name.** A single-call helper whose body
   reads as plainly as its name inlines, especially one that reshapes
   data its caller reshapes again.
1. **Bespoke versions of what exists.** Hand-rolled key joins, a pick
   that enumerates every key, a type test by exclusion where a
   predicate exists, a literal record a constructor already builds.
   Check `util` and the file's own helpers.
1. **An expression at three or more sites** that a small helper names.
1. **Build then reduce.** A collection built only to extract a value or
   two can compute those directly.
1. **Distance between definition and use.** A setup loop far from its
   only reader, a helper in a section other than its callers'. Move
   each beside what reads it.
1. **Names.** Abbreviations; one thing under several names across
   stages; names for mechanism where the file already has a name for
   the role.
1. **Branch shape.** A negated flag that exists only to pick a branch;
   an early return guarding one trailing block; independent `if`s with
   exclusive conditions; a status chain that reads as a table.
1. **Defensive copies** whose consumer only reads.
1. **Narration** that restates the code.

## 5. Hazards

Each move below has a check; run it before proposing the move.

1. **Inlining a helper** can drop a guard it held for its callee. Read
   the callee's `--pre` and carry the guard over.
1. **Converting a value earlier** changes its frame or unit for every
   later use. Trace each use, or give the converted value a new name.
1. **Dropping a local used more than once** recomputes it: the value
   must be stable between the sites, and a `nil` must not become
   `false` against a contract that says `nil`.
1. **Specialising a shared read** duplicates how its data is assembled.
   If two places must agree on that, keep the one path.
1. **Renaming** must still describe everything the thing does.
1. **Pruning comments** keeps the WHY that is non-local: ordering
   dependencies, cross-function mirrors, why a skip isn't taken, which
   frame a value is in. A rewritten comment is checked against the code
   as it now stands: names, directions, which case does what.
1. **Module state in place of a parameter** hides a write; it shortens
   the signature but not the reasoning.
1. **Reordering statements** in a mutating function: check nothing
   between depends on the old order.

## 6. Report

Bring to the chat a summary of what you found. Highlight what you
consider the lowest-hanging fruit for improvement. For each local
move, name the hazard check it passed.

No preambles, padding or sign-offs, and say it as simply as you can
with no fluff.
