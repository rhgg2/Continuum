-- UI wiring for the note-FX editor (retrig + vibrato + slide). Pins cursorNote ->
-- setNoteFx / setFxKindActive / setFxField. Continuous kinds coexist -- both sum at the node.

local t    = require('support')
local util = require('util')

local DELTA_MSB = 20   -- toy fixed vibrato carrier (cf. tm_vibrato_spec)

local function addHost(h, fx, lane)
  h.tm:addEvent{ evType = 'note', ppq = 0, endppq = 240, chan = 1, pitch = 60,
                 vel = 100, detune = 0, delay = 0, lane = lane or 1, fx = fx }
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

local function byKind(fx)
  local out = {}; for _, e in ipairs(fx or {}) do out[e.kind] = e end; return out
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

  {
    name = 'setFxKindActive adds a section, preserving the other category',
    run = function(harness)
      local h = harness.mk()
      addHost(h, { { kind = 'retrig', period = { 1, 4 }, ramp = 0 } })
      local uuid = hostUuid(h)
      h.vm:setFxKindActive(uuid, { kind = 'vibrato', period = { 1, 2 }, depth = 30, onset = 1 }, true)
      local k = byKind(h.vm:noteFx(uuid))
      t.truthy(k.retrig and k.vibrato, 'retrig and vibrato co-resident')
      t.eq(k.vibrato.depth, 30, 'vibrato seeded from its default')
    end,
  },

  {
    name = 'setFxKindActive false removes one section; last removal clears fx',
    run = function(harness)
      local h = harness.mk()
      addHost(h, { { kind = 'retrig',  period = { 1, 4 }, ramp = 0 },
                   { kind = 'vibrato', period = { 1, 2 }, depth = 30, onset = 1 } })
      local uuid = hostUuid(h)
      h.vm:setFxKindActive(uuid, { kind = 'retrig' }, false)
      local fx = h.vm:noteFx(uuid)
      t.eq(#fx, 1, 'retrig removed, vibrato kept')
      t.eq(fx[1].kind, 'vibrato', 'the survivor is vibrato')
      h.vm:setFxKindActive(uuid, { kind = 'vibrato' }, false)
      t.falsy(h.vm:noteFx(uuid), 'emptying clears fx entirely (no empty list)')
    end,
  },

  {
    name = 'setFxKindActive seeds slide alongside vibrato (continuous kinds coexist)',
    run = function(harness)
      local h = harness.mk()
      addHost(h, { { kind = 'vibrato', period = { 1, 2 }, depth = 30, onset = 1 } })
      local uuid = hostUuid(h)
      h.vm:setFxKindActive(uuid, { kind = 'slide', over = { 1, 2 }, target = 'next' }, true)
      local k = byKind(h.vm:noteFx(uuid))
      t.truthy(k.vibrato and k.slide, 'vibrato and slide co-resident -- both sum at the node')
      t.eq(k.slide.target, 'next', 'slide seeded with target=next')
      h.vm:setFxField(uuid, 2, 'over', { 1, 4 })
      t.eq(h.vm:noteFx(uuid)[2].over[2], 4, 'over cycled via the generic field writer')
    end,
  },

  {
    name = "slide target='fixed' bends by its cents demand; 'next' needs a following note",
    run = function(harness)
      local h = harness.mk()
      addHost(h, { { kind = 'slide', over = { 1, 2 }, target = 'fixed', cents = 200 } }, 1)
      local uuid = hostUuid(h)
      local function carrierCount()
        local n = 0
        for _, c in ipairs(h.fm:dump().ccs) do
          if c.evType == 'cc' and c.cc == DELTA_MSB then n = n + 1 end
        end
        return n
      end
      t.truthy(carrierCount() >= 3, 'a fixed slide bakes a carrier with no next-note lookup')
      h.vm:setFxField(uuid, 1, 'target', 'next')
      t.eq(carrierCount(), 0, "target='next' with no following note yields no carrier")
    end,
  },

  {
    name = 'setFxField writes vibrato depth and onset',
    run = function(harness)
      local h = harness.mk()
      addHost(h, { { kind = 'vibrato', period = { 1, 2 }, depth = 30, onset = 1 } })
      local uuid = hostUuid(h)
      h.vm:setFxField(uuid, 1, 'depth', 55)
      h.vm:setFxField(uuid, 1, 'onset', 2)
      local e = h.vm:noteFx(uuid)[1]
      t.eq(e.depth, 55, 'depth written')
      t.eq(e.onset, 2,  'onset written')
    end,
  },

  {
    name = 'a vibrato entry on a lane-1 host bakes a carrier stream',
    run = function(harness)
      local h = harness.mk()
      addHost(h, nil, 1)
      local uuid = hostUuid(h)
      h.vm:setNoteFx(uuid, { { kind = 'vibrato', period = { 1, 2 }, depth = 30, onset = 0 } })
      local n = 0
      for _, c in ipairs(h.fm:dump().ccs) do
        if c.evType == 'cc' and c.cc == DELTA_MSB then n = n + 1 end
      end
      t.truthy(n >= 4, 'the view path realises vibrato as a sparse carrier stream (extrema + anchors)')
    end,
  },

  {
    name = 'authoring fx reconciles the CC node (pa:apply on every setNoteFx)',
    run = function(harness)
      local h = harness.mk()
      addHost(h, nil, 1)
      local uuid = hostUuid(h)
      local calls = 0
      h.pa.apply = function() calls = calls + 1 end   -- spy at the boundary
      h.vm:setNoteFx(uuid, { { kind = 'vibrato', period = { 1, 2 }, depth = 30, onset = 1 } })
      t.eq(calls, 1, 'authoring a carrier triggers a node reconcile')
      h.vm:setFxField(uuid, 1, 'depth', 40)
      t.eq(calls, 2, 'a field edit routes through setNoteFx -> reconcile')
      h.vm:setNoteFx(uuid, util.REMOVE)
      t.eq(calls, 3, 'clearing reconciles again')
    end,
  },
}
