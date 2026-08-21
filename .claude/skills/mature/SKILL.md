---
name: mature
description: Advance a design doc one stage along its arc.
disable-model-invocation: true
---

This skill takes a file from `design/`, passed by the invocation and
advances it one step towards an implementation-ready document. 

## 1. Choose the advance

Read the doc whole. Also search `design/decisions.md` and
`design/archive/` for any related material.

This stage chooses how the doc will advance. There is no ladder of
stages to consult; we simply find the next thing needed to get the doc
closer to implementation-ready. The doc itself may know what this is,
or it may be up to you to figure it out.

Think small: an advance requiring a tree of decisions is probably too
large. Prune it back to the children of the root.

**Done when** you know where the doc is and what the possible advances
are. Bring these to the chat, and we'll settle which to pursue next.

## 2. Research the advance

Investigate possible approaches to the chosen advance: from source,
design docs, or spikes in the spike worktree. For a problem with a
range of possible answers, consider dispatching a few subagents in
parallel, each under a different constraint, and cherry-pick the best
bits from each.

**Done when** you understand the advance fully.

## 3. Settle the advance

Bring your thoughts to the chat. We will now collaborate to sharpen
the design and refine what will get written into the doc. Explicitly,
we will determine which new sections will be added, and which existing
ones need revising.

For each section that's touched, we should be able to state the
section's thesis (new or revised) in one sentence, and name any
definitions or vocabulary it will introduce.

**Done when** we have agreed on the form of the changes, the theses,
and any new definitions or vocab.

## 4. Write the advance

Read `docs/STYLE.md` for the register, and then rebuild the doc to the
agreed form. When this supercedes part of the document, delete it.
When an open question is settled, delete the question and rewrite the
section it bears upon; `/commit` records the decision itself.

Stage the rebuild as one `apply_patches` call. 
