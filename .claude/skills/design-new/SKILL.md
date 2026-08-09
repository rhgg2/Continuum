---
name: design-new
description: Open a new design doc and take it to its first stated model.
disable-model-invocation: true
---

This skill opens `design/<slug>.md` for an idea that has no doc yet, and
leaves it stating a model. Advancing that model from there is `/mature`.

## 1. Place the idea among what exists

The invocation names the subject, and may point at where it came from —
a line in `todo.md`, a review's findings, the conversation above. Read
that in full before anything else.

Then search `design/`, `design/archive/`, `design/pipe-dreams.md` and
`design/decisions.md` for related material. Three stop conditions may
arise:
- the subject already has a live doc, advancing which is `/mature`'s job; 
- it was built and its doc archived, so what is wanted is a change to shipped code; 
- it was settled against, and that decision stands until we reopen it deliberately.

**Done when** you can say no doc covers the subject, and name the docs
this one will cite.

## 2. Establish the problem

A design doc is opened against the code as it is. Before proposing
anything, say what the codebase does today at the seam the idea touches,
and what about that fails to serve the idea.

Verify every claim in that statement: `map_query` for where things live,
a subagent for anything that needs reading breadth, the session's spike
worktree for behaviour you can only learn by running it. Everything
downstream leans on the problem, so nothing enters it on the strength of
a plausible-sounding memory.

**Done when** you can state the problem in a paragraph and have seen the
evidence for each of its claims.

## 3. Settle the opening

Bring to chat, before writing any of the doc: the problem as you would
write it; what the doc covers and what it deliberately excludes; the
stage it opens at; and the slug and title you propose. Where the problem
already forces a first design decision, name it with the answer you
would give.

The stage is a claim about how much is settled, so pitch it at what you
actually have. A vision with no mechanism opens at `vague, pre-design`
and says so.

**Done when** I give you the nod to lay it out.

## 4. Lay out the sections

Write every heading the doc will have before writing any of its prose.
Under each, one sentence saying what that section claims — its
**thesis** — and the terms that section is where we define.

Read the layout as a whole, and take what it exposes:

- a thesis that needs more than one sentence is two sections;
- a thesis another section already states means one of the two goes;
- a term used in a thesis before the section that defines it is an
  ordering fault, and so is a cost stated before its motivation, or a
  consequence before what it follows from.

Ordering is nearly free to settle here and expensive afterwards: moving
two finished sections means rewriting every sentence that joined them to
what came before. So resolve it now, on a page you can hold in one look.

**Done when** we have agreed the sections and their order.

## 5. Fill the sections in

Read `docs/STYLE.md` for the register and ground rules. The doc states
the intended model and nothing about how we arrived at it: no
inventory of what was considered, no section named for a rejected
alternative.

Write the layout into this skeleton:

```markdown
# <title> — <the distinguishing phrase>

> opened: <today's date> · status: <stage>; not started

**<The thesis in one sentence.>**

## <the sections in their agreed order>

## Open

<what is not settled>
```

The bolded thesis belongs to a doc whose model is already sharp enough
to state in a sentence; a doc opening at `vague, pre-design` leads with
prose that says what it is a vision of.

`## Open` is the one section a new doc is expected to be full of, and is
what `/mature` reads first. Everything step 3 left unsettled goes there,
each phrased so that answering it advances the doc.

Stage the doc as one `apply_patches` call, then apply the `/refining`
skill to it whole, and the `/surveying` skill after that — a cold read
is how we find out whether the order settled in step 4 survived being
written into.

**Done when** surveying's findings have been agreed and landed. Point at
`/mature` for the first round of advance.
