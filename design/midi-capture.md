# midi capture — the keyboard's held set, mirrored to the grid

> opened: 2026-08-05 · status: design settled; one open question blocking
>
> Working design doc. Promotes `todo.md`'s "Live/MIDI-in capture."

Continuum has no MIDI input path at all. Note entry is QWERTY:
`cmgr:noteChars(char)` maps a key to a semitone and an octave offset,
`pitchFromKey` snaps that onto the active temper, and `tv:chordStrike`
assembles a chord while shift is held.

The pitch: a controller's **held set** is mirrored into the grid
continuously, and the sustain pedal is the only clock.

## What release means

**1** Two readings of release present themselves, and the design turns
on refusing the first. On that reading release has two jobs — before
anything is committed it *removes* the note from the grid, and after a
note has been carried across a step it *ends* it. Two jobs means a flag
recording whether the gesture has committed yet, and a flag means two
paths that have to be kept agreeing.

**2** They are one job. **A note's extent is the rows it was held
across, and a note of zero extent does not exist.** Press at row 0 and
release at row 0: extent zero, nothing was ever there. Press at row 0,
stomp to row 4, release: it spans 0→4, and row 4 is free for whatever
is pressed next. Removal is the degenerate case of ending, not a
separate phase of the gesture.

**3** Release at row R ends the note *at* R rather than short of it, so
consecutive pitches are legato by default. Staccato is not a gesture;
it is a smaller `advanceBy` and explicit rests.

## What the rule pays for

**1 Length.** Every other step-input implementation makes note length a
setting chosen beforehand and corrected afterwards. Here it is the one
thing the hands are already saying. `advanceBy` exists already
(`configManager.lua:38`); a note held through three stomps at
`advanceBy=4` is twelve rows long, and no number was typed.

**2 Audition.** Press keys, hear them, watch them appear, release: gone,
because their extent is zero. Hunting for a voicing at the row you
stand on costs nothing and commits nothing. The uncommitted audition is
not a feature bolted to the model; it is the model's degenerate case
put to work.

**3 Rests.** Stomp with the hands off the keys. Silence is written by
playing nothing — the one way of entering rhythm into a tracker that
does not involve counting rows.

## The pedal is the only clock

**1** Between two pedal presses neither ordering nor timing matters.
Every event lands on the current row, so releasing one chord and
pressing the next need not be simultaneous, or close, or even in that
order.

**2** One case looks as though it should break this, and cannot arise.
Two events on one row conflict only when they are the same pitch in the
same lane — release C, press C, and which came first decides between a
re-articulation and a collision. But a key already held cannot be
pressed again. Re-articulating a pitch on a single controller *must* be
release-then-press. The hardware enforces the invariant we would
otherwise have to.

**3** The clock leaks once. A release within a frame of the stomp is
genuinely ambiguous: `MIDI_GetRecentInputEvent` returns sequence
numbers, so the true order is recoverable, but the player's intent at
that resolution is not. We honour the sequence order and refuse a
tolerance window. Being wrong costs one step of extra length, visible
in the grid the instant it happens and cheap to fix; a window would
trade that for a rule nobody can predict. Releasing cleanly before the
foot lands is something organists do without thinking about it.

## There is no capture mode

**1** The tempting design gives capture an armed mode, because that is
what every DAW does, and because a mode is where the device filter and
the pedal binding would naturally hang. It is wrong here, for a reason
worth stating plainly: **the cursor already carries what the mode would
carry.** A tracker cursor is always somewhere, and where it is says
whether writing a note is meaningful.

**2** So input is live always, and the division is between sounding and
writing. The controller *sounds* unconditionally — audition costs
nothing and is useful wherever the cursor stands. It *writes* under
exactly `tv:chordStrike`'s existing precondition
(`trackerView.lua:1105`): a note column, on a pitch stop, at that stop's
start. Off that cell the keyboard is merely a keyboard and the document
is untouched.

**3** With no mode there is no disarm, so held notes terminate on
whatever interrupts them — page change, take change, the rebuild paths
that route to `chordAbandon` today. They terminate at the current row
rather than vanishing, which is the extent rule again and not a second
decision.

**4** The cursor may also be moved by hand mid-hold, and the rule
already answers it: a note ends wherever the cursor is when the key
comes up. Moving the cursor back past a note's own onset drives its
extent to zero, and a note of zero extent does not exist. Consistent,
if strange to watch.

## The open question — what capture does to notes already there

**1** Typing overwrites the cell under the cursor, and should: you
aimed at it. Capture is ambient, the keyboard being live whether or not
you meant to write, and the same allocation would make a stray press
destructive. Two of `chordStrike`'s behaviours carry the danger.
`strikePitch` assigns straight over a note occupant
(`trackerView.lua:800`), and the adopt branch enrols an existing
sounding note into the gesture (`:1138`) — which would give a stray
press the power to truncate document material on release.

**2** The proposal is that capture allocates onto the lowest lane free
of *any* note, not merely free of gesture members, and never adopts.
Capture then only ever adds. The cost is that a pass over existing
material sprouts lanes beside it rather than replacing it, which may be
precisely wrong for overdubbing onto a part you meant to correct.

**3** Nothing below depends on the answer, but the answer decides
whether capture is safe to leave live, which is this document's central
claim. It wants settling before the gesture is built.

## What this is not — `chordStrike` with a moving row

**1** `tv:chordStrike` pins one row for the gesture's whole life
(`trackerView.lua:1108`). This gesture has a cursor that moves while its
notes stay anchored to the rows they began on. That is not a parameter
change.

**2** What carries over is the layer beneath: `strikePitch`, the lane
allocation, `chordCell`'s discipline of re-resolving members through
`cells[row]` rather than holding event refs (`:1082`), the audition
trio, `tuning.snap`. Members grow a field — `{ pitch, lane, chan }`
becomes `{ pitch, lane, chan, onsetRow }` — because the row has stopped
belonging to the gesture.

**3** `chordBackspace` and `chordNudgeVel` do not come along. They
compensate for hardware that can report neither a held set nor a
velocity, and a controller reports both.

**4** The unification is tempting and should be refused. Typing a chord
is a sequence of taps; the hand is not holding C, E and G down
together, and QWERTY cannot observe a held set. One shared gesture
would be one implementation and one simulation of it.

## The seam

**1** Two pieces, split at the REAPER touchpoint. A `midiInput` module
owns the poll: `MIDI_GetRecentInputEvent` walked back from `idx=0` to
the last sequence number seen, decoded into ordered note-on / note-off /
CC64, called from the coordinator's frame. It holds no view state, so
specs can drive it on production shape.

**2** The gesture lives in `trackerView` beside `chordStrike`, because
`strikePitch`, `chordCell` and the lane allocation are its private
locals, and reaching them from elsewhere would mean publishing three
functions to serve one caller.

## Build order

1. **The poller** — `midiInput`, decode and sequence-order only.
2. **The gesture** — writing live per event and flushing through
   `settleTypedEdit` exactly as `chordStrike` does today
   (`trackerView.lua:1089`).
3. **Undo granularity, for both keyboards at once** — v1 inherits
   `chordStrike`'s precedent, so every press and release reaches the
   take, including the presses that vanish on release. That is the
   wrong granularity for both gestures, and fixing it for one alone
   would leave the two differing for no reason a reader could recover.

## Not v1

**1 The pedal as a bindable keyspec.** `commandManager` owns a flat
command namespace and scopes own the keymaps (`commandManager.lua:3`);
a MIDI event admitted as a keyspec (`:12`) would make the pedal
rebindable and stand it in the help overlay beside everything else. v1
hard-wires CC64 to `ec:advance()`. The generalisation is real, but it
is a commandManager change wearing a capture hat.

**2 Timed capture.** `MIDI_GetRecentInputEvent` returns a timestamp in
samples relative to now, and a note carries a delay offset on its raw
note-on (`docs/timing.md`). Playing in loosely and getting rows *plus* a
delay value carrying the feel is beyond this document's model, which
needs the pedal to advance a row; a note crossing a row boundary
unbidden must then decide whether it is long or new. A different
design, sharing this one's poller.
