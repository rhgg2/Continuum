-- The gm <-> tm intent/realisation seam (Option B: the per-instance
-- `conform` marker and the group-frame legato passes are gone; tm's
-- universal tail pass owns every realised note-off, pinned by
-- tm_conform_tail_spec). gm's job is now narrow: carry INTENT into the
-- group frame and back out to siblings. It reads a concrete's intent
-- from the tm-stamped endppqL (anchor-rebased to a group `dur`, or
-- open == nil dur) and STAGES that intent back as endppq (finite, or
-- util.OPEN); the real tm stamps endppqL and derives the realised
-- tail. The fake tm does neither, so these tests assert the staged
-- endppq, never a realised clip.
--
-- These tests pin that seam through the real preflush/reproject path
-- with a faithful fake tm (it does NOT run the tail pass -- so it can
-- only assert what gm STAGES as intent, never a realised clip).

local t    = require('support')
local util = require('util')

local function fakeTm()
  local hooks, staged, seq = {}, { add = {}, assign = {}, del = {} }, 0
  local tm = {}
  function tm:subscribe(sig, fn)  hooks[sig] = fn end
  function tm:addEvent(evt)       staged.add[#staged.add + 1] = evt end
  function tm:assignEvent(evt, u) staged.assign[#staged.assign + 1] = { evt = evt, update = u } end
  function tm:deleteEvent(evt)    staged.del[#staged.del + 1] = evt end
  function tm:length()            return 4000 end
  function tm:flush(adds, assigns, deletes)
    if hooks.preflush then hooks.preflush(adds or {}, assigns or {}, deletes or {}) end
    for _, e in ipairs(staged.add) do
      if e.uuid == nil then seq = seq + 1; e.uuid = 1000 + seq end
    end
    if hooks.postflush then hooks.postflush() end
  end
  return tm, staged, hooks
end

local function fakeCm()
  local store = {}
  return { get = function(_, k) return store[k] end,
           set = function(_, _l, k, v) store[k] = v end }
end

local function mk()
  local tm, staged = fakeTm()
  local gm = util.instantiate('groupManager', { tm = tm, cm = fakeCm() })
  return gm, tm, staged
end

local nextUuid = 0
-- Finite by default: a real authored note carries endppqL (intent
-- ceiling). `extra.open=true` seeds the freshly-placed open note --
-- endppqL = util.OPEN. (`open` itself is not a note field any more;
-- it must not leak into the group template via copyScalars.)
local function note(ppq, pitch, dur, extra)
  nextUuid = nextUuid + 1
  local n = { evType = 'note', chan = 1, lane = 1, ppq = ppq,
              endppq = ppq + (dur or 240), pitch = pitch, vel = 100,
              uuid = nextUuid }
  n.endppqL = (extra and extra.open) and util.OPEN or n.endppq
  for k, v in pairs(extra or {}) do if k ~= 'open' then n[k] = v end end
  return n
end

-- 960-wide region; siblings stack at the next bar (half-open: [0,960)
-- and [960,1920) are disjoint, so no regionConflict).
local function rect() return { ppq = 0, dur = 960, chanLo = 1,
                               streams = { [0] = { ['note:1'] = true } } } end

local function addAt(staged, ppq)
  for _, e in ipairs(staged.add) do if e.ppq == ppq then return e end end
end
local function assignFor(staged, evt)
  for _, a in ipairs(staged.assign) do if a.evt == evt then return a.update end end
end

return {
  {
    name = 'a finite note carries its ceiling (endppqL) rigidly to the sibling',
    run = function()
      local gm, tm, staged = mk()
      local A = note(0, 60, 240)                 -- ceiling 240
      local gid = gm:markGroup({ A }, rect())
      gm:newInstance(gid, { ppq = 960, chan = 1 })

      local copy = addAt(staged, 960)
      t.truthy(copy, 'sibling copy projected')
      t.eq(copy.endppq, 1200, 'intent ceiling staged on endppq, rebased to anchor 960 (960+0+240)')
      t.eq(copy.endppqL, nil, 'gm stages endppq only; endppqL is tm-private')
      t.truthy(copy.endppq ~= util.OPEN, 'a finite note is not open')
    end,
  },

  {
    name = 'an open note travels as open: no ceiling, provisional onset+1 tail',
    run = function()
      local gm, tm, staged = mk()
      local O = note(0, 60, 240, { open = true })   -- no ceiling
      local gid = gm:markGroup({ O }, rect())
      gm:newInstance(gid, { ppq = 960, chan = 1 })

      local copy = addAt(staged, 960)
      t.truthy(copy, 'sibling copy projected')
      t.eq(copy.endppq, util.OPEN, 'open intent staged on endppq; tm derives the real tail')
      t.eq(copy.endppqL, nil, 'gm stages endppq only; endppqL is tm-private')
    end,
  },

  {
    name = 'a group-level create is open in the group frame (no birth ceiling)',
    run = function()
      local gm, tm, staged = mk()
      local A = note(0, 60, 240)
      local gid = gm:markGroup({ A }, rect())
      gm:newInstance(gid, { ppq = 960, chan = 1 })
      tm:flush(); staged.add, staged.assign, staged.del = {}, {}, {}

      local born = note(240, 62, 240)                  -- a create
      tm:flush({ { evt = born } }, {}, {})

      -- The created note is open like tv's placeNewNote, regardless of
      -- the birth endppq it arrived with. Its sibling copy is open.
      local sib = addAt(staged, 1200)                  -- 960 + 240
      t.truthy(sib, 'sibling copy of the created note projected')
      t.eq(sib.endppq, util.OPEN, 'a fresh create has no birth ceiling -> util.OPEN')

      -- A is NOT clipped in the group frame by the new onset: the
      -- group frame carries intent only; tm clips the realised tail.
      local aSib = addAt(staged, 960)
      if aSib == nil then
        for _, a in ipairs(staged.assign) do
          if a.evt.pitch == 60 then aSib = a.update end
        end
      end
      t.falsy(aSib and aSib.endppq and aSib.endppq ~= 1200 and aSib.endppq ~= util.OPEN,
        'A keeps its own ceiling -- project never clips intent to the new onset')
    end,
  },

  {
    name = 'a group-level delete does NOT grow the predecessor in the group frame',
    run = function()
      local gm, tm, staged = mk()
      local A, B, C, D = note(0, 60), note(240, 62), note(480, 64), note(720, 65)
      local gid = gm:markGroup({ A, B, C, D }, rect())
      gm:newInstance(gid, { ppq = 2000, chan = 1 })
      tm:flush(); staged.add, staged.assign, staged.del = {}, {}, {}

      tm:flush({}, {}, { { evt = C } })                -- non-local delete of C

      local delPitch = {}
      for _, e in ipairs(staged.del) do delPitch[e.pitch] = true end
      t.truthy(delPitch[64], 'C is delete-propagated to the sibling')

      -- B's ceiling is untouched: the universal tm tail pass regrows B's
      -- realised note-off over the hole, NOT a group-frame legato grow.
      for _, a in ipairs(staged.assign) do
        if a.evt.pitch == 62 then
          t.falsy(a.update.endppqL or a.update.dur,
            'B keeps its authored ceiling -- project never grows intent')
        end
      end
    end,
  },

  {
    name = 'markGroup seed is canonical -- it never rewrites the take geometry',
    run = function()
      local gm, tm, staged = mk()
      local A = note(0,   60, 240)
      local B = note(240, 62, 9360)                    -- long, last in lane
      -- Narrow 480-wide region so the cascade's first copy at anchor
      -- 480 is disjoint from the [0,480) seed (no regionConflict).
      local seedRect = { ppq = 0, dur = 480, chanLo = 1,
                         streams = { [0] = { ['note:1'] = true } } }
      gm:duplicateInto(nil, { A, B }, seedRect, { ppq = 480, chan = 1 })
      tm:flush()

      -- The user's existing take is authority: the seed must not stage
      -- any geometry rewrite of B (no conform marker exists to stamp).
      for _, a in ipairs(staged.assign) do
        if a.evt == B then
          t.eq(a.update.ppq,     nil, 'B onset untouched -- take is canonical')
          t.eq(a.update.endppq,  nil, 'B raw tail untouched')
          t.eq(a.update.endppqL, nil, 'B ceiling untouched')
          t.eq(a.update.dur,     nil, 'B duration untouched')
        end
      end
    end,
  },
}
