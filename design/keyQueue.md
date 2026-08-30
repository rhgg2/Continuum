# keyQueue — design

> opened: 2026-08-28 · status: landed 2026-08-30 — the model lives in
> `docs/keyQueue.md`.

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

Landed: see `docs/keyQueue.md` § Order.

## What guards, and what claims

Landed: see `docs/keyQueue.md` § Guards, and `docs/trackerPage.md`
§ Keys for the two guards on the note entry scan.
