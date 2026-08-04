---
description: Implement the plan's Now brief — red spec first, brief kept current, suite green.
disable-model-invocation: true
---

The implementation brief `plan/IMPL.md` arrives injected by the
`UserPromptExpansion` hook, so work from that rather than re-reading it
(a brief over the 10k cap arrives as a path plus preview — read the
path). No brief means none has been compiled: say so and point at
`/plan-next`. The hook also names the live plan; if the brief's `plan:`
line disagrees, stop and ask, because the brief belongs to a plan that
isn't the one in flight.

The brief was compiled to be sufficient on its own — that's why it
exists — so neither the plan file nor the design doc named in its
`source:` line is part of the loop, and neither is injected. Open the
anchors the brief names, write the red spec first when it calls for
one, implement, and get the suite green via `lua_test_run`.

The brief's premises are inherited with their provenance, not
re-derived: re-verification is bounded to the checks the brief
explicitly names, each one command. Beyond that, re-derive on
suspicion — a premise contradicting the code in front of you —
never by default.

When the brief turns out not to be sufficient, the response scales
with the size of the gap:

- **Mechanical** — anchors drifted, a local renamed, a range moved:
  reconcile against the code and carry on.
- **Tactical** — the brief needs a decision it didn't settle, but the
  design intent is clear enough to settle it locally: propose the
  settlement, and on approval write it back as a dated note in the
  design doc (the way `/plan-next` does) and prune the brief. This is
  the rung that actually fires; without the write-back the decision
  survives only in a commit message.
- **Design** — the code contradicts the design doc's model, or the
  item dissolves or splits on contact: stop implementing and surface
  it. The fix is a design-doc conversation and a `/plan-next` re-run.
  Read the plan file — it isn't injected — return the item to the top
  of Queued with a one-line note of what broke, empty Now, and delete
  `plan/IMPL.md`: the brief is wrong by hypothesis at this rung, and
  leaving it would block the re-run.

Done is the brief's own definition plus a green suite; remind to commit
(`/commit` carries the landing bookkeeping, which empties Now and
deletes the brief). Stopping short of done is fine — just leave
`plan/IMPL.md` amended to actual state, tactical escalations included,
so the next session inherits the truth.
