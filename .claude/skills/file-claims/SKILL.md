---
name: file-claims
description: "Run a filing pass over the memory store in .claude/agent-memory/: drain the unfiled jots onto claims or into the open end, test the open end for a crystal with the bundled rising-sea method, apply the half-life over the open end, the standing promotions and the us-claim decay rule, and rewrite MEMORY.md's two delivery registers (priors stated in full; lexically anchored facts). Produces one reviewable batch, or an honest 'no crystal, nothing decayed'."
---

# The filing pass

Jotting is meant to cost nothing, so `tools/wonder.py` appends to an untracked
spool and stops, and the commit skill's triage moves what outlived the session
into `## Unfiled`. That triage judges only whether a jot is still live — this is
the pass that pays for the rest: the one moment anything is classified, anything
is promoted, and the decay rule is evaluated at all. If the pass doesn't run,
nothing in the store moves.

Filing is not a conveyor. Every entry has somewhere it belongs, and one of those
places is the bin; another is straight out into a claim, because *this one is
already confirmed* is a judgement the pass can make and a jot cannot.

Three definitions the steps lean on:

- **Subject** — who a claim is about: `world`, the platforms
  underneath, which don't change; `build`, Continuum's own
  construction, which changes when we change it; `us`, how the two of
  us work — whose subject changes under Claude, which is why step 5
  decays `us` standing rather than letting it persist.
- **Provenance** — whatever is genuine (`opened:` a date, an
  `originSessionId:`) and nothing else; no quotation.
- **A convention is not a claim.** A claim states what is true, so an
  incident could refute it; a convention is arbitrary, in force or
  not, with nothing to refute. Conventions belong in CLAUDE.md, and
  "this is a convention" is a reason a drained entry is dropped here
  and re-homed there.

1. **Gather the whole store in one `multi_read`** — `MEMORY.md`, `open.md`, and
   every claim file, each entire, decay logs included. This pass is the store's
   only regular whole-store read, and reading part of it defeats it: standing,
   crystallisation and decay are all judgements across the set.

2. **Drain `open.md`'s `## Unfiled` section — decide by hand, move by
   machine.** Each entry goes to exactly one place. Decide a verdict per
   entry, in order, and hand the list to `tools/bookkeep.py` as a `drain`
   manifest; the tool moves the text verbatim and restores the
   `(nothing unfiled)` placeholder itself. Retyping an entry to move it is
   the recorded failure mode this replaces, so a moved entry lands verbatim
   and stays verbatim: folding it into a claim's prose is a later pass's work
   (step 3), and the only shaping this pass owes a moved entry is the
   frontmatter and body of a claim file the drain had to create.

   - `world` / `build` / `us` — the subject section a promoted claim would
     land under;
   - `claim: <file> @ <line prefix>` — spliced in as an instance above the
     line that prefix names; on a `us` claim that is a firing, which step 6
     will record. The anchor is not decoration: claims close on synthesis —
     the general lesson, the remedy, the pointer to a kin claim — and a decay
     log sits below that again, so the bare `claim: <file>` form lands the
     entry *after* the paragraph that concludes the claim. A prefix matching
     zero or several lines dies rather than falling back, since the fallback
     is the wrong place. An entry that is *already confirmed* takes the
     verdict naming a new file and no anchor: the tool creates it holding the
     bare instances, and step 8's batch wraps them in frontmatter and a body;
   - `drop: <why>` — the bin, with the why in the verdict itself so it
     survives in the command record;
   - `keep` — still unfiled, for an entry that arrived after step 1's read.

   The tool dies on a verdict/entry count mismatch: the store has recorded a
   jot arriving mid-pass, and the count is the guard that step 1's snapshot
   still holds at write time.

   Send the manifest with `"dry": true` first. It computes every destination
   and prints each entry's headline against where it would go, writing
   nothing. The count guard catches an entry *arriving*; it cannot catch a
   transposition, which keeps the count and lands the wrong entry in the bin
   — and `drop` is the one verdict only git can answer for afterwards. The
   list is positional, so a verdict read on its own names a destination with
   no visible subject; pairing headline with destination before the write is
   the only reading that can see the error.

   **Landing an instance pays for the one above it.** For each claim the drain
   touched, fold the entry an *earlier* pass landed there verbatim into the
   body — keeping whatever it sharpened about the model — and cut the incident
   to one line naming its mechanism, in the shape of the short bullets at the
   head of `world_vantage_not_neutral.md`. On a `us` claim that line already
   exists: it is the `fired` line in the section step 6 keeps. One in, one
   compressed, so a claim settles at the depth its drain rate sustains, and one
   nothing lands on is one that is not growing. The trigger matters more than
   the rule — a `claim:` verdict is a write already happening, where "compress
   the old ones while you are here" is a judgement step, and only judgement
   steps that present a decision fire at all (us_brief_horizon). It is also why
   instances carry no date and want no blame archaeology: both were considered
   and dropped, the second because a whole-file rewrite resets it.

3. **Crystallise.** Follow `rising-sea.md` in this directory over the subject
   sections of `open.md`, with the bullets themselves as raw material — its step
   1 wants the text, not a summary of it. *Ripe* → a new `observed` claim
   file whose instances are dated one-liners naming each incident, while the
   bullets themselves are deleted from `open.md` in the same batch: the
   landing commit's diff is the full text's archive, and quotation into the
   claim file is a second copy with no reader. Fresh text arrives whole; aged
   text travels as a pointer, which is the fold step 2 owes each claim the
   drain touched. *Not yet* or
   *no crystal* → change nothing else, say so, and append a `[<date>, filing:
   ...]` note to the entry the test was run over, carrying the verdict and — for
   a *not yet* — the specific thing that would ripen it. The note is where a
   negative run survives: spoken only to the user it dies with the transcript,
   and the next pass meets an entry that still looks untested and re-runs the
   whole procedure blind. An open claim carries no obligation to be promoted;
   some entries feed a theory and some are only interesting.

4. **Promote `observed` → `load-bearing`** on the bar of three instances across
   *different sessions*, rhyming on a mechanism. The falsifier is "does it yield
   a check you could run before the mistake?" — used as a test, never as the
   output shape. A claim states what is true, not what to do; wording that
   arrives as an instruction is a claim not yet found.

5. **Half-life over the subject sections** — after crystallisation
   deliberately, so a due entry's last chance to ripen is this pass. An entry
   is due when its newest dated line — bullet date, filing note, appended
   material — predates the last-but-one *pass-day*: a day on which a
   `memory:` commit landed. `bookkeep.py --due` computes this from git. The
   clock counts elapsed opportunity, not calendar time — and it ticks in
   pass-days, not passes, because passes cluster and two an hour apart give
   an entry no interval to ripen in. A due entry gets one of three verdicts,
   said out loud:
   - **sweep** — answered, absorbed, refuted, or its interest spent: delete
     it. Git is the archive — the removing commit's diff names what left and
     when — so a sweep demotes the text from the working set rather than
     destroying it.
   - **compress** — still open, or raw material a later theme might strike
     against: rewrite to a line or two under the entry's original date. A
     compressed entry that comes due again is swept, not re-compressed — two
     rungs and out, on the decay rule's own cadence.
   - **stay** — the full text must survive for a reason you can name (an
     awaited event, a live thread), appended as a dated `[<date>, filing:
     stays — <why>]` note — itself the touch that resets the clock. A bare
     stay is not available: an unnamed reason is the judgement step silently
     never firing.

6. **Decay, `us` claims only.** Append one dated line to the claim's
   `**Instances and decay log.**` section — shape at the foot of
   `us_reconstruction_vs_retrieval.md` — reading `fired <date> — <incident>` or
   `quiet <date>`. That section is also the claim's instance record: a `fired`
   line is where the incident lives, so write it to carry enough of the
   mechanism that a later pass can rhyme a candidate against it, and do not
   leave a second narration of the same incident in the body above. Two
   consecutive quiet lines from different days drop the claim a rung — days,
   not passes, for the half-life's reason: passes
   cluster, and quiet an hour apart is one opportunity, not two. Any firing
   cancels accumulated quiet. A claim that
   falls to `open` keeps its file and its body, with the frontmatter `standing:`
   following it down. Silence is not evidence against a `world` or `build`
   claim: those fall only by refutation — an incident that
   contradicts one sets `standing: refuted`, and the file stays.

7. **Rewrite the `MEMORY.md` registers to match the files** — the index is
   what a session actually meets at start; the files behind it are provenance
   and evidence, opened by this pass and rarely otherwise. So a claim enters
   the index only by passing one of two delivery tests, and lands in the
   matching register:
   - **Priors** — abstract claims. The line must carry the whole model,
     self-contained: a reader holding nothing else could apply it. Write it
     from the claim body, never from the previous hook — compressing a
     compression loses the codebook. Session-local vocabulary fails the test;
     so does a pointer-shaped tail ("five shapes it takes here"); so does a
     fragment that parses only with its incident in hand — that is provenance,
     and it stays in the file. Absorbing a new instance means restating the
     model so it covers the case, never splicing a rider onto the standing
     line: a chain of "— and" clauses is the previous hook surviving. Past
     ~100 words, suspect the line is carrying evidence, or is two claims.
   - **Facts** — concrete claims. The line must contain an anchor that
     resolves in the repo or a platform namespace (a symbol, an API name), so
     retrieval is lexical: the moment names itself and the file gets opened.
   A claim that passes neither test keeps its file, frontmatter and standing
   and is simply not indexed — delivery and standing are orthogonal axes, and
   the whole-store read in step 1 still meets it every pass. Subject and
   standing live in frontmatter only; the registers do not group by them.
   `open.md` is not indexed: its consumers are this pass and the commit
   skill's triage, and a gnomic hook delivers nothing at session start.
   The index is derived from the store: every line the pass touches is
   written from its claim body. But touch only the lines whose claims this
   pass changed, and leave the rest byte-untouched — re-emitting an unchanged
   hook by hand is transcription risk the store has recorded twice, and it
   protects nothing. Derivation is the invariant; whole-register rewriting
   was only ever one mechanism for it.
   Whatever prose sits above the first register heading is not the pass's to
   touch.

8. **Stage the pass's authored writing as one `apply_patches` batch** — new
   claim bodies, register lines, filing notes, decay lines, half-life
   compressions and sweeps, and the frontmatter and body for any claim file
   the drain created. The user reviews the pass as a pass, hunk by hunk; the
   drain's verbatim moves have already landed through `bookkeep.py`, reviewed
   as the dry run and the diff it produced.
