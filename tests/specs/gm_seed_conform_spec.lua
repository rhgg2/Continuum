-- markGroup seeds instance 1 from the user's existing take events: that
-- geometry is canonical for the group and must not be rewritten. But the
-- last-in-lane note per stream still needs its realisation `conform` flag,
-- exactly as newInstance sets it on the copies it builds -- otherwise the
-- conform-tail rebuild pass can't clip a pattern-length tail before lane
-- allocation, and a note dropped inside that tail (the first duplicate
-- copy) gets bumped to a sibling lane.
--
-- Same faithful-fake seam as mirm_propagate_spec.

local t      = require('support')
local util   = require('util')

local function fakeTm()
  local hooks, staged, seq = {}, { add = {}, assign = {}, del = {} }, 0
  local tm = {}
  function tm:subscribe(sig, fn)    hooks[sig] = fn end
  function tm:addEvent(evt)         staged.add[#staged.add + 1] = evt end
  function tm:assignEvent(evt, u)   staged.assign[#staged.assign + 1] = { evt = evt, update = u } end
  function tm:deleteEvent(evt)      staged.del[#staged.del + 1] = evt end
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
  return {
    get = function(_, k) return store[k] end,
    set = function(_, _lvl, k, v) store[k] = v end,
  }
end

local function mk()
  local tm, staged = fakeTm()
  local gm = util.instantiate('groupManager', { tm = tm, cm = fakeCm() })
  return gm, tm, staged
end

local nextUuid = 0
local function note(ppq, endppq, pitch)
  nextUuid = nextUuid + 1
  return { evType = 'note', chan = 1, lane = 1, ppq = ppq,
           endppq = endppq, pitch = pitch, vel = 100, uuid = nextUuid }
end

local function rect()
  return { ppq = 0, dur = 480, chanLo = 1,
           streams = { [0] = { ['note:1'] = true } } }
end

local function conformUpdateFor(staged, evt)
  for _, a in ipairs(staged.assign) do
    if a.evt == evt and a.update.conform ~= nil then return a.update.conform end
  end
end

return {
  {
    name = 'duplicate-seed markGroup conform-marks the last-in-lane note, leaving its geometry canonical',
    run = function()
      local gm, tm, staged = mk()
      local A = note(0,   240,  60)            -- clipped, row 1
      local B = note(240, 9600, 62)            -- pattern-length, row 2, last in lane

      -- Cascade seed: nil group -> markGroup + first copy one region below.
      gm:duplicateInto(nil, { A, B }, rect(), { ppq = 480, chan = 1 })
      tm:flush()

      t.eq(conformUpdateFor(staged, B), true,
        'B (pattern-length, last in lane) is conform-marked on the seed')
      t.eq(conformUpdateFor(staged, A), nil,
        'A is not last in lane -- no conform flag')

      -- The take is canonical: no staged assign rewrites B's geometry.
      for _, a in ipairs(staged.assign) do
        if a.evt == B then
          t.eq(a.update.ppq, nil, 'B onset untouched -- take is canonical')
          t.eq(a.update.endppq, nil, 'B tail untouched -- take is canonical')
          t.eq(a.update.dur, nil, 'B duration untouched -- take is canonical')
        end
      end
    end,
  },
}
