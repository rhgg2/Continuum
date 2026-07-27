# pipe dreams — designs we are deliberately not building

> opened: 2026-07-26 · status: standing collection; nothing here is queued
>
> A home for ideas settled enough to be worth writing down and
> deliberately not on any plan. Nothing here is queued, and nothing here
> should be started because it looks ready.
>
> Each entry says what it is, what it would cost, and — the part that
> earns its keep — **the obligation on today's work**: the small
> discipline that keeps the door open without building anything. An
> entry leaves this doc in one direction only, promoted into its own
> design doc when something real wants it.

## Param modulation — a stage that bends a sibling stage's parameter

> From `design/note-macros-v2.md` § The chain surface. Read § The fx
> chain first for the stream/stage/dest vocabulary this uses.

"Bend the vibrato rate in flight" generalizes `dest` once more:
`param:<stage>.<field>` — a continuous stage whose output targets a
sibling stage's parameter instead of a MIDI wire. Depth 1 only, the
modulator living inside the chain it modulates. That constraint is what
keeps it a comb rather than a graph: no modulator of a modulator, no
cross-chain reach.

It is the natural end of the transformer/source line the chain draws. A
transformer rewrites event *values* and nudges *discrete* timing; it
cannot coherently rewrite a continuous source's **rate**, because
vibrato's breakpoints are placed by accumulated phase and resampling
them loses coherence. So rate/period/phase stay source params — and
modulating a param is how you move one without resampling anything.

**The obligation now:** keep `dest` a clean single axis. Nothing else.

## Stepped feed — modulation's contract

A modulated param stops being a scalar and becomes a control signal, and
the contract must decide who integrates it over time. Handing bodies
`params:at(t)` leaves integration as per-author folklore — a closed-form
body under a varying param fails silently (vibrato's sine needs a phase
accumulator once `period` moves; the classic FM error).

The structural answer: the **runner drives the body through time** —
`expand(block, params, ctx, state)` — resolving modulators to *constant*
params per block and threading explicit state (vibrato: phase; arp: step
index; retrig: next fire). A block is just a **narrowed host** (window
shrunk, streams sliced), and a one-shot kind is a stepped kind run with
one block spanning the window — the same no-special-case-head move the
chain made when it retired the source/transformer role split.
Whole-window properties (vibrato's end-of-window re-centre) become runner
epilogues, not block business.

Blocks are **segment-driven, not fixed-size**: edges at the union of
modulator breakpoints and membership note-on/offs (sample-and-hold at the
modulator's own breakpoints — exact, no block-size/aliasing trade). With
membership edges in the cut, params *and* polyphony are block-constant —
a block is precisely an interval of constancy, and bodies go
straight-line: no scanning, no mid-block cases.

**Notes arrive as held + triggered.** Per block: `held` = sounding at
block start (onset before it), `triggered` = note-ons inside it. No
`released` set — every note carries `endppqL`, so gate-shaped bodies read
release edges off the events. The partition **tiles the membership**:
each note is triggered in exactly one block, held in every later block it
spans; union over blocks = today's overlap query. The degenerate
one-block case is *more* correct than the flat list (`playingAt` stops
being something arp implements and becomes `held ∪ triggered`, handed
in). Simultaneous onsets in `triggered` order by ascending realised pitch
so "first triggered" stays G4-stable; segmentation is a pure function of
the input streams, so determinism holds by construction. Cost stays
proportional to event count, all offline; the shape also mirrors the
node's per-block run one level up, and is streaming-ready if live feeds
(preview, plink) ever want it.

**The obligation now is a writing discipline only**, same register as the
ctx discipline: shape new continuous kinds *incrementally* — phase
accumulators and step loops, never closed forms over the window — so the
window can shrink without rewriting the body. Discrete kinds are already
step-shaped.

**When it lands, the build order writes itself:** segment cutter + state
threading in the runner, vibrato ported as the proving kind.
