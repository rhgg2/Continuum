-- See docs/patternEditor.md for the model.

--contract: OWNS ps/cm/ds/eventMeta + mm/tm/tv/cmgr/ccm/pa; RECEIVES the host facade + main ds
--contract: checkout take parks on scratch, never slot-registered; close deletes it directly
--contract: bind/unbind pass skipGuard -- the mini stack must never touch the host's guardedTrack
local util    = require 'util'
local scratch = require 'scratch'

local facade, mainDs = (...).facade, (...).ds

----- Own stack -- the harness `mk` shape, wired to the real shared facade
local ps        = util.instantiate('pextStore')
local cm        = util.instantiate('configManager',   { ps = ps })
local ds        = util.instantiate('dataStore',       { ps = ps })
local eventMeta = util.instantiate('eventMeta',       { ps = ps })
local mm        = util.instantiate('midiManager',     { take = nil, eventMeta = eventMeta })
local tm        = util.instantiate('trackerManager',  { mm = mm, cm = cm, ds = ds })
local ccm       = util.instantiate('ccManager')
local pa        = util.instantiate('paramAutomation', { cm = cm, ds = ds, facade = facade, ccm = ccm })
local cmgr      = util.instantiate('commandManager',  { cm = cm })
local tv        = util.instantiate('trackerView',
  { tm = tm, cm = cm, ds = ds, cmgr = cmgr, gm = nil, pa = pa, facade = facade })

local pe = {}

local item, poolGuid   -- set between open and close; nil while dormant

----- Materialise the stored body onto the bound checkout take

-- Specs are park-shaped and unswung, so wire ppq == logical ppqL. The stamped
-- fields (lane/detune/delay) must ride or tm crashes at pickStampedLane.
local function materialiseNotes(specs)
  for _, s in ipairs(specs or {}) do
    mm:add{ evType = 'note', chan = 1,
            ppq = s.ppqL, endppq = s.endppqL, ppqL = s.ppqL, endppqL = s.endppqL,
            pitch = s.pitch, vel = s.vel,
            lane = s.lane or 1, detune = s.detune or 0, delay = s.delay or 0,
            sample = s.sample }
  end
end

-- Curve points are bipolar -1..+1; the pb column authors in cents, full-scale
-- at the take's pbRange. Commit (P3 step e) normalises back by the same factor.
local function materialiseCurve(points)
  local fullScaleCents = cm:get('pbRange') * 100
  for _, p in ipairs(points or {}) do
    mm:add{ evType = 'pb', chan = 1, ppq = p.ppq, ppqL = p.ppq,
            val = p.val * fullScaleCents, shape = p.shape, tension = p.tension }
  end
end

----------- PUBLIC

--contract: mint a checkout take on scratch, materialise `name`'s body, bind the mini tm
--contract: no-op if already open or `name` is unknown
function pe:open(name)
  if item then return end
  local body = (mainDs:get('fxPatterns') or {})[name]
  if not body then return end

  item = reaper.CreateNewMIDIItemInProj(scratch.track(), 0, 1, true)
  local take = reaper.GetActiveTake(item)
  tm:bindTake(take, { skipGuard = true })   -- bindTake keys cm to the take; no separate setContext
  poolGuid = mm:poolGuid()

  mm:setLength(body.lengthPpq / mm:resolution())
  mm:modify(function()
    if body.kind == 'curve' then materialiseCurve(body.points)
    else                         materialiseNotes(body.specs) end
  end)
end

--contract: sweep the pool metadata (write-through, so leaks without this)
--contract: unbind the mini tm, delete the checkout item
function pe:close()
  if not item then return end
  eventMeta:dropPool(poolGuid)
  tm:bindTake(nil, { skipGuard = true })
  reaper.DeleteTrackMediaItem(scratch.track(), item)
  item, poolGuid = nil, nil
end

function pe:isOpen()      return item ~= nil      end
function pe:currentTake() return tm:currentTake() end

return pe
