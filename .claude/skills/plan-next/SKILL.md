---
name: plan-next
description: Split in-flight phases, or compile impl brief for next queued item.
disable-model-invocation: true
---

1. This skill concerns the live plan, and the live implementation
brief. The plan and the brief's existence arrive injected by hook. A
plan over the 10k context cap should be read from the given file path.

2. The plan file is a working buffer, and its sections are what the
dispatch in §3 below reads:

- **Phases** is the plan's roadmap. One phase is a possibility.
- **Queued** is the items of the in-flight phase that haven't been
  compiled yet; compiling one takes it out of the section.
- **Now** names the item being implemented in one line.
- **Landed** prunes below ~4 entries — git and the design doc's dated
  notes are the permanent record.

3. Dispatch. There are four possibilities:

- **A brief exists.** The last planned item hasn't landed; say so and
  stop, citing `/implement-next` to finish it or `/commit` to land.
- **Queued is non-empty.** Compile its top entry into a brief:
  [compile.md](compile.md). Say that `/reconcile` checks the brief
  against the item it came from — the brief is gitignored, so no later
  run can.
- **Queued is empty and work remains unqueued.** Fill it from the next
  unlanded phase: [fill.md](fill.md).
- **Queued is empty and all phases are landed.** The work is
  finished: say so, point at `/plan-close`, stop. 
