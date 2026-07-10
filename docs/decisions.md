# Decision log

One dated entry per non-trivial design decision: what was chosen, over
what, and why — one or two lines. Newest first. The commit skill
prompts for an entry at commit time.

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
