# Decision log

One dated entry per non-trivial design decision: what was chosen, over
what, and why — one or two lines. Newest first. The commit skill
prompts for an entry at commit time.

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
