- CC smoothing
- 14bit CCs in tracker view
- wm - midi channel filter
- wm - master multi-outs / deal with restriction on single audio feed
  to master
- wm - send from folder child track direct to master
- MIDI PDC alignment at a merge — verify pdc_midi=1 if MIDI-vs-audio
  skew shows up. 
- component auto-stack / snap to grid / autolayout
- drag samples to tracker page
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
- roll, strum, echo
- scales
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

- PA events inside a copied span ride through the structural emitter
  and land as notes at the destination. Predates this change; fixing
  it means deciding whether a copied PA follows its host note.
- `sample` is wired as a lane and will fill forward like velocity, but
  nothing exercises it — the specs cover pitch, vel and delay only. It
  needs tracker mode to have a part at all, so a case there would be
  worth having before anyone relies on it.
- add slot renumbering to "tidy" button in arrange view

Keyboard gaps read off manifest.lua (2026-09-02). None is in design/.

Mechanism exists, verb missing:
- tracker: loop the block (Play/Loop/Block) — tv:setLoopRangeQN over
  the selection's QN span; the map already sets a loop by drag
- tracker: mute / solo the cursor's channel, and unmute/unsolo all —
  tv:toggleChannelMute/Solo are reached only by a header click
- arrange: cut / copy / paste / select all — paste is am:duplicateTake
  per take with QN and track deltas, as the group-drag commit does
- tracker: jump to next / previous event in column, prefix-aware —
  Alt+Up/Down are spent on instances

Block transforms — translation (nudge) and dilation (scale) exist,
reflection doesn't:
- retrograde: reverse the block in time, note-offs re-derived
- inversion: reflect pitch about an anchor in cents, writing intent
  (tuning.transposeNote's sibling)
- humanize vel/delay over the block — the selection-edit face of
  "randomness/humanize as an fx" above; delay is already per-note

Larger:
- repeat last command (C-x z) — lives in cmgr, carries the prefix
- column reorder: move lane left / right
- typed filter over command labels beside the letter-walk menu;
  low confidence it earns its keep over walk + cheat-sheet
