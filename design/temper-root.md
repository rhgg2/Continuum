# Design — The temper's root

> opened: 2026-08-10 · status: design note; not started

**A temper states where its scale sits in sound and which octave numbers
its steps carry, as one correspondence between a sounding pitch and a
scale coordinate.**

## What a root is

1. A temper's **root** is a correspondence: a `(pitch, detune)` on one
   side, the `(step, octave)` it names on the other. `(69, −101.27) =
   (10, 4)` says that MIDI 69, tuned a hundred cents flat, is the tenth
   step of octave 4.

2. Four authored fields carry it — `rootPitch` and `rootDetune` for the
   sounding pitch, `rootStep` and `rootOctave` for the coordinate.

3. The default root is `(0, 0) = (1, −1)`: MIDI 0 is the unison of
   octave −1. That is what the module does today, so nothing branches on
   whether a root was stated.

## Sound and notation

1. The root fixes where the scale sits in sound and which octave numbers
   its steps carry. `tuning.derive` separates the two.

2. **`rootCents`** is where the scale's unison sits: `rootPitch · 100 +
   rootDetune − cents[rootStep]`. It fixes every sounding pitch and no
   name.

3. **`octaveBase`** turns a period-index into an octave number: `octave
   = index + octaveBase`. It is `rootOctave` untransformed, and it fixes
   every name and no pitch.

4. The two move separately. `(0, −31.77) = (1, −1)` flattens every pitch
   by a third of a semitone and renames nothing; `(0, 0) = (1, 3)` moves
   no pitch and shifts every octave label by four.

5. It does not matter which point of the scale the correspondence names.
   Any step of any octave states the whole tuning, so `(0, 0) = (1, −1)`,
   `(4, 0) = (5, −1)` and `(60, 0) = (1, 4)` are one tuning written three
   times.

6. A consumer that never displays therefore reads `rootCents` and
   ignores `octaveBase`. That is what lets adaptive tuning take a temper
   as a target without inheriting its notation
   (`design/adaptive-tuning.md` § What a target is).

## The convention as data

1. The notation half is a literal the module already carries.

2. `tuning.stepToMidi` adds one to the octave before multiplying by the
   period (`tuning.lua:420`), `tuning.midiToStep` subtracts one from the
   octave it returns (`tuning.lua:411`), and the octave field is sized
   from `floor(12700 / period) − 1` (`tuning.lua:35`).

3. `docs/tuning.md` § Coordinate systems states the same thing in prose:
   cents 0 is `C-1`, MIDI 0. That is the default root, written where it
   cannot be edited.

4. That the width budget carries the literal is the evidence it belongs
   to notation: a display quantity has no reason to know where the scale
   sits in sound.

## What it unlocks

1. What the root unlocks is placement — where a scale sits, stated once
   rather than spelled into every step.

2. Concert pitch. `(69, −101.27) = (10, 4)` tunes A4 to 415 Hz; A=442 is
   `+7.85¢` and A=432 is `−31.77¢`.

3. A temper can be authored to sound those pitches today, by spelling
   every step in cents against the offset — `−31.77`, `68.23`, `168.23`
   and so on for A=432. It costs the invariant that `cents[1]` is the
   unison, and it costs every ratio token.

4. The second cost is fatal for adaptive tuning, whose targets must
   carry ratios: a scale spelled in cents has no coords to score, so it
   cannot be a target (`design/adaptive-tuning.md` § What a target is).

5. Just scales. `(69, 0) = (1, 4)` puts `1/1` on A4, and no ratio is
   respelled.

6. Rooting renames. Under that root MIDI 60 reads `D#3`; under the A=415
   root it reads `C#4`, sitting 101.27¢ above the scale's C and 1.27¢
   below its C♯. The names follow the scale, which is what rooting a
   scale means.

7. The keyboard map. `design/rank2-temperaments.md` § Three layers,
   currently two fused describes it as welded to the tuning. That
   welding assumes a placement, and the root is that assumption made
   editable.

## The blast radius

1. The change is confined to `tuning.lua`. `tuning.derive` stamps the
   two derived fields; the conversions read them.

2. `tuning.midiToStep` subtracts `rootCents` before reducing and adds
   `octaveBase` to the octave it returns; `tuning.stepToMidi` inverts
   both; the octave field is sized from `floor(12700 / period) +
   octaveBase`. At the default root each line reduces to the arithmetic
   it replaces.

3. Nothing outside `tuning.lua` reads a quantity the root moves.
   `temper.cents` and `temper.period` are scale-internal, measured from
   the unison, and the root never enters them.

4. `temperEditor.lua` gains rows for the four authored fields. Nothing
   else in it changes.

5. So `addStep`'s clamp of a new step against the period
   (`temperEditor.lua:150-155`) is unaffected despite reading both. The
   callers further out want a count of steps (`trackerRender.lua:943`),
   a difference between adjacent steps (`viewContext.lua:39-42`), or a
   character width (`trackerView.lua:3036-3037`).

6. A generator does not disturb the root. `generateInto` overwrites the
   pitches, the period and the step names (`temperEditor.lua:177-184`),
   and the root is a property of where the scale sits rather than of the
   intervals a generator makes.

7. `docs/tuning.md` § Coordinate systems states the anchoring as prose,
   including that the first step of every temperament is `C`, which
   `(69, 0) = (1, 4)` falsifies. That passage is rewritten when the root
   lands.

## Open

1. Whether a root may be stated away from the unison. `rootCents`
   subtracts `cents[rootStep]`, so inserting a step below the one a root
   names slides the whole scale. The unison is immune and is the
   default, so only a root stated elsewhere is exposed, and the editor
   would have to refuse such a root or restate it on every step edit.

2. What becomes of a temper persisted before the root exists.
   `tuning.findTemper` returns what was serialised and nothing
   re-derives on load, so such a temper comes back without the derived
   fields and the conversions raise. `library.importFactory` re-seeds,
   and whether that is enough for a pre-beta library is undecided.

3. Whether the temper editor should speak in hertz. A root is stated in
   cents; concert pitch is thought about in hertz. The editor could show
   a derived reading, or take hertz as an entry form.

4. Where the key belongs. A root says where a scale sits in sound; which
   of a target's points the material meets is a different question, and
   answering it in the temper would mean a library copy of every target
   per key. The two add rather than conflict, and the key is deferred.
