---
name: clarity
description: "Review Lua for how clearly it reads to someone meeting it cold: naming, self-description, structure, readable conditions, and over-building (needless abstraction, reinvented helpers, dead flexibility) — since code the reader doesn't need is still code the reader must wade through. Returns a ranked list of recommendations to implement in a later pass. Reviews the working-tree diff by default, or the files/paths passed as args. Read-only: it lists findings and changes nothing."
---

# Clarity review

Read code the way someone meeting it cold would, and report every place they
would have to reread, decode, or wade through more than the job needs. The
lens is: does this read clearly? Two things fail that test — code that is hard
to follow, and code that shouldn't be there at all. You attack both. What you
never do is flag something merely for being long: a shorter line that reads
worse is not an improvement, and length that carries real work stays. You
produce a ranked list; you apply nothing. A separate pass implements what the
user accepts.

## Scope the target

- **Args given** — review exactly those files or paths.
- **No args** — review the working-tree diff against HEAD (`git diff HEAD`,
  plus untracked files). Review only the changed regions and enough
  surrounding code to judge them; do not sweep whole files the diff didn't
  touch.

Per repo convention, read `map/<file>.map` before pulling ranges from a
`.lua`, and check `docs/<file>.md` when a shape's rationale is unclear. Before
reporting a `reuse:` finding, actually confirm the helper exists — read
`util.lua` (or the relevant module) rather than assuming. Do not hand-edit
maps or source.

## What to look for

Every finding is a place the reader stumbles or reads more than they should.
Correctness, security, and performance are out of scope — route those to
`/code-review`. Everything about how the code *reads*, including over-building,
is in scope here. The tags below are the vocabulary, not a fence: if code
reads badly for a reason none of them name, report it under the closest tag
and say why in the `what` — a real stumble unnamed by the list still belongs
in the list.

Naming and self-description:

- `name:` — a name that hides or misleads: single letters, opaque
  abbreviations (`p`, `e`, `rec`, `projRec`), or a name that says one thing and
  does another. The wrong name is worse than the cryptic one. Give the
  replacement. (Names are the first documentation.)
- `magic:` — an unexplained literal doing real work (a number, string, or
  offset) that should be a named constant stating its meaning. The ±1
  MIDI-channel boundary is the classic: a bare `+1` there wants a name or a
  one-line WHY.
- `shape:` — a table that crosses a function or pass boundary carrying bare
  coordinate fields (`x1/x2/hW`) instead of role-named ones (`xLo/xHi`,
  `chanLeft`, `pitchWidth`). Bare names are for tight local math only.
- `annotation:` — a missing or inaccurate `--KIND:` annotation (invariant /
  contract / shape / emits / reaper) where the module's contract or a table's
  shape should be stated at the site. See `docs/CONVENTIONS.md`.

Structure the reader has to hold:

- `structure:` — a cryptic loop, or one that builds several tables inline;
  extract a named helper whose name states what it does. Scope it tightly if
  single-use.
- `scope:` — a function or closure doing several unrelated things at once, or
  a parameter that is really two, so the reader can't hold it in one glance.
  Split it, or rename to reveal the single responsibility.
- `nesting:` — a deep if/else pyramid or arrowhead code; flatten with guard
  clauses and early returns so the happy path reads straight down.
- `flow:` — gather → compute → mutate is violated: a mid-function mutation
  that invalidates references still in use, hurting readability (and often
  correctness).

Local reading friction:

- `boolean:` — a condition that needs a truth-table to read; name the
  predicate or introduce an intermediate boolean so the true/false cases are
  obvious.
- `idiom:` — code that solves something a different way than the established
  pattern in adjacent code, forcing the reader to reconcile two idioms for one
  job. Match the local idiom.
- `comment:` — a comment that restates WHAT the code does (delete it), a
  missing WHY the code genuinely cannot carry (add it), or in-progress /
  stale cruft. Respect the length caps in `docs/CONVENTIONS.md`.

Over-building (code the reader shouldn't have to read at all):

- `reuse:` — a hand-rolled thing that `util.lua`, the stdlib, or a native
  REAPER/ReaImGui feature already ships. Name the helper (`util:assign`,
  `util:pick`, `util:serialise`, the `util.REMOVE` sentinel, …). Confirm it
  exists before reporting.
- `yagni:` — an abstraction, config, or flexibility with a single real caller:
  an interface with one implementation, a factory for one product, a knob for
  a value that never changes. Inline it until a second case actually exists.
- `intermediate:` — an unjustified intermediate table or an extra pass over
  data that could fold into the next operation. Every pass must earn its keep.
- `duplicate:` — the same shape repeated across three or more *real* sites
  (not two, not anticipated); factor the shape. Below three, prefer the
  repetition.
- `delete:` — dead code, an unused local / parameter / branch, or vestigial
  flexibility nothing reaches. Remove it; nothing replaces it.

If a line is already clear and carries its weight, leave it alone — a review
that flags clean code trains the reader to ignore it.

## Output

One finding per line, ranked highest payoff first, in this shape:

```
<file>:L<nn>  <tag>  <what reads badly>. → <the fix>.
```

Multi-file diffs keep the path on every line; a single-file review may drop it
after the first. Show the replacement name, the helper, or the shorter form
concretely — never "consider whether…". End with a one-line tally
(`9 findings: 2 name, 2 reuse, 2 boolean, 1 yagni, 1 delete, 1 comment.`). If
nothing needs changing, say `Reads clean.` and stop.

Apply nothing. The list is the deliverable.
