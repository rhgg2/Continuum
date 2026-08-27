---
name: implement-next
description: Implement the plan's Now brief.
disable-model-invocation: true
---

The goal is to fulfil the live implementation brief. This arrives
injected by hook; no brief means none has been compiled, so
stop and point at `/plan-next`. The hook also names the live plan; if
the brief's `plan:` line disagrees, stop and clarify the intent.

## 1. The implementation

The brief is self-standing; open the anchors it names, write the specs
and production code, and verify the brief's own completion conditions.
Don't re-open settled decisions unless necessary; see §3 below.

The brief is also ephemeral, so doesn't need updating as
implementation progresses.

## 2. The kernel

Some briefs will name `plan/IMPL.diff`; this is a spike's working
kernel. The brief will classify its hunks into **source code** or
**target code** and you should treat these differently.

- **Target code** comprises specs that are part of the "done"
  conditions of the brief; it should be copied over verbatim *before*
  implementation, to verify that it goes red or green as required.

- **Source code** comprises partially-written production code or specs
  which are in part the subject of the brief. For production code,
  write your own implementation first, and only then compare against
  the diff code. If (and only if) the two differ, report back on which
  you will keep and why. For specs marked as source code, an empirical
  evaluation should suffice; `spec_perturb` is a useful tool to
  determine whether the spec fires on the right things.

## 3. Escalation

When the brief turns out not to be sufficient, the response scales
with the size of the gap:

- Mechanical: if anchors drifted, a local was renamed or a range
  moved, reconcile against the code and carry on.
  
- Tactical: if the brief needs a decision it didn't settle, but the
  design intent is clear enough to settle it locally, then propose the
  settlement. On approval update the design doc where the model
  changed, and carry on; `/commit` records the decision itself.

- Design: the code contradicts the design doc's model, or the item
  dissolves or splits on contact. Stop implementing and say what
  happened. The fix is a design-doc conversation, which may be taken
  here, or may require an unwind; we will take this on a case-by-case
  basis.
