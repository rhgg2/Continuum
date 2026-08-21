# voicing

Same-pitch voice policy: of two notes colliding on one raw
`(ppq, chan, pitch)`, which is a duplicate to kill and which are
distinct voices to separate. Pure module — no state; callers stage
every mm write themselves.

## The model

MIDI voices one note per `(chan, pitch)`: two note-ons at the same raw
onset are illegal — mm's token index and the wire format both key on
it. But raw collision does not mean same *voice*. Intent lives in the
sidecar metadata — `ppqL` (logical seat), `detune`, `derived` — and two
notes with distinct intent are two voices that swing, delay, or a
detune cluster happened to collapse onto one raw. Killing one destroys
authored music; the policy instead nudges the successor to
`prev.ppq + 1` so each voice keeps its own onset (and with it its own
pb absorber).

A collision is a genuine duplicate only when the notes carry the same
intent — equal `ppqL` and `detune` — or when one is a regenerable
fxNote (`derived`), which always loses to an authored note. Duplicates
collapse to the longer (authored `endppqL` preferred over raw
`endppq`). Foreign MIDI, carrying no intent at all, degrades to the
blind keep-the-longest this policy replaced.

## Why one module

mm and tm consume the same policy from this one pure module. mm's load-dedup
runs before the metadata join, so it cannot see intent: judging on its own it
would eat voices on external collapse (Ctrl-Z, or a foreign script moving two
authored notes onto one raw).

Verdicts, not traversals. `separateOnset` judges one collision and says
nothing about which notes to ask or in what order; tm's tail walk asks
only the notes its interval dirt has news for, and mm's backstop asks a
whole group. The module exported the whole-channel walk too until
2026-07-17, when the tail walk went interval-native and no caller wanted
it any more (`docs/trackerManager.md` § Rebuild: tail walk).

`resolveGroup` sorts its group `(ppq, ppqL)` in place before walking,
so callers can't skip the ordering the nudge cascade depends on. A
caller that already holds the group in that order — tm's flush scan,
bucketing the raw index's `rawThenLogical` walk by pitch — enters
through `resolveSorted`, which is the same walk without the sort.

Deliberately a sibling entry point and not a `presorted` flag on
`resolveGroup`: a flag would let any caller assert its way past the
ordering, which is the one thing the in-place sort exists to prevent.
The second door still names the ordering it requires, in its contract,
so the guarantee is made once at a seam that has a name.

## Enforcement layers

The invariant is mm's; enforcement is layered, outermost first:

- **tm's tail walk** separates in steady state and keeps tm's live
  clones coherent — see `docs/trackerManager.md` § Same-pitch onset
  separation. The reseat and the flush scan separated too until
  2026-07-17; both were redundant layers below it.
- **mm write-path backstop** repairs anything a write path missed, at
  the outermost `modify` unwind — `docs/midiManager.md` § Mutation
  contract. In steady state it finds nothing.
- **mm load-dedup** applies the verdicts to whatever arrives from the
  take, so an external collapse nudges instead of eating a voice.
- **midiBlob.buildWire** asserts, warn-and-write: a collision reaching
  the codec is an upstream bug reported loudly, never edited silently —
  the codec stays a pure bijection.
