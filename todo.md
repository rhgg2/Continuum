- tuning editor
- FX, ideas:
  - flam
  - trill
  - cc macros
  - arpeggio
- automation smoothing
- 14bit CCs
- move to command based key/mouse interactions
- fix prefix argument / scale
- undo for groups feature / swing / tuning changes
- can ppq logical be float everywhere?

  Reframing to "what a competent tracker offers that Continuum's
  tracker doesn't" — and discounting what's REAPER's job (transport,
  mixing, FX hosting, song arrangement, undo via util.atomic) and
  what's already there (mute and solo, quantize incl. keep-realised,
  swing/groove, microtuning, copy/paste/interpolate/duplicate/block
  ops, CC automation with the curve editor, per-note delay/detune,
  groups+instances for pattern reuse). The genuine domain gaps:

  1. No live/MIDI-in capture. Entry is keyboard step-only — there's no
  path that records a played MIDI phrase into the grid (real-time or
  step-from-keyboard) and quantizes it on the way in. REAPER records
  to the item, but the tracker has no capture verb of its own. This is
  the most conspicuous missing tracker affordance.

  2. No note generators — arpeggio, chord-stamp, roll/retrigger,
   strum, echo. One keystroke to lay a chord or arpeggiate/roll a
   selection is a tracker staple; nothing here does it. The chord hits
   in the code are key-combos, not musical chords. This is the same
   cardinality-changing genus randomness.md explicitly fences off
   ("random generation … a different genus"), so it's deliberately
   unaddressed rather than overlooked — but as a capability it's a
   real absence, and a notable one for a tracker.

  3. No scale/key constraint. tuning is temperament (microtuning), not
   diatonic key. There's no constrain-to-scale on entry and no
   transpose-within-scale; pitch change is generic coarse/fine nudge
   on the focused field, with no named selection-wide or scale-aware
   transpose verb. Modern trackers and most piano-roll tools offer
   this.

  4. Humanize/randomize. Absent as a shipped capability — this is
   exactly the randomness.md displacement-noise feature, the one thing
   genuinely queued.

  The classic per-cell effect command column
  (volume/portamento/vibrato/sample-offset) I'd not call a gap: it's
  largely subsumed by typed/CC columns plus the curve editor. The
  parts of it that aren't subsumed are the note-generating commands —
  arpeggio and retrigger — which fold into gap #2.

  So, ranked by how much a tracker user would feel the absence: note
  generators (arp/chord/roll) and live MIDI capture first, scale
  constraint second, humanize third.
