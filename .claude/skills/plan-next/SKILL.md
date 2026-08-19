---
name: plan-next
description: Split in-flight phases, or compile impl brief for next queued item.
disable-model-invocation: true
---

## 1. Orientation

This skill concerns the live plan, and the live implementation brief.
The plan and the brief's existence arrive injected by hook. A plan
over the 10k context cap should be read from the given file path.

The plan file is a working buffer, structured thusly:

- Phases: The plan's roadmap. One phase is not unusual.
- Queued: The uncompiled items of the in-flight phase. 
          Compiling one takes it out of the section.
- Now:    The item being implemented in one line.
- Landed: Most recent commits, pruned to 4 entries.

## 2. Dispatch

There are four possibilities:

1. A brief exists: stop, noting that the planned item hasn't landed,
   and pointing at `/implement-next`.
1. Queued is non-empty: compile its top entry into a brief via
   [compile.md](compile.md).
1. Queued is empty, and there are uncompleted phases: refill Queued
   via [fill.md](fill.md).
1. Queued is empty and all phases are landed: stop, noting that the
   work is finished, and pointing at `/plan-close`.
