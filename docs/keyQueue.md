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

## Ownership

1. A reader that takes the whole keyboard **owns** the queue for the
   frame. Ownership is settled at the fill, which records the owner's
   name; the precedence is the coordinator's (`docs/coordinator.md` §
   The frame).

1. The names are `help`, `modal`, `picker` and `statusEdit`. `take` and
   `takeAny` answer nil to a claimant other than the name recorded, and
   a claimant outside the four raises — a typo would otherwise read as
   a key that quietly does nothing.

1. A reader hosted by an owner claims under that owner's name.
   `keyDispatch` takes the name from the state it is given, so the mini
   pattern editor captures inside the modal while the coordinator's own
   dispatch does not.

## Hold and repeat

1. A key's state is not a press. `keyQueue:held(key)` and
   `keyQueue:mods()` read ImGui live, and answer the same whoever owns
   the queue.

1. The chord gate, the commit on shift release, and the modifiers a
   mouse gesture reads are all state questions, and use those two.

1. Autorepeat rides on the entry, so a reader wanting fresh strikes
   only tests `repeated`.
