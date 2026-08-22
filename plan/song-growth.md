# Song growth — plan

> source: `design/song-growth.md` — synthesis compiled from there;
> don't design here.

## Phases

1. **Phase 1 — The current instance** (§ The tracker remembers its instance,
   § Rendered span and source span, § Loop to item) — the tracker remembers
   which instance of the bound slot it is in, written by the dive, by the play
   head entering one, and by a seek on slot change; F6 is its first consumer
   and loop to item its second.  ← in flight
2. **Phase 2 — What the grid draws** (§ What the grid draws) — the play-row
   caret from `(playQN − instanceStartQN)` over `ppqPerRow`, and the cut line
   where the rendered span ends before the source does.
3. **Phase 3 — again** (§ again) — a pooled instance appended at the current
   instance's rendered end, refused unless the free span covers the natural
   length; one atomic block, rebind, loop follows.
4. **Phase 4 — vary** (§ vary) — the current instance replaced by an instance
   of a fresh variant slot named `<parent> (var N)`; refused on a slot with one
   instance; one atomic block, rebind.

## Landed  (newest first; prune below ~4)

- 2026-08-22 tracker: remember which instance of the bound slot we are in (§ The tracker remembers its instance)

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)

- Loop to item: cm `loopToItem` at the global tier, default false;
  `av:loopToItem`/`av:setLoopToItem` through the facade; `tp:bind` brackets the
  current instance's rendered span via `am:setLoopRangeQN`, turns REAPER repeat
  on, and moves the edit cursor and play head to its start. No current instance
  leaves the transport untouched. Needs `GetSetRepeat` in fakeReaper.
- The toggle surface: `toggleLoopToItem` in the tracker command scope, its key
  binding, help entry and a toolbar checkbox — arrange's `followPlay` segment
  and `toggleFollowPlay` as the model.
