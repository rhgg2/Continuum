---
name: mature
description: Advance a design doc one stage along its arc.
disable-model-invocation: true
---

This skill takes a file from `design/` and advances it one step
towards an implementation-ready document. 

## 1. Locate the doc and find the blocker

The invocation holds the file to consider; read it whole. A subject
with no doc yet belongs to `/design-new`, which opens one.

Also search `design/decisions.md` and `design/archive/` for any
related material, so that a question settled earlier is not reopened.

Most docs say what holds them back — `## Open`, or a section titled as
the blocker. Where there is no such section, because the doc is a
review's findings or is still vague, work it out and say that the
reading is yours.

**Done when** you can say what stage the doc is at and what holds it
there.

## 2. Choose and research the advance

There is no ladder of stages to consult. Ask instead what is the
single next thing that would have to be true for this doc to be
further along than it is.

If what comes next is a tree of decisions rather than one, you have
named too large an advance. As soon as you can see a first necessary
decision come into focus, scope your attention to that. We can
continue with further rounds if needed after step 4.

Research how you would settle the chosen advance. Dispatch for
anything the tree can answer, and verify every claim whose evidence
you have not seen yourself, either from the source or via the
session's spike worktree.

Where the blocker is what shape an interface should take, and the
shape is not already obvious, design it twice: subagents in parallel,
each under a different constraint — the smallest interface, the most
flexible, the easiest for the commonest caller. Compare them on what
each hides and where change would concentrate.

**Done when** you have everything the proposal needs and nothing left
to look up.

## 3. Settle the advance

Once you have gathered everything, and have a proposal, bring it to
chat. Name the stage, what holds it there, and the advance you
propose; then lay out any fork, each with the decision you would make.
If there are four or five forks, you did too much in round 2. Propose
explicitly any new vocabulary you wish to adopt, so we can settle its
scope and meaning.

**Done when** I give you the nod to land the round.

## 4. Update the design doc

Rebuild the doc in light of the advance. When an open question is
settled, delete the question and rewrite the section it bears upon.
When this supercedes part of the document, delete it. This is an
active working document, not a historical record of all avenues
explored. Stage the rebuild as one `apply_patches` call.

After this initial pass, apply the `/refining` skill, scoped to the
changed parts.

**Done when** the run of `/refining` is complete. We stop here unless
I ask for another round, which returns us to step 2.
