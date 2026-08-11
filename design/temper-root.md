# Design — The temper's root

> opened: 2026-08-10 · status: in flight; plan at `plan/temper-root.md`

**A temper states where its scale sits in sound and which octave numbers
its steps carry, as one correspondence between a sounding pitch and a
scale coordinate.**

## What a root is

1. A temper's **root** is a correspondence: a `(pitch, detune)` on one
   side, the `(step, octave)` it names on the other. `(69, −101.27) =
   (10, 4)` says that MIDI 69, tuned a hundred cents flat, is the tenth
   step of octave 4. The worked examples throughout are 12EDO.

2. Four authored fields carry it — `rootPitch` and `rootDetune` for the
   sounding pitch, `rootStep` and `rootOctave` for the coordinate.

3. The default root is `(0, 0) = (1, −1)`: MIDI 0 is the unison of
   octave −1. That is what the module does today, so nothing branches on
   whether a root was stated.

4. It does not matter which point of the scale the correspondence names.
   Any step of any octave states the whole tuning, so `(0, 0) = (1, −1)`,
   `(4, 0) = (5, −1)` and `(60, 0) = (1, 4)` are one tuning written three
   times.

5. The correspondence names a step, not a cents value. So retuning the
   step a root names moves the scale: that step goes on sounding what the
   root says it sounds, and every other step shifts by the change. Every
   other scale edit leaves the placement where it was.

6. Root state is project-tier. The library and factory copies of a temper
   carry none of the four fields, so what the library holds is a scale and
   what a project holds is a scale placed. Editing a root field forks the
   row to project as any other edit does, and publishing back to the
   library drops the four. Divergence from a library source is therefore
   measured on the scale alone.

7. The **library form** of a temper is that copy: the four dropped and the
   derived stamps refreshed at the default root. `publish` writes it, and the
   divergence checks compare the two copies in it — the library copy is
   reduced as well as the project one. `tuning.unrooted` computes it, and
   `library` takes it per key as the form that tier keeps, so the tier logic
   never learns what a root is.

   Reducing both sides was not the first plan; the library copy looked like a
   fixed point, since it carries no root to drop. It isn't, because the form
   re-derives: a library copy stored before `rootCents` existed carries no
   stamps, and one round-tripped through `util.serialise` carries cents a
   `tostring` short of the recomputed ones. Both read as drift against a
   freshly derived project copy, and a stock 19EDO forked and rooted duly wore
   the modified badge. The comparison is therefore between canonical forms,
   and publishing heals the library copy it compared against. The narrower
   reading — that derived state has no business being persisted at all, and
   `findTemper` should derive on read — is a separate question, and `tidy`,
   which compares whole, is still exposed to it.

8. `tidy` and `revert` go on comparing and copying whole. `tidy` destroys a
   project copy, so it needs identity rather than identity-of-scale; `revert`
   restores the library's copy, so it drops the root the project copy carried.

## Sound and notation

1. The root fixes where the scale sits in sound and which octave numbers
   its steps carry. `tuning.derive` separates the two.

2. **`rootCents`** is where the scale's unison sits: `rootPitch · 100 +
   rootDetune − cents[rootStep]`. It fixes every sounding pitch and no
   name.

3. **`octaveBase`** turns a period-index — a count of whole periods
   above the root — into an octave number: `octave = index +
   octaveBase`. It is `rootOctave` untransformed, and it fixes every
   name and no pitch.

4. The two move separately. `(0, −31.77) = (1, −1)` flattens every pitch
   by a third of a semitone and renames nothing; `(0, 0) = (1, 3)` moves
   no pitch and shifts every octave label by four.

5. A consumer that never displays therefore reads `rootCents` and
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

4. The second cost is fatal for adaptive tuning. Its targets are scored
   on the prime factors of a ratio, which a scale spelled in cents does
   not carry, so such a scale cannot be a target
   (`design/adaptive-tuning.md` § What a target is).

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

## Negative octaves

1. A root puts octaves below −1 in reach. `(69, 0) = (1, 4)` addresses
   −2 to 8 in 12EDO, and the `M` convention for octave −1
   (`docs/tuning.md` § Display) has no answer for −2.

2. So a negative octave renders as its magnitude in
   `colour.tracker.negative`, which is what the delay lane already
   does with a negative offset (`gridPane.lua:139-143`).

3. The `M` convention retires with it. Octave −1 reads a tinted `1`,
   in the tracker's untempered fallback label as much as under a
   temper.

4. The field is then sized on magnitudes, and either end of the range
   may be the wider: the bottom is `floor(−rootCents / period) +
   octaveBase`, the top `floor((12700 − rootCents) / period) +
   octaveBase`.

5. `tuning.stepToParts` returns the label as a string, so the negative
   travels beside it through `viewContext.noteProjection` and
   `trackerView` to `gridPane`, which tints columns of a cell through
   its `overrides` table. The bump at `octaveStep` means the sign is
   the rendered octave's, not the caller's.

6. Entry follows display. `-` negates the octave under the cursor, and
   arms a pending flip at 0 so the sign shows before the digit lands,
   which is the gesture the delay lane takes for a negative offset
   (`trackerView.lua:948-956`). A plain digit sets the magnitude and
   keeps the sign.

7. An octave the note cannot sit on is refused, not clamped. The tempered
   path already reads a fold past half a semitone as a rejection; the
   untempered fallback clamped into MIDI range instead, which under a
   negating `-` would move a note an octave and say nothing about it.

8. The arm is per part rather than per cell, since a note column now has
   two fields that arm. The pending flip is matched on its part as well as
   its row and column, and the sign a digit inherits is its own field's.

9. A period well below the octave puts multiple digits in range. A
   shift-held digit overwrites one place and stays on the row, which
   is how the multi-digit fields already take a value
   (`trackerView.lua:871-873`).

## The blast radius

1. The arithmetic is confined to `tuning.lua`. `tuning.derive` stamps
   the two derived fields; the conversions read them. What changes
   elsewhere is a surface to author the root, the octave label's answer
   to a negative (§ Negative octaves), and a passage of prose.

2. `tuning.midiToStep` subtracts `rootCents` before reducing and adds
   `octaveBase` to the octave it returns; `tuning.stepToMidi` inverts
   both. At the default root each line reduces to the arithmetic it
   replaces.

3. Nothing outside `tuning.lua` reads a quantity the root moves.
   `temper.cents` and `temper.period` are scale-internal, measured from
   the unison, and the root never enters them.

4. A temper is persisted whole, derived stamps included, and never
   re-derived on load (`configManager.lua:349-355`). So a project saved
   before the pair existed reads nil at the conversions. Pre-beta: the
   break is accepted rather than guarded, and `tuning.derive` stays the
   single owner of the default.

5. `temperEditor.lua` gains rows for the four authored fields, and the
   copy it publishes to the library drops them (§ What a root is).
   `rootPitch` is spelled beside its number in the untempered twelve-name
   convention — `60` reads `C4` — since the temper's own naming is the
   thing the root fixes.

6. A step edit renumbers the steps around the root, and the root follows
   the step it names. Which step that is, the edit knows, so following it
   is index bookkeeping rather than a search: `tuning.sortSteps` carries
   `rootStep` with its row through the sort, and `tuning.removeStep` walks
   it down past a deleted step.

7. Both live in `tuning.lua` rather than in the editor, because both
   maintain the ascending-cents order the module's own arithmetic assumes.

8. Deleting the step a root names is the one edit with no step to renumber
   onto. The root restates on the unison at the same `rootCents`, which is
   the same tuning written differently (§ What a root is).

9. So `addStep`'s clamp of a new step against the period
   (`temperEditor.lua:150-155`) is unaffected despite reading both. The
   callers further out want a count of steps (`trackerRender.lua:943`),
   a difference between adjacent steps (`viewContext.lua:39-42`), or a
   character width (`trackerView.lua:3036-3037`).

10. A generator resets the root. `generateInto` overwrites the pitches,
    the period and the step names, so the scale a root placed is gone, and
    what the editor writes is the unrooted form the library keeps (§ What a
    root is).

11. `docs/tuning.md` § Coordinate systems states the anchoring as prose,
   including that the first step of every temperament is `C`, which
   `(69, 0) = (1, 4)` falsifies, and § Addressable range 1 states it again
   as `cents 0 ≡ MIDI 0 (C-1)`. Both passages are rewritten when the root
   lands.

## Open

1. Whether the temper editor should speak in hertz. A root is stated in
   cents; concert pitch is thought about in hertz. The editor could show
   a derived reading, or take hertz as an entry form.

2. Where the key belongs. A root says where a scale sits in sound; which
   of a target's points the material meets is a different question, and
   answering it in the temper would mean a library copy of every target
   per key. The two add rather than conflict, and the key is deferred.
