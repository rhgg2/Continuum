---
name: architecture-review
description: Review a subsystem's architecture
disable-model-invocation: true
---

Survey a subsystem for architectural friction. The output is a survey
rather than a proposal. 

## 1. Scope

Whatever is named in the invocation; failing that, run `git log
--oneline -400 --name-only --pretty=format: -- '*.lua'` and pick
whatever has been most active recently.

## 2. Research

search `design/` an `plan/` for relevant live proposals that may bear
on what you propose. For the history, check also `design/archive/`,
`design/decisions.md` and `doc/oddities.md`.

Also map the call graph using `map_query` with `module=<target>`, and
`kind='uses'` on the orchestrating function: deterministic, free, and
it gives you real line ranges for the next step.

**Check in.** Name the target with its churn share and size, what
`design/` and `plan/` already propose about it, and the clusters you
would fan out over. When I give you the go-ahead, we're ready for
fan-out.

## 4. Fan out

One `Explore` agent per cluster, in parallel. Each brief asks what
state the cluster owns; what it reads that another wrote; what arrives
as a parameter versus ambiently; and if extraction yields a small
interface or one nearly as wide as the body. For anything that looks
like a pass-through, ask the deletion test: would deleting it
concentrate complexity, or only move it? Concentrating is the signal.
Ask for `file:line` evidence, and ask each agent to say where the code is well-factored —
you want a read, not a complaint list.

Give each agent one sharp question aimed at what its cluster
specifically risks, and hand over what step 2 settled, so nobody spends
a paragraph re-proposing a decision already taken.

**Check in.** Give me the candidates, each marked **Strong**, **Worth
exploring** or **Speculative**, and say which of them rest on a claim
a probe would settle. When I give you the go-ahead, we'll settle any
loose ends.

## 5. Verify before anything reaches the doc

Verify every claim whose evidence you have not seen yourself. A
citation is settled by grep in seconds, and an agent's reading of a
comment is a claim like any other.

Identity, aliasing, mutation order and what a stage actually observes
are what reading cannot settle. Take those to the session's spike
worktree: a probe that prints the fact, and the suite to drive it.

**Done when** each claim is verified, measured or dropped, and you have
said which way it went. A claim that does not survive is worth as much
as one that does.

## 6. Land it

Amend the live design doc in the register of `docs/STYLE.md`, or open
`design/<slug>.md` if there is none. Describe each seam and badge how
well it is evidenced — the badge grades the evidence, not your appetite
for the work:

- **Strong** — measured, or reached independently by two readers.
- **Worth exploring** — read once and plausible; a design would have to
  test it.
- **Speculative** — noticed and unverified, recorded so it is not lost.

Carry a section for the claims that did not survive step 5, your own
included. Stage the whole set as one `apply_patches` call, then stop —
`/mature` picks a finding up when I am ready.
