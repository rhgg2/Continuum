---
name: plan-next
description: Split in-flight phases, or compile impl brief for next queued item.
disable-model-invocation: true
---

## 1. Orientation

This skill concerns the live plan, and the live implementation brief.
The plan and the brief's existence arrive injected by hook. A plan
over the 10k context cap should be read from the given file path.

The plan file is a working buffer, and its sections are what the
dispatch reads:

- Phases: the plan's roadmap. One phase is not unusual.
- Queued: the uncompiled items of the in-flight phase. Compiling one
  takes it out of the section.
- Now: the item being implemented in one line.
- Landed: prunes below ~4 entries.

## 2. Dispatch

There are four possibilities:

- A brief exists. The last planned item hasn't landed; say so and
  stop, citing `/implement-next` to finish it or `/commit` to land.
- Queued is non-empty. Compile its top entry into a brief:
  [compile.md](compile.md).
- Queued is empty and work remains unqueued. Fill it from the next
  unlanded phase: [fill.md](fill.md).
- Queued is empty and all phases are landed. The work is finished: say
  so, point at `/plan-close`, stop.
