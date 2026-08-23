---
name: design-new
description: Open a new design doc and take it to its first stated model.
disable-model-invocation: true
---

This skill writes a new design doc to `design/<slug>.md`.

## 1. Research the idea

The invocation names the subject and its source material. Search
`docs/`, `design/`, `design/archive/`, `design/pipe-dreams.md` and
`design/decisions.md` for related material. If the subject already has
a live doc: stop and point to `/mature`. Where `docs/` already states
part of the model, the new doc covers only the departure from it.

Now research how this idea sits with today's codebase. Read code (maps
first), specs and docs, or settle questions empirically in the spike
worktree. 

**Done when** you know how this idea relates to previous design art
and to today's codebase.

## 2. Scope the design doc and distil the abstract

The doc will state the intended model ahistorically, with no record of
design decisions made along the way or commentary on strengths and
weaknesses of different approaches. Where the doc evolves an existing
model, it only needs to state what is new, without comparing or
weighing against what exists.

We now settle the fundamentals:

- what the doc covers;
- the stage it opens at; 
- the slug and title;
- the design abstract: one or two sentences that describe the main
  idea.

We will do this collaboratively. Bring what you found in §1 to the
chat, along with your suggestions for answers to the above questions.
It may be that answering these first requires some design decisions;
if so, bring those to the chat first.

**Done when** we have decided the four points above.

## 3. Lay out the sections

We now settle in chat the skeleton of the design doc: the ordered list
of sections it will contain, and for each:

- its heading;
- its **thesis** — one sentence saying what that section does;
- its **definienda** — the terms to which it assigns precise meaning.

Note that:

- If the thesis requires more than one sentence, the section should be
  two sections;
- If another section already states a thesis, the two sections should
  be one;
- A definiendum used in a thesis should have been defined in a prior
  section.

**Done when** we have agreed the skeleton.

## 4. Fill the sections in

First read `docs/STYLE.md` for the register.

The skeleton becomes markdown thusly:

```markdown
# <title> — <the distinguishing phrase>

> opened: <today's date> · status: <stage>; not started

**<The abstract.>**

## <the sections in their agreed order>

## Open

<what is not settled>
```

`## Open` is likely well-populated: it contains everything left
deliberately unsettled, and whose settlement would advance the doc.

Stage the doc as one `apply_patches` call, then apply the `/refining`
skill and the `/surveying` skill.

**Done when** surveying's findings have been agreed and landed. Point
at `/mature` for the first round of advance.
