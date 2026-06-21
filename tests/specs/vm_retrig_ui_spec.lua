-- UI wiring for the retrig editor; key dispatch is thin REAPER glue (cf.
-- tracker_page_spec). Pins the real editing path: cursorNote -> setNoteFx / setFxField.

local t    = require('support')
local util = require('util')

local function addHost(h, fx)
  h.tm:addEvent{ evType = 'note', ppq = 0, endppq = 240, chan = 1, pitch = 60,
                 vel = 100, detune = 0, delay = 0, lane = 1, fx = fx }
  h.tm:flush()
end

local function lane1Idx(h)
  for i, c in ipairs(h.vm.grid.cols) do
    if c.midiChan == 1 and c.type == 'note' and c.lane == 1 then return i end
  end
end

-- The host is the sole authored (non-derived) note; fxNotes carry derived.
local function hostUuid(h)
  for _, n in ipairs(h.fm:dump().notes) do if not n.derived then return n.uuid end end
end

local function fxNoteCount(h, uuid)
  local n = 0
  for _, note in ipairs(h.fm:dump().notes) do
    if note.derived == uuid then n = n + 1 end
  end
  return n
end

return {
  {
    name = 'cursorNote returns the caret note, nil off a note',
    run = function(harness)
      local h = harness.mk()
      addHost(h, nil)
      h.vm:setGridSize(80, 40)
      local ci = lane1Idx(h)
      h.ec:setPos(0, ci, 1)
      t.truthy(h.vm:cursorNote(), 'note under caret returned')
      h.ec:setPos(8, ci, 1)              -- empty row
      t.falsy(h.vm:cursorNote(), 'no note on an empty cell')
    end,
  },

  {
    name = 'setNoteFx seeds retrig -> rebuild expands; REMOVE clears',
    run = function(harness)
      local h = harness.mk()
      addHost(h, nil)
      h.vm:setGridSize(80, 40)
      local uuid = hostUuid(h)
      h.vm:setNoteFx(uuid, { { kind = 'retrig', period = { 1, 4 }, ramp = 0 } })
      t.eq(fxNoteCount(h, uuid), 3, '1/4 over a 1-QN host derives fxNotes 2..4')
      h.vm:setNoteFx(uuid, util.REMOVE)
      t.eq(fxNoteCount(h, uuid), 0, 'REMOVE clears the derived notes')
    end,
  },

  {
    name = 'setFxField writes period; finer period adds fxNotes',
    run = function(harness)
      local h = harness.mk()
      addHost(h, { { kind = 'retrig', period = { 1, 4 }, ramp = 0 } })
      h.vm:setGridSize(80, 40)
      local uuid = hostUuid(h)
      t.eq(fxNoteCount(h, uuid), 3, 'baseline 1/4')
      h.vm:setFxField(uuid, 1, 'period', { 1, 6 })   -- finer
      t.eq(h.vm:noteFx(uuid)[1].period[2], 6, 'period written to 1/6')
      t.eq(fxNoteCount(h, uuid), 5, 'finer period derives more fxNotes')
    end,
  },

  {
    name = 'setFxField writes ramp; fxNote velocities shift',
    run = function(harness)
      local h = harness.mk()
      addHost(h, { { kind = 'retrig', period = { 1, 4 }, ramp = 0 } })
      h.vm:setGridSize(80, 40)
      local uuid = hostUuid(h)
      h.vm:setFxField(uuid, 1, 'ramp', -10)
      t.eq(h.vm:noteFx(uuid)[1].ramp, -10, 'ramp updated on the entry')
      -- fxNote 2 (i=1) gets vel + 1*ramp = 100 - 10 = 90; later ones lower.
      local top = 0
      for _, n in ipairs(h.fm:dump().notes) do
        if n.derived == uuid and n.vel > top then top = n.vel end
      end
      t.eq(top, 90, 'first fxNote velocity ramped by -10')
    end,
  },

  {
    name = 'setFxField rewrites one entry, leaving siblings intact',
    run = function(harness)
      local h = harness.mk()
      addHost(h, { { kind = 'retrig', period = { 1, 4 }, ramp = 0 },
                   { kind = 'retrig', period = { 1, 4 }, ramp = -5 } })
      h.vm:setGridSize(80, 40)
      local uuid = hostUuid(h)
      h.vm:setFxField(uuid, 2, 'ramp', 7)
      local fx = h.vm:noteFx(uuid)
      t.eq(fx[1].ramp, 0, 'entry 1 untouched')
      t.eq(fx[2].ramp, 7, 'entry 2 rewritten')
    end,
  },
}
