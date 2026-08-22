---
name: architecture-review
description: Review a subsystem's architecture
disable-model-invocation: true
---

Survey a subsystem for architectural friction. The output is a survey
rather than a proposal. The scope is usually named in the invocation;
otherwise, run `git log --oneline -400 --name-only --pretty=format: --
'*.lua'` and pick whatever has been most active recently.

## 1. Research

search `design/` and `plan/` for relevant live proposals that may bear
on what you propose. For the history, check also `design/archive/`,
`design/decisions.md` and `doc/oddities.md`.

Also map the call graph using `map_query` with `module=<target>`, and
`kind='uses'` on the orchestrating function. This gives you real line
ranges for the next step.

Come to the chat with the target, its size, what `design/** and `plan/**
already propose about it, and the main clusters in the subsystem. 

**Done when** I give you the go-ahead for fan-out.

## 2. Fan out

Launch one `Explore` agent per cluster, in parallel. Each brief asks:

- what state the cluster owns; 
- what it reads that another wrote; 
- what arrives as a parameter versus ambiently;
- if extraction yields a small interface or one as wide as the body. 

Ask for `file:line` evidence, and emphasise that "the code is already
in good shape" is a valid answer. Give each agent one sharp question
aimed at what its cluster specifically risks.

Once the reports are back

**Check in.** Give me the candidates, each marked **Strong**, **Worth
exploring** or **Speculative**, and say which of them rest on a claim
a probe would settle. When I give you the go-ahead, we'll settle any
loose ends.

## 3. Verify before anything reaches the doc

Verify every claim whose evidence you have not seen yourself. A
citation is settled by grep in seconds, and an agent's reading of a
comment is a claim like any other.

Identity, aliasing, mutation order and what a stage actually observes
are what reading cannot settle. Take those to the session's spike
worktree: a probe that prints the fact, and the suite to drive it.

**Done when** each claim is verified, measured or dropped, and you have
said which way it went. A claim that does not survive is worth as much
as one that does.

## 4. Land it

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
