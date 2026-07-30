# The rebuild pipeline, in Simplified Technical English

This document tells you how the trackerManager rebuild pipeline operates.
It is a high-level description. It does not give the detail of each stage.

The text obeys ASD-STE100. Thus the sentences are short, the voice is
active, and the tense is the simple present. Each sentence has one topic.

This document says the same thing as `docs/trackerManager.md` § Rebuild,
but in a different register. That section is the authority. If the two
disagree, the other document is correct and this one is out of date.
Refer to `docs/timing.md` for the two time frames.

## Technical names

| Name | What it is |
|---|---|
| tm | trackerManager. It holds the 16 channels of columns. |
| mm | midiManager. It holds the MIDI events of the take. |
| cm | configManager. It holds the configuration. |
| ds | dataStore. It holds the data of the project. |
| take | The MIDI item in REAPER. |
| channel | One of the 16 MIDI channels. |
| column | A list of events in a channel. |
| lane | The position of a note column in its channel. |
| ppq | A position in time. |
| logical frame | The time that the user writes. |
| realisation frame | The time that REAPER stores. |
| swing | The rule that changes logical time into realisation time. |
| delay | A time offset on one note in the realisation frame. |
| detune | A pitch offset on one note. The user writes it. |
| absorber | A pitchbend event. It gives a note its detune. |
| dirt | A record of the channels that changed. |
| park | To move an event out of the take, but to keep it in ds. |
| fx region | An area that makes derived events. |

## What a rebuild does

A rebuild reads the events from mm. Then it writes the columns of the 16
channels. The columns must agree with the events in mm.

A rebuild does more than a copy. It also does this work:

- It puts each note in its lane.
- It calculates the two times of each event.
- It writes the derived events of the fx regions.
- It sets the end of each note.
- It writes the pitchbend stream for the detune values.

## When a rebuild starts

Three sources start a rebuild:

- mm sends `reload`. mm sends this signal after each change to the events.
- cm sends `configChanged`. One configuration key is for the view only.
  That key does not start a rebuild.
- ds sends `dataChanged`. tm rebuilds for five keys of the project data:
  `swing`, `fxRegions`, `fxParked`, `extraColumns` and `noteDelay`.

`tm:requestRebuild()` does not start a rebuild. It tells the next rebuild
to continue past the third gate.

## The three gates

`tm:rebuild` stops immediately in these three conditions:

1. A rebuild is already in operation. A rebuild must not start in a rebuild.
2. mm has no take. The user deleted it. tm makes no change, and the view
   keeps its last data.
3. There is no work. No channel is dirty, no swing changed, mm did not read
   all its events again, the take did not change, and no caller made a
   request.

The third gate is important. Many signals occur when nothing changed. This
gate makes those signals almost free.

## Before the stages

tm does four steps before the stages:

1. It removes the swing values from the cache. The rebuild is the point
   where cm and mm agree again.
2. It keeps the columns of each clean channel. A clean channel has no dirt.
   Thus its columns are still correct, and no stage looks at them.
3. It makes an empty channel for each dirty channel.
4. If mm read all its events again, tm reads its index again.

Then tm opens one mm batch. All the stages put their operations in this
batch. Thus REAPER receives one write, and the index changes one time.

## The stages

The stages operate in this sequence.

1. **The internal notes** — `rebuildInternals`. The stage divides the notes
   of mm into three groups: internal, external and derived. An internal
   note has correct Continuum data. The stage copies each internal note
   into its lane. If the swing of the channel changed, the stage
   calculates the realisation time of the note again.

2. **The cc walk** — `rebuildCCs`. The stage reads the cc, at and pc
   events. It calculates the two times of each event under the current
   swing. Then it writes the events into their columns. It does not do the
   pb events. The absorber stage does them.

3. **The extra columns** — `rebuildExtraColumns`. The user can open a
   column that has no events. This stage makes those columns. It also
   increases the count of note lanes if the channel needs more.

4. **The external notes** — `rebuildExternals`. An external note comes from
   a different program. A note whose data does not agree with its position
   is also external. The stage puts each external note in a free lane. A
   subsequent stage can make the note shorter, but it must not move the
   start.

5. **The samples** — `stampSamples`. A note that has no sample gets the
   sample of the pc before it.

6. **The windows** — `computeFxWindows` and `generators.parkWindows`. tm
   calculates the time window of each fx region. It also calculates a
   window for each note that makes derived events. The subsequent stages
   use these windows.

7. **The park** — `rebuildRegionPark`. A window of the replace type covers
   some notes and some ccs. Those events must not sound. The stage moves
   them out of the take and keeps them in ds. If a window no longer covers
   an event, the stage puts that event back in the take.

8. **The poly aftertouch** — `rebuildPA`. Each pa event applies to one
   note. The stage puts each pa event in the column of that note. The
   stage operates here because it needs all the notes of the two note
   stages.

9. **The fx events** — `rebuildFx`. Each producer makes its derived events
   in its own window. The stage compares the new events with the events of
   the last rebuild. It keeps the events that did not change, and it
   removes the events that the producer no longer makes. It gives the list
   of new notes to the subsequent stage.

10. **The tail walk** — `rebuildTails`. Two notes of the same pitch can
    start at the same ppq in the realisation frame. MIDI permits only one.
    Thus the stage moves the second note one ppq later. Then it sets the
    end of each note. The end must not go past the next note in the same
    lane or at the same pitch. This stage writes all the note operations of
    the pipeline.

11. **The absorbers** — `rebuildPbs`. The stage puts an absorber at the
    start of each lane-1 note that has a detune value. It calculates the
    pitchbend value of each absorber from the final position of the note.
    Then it writes the pb column.

12. **The program changes** — `rebuildPCs`. In tracker mode, tm calculates
    the pc stream of each channel again from the notes.

## After the stages

tm does four steps at the end:

1. It writes the window set into ds. The next rebuild compares its own
   windows with this set.
2. It removes the staged operations that no stage sent to mm.
3. It records the dirty channels for the mute step. Then it removes the
   dirt.
4. It records the inputs of the derived data.

Then tm closes the batch and sends the `rebuild` signal. The layers above
tm read the new columns. The signal tells them if the take changed.

## Why the sequence is important

Each stage uses the results of the stages before it:

- The windows need the notes. Thus the two note stages operate first.
- The park stage needs the windows.
- The fx stage needs the parked notes, because a parked note can be a
  producer.
- The tail walk needs all the notes. The fx stage makes some of them. Thus
  the tail walk operates after the fx stage.
- The absorber stage needs the final position of each lane-1 note. The tail
  walk can move a note. Thus the absorber stage operates last but one.

A stage in an incorrect position reads data that is not complete. The
result can look correct in one rebuild and be incorrect in the next one.
