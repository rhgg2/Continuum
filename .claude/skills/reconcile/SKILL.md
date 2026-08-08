---
name: reconcile
description: Check one translation in the plan chain against the claim above it.
disable-model-invocation: true
---

The plan chain is a series of translations between different rungs,
each compiled by a different invocation:

    design §  →  phase line  →  Queued item  →  IMPL brief  →  code

Your goal is to verify one of these translation steps, and ensure that
it was done well. This is not about the correctness of the output
rung; it is about its fidelity to the input rung.

## 1. Pick the two rungs

The two rungs come from whatever we just did in the session. State
which two you inferred, and why; if the session doesn't tell you,
say so and ask rather than guess. 

- **just ran `/plan-new`** — the design § against the phase lines.
- **just filled Queued from a phase** — the phase line against its items.
- **just compiled a brief** — the Queued item against the brief.
- **implemented, nothing committed** — the brief against the working diff.
- **cold** — the first two, from history. The others no longer exist.

## 2. Gather the data

For the input rung, find the claim **as it was first written**, not as
it stands. For example, a phase line edited in flight has already
absorbed some of the drift you are looking for, so `git log -p
plan/<slug>.md` over the Phases block, and take the line as
`/plan-new` left it.

Every rewrite you pass on the way is itself a finding to test: ask
whether a dated decision note in the design doc accounts for it. An
unaccounted rewrite is drift absorbed rather than decided, and it
costs no code reading to find.

**Done when** you have full knowledge of the input and output rungs
and can say when each was written.

## 3. Send it out cold

One subagent, given the pair of rungs and nothing else — not the
design doc, not the transcript, not your reasoning. If either rung is
neatly encapsulated by a file and a line-range, send it by reference;
otherwise, attach the text in full.

Ask the agent to report three kinds of deviation from full fidelity:

- **dropped** — in the claim, absent from the translation.
- **added** — in the translation, traceable to nothing in the claim.
- **altered** — in both, saying different things.

**Done when** you get the agent reports back.

## 4. Report

Give me the findings and stop. Correcting drift is a design call, so
we'll decide in chat what to do next. A clean run is a viable result.
