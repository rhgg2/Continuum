---
name: plan-new
description: Open a new plan and push it onto the CURRENT stack.
disable-model-invocation: true
---

Create a new implementation plan for the design doc passed as an
argument; with no argument, stop and confirm which design doc was
intended.

The design doc holds the model, `design/decisions.md` the decisions;
the plan only the implementation machinery.

## 1. Gather background

A hook injects `plan/CURRENT`, the stack of current plans, and the
`plan/`, `plan/archive/` and `design/` listings. Read the design doc
in full, and any relevant related material linked from there.

## 2. Split the work

Split the implementation work into phases. Each phase should be
approximately 2-4 commits of <150k context size. One phase is totally
acceptable.

## 3. Write the file and update the current stack

Write `plan/<slug>.md` to the skeleton below, and push the new
filename onto the top of `plan/CURRENT`, so it becomes the current
plan. Stage the new plan and the CURRENT edit as one `apply_patches`
call, then stop and point at `/plan-next`. Name the plan you pushed in
front of, if there was one.

```markdown
# <programme> — plan

> source: `design/<doc>.md` — synthesis compiled from there;
> don't design here.

## Phases

1. **Phase 1 — <name>** (§ <section>) — <one line>  ← in flight
2. **Phase 2 — <name>** (§ <section>) — <one line>

## Landed  (newest first; prune below ~4)

(nothing yet)

## Now

(empty — new plan; run /plan-next to split phase 1 into Queued.)

## Queued (current phase; one-liners)

(empty)
```



