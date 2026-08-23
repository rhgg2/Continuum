# Continuum User Manual

Draft skeleton: one section per page, bare lists of user-facing facilities.
To be filled out with descriptions, screenshots, examples.

## Global / Navigation

### Page switching
- Switcher toolbar buttons (A / W / T / S / E)
- Direct-jump hotkeys: F2 arrange, F3 wiring, F4 tracker, F9 sample, F10 editor
- Alt+Tab — cycle pages (tracker → arrange → sample → wiring → tracker)
- Return to previous page (editor's Close / Esc)
- Return to arrange (tracker's Enter)
- Dive-to-editor from tracker (edit swing / edit tuning)
- Dive-to-sampler from tracker/wiring/arrange

### Transport (global)
- Play / Pause — Space
- Stop — F8

### Editing (global)
- Undo — Ctrl+Z
- Redo — Ctrl+Shift+Z
- Universal numeric-prefix argument — Cmd/Super+U
- Quit — Ctrl+Q
- Toggle floating FX windows — F11
- Reach Continuum commands from REAPER's own keymap (external-command bridge)

### Help & keybindings
- F1 — toggle per-page cheat-sheet overlay
- Click a shortcut's chip to rebind it; add/remove chords; conflict prompt on collision
- (No standalone keybindings settings screen — the F1 overlay is the only one)

### Window / chrome
- Master mix strip — drag to set master volume, double-click resets to 0dB, live dB readout, peak-hold
- Toolbar segments collapse/expand (click disclosure triangle), state persists
- Modal dialogs (prompt / confirm), shared across pages

---

## Tracker page

### Toolbar
- Track picker
- Take picker
- Rows/beat: double, halve, set, match-to-cursor
- Tuning: pick tuning, edit tuning
- Swing: pick swing, edit swing (+ per-channel swing picker, mouse-only)
- Sample stepper (up/down) + sample dropdown (typeahead)
- "Graph" checkbox (lane strip visibility)

### Movement
- Cursor up/down/left/right
- Column left/right
- Channel left/right
- Top / bottom
- Page up/down
- Mouse: click grid to move cursor; mouse wheel steps cursor

### Editing
- Note off
- Clear cell / delete selection
- Interpolate
- Push back/forward, push left/right
- Shrink/grow note
- Nudge value +/- (fine/coarse)
- Scale ×½ / ×2
- Quantize / quantize (keep realised)
- Retune (opens Retune modal: scope, target, facility, sonority/harmonic-lock/purity/strength)
- Edit note FX
- Shift-chord entry

### Selection
- Select up/down/left/right
- Clear selection
- Cycle selection (horizontal/vertical)
- Swap block ends
- Cut / copy / paste
- Duplicate
- Mouse: click / shift-click / drag-select in grid

### Columns & rows
- Add note lane
- Add cc/pb/at/pc column (text prompt)
- Remove column
- Insert / delete row

### Groups & region
- Region mode (arm/exit/bail)
- Region paint extend/shrink (keyboard)
- Region paint drag (Shift-drag adds, Alt-drag removes) — mouse
- Duplicate/paste group
- Toggle local
- Previous/next group instance

### Input
- Octave up/down
- Sample select up/down

### Take management
- New take
- Duplicate below (another instance of the bound take)
- Previous/next variant (stepping past the last one varies)
- Take properties (modal: length ×2/÷2, Resize/Rescale/Tile mode, truncate confirm)
- Delete take + instances (confirm)

### Grid — mouse only
- Click channel-label row to select channel; right-click to mute
- Click column-label row to select column
- Click-drag to select a block

### Lane strip (curve editor) — mouse only
- Drag anchor to move (Shift = free position)
- Click curve to insert anchor
- Double-click anchor to delete
- Double-click segment to cycle shape (step/linear/slow/fast-start/fast-end/bezier)
- Drag bezier segment to adjust tension
- Grow/shrink strip row count
- Same gestures reused by the FX-chain pattern/generator curve editor

### FX param palette — mouse only
- Tab: parameters / fx
- Automate / remove buttons
- Find/filter text box
- Expand/collapse fx row; select param row; double-click to automate
- Per-fx "show" (open FX UI) / "learn"/"stop" (MIDI-learn)

### FX chain tab — mouse only
- Clear / freeze / to-group / commit / cancel
- Save/load patch to/from catalogue (with delete)
- Reorder stage (↑/↓), bypass, delete stage
- Swap stage kind
- Add stage
- Pattern field → opens pattern/curve editor

### Status bar
- Column label, bar:beat.sub/RPB, octave, advance-by step, current sample slot (read-only)

---

## Sample page

### Toolbar
- Track picker (bind page to a sampler-FX track)
- "Preview in place" checkbox
- "Advance on load" checkbox

### Keyboard commands
- Browser up (parent folder) / browser preview (descend or audition)
- Browser assign (load into slot)
- Slot next/prev
- Slot rename

### Folder tree
- Click folder to select; double-click to rebrowse root
- Expand/collapse subtree
- "↑" to move browse root up

### Files / browser pane
- Arrow keys move selection
- Click to select; double-click file/folder to preview/enter
- Load button; audition play/stop buttons

### Slots pane
- Click to select slot; double-click to audition
- Inline rename
- Clear slot
- Audition play/stop

### Waveform / trim strip
- Drag start/end marker to trim
- Start/End numeric fields
- Preview button

---

## Wiring page

### Keyboard
- Add FX (opens picker)
- Clear selection / cancel in-flight gesture

### Nodes
- Add FX / generator FX / free bus node (via picker)
- New source (name prompt)
- Rubber-band select; click empty canvas to clear
- Drag to move node(s)
- Right-click → context menu: delete node/buss, rotate buss, buss in/out
- Double-click Sampler node → dive to sample page
- Double-click other fx node → float its REAPER FX window
- Mute (M) / bypass (B) badges

### Connections
- Shift+hover port → port band; Shift+drag to wire
- Drag source-palette row onto canvas to start a wire
- Click port name in dropdown to pin a chip
- Drag wire endpoint to retarget; drop on empty canvas to delete
- Right-click wire midpoint → mark primary
- Hover port/wire label → tooltip
- Gain fader on audio wires: click to open, drag/wheel/shift-wheel to adjust, double-click to reset

### Buss bars
- Shift-hover to start wire from bar
- Drag wire onto bar to rewire through it
- Drag middle third to move; drag near ends to resize
- Right-click for node menu

### FX / Buss picker
- Text filter, arrow-key nav, Enter/click to commit, Escape to close

### Source palette
- Add / delete source (guarded confirm if track has takes)
- Click to focus; drag onto canvas to wire

---

## Arrange page

### Toolbar
- "Follow play" checkbox
- BPR (beats-per-row) stepper

### Navigation
- Cursor up/down/left/right, page up/down, home/end
- Mouse wheel pan (vertical/horizontal)
- Click empty grid to move cursor

### Selection
- Shift+arrow to extend selection
- Clear selection
- Click / shift-click a take
- Drag lasso (shift+drag adds)

### Takes
- Drag to move (snaps to row; Shift = free); Ctrl+drag to duplicate
- Drag end edge to resize
- Nudge back/forward; move the tail, or the head from a take's start row
- Source the take doesn't show is marked in it: `(4)…` skipped above, `…(8)` left below
- Delete / delete-and-advance
- Duplicate below (pooled)
- Previous/next variant (stepping past the last one forks a new one)
- Take properties
- Dive into take/tracker

### Slot creation & palette
- New take (modal: name, length) — via key, double-click, or double-click-drag (length from sweep)
- Palette: click row to focus; rename; delete (confirm)

### Slot placement
- Per-slot "drop" hotkey (base62) places instance at cursor and advances
- Advance-by digit prefix (Ctrl+0-9)

### Loop / Transport
- Set loop start/end at cursor
- Play from cursor
- Clear loop range
- Toggle follow play
- Click gutter to set edit cursor; drag gutter to set loop range live; right-click to clear

### Zoom
- Zoom in/out (halve/double BPR)
- Set exact beats-per-row (modal or toolbar stepper)

### Visual feedback (read-only)
- Take colour by pool identity, shared by every instance; orphans greyed
- Waveform / note previews inside take rectangles
- Phrase/bar row tints
- Blinking cursor caret
- Drag ghost preview, red border on blocked destination
- Status bar: row, column, beats/row, advance-by

---

## Editor page

### Entry / exit
- F10 — switch to Editor page
- "E" page button
- Jump in from tracker's swing/tuning edit buttons
- Close (Esc) — return to originating page

### Toolbar
- Pane selector: Swing / Tuning
- (Swing pane) Rows/qn stepper, "Wild" checkbox, phase slider

### Swing pane
- Preview band (composite + per-factor strips), resizable splitter
- Per-factor: atom dropdown, shift slider, period dropdown, phase slider, reorder (↑/↓), delete
- Add factor

### Tuning (temper) pane
- Period pitch field / "period as last step" toggle
- Root: pitch, note-name, detune, step, octave
- Step table: per-row pitch/token, name, delete; add row
- Resizable splitter to generators sub-pane

### Generators sub-pane
- Kind picker: Equal / Harmonics / Subharmonics / Chord / CPS / Diamond / Tenney ball / Rank-2 MOS
- Per-kind parameter fields
- Generate button (replaces scale)

### Library tree palette (shared by Swing & Tuning)
- New / delete entry
- Reset unsaved edits
- Publish to library / revert from library
- Tidy (drop redundant project copies)
- Import (Tuning only): load .scl file or paste Scala pitches
- Reload from factory catalogue
- Active / Project / Library folders — browse, select, expand/collapse

### Modals
- New swing / new tuning (name prompt)
- Import tuning
- Overwrite / reload / import confirms
