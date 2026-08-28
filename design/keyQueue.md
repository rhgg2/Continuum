# keyQueue — design

> opened: 2026-08-28 · status: in flight — plan/keyQueue.md, phase 1
> (the queue)

**Every key press Continuum acts on is read once, at the top of the
frame, into a queue; a reader claims what it acts on, and a claimed
press is gone.**

## The queue

1. An **entry** is one key press: `{ key, mods, repeated }` — the ImGui
   key constant, the modifier mask as the fill read it, and whether
   ImGui reports the press as an autorepeat.

1. **keyQueue** is a single instance, built in `coordinator.lua` and
   threaded into the pages beside `chrome` and `modalHost`. It holds
   one frame's entries, and each frame's fill replaces the last.

1. A **claim** removes an entry, and `keyQueue:take(key, mods)` is the
   way to make one. It returns the entry, or nil where the key is
   absent, already claimed, or carries modifiers other than `mods`.

1. An omitted `mods` means `Mod_None`, so a reader acting on a chord
   names the mask it acts on.

1. `keyQueue:takeAny()` claims and returns the first unclaimed entry,
   for a reader that acts on any press at all.

## The fill

1. The fill runs at the top of `coordinator.frame`, before any
   drawing, so the state it reads is the state that held when the
   presses arrived.

1. The keys it enumerates are read off the `imgui` shim table by name
   once at load — the shim is an ordinary table under a metatable that
   only guards missing fields — less the mouse keys and the modifier
   keys.

1. Each frame the fill asks ImGui for every enumerated key and pushes
   an entry per press. It asks for a press-or-repeat first, and only a
   positive answer costs the second call that separates the two.

1. The modifier mask is read once and stamped on every entry of that
   frame.

## Claiming

1. A reader claims in the statement where it acts, so a reader that
   acts on a press it did not claim is a defect.

1. The claim precedes whatever the press sets in motion. The keychain
   walk takes the press that selects a command before it invokes, so a
   command raising a modal, a picker or the menu walk hands it a queue
   the press has already left.

1. A reader that ends a gesture claims the press that ended it, and
   drops the state it held in the same frame.

## Ownership

1. A reader that takes the whole keyboard **owns** the queue for the
   frame. Ownership is settled at the fill, and `take` and `takeAny`
   return nil to every other reader while it holds.

1. Four readers own, in this precedence: the cheat sheet while it was
   open at frame start, an open modal, an open picker, and a status
   cell holding an open field.

1. A claim names its claimant: `take` and `takeAny` take one as a last
   argument, which the four owners pass and every other reader omits. A
   name outside the four raises.

1. Unowned is the ordinary case. A text field active at the end of the
   previous frame then claims the presses a field consumes — the
   printable keys, Backspace and Delete, and the arrows with Home and
   End.

1. Enter, Escape, Tab, and any press carrying Super or Ctrl, survive
   that claim. A field's host acts on them.

## Hold and repeat

1. A key's state is not a press. `keyQueue:held(key)` and
   `keyQueue:mods()` read ImGui live, and answer the same whoever owns
   the queue.

1. The chord gate, the commit on shift release, and the modifiers a
   mouse gesture reads are all state questions, and use those two.

1. Autorepeat rides on the entry, so a reader wanting fresh strikes
   only tests `repeated`.

## Order

1. Readers are asked in the order the frame draws them: the fill's own
   claims, the toolbar with its picker and status bar, the page body,
   the keychain walk, note entry, and last the modal and the cheat
   sheet, which own the queue whenever they are up.

1. That order is a property of the call graph, and `docs/keyQueue.md`
   states it.

## What guards, and what claims

1. `paletteFocus`, `stripFocus` and `pageSuppressed` decide which
   reader is asked. They are guards on a reader, and a press a guard
   suppresses stays in the queue for the reader after it.

1. The character queue remains the route for text. The cheat sheet's
   dismissal and the fx strip's type-to-open read it
   (`docs/help.md`); note entry reads the key stream.

## Open

1. Whether the modal renderers keep reading Enter and Escape where
   they draw, or declare the keys they act on to `modalHost`, which
   claims and dispatches them.

1. Whether `pageSuppressed` is better expressed as a cmgr scope with a
   passthrough, which would take it out of the guards above.
