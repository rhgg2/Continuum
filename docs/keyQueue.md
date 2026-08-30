# keyQueue

**Every key press Continuum acts on is read once, at the top of the
frame, into a queue; a reader claims what it acts on, and a claimed
press is gone.**

## The queue

1. An **entry** is one key press: `{ key, mods, repeated }` — the ImGui
   key constant, the modifier mask as the fill read it, and whether
   ImGui reports the press as an autorepeat.

1. **keyQueue** is a single instance, built in `coordinator.lua` and
   handed to the pages in `STD` (`docs/coordinator.md` § Pages). It
   holds one frame's entries, and each frame's fill replaces the last.

1. A **claim** removes an entry, and `keyQueue:take(key, mods,
   claimant)` is the way to make one. It returns the entry, or nil
   where the key is absent, already claimed, or carries modifiers other
   than `mods`.

1. An omitted `mods` means `Mod_None`, so a reader acting on a chord
   names the mask it acts on.

1. `keyQueue:takeAny(claimant)` claims and returns the first unclaimed
   entry, for a reader that acts on any press at all.

1. `keyQueue:restore(entry)` puts a taken entry back at the head. A
   reader claiming a press before it acts hands the press back this way
   when it declines to act on it.

1. The queue holds presses. Text arrives through ImGui's own character
   queue, which the fx strip's type-to-open reads for the frame's first
   printable character; note entry names key constants instead, because
   that queue drops repeats for the macOS press-and-hold keys
   (`docs/trackerPage.md` § Keys).

## The fill

1. The fill runs at the top of `coordinator.frame`, before any drawing,
   so the state it reads is the state that held when the presses
   arrived.

1. The keys it enumerates are read off the `imgui` shim table by name
   once at load, less the mouse keys and the modifier keys — a modifier
   is state, and rides on every entry as the mask.

1. Each frame the fill asks ImGui for every enumerated key and pushes
   an entry per press. It asks for a press-or-repeat first, and only a
   positive answer costs the second call that separates the two.

1. The modifier mask is read once and stamped on every entry of that
   frame. `keyQueue:frameMods()` returns it, so a reader deciding
   whether a chord is one it acts on tests the mask its entries carry.

1. The fill makes a claim of its own. Where no owner holds the frame
   and ImGui reports an active item, a live text field takes the keys a
   field consumes — the printable keys, Backspace and Delete, and the
   arrows with Home and End. The fill does not ask after them, so they
   reach no reader.

1. Enter, Escape, Tab and any press carrying Ctrl or Super survive that
   claim, for the field's host to act on. `ImGui.IsAnyItemActive` is the
   test, so a slider mid-drag claims as a field does.

## Claiming

1. A reader claims in the statement where it acts, so a reader acting
   on a press it did not claim is a defect.

1. `keyDispatch` claims each press it acts on, at the frame's mods and
   under the claimant its state carries. Prefix capture takes the digit
   or the slash it appends; a scope's letter sink takes the letter it
   passes on; the keychain walk takes the key whose binding fires.

1. The walk claims before it invokes. A command raising a modal, a
   picker or the menu's walk is thus handed a queue the press has
   already left.

1. A command declining its press (`docs/commandManager.md` § Dispatch &
   result protocol) gets it restored to the head of the queue, and the
   walk scans on.

1. A modal renderer claims commit and cancel through `modalHost`: one
   take covers Enter and its keypad twin, the other Escape, both under
   `modal` at the frame's mods.

1. A reader that ends a gesture claims the press that ended it, and
   drops the state it held in the same statement. The fx strip's period
   box is one: ImGui closes the field on Enter, Escape or Tab, and the
   box claims whichever arrived, so the strip's own keys, running later
   in the frame, do not read it a second time.

## Ownership

1. A reader that takes the whole keyboard **owns** the queue for the
   frame. Ownership is settled at the fill, which records the owner's
   name; the precedence is the coordinator's (`docs/coordinator.md` §
   The frame).

1. The names are `help`, `modal`, `picker`, `statusEdit` and `palette`.
   `take` and `takeAny` answer nil to a claimant other than the name
   recorded, and a claimant outside the five raises — a typo would
   otherwise read as a key that quietly does nothing.

1. `picker` covers every picker popup: the toolbar's, which chrome
   settles, and the wiring page's add-FX popup, which the page answers
   for.

1. `palette` is the tracker's right-hand pane, either tab. The
   parameters tree and the fx chain are two focus sessions on one pane
   and can overlap for a frame, so one name covers both.

1. A reader hosted by an owner claims under that owner's name.
   `keyDispatch` takes the name from the state it is given, so the mini
   pattern editor captures inside the modal while the coordinator's own
   dispatch does not. Every other reader omits a name, and on a frame
   with no owner every claim succeeds.

1. Ownership governs the keyboard alone. A reader taking the mouse keeps
   its own guard, as the cheat sheet's page-side mouse passes do
   (`docs/help.md § Input while open`).

## Order

1. Readers are asked in the order the frame draws them, which
   `docs/coordinator.md` § The frame states: the fill runs before any
   drawing, and the cheat sheet and the modal draw last.

1. Ownership settles most of that order in advance. An owned frame
   answers nil to every claim under another name, so where those
   readers sit in the draw changes nothing.

1. Order decides the outcome between the readers asked on an unowned
   frame: a page's own body readers, the keychain walk and note entry.
   All three run inside `renderBody`, and the page places the walk among
   them — the editor page walks first, the other pages last.

1. A body reader ahead of the walk takes the press from any binding on
   the same key. The wiring page's gesture cancel is one: it claims
   Escape while a draft is in flight, so the Escape-bound
   clear-selection does not fire that frame.

1. A reader after the walk gets what the walk left. The editor page's
   Escape-to-return is one, and the tracker's note entry scan another
   (`docs/trackerPage.md` § Keys), so a key that fires a command never
   also enters a note.

## Guards

1. A guard decides whether a reader is asked; a claim removes a press.
   A press a guard suppresses stays in the queue for the reader after
   it.

1. Three guards stand on the walk and the readers around it:
   - the sampler's open rename holds `acceptCmds` false, so the walk
     does not run — the rename field is not active on the frame it
     opens, so the fill's own claim does not cover it;
   - `pageSuppressed` narrows the walk to the root keymap, so a page
     binding is not asked while a body-region editor holds the page,
     and stands off under a modal scope, whose own passthrough filter
     is the narrower one and whose keys are nobody's page bindings;
   - the palette's Left and Right drive the fx tree unless the find box
     is editing text, where they stay in the queue for the box.

1. The note entry scan carries two more of its own
   (`docs/trackerPage.md` § Keys).

1. Ownership is not a guard. An owned frame needs no gate, since every
   claim under another name already answers nil.

## Hold and repeat

1. A key's state is not a press. `keyQueue:held(key)` and
   `keyQueue:mods()` read ImGui live, and answer the same whoever owns
   the queue.

1. The chord gate, the commit on shift release, and the modifiers a
   mouse gesture reads are all state questions, and use those two.

1. Autorepeat rides on the entry, so a reader wanting fresh strikes
   only tests `repeated`.
