# Compile the top queued item

The goal is to write an implementation brief for the top queued item.
This should be one committable change, tests included, fitting ≤150k
context. Sometimes, we'll implement the item in the same session; see
step 3 below.

## 1. Gather context

Study the design doc named in the `> source:` line, and the relevant
code (maps first). Use the scratchpad and spike worktree to probe
design questions that need settling before a brief can be written.

**Done when** you know what the task is and what needs to be settled.

## 2. Report back

Bring to chat a summary of what the item actually is. Write for a
reader who has a high-level understanding of the project's
architecture, but not the implementation details; thus, gloss variable
names, shapes, and existing functions and work from the big picture
down to the nuts and bolts.

Set out the points that need deciding before implementation, and any
findings you have so far on these, so we can figure them out together.
Things we settle update the design doc where they change the model;
`/commit` records the decision itself. Read `docs/STYLE.md` just
before doing this, so it's fresh in your mind.

**Done when** I give you the nod to go to the brief writing stage.

## 3. The fork

With a clear idea of the road ahead, continue to study the code until
you understand the problem well enough to be able to implement it.

Now comes a fork. You can either write an implementation brief, or
just implement. To expand on that:

By the time you understand the problem fully, and particularly if you
run any spikes, you may well have in effect done the implementation
already. In this case, it may make sense to continue straight to
implementation. Reasons to do so:

- the change has a trivial production surface, and you are confident
  about the specs;
- you would essentially write the whole code in your brief anyway;
- the kernel you would attach is nearly all target code (see below).

Reasons not to do so:

- the change is complex and liable to need tweaks;
- the kernel you would attach holds real source code;
- a fresh pair of eyes would help verify the code.

Context budget is also relevant. If you chewed through a lot studying
the problem, then it makes sense to hand a fresh 150k to an
implementer; while if the study was quick and simple, there is little
reason to stand on ceremony.

**Done when** you know how to implement; you've given your steer on
the fork; and we've settled this together. If you write the brief,
continue to §4; if not, skip to §5.

## 4. Write the brief

The brief is written to `plan/IMPL.md`. The implementer gets this and
nothing else, so it should be self-contained. Start with a header:

```markdown
# <item title>

> plan: `plan/<slug>.md` · source: `design/<doc>.md` § <section>
>
> Untracked working file — `/plan-next` writes it, `/implement-next`
> works from it, the landing bookkeeping deletes it.
```

Add:
- what and why, briefly;
- decisions already settled;
- target shapes (data structures, fields) copied in;
- file anchors with tight line ranges;
- specs: red-first when the item fixes observable behaviour, naming
  the target spec file and fixture; green-first to pin a refactor;
- what done looks like: suite green, plus the item's own evidence
  as observables and directions.
  
If compiling the brief built a working kernel in the spike tree, you
may choose to pass it on: `git -C <spike> diff HEAD > plan/IMPL.diff`.
This helps ensure correctness; the implementer writes the production
code without reading the diff, then compares against the spike. When
you hand over a diff, note it in the brief and classify the diff hunks
into:

- **source** code: partial implementation of production code, or of
test code which is the subject of the brief itself.
- **target** code: test-shaped code which forms part of the completion
parameters of the brief.

Stage the brief and the plan-file update as one `apply_patches` call:
the brief as a create with `overwrite: true`, the item cut from
Queued, leaving the numbering as it is, and Now replaced by a single
line naming the item and its design reference:

```markdown
**Teach `usedby` the intra-file `@call` index** — brief in
`plan/IMPL.md`. (design § Intra-file call edges)
```

Stop here, and point to `/implement-next`.

## 5. Direct implementation

Update the plan file first: cut the item from Queued, leaving the
numbering as it is, and name it in Now as a single line, noting that
it was implemented directly, without a brief.

Then say in the chat what §4 would have put on paper: the target
shape, the files you will touch, the spec you will write and whether
it goes red-first or green-first. Keep it short. 

Implement as `/implement-next` would: the spec first, verified failing
(or passing, to pin a refactor) for the right reason before the
production code follows; suite green at the end; the item's own
evidence demonstrated as observables.

`/implement-next` §3's escalation ladder applies unchanged except at
the design rung, where there is no brief to delete and nothing to
unwind: return the item to the top of Queued with a one-line note of
what broke, empty Now, and stop.

**Done when** the suite is green and the plan file names the item in
Now. Point at `/commit` to land it.
