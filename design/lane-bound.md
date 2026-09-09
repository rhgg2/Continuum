# The lane bound — design

> opened: 2026-08-09 · status: in flight — plan/lane-bound.md, phase 2.

**A note's tail is two numbers in two frames: the lane bound is logical
and the wire bound is raw.** One expression states the lane bound, one
pass computes it, and the conversion to raw happens once, where the
number reaches mm.

## The lane span

1. A **lane** is monophonic, so its population is a sequence of onsets
   and each event sounds until the next one. That is the whole of the
   geometry, and `eachLaneSpan` is the walk that states it.

1. The **lane bound** of an event is its own ceiling — its authored
   `endppqL`, or the take length where the ceiling is `util.OPEN` —
   clipped to the strict-next onset in its lane and floored at its own
   onset plus one. Chord-mates share an onset, so the seek is strict.

1. `overlap` is a per-note legato datum in logical ticks, added to the
   successor's onset, so a note with one overruns the next onset in its
   lane. It reaches no further than that lane: the wire bound clips it
   to the next same-pitch onset like any other tail.

1. Every term is logical: the ceiling, the successor's onset, the
   overlap, the take length and the floor. The lane bound is intent,
   and intent is the logical frame.

1. `frame.clippedSpanEnd` is that expression and the only place it is
   written. It takes the lane's population, so a caller chooses which
   population it asks about.

1. Its subject is a member of a population and carries the same shape:
   the column event, whose `ppq` is the logical onset and whose
   `endppq` is the ceiling. A caller holding a raw-frame entry reaches
   its column event by the seat stamp.

## Two populations

1. A lane's population has two halves, the column's events and the
   parked events that have left the take, and `frame.authoredEvents`
   joins them. Parking moves a note between the halves and moves no
   onset, so the population's onsets stand for the whole pass.

1. The **authored population** is that join. It answers an fx host's
   window end, a parked event's render clip, and the `endppqC` of every
   authored note.

1. The **full population** adds the pass's derived notes. It answers
   the `endppqC` of a derived note, which sits on a lane the region
   allocator gave it.

1. `allocateRegionLanes` seeds occupancy from the on-take spans, and a
   parked host's tiles occupy the lane it left. A lane's on-take
   successor is never earlier than its authored one, and derived output
   lies inside its region's window. So a derived note takes a lane only
   where the authored population has already ended, and fx expansion
   cannot move an authored note's lane bound.

## The lane pass

1. The lane pass runs at the head, after the stash render and before
   the fx window census. It walks each dirty channel's lanes ascending
   over the authored population and gives every event its lane bound.

1. It writes `endppqC` on the column event and on the parked render
   event, and it is what `clipNoteHosts` reads. One walk answers the
   three readers that each asked their own way.

1. Its output is channel-local: a lane bound reads its own lane's
   onsets and its own channel's take length. So it carries across the
   pass boundary with the channel frame, under the same carry that
   holds a clean channel's columns.

## The wire pass

1. The wire pass is `rebuildTails`, narrowed. It runs after fx
   expansion, over the raw index together with the pass's derived
   notes, and it owns what MIDI makes true rather than what the author
   wrote.

1. It separates same-pitch onset collisions, nudging the successor to
   its predecessor's tick plus one, and a nudge marks its own note
   disturbed so the cascade carries forward.

1. It gives each derived note its lane bound, over the full
   population, by the same expression the lane pass uses.

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

1. The wire pass picks a lane successor in raw order and reads its
   logical onset. A neighbour delayed far enough is taken for a
   successor of a note it does not follow. The lane pass walks the
   population in column order, so the question is settled there.

1. The frontier and linear walks split the cost of a whole-channel
   traversal. Whether the wire pass, asking only about pitch, still
   wants both is a question for after the lane pass lands.
