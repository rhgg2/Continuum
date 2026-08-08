---
name: architecture-review
description: Review a subsystem's architecture
disable-model-invocation: true
---

Survey a subsystem for architectural friction. The output is a survey
and not a proposal: what the code is, not what to do about it. It lands
in `design/` — amending the live doc where one exists, so the review
never stands a second account beside the first.

## 1. Scope

Take the direction I named. Absent one, run `git log --oneline -400
--name-only --pretty=format: -- '*.lua'` and count the files; churn
picks the target more honestly than reading does.

**Done when** one file or cluster is named, with its churn share and
its size.

## 2. Read the prior art before anything else

`ls design/ plan/` and read what is live on the target. Design docs
are live proposals, not settled decisions, and may already hold
conclusions you would reach; `design/decisions.md` and
`design/archive/` hold it settled earlier.

**Done when** you can say what has been proposed about this target, or
that nothing has.

## 3. Map the structure

`map_query` with `module=<target>`, and `kind='uses'` on the
orchestrating function for the call graph: deterministic, free, and it
gives each brief real line ranges to name.

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
