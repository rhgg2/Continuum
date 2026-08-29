# keyQueue — design

> opened: 2026-08-28 · status: in flight — plan/keyQueue.md, phase 5
> (the raising readers)

**Every key press Continuum acts on is read once, at the top of the
frame, into a queue; a reader claims what it acts on, and a claimed
press is gone.**

## The queue, and the fill

Landed: see `docs/keyQueue.md` § The queue and § The fill.

## Claiming

1. A reader claims in the statement where it acts, so a reader that
   acts on a press it did not claim is a defect.

1. The claim precedes whatever the press sets in motion. Landed for
   the dispatcher: see `docs/keyQueue.md` § Claiming.

1. A reader that ends a gesture claims the press that ended it, and
   drops the state it held in the same frame.

## Ownership

Landed: see `docs/keyQueue.md` § Ownership, and § The fill for the
claim an unowned frame's live text field makes.

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

1. `paletteFocus`, `stripFocus`, the sampler's open rename and
   `pageSuppressed` decide which reader is asked. They are guards on a
   reader, and a press a guard suppresses stays in the queue for the
   reader after it.

1. The character queue remains the route for text. The fx strip's
   type-to-open reads it; note entry reads the key stream.

## Open

1. Whether `pageSuppressed` is better expressed as a cmgr scope with a
   passthrough, which would take it out of the guards above.
