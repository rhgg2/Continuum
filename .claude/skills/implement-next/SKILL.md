---
name: implement-next
description: Implement the plan's Now brief.
disable-model-invocation: true
---

1. The implementation brief arrives injected by hook, so work from
   that rather (a brief over the 10k cap should be read from the given
   path). The brief is ephemeral, so doesn't need updating as
   implementation progresses.

2. No brief means none has been compiled: say so and point at
   `/plan-next`. The hook also names the live plan; if the brief's
   `plan:` line disagrees, stop and ask, because the brief belongs to
   a plan that isn't the one in flight.

3. The brief is self-standing; open the anchors the brief names, write
   the specs and production code, and verify the brief's own
   completion conditions. Don't relitigate settled decisions unless
   necessary; see §5 below.

4. Some briefs point at `plan/IMPL.diff`; this is a spike's working
   kernel. The brief will classify its hunks as **source code** or
   **target code** and you should treat these differently.

   - **Target code** comprises specs that are part of the "done"
     conditions of the brief; it should be copied over verbatim *before*
     implementation, to verify that it goes red or green as required.

   - **Source code** comprises partially-written production code or
     specs which are in part the subject of the brief. For production
     code, write your own implementation first, and only then compare
     against the diff code. If (and only if) the two differ, report
     back on which you will keep and why. For specs marked as source
     code, an empirical evaluation should suffice; `spec_perturb` is a
     useful tool to determine whether the spec fires on the right
     things.

5. When the brief turns out not to be sufficient, the response scales
with the size of the gap:

- **Mechanical** — anchors drifted, a local renamed, a range moved:
  reconcile against the code and carry on.
- **Tactical** — the brief needs a decision it didn't settle, but the
  design intent is clear enough to settle it locally: propose the
  settlement, and on approval write it back as an update to the design
  doc.
- **Design** — the code contradicts the design doc's model, or the
  item dissolves or splits on contact: stop implementing and surface
  it. The fix is a design-doc conversation, so unwind: read the plan
  file, return the item to the top of Queued with a one-line note of
  what broke, empty Now, and delete `plan/IMPL.md` along with any
  `plan/IMPL.diff`.
