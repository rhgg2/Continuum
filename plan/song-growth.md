# Song growth — plan

> source: `design/song-growth.md` — synthesis compiled from there;
> don't design here.

## Phases

1. **Phase 1 — The sounding instance** (§ The playhead names the instance,
   § Rendered span and source span, § Loop to item) — arrange resolves which
   instance of the bound slot contains the playhead and reports its start,
   rendered and natural spans; loop to item is its first consumer, bracketing
   that instance on each bind.  ← in flight
2. **Phase 2 — What the grid draws** (§ What the grid draws) — the play-row
   caret from `(playQN − instanceStartQN)` over `ppqPerRow`, and the cut line
   where the rendered span ends before the source does.
3. **Phase 3 — again** (§ again) — a pooled instance appended at the sounding
   instance's rendered end, refused unless the free span covers the natural
   length; one atomic block, rebind, loop follows.
4. **Phase 4 — vary** (§ vary) — the sounding instance replaced by an instance
   of a fresh variant slot named `<parent> (var N)`; refused on a slot with one
   instance; one atomic block, rebind.

## Landed  (newest first; prune below ~4)

(nothing yet)

## Now

(empty — run /plan-next to compile the next brief.)

## Queued (current phase; one-liners)

- `am:soundingInstance(take)`: the instance of take's slot (`takeIdOf`) on
  `ownerTrack(take)` whose rendered span `[startQN, startQN + lengthQN)`
  holds `am:playPositionQN()` — the `tracksTakes` record, so start, rendered
  and natural spans come with it. Nil when the transport is stopped, when the
  playhead sits in a gap, over another slot's take, or past the last item, and
  for a slot whose only instance is parked. am_spec covers each refusal.
- Loop to item: cm `loopToItem` at the global tier, default false;
  `av:loopToItem`/`av:setLoopToItem` and `arrange.soundingInstance` through the
  facade; `tp:bind` sets the loop to the sounding instance's rendered span via
  `am:setLoopRangeQN` and turns REAPER repeat on. No sounding instance leaves
  the loop untouched. Needs `GetSetRepeat` in fakeReaper.
- The toggle surface: `toggleLoopToItem` in the tracker command scope, its key
  binding, help entry and a toolbar checkbox — arrange's `followPlay` segment
  and `toggleFollowPlay` as the model.
