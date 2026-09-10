# The lane bound — design

> opened: 2026-08-09 · status: in flight — plan/lane-bound.md, phase 4.

**A note's tail is two numbers in two frames: the lane bound is logical
and the wire bound is raw.** One expression states the lane bound, one
pass computes it, and the conversion to raw happens once, where the
number reaches mm.

## The lane span

Landed: `docs/trackerManager.md` § Lane occupancy holds the lane's
authored population and the one expression over it, § Tail walk the two
bounds.

## The lane pass

Landed: `docs/trackerManager.md` § The lane pass holds the pass, what it
writes, its gating and its carry.

## The wire pass

1. The wire pass is `rebuildTails`, narrowed. It runs after fx
   expansion, over the raw index together with the pass's derived
   notes, and it owns what MIDI makes true rather than what the author
   wrote.

1. It separates same-pitch onset collisions, nudging the successor to
   its predecessor's tick plus one, and a nudge marks its own note
   disturbed so the cascade carries forward.

1. It gives each derived note its lane bound, over the lane's on-take
   events together with the pass's derived notes — what sounds there —
   by the same expression the lane pass uses.

1. It then converts: `rawBound = max(ppq + 1, min(fromLogical(laneBound),
   nextSamePitch.ppq))`. That is the pass's only conversion of a tail,
   and the only tail number that reaches mm.

## What each frame owns

1. The logical frame owns the lane bound, and the lane bound drives
   `endppqC` and so the screen. A reader wanting to know where a note
   is drawn asks the frame and converts nothing.

1. The raw frame owns onset separation and the same-pitch clip. Both
   are facts about one voice per `(chan, pitch)` on the wire, invisible
   on screen, and neither carries a cue.

1. The two passes are separated by the fx stage, and the separation is
   exact: fx expansion reads lane bounds and writes none that the lane
   pass owns.

## Open

1. `overlap` has no authoring path. Three spec fixtures write it and
   one production site reads it, so the frame it is measured in is
   settled by this model rather than by anything that exercises it.

1. A window end's integer/float subtype changes the fx output. Handing
   `clipNoteHosts` a float numerically equal to the integer it had before
   churned twenty pb seats on one fixture, which is why `projectEvent` writes
   no bound. Where downstream the subtype is read is unestablished.

1. The take end is a fixed point of every swing projection, the boundary clip
   absorbing the final partial period, so the lane bound's `takeLenL` term
   converts nothing. Whether the term wants a conversion at all is a question
   for the walk, which hoists the same number.

1. The frontier and linear walks split the cost of a whole-channel
   traversal. Whether the wire pass, asking only about pitch, still
   wants both is a question for after the lane pass lands.
