# Compile the top queued item

The goal is to write an implementation brief for the top queued item.
This should be one landable change, spec included, fitting ≤150k
context. Sometimes, we'll implement the item in the same session; see
step 3 below.

## 1. Gather context

Study the relevant parts of the design doc named in the `> source:`
line, and the relevant code (maps first). Use the scratchpad and spike
worktree to probe design questions that will need settling before a
brief can be written.

**Done when** you know what the task is and what needs to be settled,
and have all the relevant background for that.

## 2. Report back

Bring to the chat a summary of what the item actually is. Write for a
reader who knows the current state of the code, but hasn't read the
design doc. Set out the points that need deciding before
implementation, and any findings you have so far on these; we'll
figure them out together.

Things we settle should be updated in the design doc. Read
`docs/STYLE.md` just before doing this, so it's fresh in your mind.

**Done when** I give you the nod to go to the brief writing stage.

## 3. The fork

Now you have a clear idea of the road ahead, continue to study the
code until you understand the problem well enough to be able to
implement it. 

Here is a fork. You can either write an implementation brief, or just
implement. To expand on that:

By the time you understand the problem fully, and particularly if you
run any spikes, you may well have in effect done the implementation
already. In this case, it may make sense to continue straight to
implementation. Reasons to do so:

- the change has a trivial production surface, and you are confident
  about the specs;
- you would essentially write the whole code in your brief anyway;
- the kernel you would attach is nearly all target code, so handing it
  over would be a copy rather than a derivation (see below).

Reasons not to do so:

- the change is complex and liable to need tweaks;
- the kernel you would attach holds real source code, which is the
  case the diff handover was built for;
- a fresh pair of eyes would help verify the code.

(Note that fresh eyes can't help verify the framing of the design,
which is inherited wholly from your brief; if that's a concern, go
back to §2.)

Context budget may also settle it. The study is the expensive part, so
with most of the window free the direct branch costs little; with most
of it spent, the brief earns its ceremony, by handing a fresh 150k to
an implementer who need not re-derive any of this.

Give your opinion on which branch to take and why, and we'll agree it
together.

**Done when** you understand the implementation fully, and we have
decided the fork. If you write the brief, continue to 4; if not, skip
to 5.

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
- the decisions already settled;
- target shapes (data structures, fields) copied in;
- file anchors with tight line ranges;
- specs: red-first when the item fixes observable behaviour, naming
  the target spec file and fixture; green-first to pin a refactor;
- what done looks like: suite green, plus the item's own evidence
  as observables and directions.
  
If compiling the brief built a working kernel in the spike tree, you
may choose to pass it on: `git -C <spike> diff HEAD > plan/IMPL.diff`.
This is a way of ensuring correctness; the implementer writes the
production code without reading the diff, then compares against your
spike. When you hand over a diff, note it in the brief and classify
the diff hunks into:

- **source** code: partial implementation of production code, or of
test code which is the subject of the brief itself.
- **target** code: test-shaped code which forms part of the completion
parameters of the brief from step 4.

Stage the brief and the plan-file update as one `apply_patches`
call: the brief as a create with `overwrite: true`, the item cut
from Queued, and Now replaced by a single line naming the item and
its design reference:

```markdown
**Teach `usedby` the intra-file `@call` index** — brief in
`plan/IMPL.md`. (design § Intra-file call edges)
```

Stop here, and point to `/implement-next`.

## 5. Direct implementation

Update the plan file first: cut the item from Queued and name it in
Now as a single line, noting that it was implemented directly, without
a brief.

Then say in the chat what §4 would have put on paper: the target
shape, the files you will touch, the spec you will write and whether
it goes red-first or green-first. Keep it short. 

Implement as `/implement-next` would: the spec first, verified failing
(or passing, to pin a refactor) for the right reason before the
production code follows; suite green at the end; the item's own
evidence demonstrated as observables.

`/implement-next` §5's escalation ladder applies unchanged except at
the design rung, where there is no brief to delete and nothing to
unwind: return the item to the top of Queued with a one-line note of
what broke, empty Now, and stop.

**Done when** the suite is green and the plan file names the item in
Now. Point at `/commit` to land it.
