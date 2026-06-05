# Page façade & cross-page state ownership

**Status: planned, not yet implemented.** This is a design + migration plan,
not a description of current code. When a phase lands, fold its WHY into the
relevant module doc and trim the plan here.

## The problem

Two pains, one root cause.

1. **The empty-track ask.** The tracker page can't navigate to a track with no
   MIDI takes — `gotoTrackDelta` *skips* such tracks. We want to land on them
   and show an empty grid with a message.
2. **REAPER selection as an in-process bus.** Today "which take the tracker
   edits" is `coord.currentTake`, polled every frame from
   `GetSelectedMediaItem → GetActiveTake`. Navigation *writes* REAPER's global
   selection (`diveToTake` → `SelectAllMediaItems`/`SetMediaItemSelected`) so the
   poll reads it back. In-process pages talking through a global external
   mutable — the "highlight a thing in REAPER and something fires" coupling, and
   a selection-desync hazard.

The empty-track fix forces the deeper question, because an empty track has no
take, and the whole tracker stack is bound to a take.

## Decisions (settled)

- **Model B.** Cross-page domain state lives with the page that is authoritative
  for it, exposed through that page's public façade. `coord` shrinks to
  lifecycle + wiring; it is *not* a domain blackboard. (Rejected Model A:
  formalize `coord` as the mediator/blackboard — keeps the state divorced from
  its owner and grows `coord` without bound.)

- **The arrange cursor is the single source of truth** for current track + take.
  `cursorCol` = track index; `takeAtCursor()` = the take by QN-overlap at
  `cursorRow`; `.take` is the raw REAPER handle. No REAPER selection anywhere.
  Moving the cursor (on either page) changes what the tracker edits.

- **Two cross-page channels, both standard affordances:**
  - **Capability of another page** → that page's *façade* (`facade.get('arrange')…`).
  - **Navigation between pages** → `cmgr` *commands* (`cmgr:invoke('switchToTracker')`).
    (Rejected routing navigation through a `coord` façade — duplicates commands.)

- **`coord` owns the façade *registry* (wiring), not the façade *contents*.** The
  contents are each page's domain state, published by the owning page.

- **The page owns its stack; the page is the sole public face of its stack.**
  Nothing outside the arrange stack knows about `arrangeManager` (`am`) or
  `arrangeView` (`av`). The current defect: `trackerPage` constructs its own
  private `am` (`trackerPage.lua:36`) — a layering violation. It must go; the
  tracker reaches arrange data only through the `arrange` façade.

- **There is always a track.** The grid cursor always has a column (we boot into
  arrange). So `currentTrackIdx()` is never nil; the "no track" render state and
  the old `Select a MIDI item to begin.` placeholder disappear. (Zero-track
  projects are degenerate and not designed around.)

## Mechanism — façade registry + affordance injection

`coord` owns the registry and *constructs* every page (affordances are used at
construction time — stacks instantiate, toolbar segments reference `chrome`/`cm`
— so inject-after-`register` is too late).

```lua
-- coordinator.lua
local facades = {}
local facade  = {
  publish = function(name, iface) facades[name] = iface end,
  get     = function(name) return facades[name] or error('no facade: ' .. name) end,
}
-- cm/cmgr/gui arrive at coord construction; chrome/modalHost coord builds; facade is coord's.
local STD = { cm = cm, cmgr = cmgr, chrome = chrome, gui = gui, modalHost = modalHost, facade = facade }

function coord:register(name, moduleName, extra)
  local page = util.instantiate(moduleName, util.assign({}, STD, extra))
  pages[name] = page
  if not active then self:setActive(name) end
  return page          -- so Main can still run post-construct hooks
end
```

`continuum.lua` `Main()` collapses to register calls; no per-page affordance
threading, no bridging closures. `extra` ends up empty for all four pages.

```lua
coord:register('wiring', 'wiringPage')                 -- first → boots active
local ap = coord:register('arrange', 'arrangePage')
coord:register('tracker', 'trackerPage')
coord:register('sample',  'samplePage')
ap:seedCursorFromReaper()                              -- post-construct hook via return handle
-- wiringPage:enableLive() likewise
```

A page publishes its own façade and reads peers via the injected `facade`.
Resolve **lazily, at call time** (a one-liner) to sidestep construction order:

```lua
-- arrangePage.lua (publish at construction)
facade.publish('arrange', { currentTake = function() return av:currentTake() end, ... })

-- trackerPage.lua (consume)
local function arrange() return facade.get('arrange') end
... arrange():currentTake() ...
```

The façade is a **curated table, not the page object** — peers never see
`renderBody`/`bind`/`unbind`.

## The façades

**`arrange`** (published by `arrangePage`, backed by `av`):

```
arrangeFacade = {
  currentTake()            -> reaper take | nil      -- (takeAtCursor() or {}).take
  currentTrackIdx()        -> 0-based int            -- cursorCol (always valid)
  tracks()                 -> {projectTrack,...}     -- am:projectTracks()
  midiSlots(trackIdx)      -> {slot,...}             -- MIDI-only (filter relocated from tracker)
  keyForSlot(slotIdx)      -> string
  gotoTrack(dir)           -- ±1 track, no skip, land empty; moves cursor
  gotoTake(dir)            -- ±1 take/slot on current track; moves cursor
  pickTrack(trackIdx)      -- jump to track; moves cursor
  pickTake(slotIdx)        -- jump to slot on current track; moves cursor
  newTakeBelow()           -- createSlot modal + cursor onto new take
  duplicateUnpooledBelow() -- clone + cursor onto copy
}
```

**`tracker`** (published by `trackerPage`) — one method, the arrange→tracker
capability:

```
trackerFacade = { openTakeProperties(take) }
```

The snapshot-bind / point-at-take / restore-on-close logic currently in `Main()`'s
`onTakeProperties` closure (`continuum.lua:94-105`) moves *into* this method.

## Navigation semantics

- **No skip, land-empty.** `gotoTrack` steps one track (clamped to
  `#am:projectTracks()` — computed at call time, not via `av:setMaxCol`, which is
  only fresh while arrange renders). If the new track has MIDI takes, resolve and
  move onto one; if it has **zero**, keep the row and leave `currentTake()` nil.
- **Forward-first resolve.** Landing on a track always picks the nearest take
  *at/after* the cursor's QN, else the nearest *before* — fixed, independent of
  the track-nav direction:

  ```lua
  -- resolveInstance, relocated to av:
  -- was: nearest(instances, fromQN, dir) or nearest(instances, fromQN, -dir)  -- travel-relative
     now: nearest(instances, fromQN, 1)   or nearest(instances, fromQN, -1)    -- forward-first, fixed
  ```

  (`pickTrack` already does forward-first; `gotoTrack` aligns to match.)
  `gotoTake` keeps ordered slot-stepping along its own axis.

The nav algorithm (`nearest`, `resolveInstance`, `midiInstances`, `midiSlots`,
`gotoTrackDelta`, `gotoSlotDelta`, `pickTrack`, `pickSlot`) moves out of
`trackerPage` into `av`, rewritten to *set the cursor* instead of calling
`selectTake`.

## Render states (tracker `renderBody`)

There is always a track, so two empty states + the grid:

| Cursor situation | Message |
|---|---|
| Track has **zero** MIDI takes | `No MIDI takes on this track.` |
| Track has MIDI takes, none at the cursor row | `No take at the cursor.` |
| Take under cursor | the grid |

Navigation never produces the middle state (forward-first always resolves on a
non-empty track). It arises only from a **disappearance** (the bound take deleted
under you) or from free arrange-grid cursor movement onto a gap.

## Disappearance handling — show empty, never auto-seek

When the bound take vanishes (e.g. deleted in REAPER while you're in the tracker),
the cursor stays put, `currentTake()` goes nil, the grid renders empty. **Never
relocate the edit target in reaction to a disappearance** — silently jumping onto
a neighbouring take risks editing the wrong take unnoticed. Relocation happens
*only* via explicit navigation. This is free: it's the natural consequence of
`currentTake = takeAtCursor` returning nil.

### Why the staleness machinery is a tracker-only concern

The tracker is the only page that **materializes and holds a per-take model
across frames** (`tm:bindTake` builds `mm` events + the `tv` grid and caches
them). Arrange and wiring are project-wide and re-derive from live `am`/project
data every frame — `takeAtCursor` iterates `am:tracksTakes` fresh; arrange's
`focus` is a bare handle re-resolved via `am:findTake` (self-heals to nil). No
cache, no held pointer, so deletions/external edits just reflect next frame.
Sample binds a *track*, not a take, and caches no take-derived model. So the
`ValidatePtr2` + hash-diff watchers (`coordinator.lua:131-145,283`) are the cost
of the tracker's caching and **move into the tracker**.

Ordering in `renderBody`: rebind-on-change check **first** (sees `currentTake()`
differ → unbind, drop the model), then the hash-watcher, which no-ops on the
now-nil bind. That closes the one-frame stale-pointer window without
`ValidatePtr2`. Rests on `am:tracksTakes` reflecting live project state —
**verify in phase 2** before deleting the `ValidatePtr2` path.

## `trackerPage` reduction

- **Delete** its `am` construction (`trackerPage.lua:36`) and the whole
  `Palette navigation` block (~311-389): `boundAmTake`, `midiInstances`,
  `midiSlots`, `nearest`, `resolveInstance`, `selectInstance`, `gotoTrackDelta`,
  `gotoSlotDelta`, `pickTrack`, `pickSlot` — relocated to `av`.
- `boundAmTake()` → `arrange():currentTake()` everywhere.
- Nav commands → `arrange():gotoTrack(±1)` / `gotoTake(±1)`.
- Toolbar Track/Take pickers read `arrange():tracks()` /
  `arrange():midiSlots(arrange():currentTrackIdx())` / `currentTake`;
  `onPick` → `arrange():pickTrack/pickTake`.
- `newTakeBelow`/`duplicateUnpooledBelow` commands → `arrange()` delegations
  (arrange already owns this flow for its own Cmd-Enter; tracker was duplicating
  it). `adoptNewTake` goes away — the cursor move drives the rebind.
- `takeProperties` command unchanged (operates on the bound take); the page
  *publishes* `openTakeProperties(take)` for arrange.
- **Bind from the cursor:** at the top of `renderBody` (runs while active), read
  `arrange():currentTake()` and `tp:bind` on change. `bind()` becomes
  argument-less and self-sources.

## `coord` slimming

- Remove `currentTake`, `samplerTrack`, `refreshTakeFromReaper`, and
  `diveToTake`'s selection writes. No REAPER selection anywhere.
- `setActive`/`togglePage` gate on a current track (always true with ≥1 track) —
  not a take. Tracker is always in the toggle cycle.
- `diveToTake` → navigation only (`setActive('tracker')`); `returnToArrange` →
  `setActive('arrange')` (the cursor never left the take, so `revealTake` is
  unnecessary).
- `tick`'s `sample:tick(currentTake)` → `sample:tick()`; sample self-sources via
  `facade.get('arrange')`.

## Sample page

`onPickTrack` dissolves — it's a self round-trip (sample picker → `coord` →
`sample:bind`) that only exists because `coord` hoards `samplerTrack`. The sample
page owns its own track: the picker sets its own state and rebinds itself. The
`diveToSampler` command splits into `facade.get('sample').setTrack(track)`
(capability) + navigate (command).

## Phasing (each lands green)

1. **Infra** — façade registry + `register`-constructs-pages + affordance
   injection. Pure mechanical refactor, zero behaviour change. Pages accept
   `facade`, unused.
2. **Model B core** — `arrange` publishes `currentTake/currentTrackIdx` + nav +
   lifecycle; tracker binds from the cursor; nav/CRUD/takeProps callbacks
   migrate; tracker's private `am` deleted; selection bus removed; watchers move
   into the tracker. Behaviour preserved.
3. **Empty-track feature** — no-skip nav, the two empty render states, gating on
   current track.

## Open items / verify during implementation

- `am:tracksTakes` reflects live project state with no stale cache (basis for
  deleting `ValidatePtr2`). Verify in phase 2.
- `util.assign` signature/availability for the `STD`+`extra` merge in `register`.
- Post-construct hooks (`ap:seedCursorFromReaper`, `wiringPage:enableLive`) via
  the `register` return handle — or later fold into a `page:start()` lifecycle
  hook `coord` calls.
- Exact `sample` use of `currentTake` in its `tick` (confirm it only needs a
  read, self-sourceable from the façade).
- The hash-diff external-mutation watcher exact relocation into `renderBody`.
