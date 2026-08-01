# map navigation — what the maps cost to read

> opened: 2026-08-01 · status: in flight — `plan/map-navigation.md`
>
> Working design doc. The measurement below is done and is reported in
> full; it is the load-bearing part of this doc. The design that follows
> it is a proposal awaiting a plan.

## Problem

The `.map` layer answers *where does X live* well. It does not answer
*what does X call*, and inside a single file it answers almost nothing:
`trackerManager.map` lists **173 private functions and zero edges between
any of them**. `CALL_RE` (`tools/map_extract.py:72`) requires a `.` or `:`
separator, so a bare `renderUnion(...)` matches nothing at all — the
intra-file call graph is not sparse, it is absent by construction. A
second source is extracted and then discarded: `self:foo()` calls are
found and skipped at `map_extract.py:545` as "not an outbound edge",
which is true and beside the point.

The question was what to do about it, and the first answers reached for
were better *parsing* — tree-sitter or full-moon for a real AST, `luac -l
-l` for scope-resolved upvalues and field access. Both are real
capabilities. Neither turned out to be the thing.

## Why we measured instead of asking

The obvious way to choose is to ask the agent which tools it wants. That
instrument is close to worthless: it has no clock, its memory of a session
is a transcript in which a six-hop trace and a one-shot lookup look
identical, and the question comes from the person who built the tools. It
returns "pretty happy" almost regardless of the truth.

What *is* reliable is structural and already recorded. 1072 session
transcripts sit in `~/.claude/projects/`, and every tool call ever made in
this repo is in them. Crucially, **tool calls in one assistant message ran
in parallel; calls in consecutive messages are serial**, each blocked on
the last. Round-trips are the unit of cost, and they are countable.

`tools/navigation_survey.py` does the counting. Re-run it after any
tooling change — the chain histogram and the scattered-jump rate are the
numbers that should move.

## What the corpus says

494 sessions containing tool calls; 18,942 main-thread calls (subagents
excluded — they are bulk readers by design and would flatter the figures).

**Navigation is overwhelmingly serial.** 2,608 navigation runs carrying
11,888 turns. 953 runs are ≥4 dependent round-trips, and those carry
**77.7% of all navigation turns**. The deepest single run is 44
consecutive blocked turns.

**The serialism is intra-file.** Of 1,385 consecutive read-turn pairs,
**50.4% re-read the same file** at a different range. Of those:

- **81.3% are scattered jumps**, not sequential chunking
- median jump **362 lines**, p90 **1,940 lines**
- **481 jumps are backwards**, revisiting earlier code

Jumping 362 lines away and later back is call-chain following. There is no
other reading of it.

**One file dominates.** `trackerManager.lua` is 42% of all same-file
walking (295 of 698 pairs) and takes **3,292 redundant touches** across
the corpus, 4× the next file. It is 5,121 lines, 173 private functions,
78 outbound edges, zero internal ones.

**The maps are consulted, then found insufficient.** 73% of reads of a
mapped `.lua` happen after a `map_query` in the same session. Reads are
2,071 ranged against 690 whole-file, so map line numbers *are* being used
— just many of them per question.

**Incidental:** the built-in `Grep` was used **once** in the entire
corpus; `grep_window` displaced it completely. But `grep` via Bash ran
1,132 times, so shell fallback is still substantial. 380 navigation calls
came back empty, and the next move was usually shell grep (159) or another
search (109) — silence is not trusted, it is re-asked by hand.

One caveat on the instrument: **the session running the survey is inside
the corpus it surveys**, and is still being appended to. Two runs minutes
apart disagreed by 2 runs in 2,610 — the measuring session had navigated
in between. Immaterial at this scale, and worth knowing before reading a
small before/after delta as signal.

## Two traps

Both of these looked right and were not. They are recorded because the
tidy version of this design would omit them and invite the next reader
straight back in.

**Accuracy is not the bottleneck.** The investigation opened on parser
correctness — the multi-assignment limitation at `map_extract.py:578`, a
live bug where `extract_uses` splits on `--` over raw lines
(`map_extract.py:538`) so a `--` inside a string truncates the scan,
shadowing-blind alias resolution, the `ATTACH_GAP = 3` adjacency
heuristic. All real. None of them cost measurable time. A map that is 3%
more correct saves nothing; the cost is round-trips, and correctness does
not touch round-trips.

**Transitive expansion is the answer to a question nobody asked.** Once
"round-trips are the cost" is established, a tool that expands a call tree
N levels deep in one call follows so naturally that it survived until the
data hit it. It does not survive the data. Of 394 consecutive
`map_query → map_query` pairs, only **19.3%** carry a term from the
previous query's *result*; **50% have no `kind` filter on either side**.
The actual pairs are `*col* → *grid* → *lane*`, `*status* → *toolbar*`,
`*park* → *region* → *derived*`. Those are **vocabulary searches** — not
knowing what a thing is called and trying synonyms. A transitive expander
would have elaborated a graph nobody was walking.

(The term-carry test is a proxy and could undercount, since a concept can
be carried without a literal token; treat 19.3% as a floor. The 50%
kind-less figure is direct and does not depend on the proxy.)

## The design

### Intra-file call edges

One edge list per file: `(caller, callee, line)` for calls to functions
declared in the same file. Two sources, very different costs:

1. **`self:foo()` — already extracted, currently discarded.** Removing the
   skip at `map_extract.py:545` and routing those edges to the new list is
   nearly free.
2. **Bare `foo(...)` — needs a new pass**, but a small one: match
   `\b(name)\s*\(` over already-masked code for names in the known
   private-function set, attributed with the existing `caller_at(line)`.

The edge list is one thing; it should be *rendered* twice, because the
forward and reverse questions are both asked and neither should need a
query-time inversion:

- **Forward, at the site** — on the `@fn` row, where the reader already
  is, so scanning the function inventory gives the graph shape for free:

      @fn rebuildPipeline(seed)  @ 4801-4890
          -> sortByPPQ:4812  dirtyChan:4830,4841  renderUnion:4877

- **Reverse, as an index** — a `# Calls (intra-file)` section, one row per
  callee with callers grouped, reusing `render_caller_groups` so it parses
  like every other row:

      @call sortByPPQ  @ rebuildPipeline:4812 flushParked:1450

The rejected alternative is extending `@use` with a `local` kind. It is
the least new machinery and it is wrong: `usedby` scans every map for
callers of a symbol, so every internal helper call would pollute
cross-module caller queries unless the kind were filtered at every call
site. The direction differs, so the row should differ.

### Vocabulary — unsettled

The 197 kind-less consecutive `map_query` pairs say the agent frequently
cannot name what it is looking for. That is a *discovery* failure and it
was on nobody's list before the corpus produced it. Candidate shapes:
synonym/alias support, fuzzy matching, or returning near-misses instead of
nothing. It wants its own look before anything is built.

Relatedly and more cheaply: 380 empty results, and `map_query` cannot
currently distinguish *no such thing* from *your regex was wrong* from
*not indexed*. "0 matches; `module=` matched 0 of 66 modules; nearest:
`trackerView`" would stop a wasted hop, or a false conclusion.

## Mechanism: park the rewrite

Nothing above needs tree-sitter. The winning change is small and additive
to the existing extractor, which argues against the ambitious option on
its own terms — the AST rewrite was justified by accuracy, and accuracy is
the thing the corpus says is not costing anything.

`luac` keeps a narrower role, and a good one. A module-level helper called
from a method is, in bytecode, exactly `GETUPVAL` followed by `CALL`, so
`luac -p -l -l` yields the same intra-file call graph with shadowing and
aliasing already resolved by the compiler. That makes it an **oracle**,
not a producer: build the cheap regex version, diff its edges against
luac's across all 66 modules, and upgrade the mechanism only if the
disagreement rate turns out to matter. Two independent derivations of one
fact is a directional check; a spec written against our own parser is not.

(`luac -l` without `-p` writes `luac.out`. Its listing format is
undocumented and version-coupled, which is tolerable for a hand-run oracle
and would not be for a shipped dependency. Instruction order is not source
order — the compiler reorders, so line numbers within a prototype are not
monotonic.)

**Migration discipline.** 66 maps and `map_query` depend on the format.
Any change to how the extractor parses should hold the emitted `.map`
byte-identical first, diff all 66, and treat every non-zero diff as either
a new bug or a provable improvement audited one at a time. New sections
land only after that gate. Otherwise a fix and a regression are
indistinguishable.

**The gate needed `sha=` out of the header first** (2026-08-01). The
discipline above quietly assumes byte-identity is *reachable* on a clean
tree. It wasn't. The header carried `sha=`, the source's last-commit short
hash from `git log -1` at generation time — and maps regenerate on edit,
which is always before the commit exists, so a committed map's sha was one
commit stale by construction. A fresh regen disagreed on 125 of 317 maps
on that field alone, with zero content drift anywhere in the corpus. 39%
wrong was the steady state, not a backlog.

That is fatal to this section specifically: a gate reporting 125
differences on a clean tree cannot tell a regression from a fix, nor
either from a commit having happened — the exact confusion the paragraph
above exists to prevent. Nothing read the field (`map_extract` wrote it;
`server.py`'s header regex required it only to discard the capture), so it
was dropped and the corpus regenerated: header lines only, verified zero
non-`sha` differences. Full regen fell from 12s to 1.7s, the 317 `git log`
subprocesses having been most of the cost.

The trap worth naming is the tempting repair — keep the field, but make it
a content hash of the source rather than a git sha. Self-verifying, and it
makes a staleness check cheap enough to skip parsing entirely. It fails
here, and backwards: when the *extractor* changes, every source hash is
unchanged, so it would pronounce the corpus current at precisely the
moment every map in it is stale. Staleness in a derived corpus is a
property of the generator, not of the source.

**The gate's two modes came out asymmetric** (2026-08-01).
`tools/map_regen.py` now owns the source set — `*.lua` and `tests/*.lua`
→ `map/`, `tests/specs/*.lua` → `map/specs/` — and drives the extractor
in-process across all 318 in 1.6s. Where the design above was silent, two
choices, both falling out of one distinction: `--check` asks whether the
corpus can be trusted, `--write` makes it so. So an orphan — a `.map`
whose source is gone — fails `--check` and not `--write`, because a hook
regenerating a single edited file has no business failing over a stale map
nobody touched. And `--write` writes only the maps whose content actually
changed, so mtimes stay put.

That second one quietly settles part of a decision still ahead of it. The
hooks were to run something like `--stale-only` on two grounds, speed and
not rewriting 318 files per edit; the second is now true by construction,
so `--stale-only` has to earn itself on the 1.6s alone.

## Open questions

- What is the shadowing error rate of the cheap regex pass? Measurable
  against luac before committing to it. House style (long descriptive
  names, no gnomic abbreviations) suggests it is low; that is a guess.
- Are early-return guards worth surfacing? "This function does nothing
  unless X" is a recurring answer when tracing why something *didn't*
  happen, and it is invisible until the body is read. Untested — it should
  be checked against the corpus, not assumed.
- Do these numbers hold for subagents? They were excluded as bulk readers
  by design; whether their navigation is also chain-shaped is unknown.
- Does the vocabulary problem want synonyms, fuzziness, or better negative
  results? Unknown, and the three have very different costs.
