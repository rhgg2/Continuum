# interval dirt — dirty ppq ranges, not dirty channels

> Working design doc, **not started**. Successor to the
> `incremental-rebuild` programme (`design/archive/incremental-rebuild.md`,
> closed 2026-07-15). One idea: make the unit of derivation dirt a **ppq
> interval within a channel** rather than the whole channel. It subsumes
> that programme's one deferred gap — the fx dirt signal — which is why
> that gap was deliberately left undone rather than patched.

## Status at a glance

| | |
|---|---|
| state | pinned, unstarted |
| supersedes | `incremental-rebuild` gap 4 (fx dirt signal) |
| enduring model it changes | `docs/trackerManager.md` § Derivation dirt |
| the hard part | forward propagation (below) — everything else is bookkeeping |

## The problem it solves

Derivation dirt is currently a per-channel set, `dirtyChans`. A channel
absent from it freezes completely: its columns carry forward, its derived
notes/CCs/absorbers/PCs stand untouched in mm, and every gated stage skips
it.

fx breaks this. fx output regenerates every rebuild with **no change
tracking**, so fx-hosting channels are marked dirty *wholesale*, every
time. On a macro-heavy take — where most channels host fx — the gate
degrades toward doing nothing, and those takes get materially less of the
gating win than the headline numbers suggest.

The obvious patch is to give fx its own dirt signal by hashing the
generator inputs per host. That was **rejected**: it bolts a second dirt
axis alongside `dirtyChans`, to be plumbed through every stage that reads
it, and this project deletes it again. Two mechanisms wired together where
one suffices.

## The idea

Dirt becomes a set of intervals per channel. fx then needs no dirt signal
of its own, because the question answers itself:

> **a host regenerates exactly when a dirty interval intersects its window.**

That test is expressible against what the pipeline already computes.
`computeFxWindows` yields, for each fx host, a **logical-ppq extent** —
the voice's authored end, the take end, or the strict next same-lane
onset, soonest wins. Windows are already ppq ranges. Nothing new needs
representing; only the dirt does.

The channel model becomes the degenerate case (interval = the whole
channel), which is what makes the migration tractable: every stage can be
ported one at a time, and a stage that hasn't been ported yet simply
widens its interval to the channel and behaves exactly as it does today.

## The crux: forward propagation

**This is the whole risk.** Today's gate is sound on a blast-radius
argument: every derivation rule (tail clip/regrow, same-pitch cascades,
absorber reseats, PC streams, fx windows) is *intra-channel*, so a whole
dirty channel over-approximates the closure of any edit.

Intra-channel is not the same as **ppq-local**, and the distinction is the
project:

- **pb / absorber seats** run forward as a stream. A detune change
  perturbs seats onward until the next event that re-anchors the channel.
- **PC streams** run forward as a run-length encoding. Changing one note's
  sample changes the prevailing PC until the next note that explicitly
  sets one.
- **Tails** clip against the next onset — and *regrow* against it, so
  deleting a note reaches **backwards** to the preceding note-on too.
- **Same-pitch cascades** chain forward through the separation rule.

So a dirty ppq interval is not the blast radius. It is the **seed** of
one. Each stage needs a rule that closes its interval forward (and, for
tails, backward) to the next anchoring event before consuming it.

Get a closure rule wrong and the failure mode is **silent stale output** —
precisely the class the channel gate was chosen to make impossible. That
asymmetry should govern the whole design: spurious dirt costs one
re-derive; missed dirt writes wrong notes and says nothing.

Worst case a closure runs to the end of the channel, which *is* today's
behaviour. The win is that the typical case does not.

## What this does not buy

Worth stating plainly, so the project is scoped honestly rather than sold:

- **Not the one-note edit.** That path is already at a ~1.15ms floor, and
  its largest single item (`fire`, 0.53ms) is subscriber notification, not
  derivation. There is little left to gate away.
- **Not the bind.** A foreign-take bind marks everything dirty by
  definition — every event is genuinely new.

The win is concentrated on **fx/macro-heavy takes**, which is exactly gap
4's target, plus finer gating on fat multi-channel edits. If that is not a
shape of project you are working on, this buys nothing, and the honest
move is to leave the wholesale fx row where it is.

## Open questions

1. What is the anchor, per stage, that terminates a forward closure? Each
   needs naming precisely — that set *is* the design.
2. Where do intervals come from? mm's `reload` payload names channels
   today; it would have to name ranges.
3. How do intervals merge? A fat edit produces many; coalescing overlapping
   ranges per channel keeps the set small, but the closure must run
   *after* the merge, not before.
4. Is `noteLive` still the right carrier between fx and its downstream
   readers (`tails`, `pbs`, `pcs`)? Its current virtue — one gate, no
   cross-stage dirt plumbing — is worth preserving if the interval can
   ride it.
