# Compile the top queued item

The goal is to write an implementation brief for the top queued item.
This should be one committable change, tests included, fitting ≤150k
context.

## 1. Read the item and its source

Read the top queued item, and the design doc section named in its
`> source:` line.

**Done when** you can state the item in a sentence.

## 2. Locate the code

Dispatch a single Explore agent to find the code you know you need.
Its job is to return file paths with tight line ranges, rather than
quoting source or giving an account of what it found. Hand it the item
statement and anything cited in the documentation, so that it doesn't
start cold.

**Done when** you hold a list of anchors.

## 3. Read the anchors

Read exactly those ranges.

**Done when** they're read.

## 4. Report back

Bring to chat a summary of what the item actually is. Write for a
reader who has a high-level understanding of the project's
architecture, but not the implementation details; thus, gloss variable
names, shapes, and existing functions and work from the big picture
downwards.

Set out the points that need deciding before implementation, and any
findings you have so far on these, so we can figure them out together.
Things we settle update the design doc where they change the model;
read `docs/STYLE.md` just before making that edit. `/commit` records
the decision itself.

Then propose whatever further research would help: more code to read,
or a spike probe to settle a design question. Say what each would tell
us, and we'll decide together what's worth doing. 

**Done when** I give you the nod to go to the brief writing stage.

## 5. Write the brief

Carry out whatever research §4 settled on. Then write the brief to
`plan/IMPL.md`. The implementer gets this and nothing else, so it
should be self-contained. Start with a header:

```markdown
# <item title>

> plan: `plan/<slug>.md` · source: `design/<doc>.md` § <section>
>
> Untracked working file — `/plan-next` writes it, `/implement-next`
> works from it, the landing bookkeeping deletes it.
```

Add:
- what and why, briefly;
- decisions already settled (one-liners);
- target shapes (data structures, fields) copied in;
- file anchors with tight line ranges;
- specs: red-first when the item fixes observable behaviour, naming
  the target spec file and fixture; green-first to pin a refactor;
- what done looks like: suite green, plus the item's own evidence
  as observables and directions. Tooth-testing of specs should be done
  using the continuum_perturb MCP server.

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
