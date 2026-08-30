# keyQueue — design

> opened: 2026-08-28 · status: in flight — plan/keyQueue.md, phase 6
> (the rest, and the record)

**Every key press Continuum acts on is read once, at the top of the
frame, into a queue; a reader claims what it acts on, and a claimed
press is gone.**

## The queue, and the fill

Landed: see `docs/keyQueue.md` § The queue and § The fill.

## Claiming

Landed: see `docs/keyQueue.md` § Claiming.

## Ownership

Landed: see `docs/keyQueue.md` § Ownership, `docs/coordinator.md` §
Pages for the `keyboardOwner` a page answers, and `docs/keyQueue.md` §
The fill for the claim an unowned frame's live text field makes.

## Hold and repeat

Landed: see `docs/keyQueue.md` § Hold and repeat.

## Order

1. Readers are asked in the order the frame draws them: the fill's own
   claims, the toolbar with its picker and status bar, the page body,
   the keychain walk, note entry, and last the modal and the cheat
   sheet, which own the queue whenever they are up.

1. That order is a property of the call graph, and `docs/keyQueue.md`
   states it.

## What guards, and what claims

1. The sampler's open rename, `pageSuppressed` and the palette's
   `treeArrows` decide which reader is asked, or whether a reader acts.
   They are guards on a reader, and a press a guard suppresses stays in
   the queue for the reader after it.

1. The character queue remains the route for text. The fx strip's
   type-to-open reads it; note entry reads the key stream.

## Open

1. Whether `pageSuppressed` is better expressed as a cmgr scope with a
   passthrough, which would take it out of the guards above.
