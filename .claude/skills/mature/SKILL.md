---
name: mature
description: Advance a design doc one stage along its arc.
disable-model-invocation: true
---

`design/` holds docs from "vague, pre-design" through to "approved,
ready to implement", and the status line under the title says where on
that arc each one sits. A round moves one doc one step. The status line
is how you tell that it moved.

Not every doc should advance, and none has to advance far. A review's
findings can sit unproposed for as long as they need to, and
`design/pipe-dreams.md` is a standing collection that should never move
at all.

## 1. Locate the doc

Read it whole, and read `design/decisions.md` and `design/archive/` on
the same subject, so that a question settled earlier is not reopened
as an open one. A doc that does not exist yet is one step behind
vague: handed a `todo.md` line or a brand new request via arguments,
open one.

Most docs say what holds them back — `## Open`, or a section titled as
the blocker. Where there is no such section, because the doc is a
review's findings or is still vague, work it out and say that the
reading is yours.

**Done when** you can say what stage the doc is at and what holds it
there.

## 2. Name the advance

There is no ladder of stages to consult; the status lines are prose
because the arc resists enumeration. Ask instead what would have to be
true for this doc to be further along than it is, and which of those
comes next.

**Check in.** Name the stage, what holds it there, and the one advance
you propose. When I give you the go-ahead, we'll settle it.

## 3. Settle it

`/grilling` works the frontier in rounds. Finding facts is your job:
dispatch for anything the tree can answer, and put only the decisions
to me.

Verify every claim whose evidence you have not seen yourself. Grilling
turns up claims about the code as fast as reading does, and a citation
is settled by grep in seconds. Identity, aliasing and mutation order
need the session's spike worktree.

Where the blocker is what shape an interface should take, and the shape
is not already obvious, design it twice: subagents in parallel, each
under a different constraint — the smallest interface, the most
flexible, the easiest for the commonest caller. Compare them on what
each hides and where change would concentrate.

**Done when** the advance is settled, or you can say what stopped it.

## 4. Land the round

Amend the doc in the register of `docs/STYLE.md`, and rewrite the
status line. If you cannot honestly rewrite it, the round advanced
nothing — say so, rather than dress a shuffle as progress.

Stage the round as one `apply_patches` call. A landed round is a
stopping point: the doc is whole and committable as it stands.

**Check in.** Say what the status line now reads and what the next
advance would be. We stop there unless I ask for another round — and if
we go again, return to step 2, because the doc is already located.
