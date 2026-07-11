# Decision log

One dated entry per non-trivial design decision: what was chosen, over
what, and why — one or two lines. Newest first. The commit skill
prompts for an entry at commit time.

- **2026-07-11** — A pb gm member stores INTENT in the group frame under `val`
  (its existing name), and `toGroup` sources it from `evt.cents` — frame-invariant
  intent — never the um entry's `val`, which `makeEntry` builds as `rawToCents(wire)`
  (intent + governing detune, i.e. realisation, stale at any sibling whose detune
  differs). Over renaming the group field to `cents` at every boundary: the intent
  ingress is a single chokepoint (`toGroup`), so one arm there beats N renames, and
  `detune` is already `DERIVED`-denied so the wire re-derives per seat at flush.
  `makeEntry`'s pb pick also now carries `uuid`, without which gm's per-rebuild
  re-anchor (`tm:byUuid`) silently loses the member and no-ops every later edit.

- **2026-07-11** — `tm:requestRebuild()` is a *deferred* force-rebuild: it sets a flag
  the imminent flush consumes past its no-op guard, for a geometry change that stages
  zero mm ops (an empty-group instance verb: nothing to project, so the commit flush
  would otherwise skip the rebuild and leave tv's `cellKind` region tags stale — the
  first edit in the region then misroutes to a plain, non-propagating note). Distinct
  from swing/fxRegions' immediate `tm:rebuild(false)`, which fires from a config/data
  subscriber *outside* any flush; a flag there would have nothing to consume it. Not
  unified — the two serve opposite call contexts (mid-/pre-flush defer vs standalone now).

- **2026-07-11** — FX regions join the rectangle clipboard (copy/paste/delete),
  captured by *onset-in-band* — a region starting inside the rectangle rides whole,
  tail spilling past the band, exactly as a note's tail copies; one starting above and
  merely passing through is skipped. Over overlap-capture (would make fx unlike every
  other column) or clip-to-band (meaningless for a chain, whose identity is its window).
  Paste *stacks* (no destination wipe) since regions overlap by design. Rides the cell
  clip as `clip.fxRegions` via an injected `fx` hook; delete-caret still targets the
  region under the cursor (`cursorRegionBefore`), not the onset rule.

- **2026-07-11** — Chord channel spread rides Alt *per strike* (Shift+Alt+note
  walks to the lowest gesture-free channel; plain Shift+note stacks lanes on home),
  over a mode-at-arm modifier or a config toggle — per-strike subsumes both and
  allows mixed chords. Toggle stays pitch-keyed, so cross-channel unison doubling
  is foreclosed. Chord entry is gated off the pattern surface (gridPane host param
  `chordEntry`; patterns are single-channel bodies).

- **2026-07-11** — Shift-held value entry is a keep-below overwrite cursor over a
  field's places: each digit overwrites only its own place (lower places intact),
  the sub-caret steps right, and the row stays pinned while shift is down.
  Backspace restores the place the last digit overwrote (retype it); shift release
  jumps back to the entry column, then advances. Replaces the old half-a-place
  Shift trick (setDigit's `half` -> `keepBelow`). Hex parts take 0-9a-f, decimal
  0-9 (the a-j additive carry stays a separate non-shift mechanism).

- **2026-07-11** — Chord entry (shift-held): velocity digits live on Shift+Alt, not
  plain Shift, because the upper note row *is* the digit row (`2 3 5 6 7 9 0` are
  black keys/high notes) — plain digits stay strikeable. A struck pitch already at
  the pinned row is adopted into the gesture, never duplicated (one voice per
  (chan, pitch, ppq); the voicing pass would eat a duplicate unpredictably); a
  re-strike toggles off. Accepted: chords can't *start* on 9/0/,/. (Shift-bound
  commands win at dispatch; they decline only once a gesture is live).

- **2026-07-11** — Decimal grid value entry (pb, delay): letters `a`–`j` enter
  digit `0`–`9` at the current place plus an *additive* `+1` carry into the place
  to its left (a tracker range-extender: `a`=10 … `j`=19), clamped to the field cap.
  Chose additive carry over literal-set-to-1 (non-destructive: `350`+tens`b`→`410`,
  not `110`). Dropped the `f`→full-scale special-case; full scale now falls out of a
  carry that overflows the top place and clamps.

- **2026-07-10** — The fx palette tab stands alone: a mouse click pins either tab
  (`tabOverride`, generalising the old params-only override) *without* grabbing
  focus, and `stripPlan` draws a bare add row on a host with no fx. Minting splits
  by entry path — the mouse mints the host lazily on the first `add`, the keyboard
  `editFx` still mints eagerly and pops the picker. Rejected making the keyboard
  path lazy too (kept its eager snapshot/husk-prune session).

- **2026-07-10** — Empty pb cells inherit their entry sign — the displayed
  ghost's, else the previous visible breakpoint's — so a negative run is one
  `-` plus digits and typing edits what you see; explicit zeros don't inherit
  (they display unsigned). The `-` arm is now a flip of the inherited sign, and
  a sub-thousands digit on full scale wraps (clears the thousands) rather than
  clamping to a silent no-op.

- **2026-07-10** — Signed grid entry: `-` sign-flips in place (no advance); on a
  zero cell it arms a *transient* `-0` held in trackerView, not the event —
  pb serialises to a wire where -0 == 0, so a persisted signed zero dies at the
  next flush/rebuild. Key clashes (Shift+8 octave, plain-1 noteOff pattern)
  resolve by commands *declining* in value-part context, not by rebinding.

- **2026-07-10** — Pattern-editor curves default to linear by *seeding* a fresh
  body with two linear zero anchors + having `tv:enterValue` inherit the previous
  breakpoint's shape (like the curve pane's mouse insert). Rejected a
  `newBreakpointShape` config key: seeding needs no per-context default and unifies
  grid-entry with mouse-insert. Main tracker keeps REAPER's step (no linear seed).

- **2026-07-10** — `chrome.screenPainter()` (identity painter over the current
  window's draw list) is the reach for screen-space drawlist work; raw
  `GetWindowDrawList`/`DrawList_Add*` is out — it loses chrome's colour
  discipline (names/tokens, not raw ints). Extracted from three palette sites;
  the fx palette's row-highlight + flow rule adopt it.

- **2026-07-10** — A `pa` parks off-take with its host note (replace-region /
  note-host park), rather than staying take-side and sounding against the fresh
  derived stream (rejected: stale PAs against different derived notes are
  meaningless). It still rides the host's note column for display; the generator
  owns any new realisation PAs.

- **2026-07-10** — FX chain moved from a docked 2D strip to a `parameters|fx`
  palette tab, rotated vertical for 1D nav (Up/Down walk all fields, Left/Right
  edit). fx auto-raises under the caret; Super-R parks a parameters override
  (clears on caret move), Super-X cancels it — symmetric. Chain adopts the param
  tree's row grammar (label left, value column right) for one UI, not two.

- **2026-07-10** — UI vocabulary: tables crossing a pass boundary get
  role-named fields (`xLo/xHi`, `chanLeft`, `pitchWidth`, `viewRows`),
  never bare coordinates; piloted in gridPane, rule in CLAUDE.md.

- **2026-07-10** — Per-file docs stay, as pointer-target overflow for the
  comment caps; rejected wholesale deletion (≈150 `see docs §` pointers
  pin dense WHY that can't compress to site comments).
