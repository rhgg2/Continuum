-- mirrorDuplicate cascade lifetime (trackerPage wiring contract).
--
-- A run of mirrorDuplicate presses links every copy into ONE group so
-- they mirror-track. The run is page UX state (mirrorDupGroupId), held
-- by a doBefore keep-set: pure cursor moves keep it; any new selection
-- or mutation drops it, so the next mirrorDuplicate seeds a fresh
-- group instead of silently extending the old one wherever the cursor
-- drifted.
--
-- The earlier bug: the cascade rode mirm's shared active pointer,
-- whose keep-set is the broad MIRROR_KEEP, so it never stopped "as
-- long as there's a selection". mirm:duplicateInto takes the explicit
-- token only and never falls back to active. Real mirm + real cmgr;
-- fake tm as in mirm_wiring_spec.

local t    = require('support')
local util = require('util')

local function fakeTm()
  local hooks, staged, seq = {}, { add = {} }, 0
  local tm = {}
  function tm:subscribe(s, fn) hooks[s] = fn end
  function tm:addEvent(e)      staged.add[#staged.add + 1] = e end
  function tm:assignEvent()    end
  function tm:deleteEvent()    end
  function tm:flush()
    if hooks.preflush then hooks.preflush({}, {}, {}) end
    for _, e in ipairs(staged.add) do
      if e.uuid == nil then seq = seq + 1; e.uuid = 1000 + seq end
    end
    if hooks.postflush then hooks.postflush() end
  end
  return tm, staged
end

local function fakeCm()
  local store = {}
  return { get = function(_, k) return store[k] end,
           set = function(_, _l, k, v) store[k] = v end }
end

local function note() return { evType = 'note', chan = 1, lane = 1,
  ppq = 0, endppq = 240, pitch = 60, vel = 100 } end
local function rect() return { ppq = 0, dur = 960, chanLo = 1,
  streams = { [0] = { ['note:1'] = true } } } end

-- Reproduces trackerPage's mirrorDuplicate body + DUP_KEEP sweep
-- against a real cmgr scope. groupOf() exposes the page token.
local function wire(mirm, cmgr)
  local DUP_KEEP = { mirrorDuplicate = true, cursorDown = true }
  local mirrorDupGroupId
  local sc = cmgr:scope('tracker')
  sc:registerAll{
    cursorDown = function() end,
    selectDown = function() end,
    deleteSel  = function() end,
    mirrorDuplicate = function()
      mirrorDupGroupId = mirm:duplicateInto(mirrorDupGroupId,
        { note() }, rect(), { ppq = 960, chan = 1 })
    end,
  }
  local dupClearOn = {}
  for name in pairs(sc.registered) do
    if not DUP_KEEP[name] then dupClearOn[#dupClearOn + 1] = name end
  end
  cmgr:doBefore(dupClearOn, function() mirrorDupGroupId = nil end)
  cmgr:push('tracker')
  return function() return mirrorDupGroupId end
end

local function mk()
  local tm     = fakeTm()
  local cm     = fakeCm()
  local mirm   = util.instantiate('mirrorManager', { tm = tm, cm = cm })
  local cmgr   = util.instantiate('commandManager', { cm = cm })
  local groupOf = wire(mirm, cmgr)
  return mirm, cmgr, groupOf
end

return {
  {
    name = 'a cursor move keeps the cascade: the next duplicate joins the same group',
    run = function()
      local mirm, cmgr, groupOf = mk()
      cmgr:invoke('mirrorDuplicate')
      local g1 = groupOf()
      t.truthy(g1, 'first duplicate seeded a cascade group')
      cmgr:invoke('cursorDown')
      cmgr:invoke('mirrorDuplicate')
      t.eq(groupOf(), g1, 'cursor move kept the cascade; same group')
    end,
  },
  {
    name = 'a new selection ends the cascade: the next duplicate seeds a fresh group',
    run = function()
      local mirm, cmgr, groupOf = mk()
      cmgr:invoke('mirrorDuplicate')
      local g1 = groupOf()
      cmgr:invoke('selectDown')
      t.eq(groupOf(), nil, 'a new selection dropped the cascade token')
      cmgr:invoke('mirrorDuplicate')
      local g2 = groupOf()
      t.truthy(g2 and g2 ~= g1, 'a distinct fresh group, not the old one')
    end,
  },
  {
    name = 'a mutation ends the cascade: the next duplicate seeds a fresh group',
    run = function()
      local mirm, cmgr, groupOf = mk()
      cmgr:invoke('mirrorDuplicate')
      local g1 = groupOf()
      cmgr:invoke('deleteSel')
      t.eq(groupOf(), nil, 'a mutation dropped the cascade token')
      cmgr:invoke('mirrorDuplicate')
      t.truthy(groupOf() ~= g1, 'a distinct fresh group, not the old one')
    end,
  },
}
