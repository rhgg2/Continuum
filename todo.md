- CC smoothing
- 14bit CCs in tracker view
- wm - midi channel filter
- wm - master multi-outs / deal with restriction on single audio feed
  to master
- wm - send from folder child track direct to master
- MIDI PDC alignment at a merge — verify pdc_midi=1 if MIDI-vs-audio
  skew shows up. 
- component auto-stack / snap to grid / autolayout
- fx containers as first class entities
- containers with holes (wiring macros)
  - gainstage
  - pre/post emphasis
  - mid/side
  - bandsplit
  - magic polysynth
  - drum pad chains
- fx on groups (group instances)
- randomness/humanize as an fx (overlay OR note generator)
- cv-2
- chord-stamp, roll, strum, echo
- scales
- Live/MIDI-in capture — promoted to `design/midi-capture.md`.
- Quarantine UX (Open questions) — a darkened component still needs to
   signal why it went dark (feedback loop / bus-aware FX) and its
   recovery path in the wiring view.
- A region-parked note's own fx stays suppressed.
One loose thread I'd flag again, since it's now measured rather than
suspected: swapping `groupDuplicate`'s destination clear to run *after*
the projection is caught by nothing in the 2241-test suite. The
ordering is real — a refused duplicate or paste empties the
destination and mints nothing over it — and it belongs to
`groupDuplicate`, not to freeze.
