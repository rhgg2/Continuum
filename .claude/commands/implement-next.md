---
description: Implement the plan's Now brief — red spec first, brief kept current, suite green.
---

The live plan arrives injected by the `UserPromptExpansion` hook, so
work from that rather than re-reading it (a plan over the 10k cap
arrives as a path plus preview — read the path). If the Now brief is
empty, say so and point at `/plan-next`.

The brief was compiled to be sufficient on its own — that's why it
exists — so the design doc named in `> source:` isn't part of the
loop. Open the anchors the brief names, write the red spec first when
it calls for one, implement, and get the suite green via
`lua_test_run`.

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
  Demote the brief back to Queued with a one-line note of what broke.

Done is the brief's own definition plus a green suite; remind to
commit (`/commit` carries the landing bookkeeping). Stopping short of
done is fine — just leave the brief amended to actual state, tactical
escalations included, so the next session inherits the truth.
