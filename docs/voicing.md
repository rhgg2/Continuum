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

The policy used to exist twice with different fidelity: tm's flush
pre-clip scan had the full verdicts, while mm's load-dedup killed
blindly — it ran before the metadata join and couldn't see intent. The
blind copy ate voices on external collapse (Ctrl-Z or a foreign script
moving two authored notes onto one raw). Hoisting the verdicts and the
separation walk into one pure module lets mm and tm consume the same
policy (`design/archive/same-pitch-enforcement.md`).

`resolveGroup` sorts its group `(ppq, ppqL)` in place before walking,
so callers can't skip the ordering the nudge cascade depends on.

## Enforcement layers

The invariant is mm's; enforcement is layered, outermost first:

- **tm separation sites** (reseat, flush scan, tail walk) separate
  in steady state and keep tm's live clones coherent — see
  `docs/trackerManager.md` § Same-pitch onset separation.
- **mm write-path backstop** repairs anything a write path missed, at
  the outermost `modify` unwind — `docs/midiManager.md` § Mutation
  contract. In steady state it finds nothing.
- **mm load-dedup** applies the verdicts to whatever arrives from the
  take, so an external collapse nudges instead of eating a voice.
- **midiBlob.serialise** asserts, warn-and-write: a collision reaching
  the codec is an upstream bug reported loudly, never edited silently —
  the codec stays a pure bijection.
