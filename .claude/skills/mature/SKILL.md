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
stages to consult. It is simply finding the single next thing that
would have to be true for this doc to be further along than it is.
Many docs will say outright what holds them back. If the doc is still
vague, it may need work to figure it out.

Think small: if the advance requires a tree of decisions, it is
probably too large. As soon as you can see a first necessary decision
come into focus, scope your attention to that.

**Done when** you can say where the doc is and what the next possible
steps are. Bring it to the chat, so we can settle which one to pursue
next.

## 2. Research the advance

Establish the background needed to inform an approach to the chosen
advance; this can be through reading source and design docs, or
evidence-gathering via the session's spike worktree.

Where the blocker is what shape an interface should take, and the
shape is not already obvious, dispatch subagents in parallel, each
under a different constraint — the smallest interface, the most
flexible, the easiest for the commonest caller. Compare them on what
each hides and where change would concentrate.

**Done when** you have everything the proposal needs and nothing left
to look up.

## 3. Settle the advance

Once you have gathered everything, bring your initial thoughts to the
chat. This is about collaborating to sharpen the design and refine the
shape of what will get written into the doc.

The goal in this stage is to find out:

- which new sections will go into the design doc, if any
- which existing sections will need revising

For each section that's touched, we should be able to state the
section's thesis (new or revised) in one sentence, and name any
definitions or vocabulary it will introduce.

**Done when** we have agreed on the form of the changes, the theses,
and any new definitions or vocab.

## 4. Write the advance

Rebuild the doc to the agreed form. When an open question is settled,
delete the question and rewrite the section it bears upon. When this
supercedes part of the document, delete it. This is an active working
document, not a historical record of all avenues explored. Read
`docs/STYLE.md` before writing to get the register. Stage the rebuild
as one `apply_patches` call.

We stop here unless I ask for another round, which returns us to step
2.
