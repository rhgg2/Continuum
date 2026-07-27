# memory-as-claims — plan

> source: `design/memory-as-claims.md` — synthesis compiled from there;
> don't design here.

## Landed  (newest first; prune below ~4)

- 2026-07-27 config: the wonder seeder for the open end (D11, D15)
- 2026-07-27 config: the decay rule into MEMORY.md's preamble (D10)
- 2026-07-27 config: fold the wonder ledger in as open claims (D11, D15)
- 2026-07-27 config: fold the store to ten claims, MEMORY.md as the claim index

## Now

**The filing pass, as a skill** (D13, D15, D10). `tools/wonder.py` writes to
`## Unfiled` and nothing reads it; the pass is also the only moment D10's decay
is evaluated. One skill directory carries the pass and the method it uses.

Firing is recorded when noticed rather than recalled at the pass: a jot lands in
`## Unfiled` and the pass routes it onto the claim as an instance. Silence reads
`quiet`.

*Parts 1 and 2 landed 2026-07-27, with the line references below replaced by
named anchors (see D13's dated note). Part 3 and the end-to-end shakedown run
remain; the run has an open question first — whether a pass on the same day as a
claim's last decay line records anything at all.*

**1. `.claude/skills/file-claims/rising-sea.md`** — `~/.claude/rising-sea.md`
copied unchanged, frontmatter included (143 lines).

**2. `.claude/skills/file-claims/SKILL.md`** — `name` and `description`
frontmatter, then numbered steps in the voice of `.claude/commands/plan-next.md`:

0. Gather the whole store in one `multi_read` — `MEMORY.md`, `open.md`, every
   claim file including its decay log. The pass is the store's only regular
   whole-store read; reading part of it defeats it.
1. Drain `## Unfiled` (`open.md:16-18`). Each entry goes to exactly one of: a
   subject section of `open.md`; straight out into a new `observed` claim file
   (D15 — filing is not a conveyor, and *this one is already confirmed* is a
   judgement the pass can make and the jot cannot); appended as an instance to
   an existing claim, which for a `us` claim is a firing; or dropped, said out
   loud with why. If the section empties, restore the `(nothing unfiled)`
   placeholder — `tools/wonder.py:20,49-50` depends on it.
2. Crystallise: follow `rising-sea.md` in this directory over the subject
   sections, with the bullets themselves as raw material (its step 1 wants the
   text, not a summary). *Ripe* → a new `observed` claim file whose instances
   are those bullets, which then leave `open.md`. *Not yet* / *no crystal* →
   change nothing and say so. An open claim carries no obligation to be
   promoted (D7).
3. Promotion `observed` → `load-bearing` is D5's bar: three instances across
   *different sessions*, rhyming on a mechanism. "Does it yield a check you
   could run before the mistake?" is the falsifier, used as a test and never as
   the output shape. D3 governs the wording: a claim states what is true, not
   what to do.
4. Decay, `us` only (D10). Append one dated line to the claim's `**Decay log.**`
   section (shape at `us_reconstruction_vs_retrieval.md:44-47`): `fired <date> —
   <incident>` or `quiet <date>`. Two consecutive quiet lines drop a rung; any
   firing cancels accumulated quiet; a claim that falls to `open` keeps its file
   and body, with frontmatter `standing:` following. Silence is not evidence
   against a `world` or `build` claim.
5. Rewrite the `MEMORY.md` index to match the files — `- [Title](file.md) —
   hook`, one line per claim, grouped by subject then standing
   (`MEMORY.md:16-51`). Leave the preamble (`:1-14`) alone; the next item moves
   it.
6. Stage the whole pass as one `apply_patches` batch.

**3. Deletions, last** (D11's order). After the commit lands:
`~/.claude/rising-sea.md` and `~/.claude/wonder/` entire — its seven open
entries are already in `open.md`, and the rest is the resolved test entry plus
`wonder.lua`, superseded by `tools/wonder.py`. Both sit outside the repo and
untracked, so confirm before removing either.

**Done looks like** `file-claims` appearing in the skill listing at next session
start (registration is by location and silent when wrong); the pass running end
to end over the real store and producing one reviewable batch, or an honest "no
crystal, nothing decayed"; `python3 tools/wonder.py "test"` still round-tripping
against the post-pass `open.md`, placeholder path included; and
`grep -rn "wonder\|rising-sea" ~/.claude .` finding no live reference to the
deleted paths. No suite run — nothing here is Lua.

## Queued (one-liners)

1. Write the loop into the workflow (D12, D14): the narrative leaves MEMORY.md
   for the workflow surface, and jot → chase → rising-sea → decay is documented
   there, including the standing permission it grants.
