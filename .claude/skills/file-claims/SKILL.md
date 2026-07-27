---
name: file-claims
description: "Run a filing pass over the memory store in .claude/agent-memory/: drain the unfiled jots onto claims or into the open end, test the open end for a crystal with the bundled rising-sea method, apply the standing promotions and the us-claim decay rule, and rewrite MEMORY.md to match the files. Produces one reviewable batch, or an honest 'no crystal, nothing decayed'."
---

# The filing pass

Jotting is meant to cost nothing, so `tools/wonder.py` appends to `## Unfiled`
and stops. This is the pass that pays for it: the one moment anything is
classified, anything is promoted, and the decay rule is evaluated at all. If the
pass doesn't run, nothing in the store moves.

Filing is not a conveyor. Every entry has somewhere it belongs, and one of those
places is the bin; another is straight out into a claim, because *this one is
already confirmed* is a judgement the pass can make and a jot cannot.

1. **Gather the whole store in one `multi_read`** — `MEMORY.md`, `open.md`, and
   every claim file, each entire, decay logs included. This pass is the store's
   only regular whole-store read, and reading part of it defeats it: standing,
   crystallisation and decay are all judgements across the set.

2. **Drain `open.md`'s `## Unfiled` section.** Each entry goes to exactly one of:
   - a subject section of `open.md` — the subject a promoted claim would land
     under;
   - straight out into a new `observed` claim file, when it is already confirmed;
   - appended as an instance to an existing claim — and on a `us` claim that is
     a firing, which step 5 will record;
   - dropped, said out loud with why.

   If the section empties, restore the `(nothing unfiled)` placeholder line.
   `tools/wonder.py` appends after the section's last non-blank line, so without
   it the next jot lands flush against the heading.

3. **Crystallise.** Follow `rising-sea.md` in this directory over the subject
   sections of `open.md`, with the bullets themselves as raw material — its step
   1 wants the text, not a summary of it. *Ripe* → a new `observed` claim file
   whose instances are those bullets, which then leave `open.md`. *Not yet* or
   *no crystal* → change nothing and say so. An open claim carries no obligation
   to be promoted; some entries feed a theory and some are only interesting.

4. **Promote `observed` → `load-bearing`** on the bar of three instances across
   *different sessions*, rhyming on a mechanism. The falsifier is "does it yield
   a check you could run before the mistake?" — used as a test, never as the
   output shape. A claim states what is true, not what to do; wording that
   arrives as an instruction is a claim not yet found.

5. **Decay, `us` claims only.** Append one dated line to the claim's
   `**Decay log.**` section — shape at the foot of
   `us_reconstruction_vs_retrieval.md` — reading `fired <date> — <incident>` or
   `quiet <date>`. Two consecutive quiet lines
   drop the claim a rung; any firing cancels accumulated quiet. A claim that
   falls to `open` keeps its file and its body, with the frontmatter `standing:`
   following it down. Silence is not evidence against a `world` or `build`
   claim: those fall only by refutation.

6. **Rewrite the `MEMORY.md` index to match the files** — `- [Title](file.md) —
   hook`, one line per claim, grouped by subject heading and then by standing.
   The index is derived from the store, so it is rewritten rather than patched.
   Rewrite from the first subject heading down; whatever prose sits above it is
   not the pass's to touch.

7. **Stage the whole pass as one `apply_patches` batch** — the user reviews the
   pass as a pass, hunk by hunk.
