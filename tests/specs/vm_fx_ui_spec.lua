-- UI wiring for the note-FX editor (retrig + vibrato + slide). Pins fxHostAtCursor ->
-- setNoteFx / setFxKindActive / setFxField. Continuous kinds coexist -- both sum offline into pb seats.

local t          = require('support')
local util       = require('util')
local generators = require('generators')

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

-- The host: parked off-take once it carries a discrete kind, else the sole
-- authored (non-derived) take note.
local function hostUuid(h)
  local parked = h.tm:getChannel(1).parked[1]
  if parked then return parked.uuid end
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
    name = 'fxHostAtCursor covers the whole note span, nil past its tail',
    run = function(harness)
      local h = harness.mk()
      h.tm:addEvent{ evType = 'note', ppq = 0, endppq = 960, chan = 1, pitch = 60,
                     vel = 100, detune = 0, delay = 0, lane = 1 }
      h.tm:flush()
      h.vm:setGridSize(80, 40)
      local ci = lane1Idx(h)
      local tail = h.vm.grid.cols[ci].tails[1]
      h.ec:setPos(tail.startRow, ci, 1)
      local host = h.vm:fxHostAtCursor()
      t.truthy(host, 'onset row resolves the host')
      h.ec:setPos(tail.endRow - 1, ci, 1)
      t.eq(h.vm:fxHostAtCursor(), host, 'a sustained row resolves the same host')
      h.ec:setPos(tail.endRow, ci, 1)
      t.falsy(h.vm:fxHostAtCursor(), 'past the tail resolves nothing')
    end,
  },

  {
    -- A PA carries a durable uuid (rpb rides a sidecar) but is a point-event with no
    -- endppqC. The host scan must skip it, not compare rowStart against its nil window.
    name = 'fxHostAtCursor: a PA under the caret is skipped, not treated as a host',
    run = function(harness)
      local h = harness.mk()
      h.tm:addEvent{ evType = 'note', ppq = 0, endppq = 960, chan = 1, pitch = 60,
                     vel = 100, detune = 0, delay = 0, lane = 1 }
      h.tm:addEvent{ evType = 'pa', ppq = 240, chan = 1, pitch = 60, vel = 64, lane = 1, rpb = 2 }
      h.tm:flush()
      h.vm:setGridSize(80, 40)
      local ci = lane1Idx(h)
      local tail = h.vm.grid.cols[ci].tails[1]
      h.ec:setPos(tail.endRow - 1, ci, 1)
      t.eq(h.vm:fxHostAtCursor(), hostUuid(h), 'the note host resolves; the PA point-event is skipped')
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
      t.eq(fxNoteCount(h, uuid), 4, '1/4 over a 1-QN host parks it and derives all 4 hits')
      h.vm:setNoteFx(uuid, util.REMOVE)
      t.eq(fxNoteCount(h, uuid), 0, 'REMOVE clears the derived notes (the host is restored)')
    end,
  },

  {
    name = 'setFxField writes period; finer period adds fxNotes',
    run = function(harness)
      local h = harness.mk()
      addHost(h, { { kind = 'retrig', period = { 1, 4 }, ramp = 0 } })
      h.vm:setGridSize(80, 40)
      local uuid = hostUuid(h)
      t.eq(fxNoteCount(h, uuid), 4, 'baseline 1/4')
      h.vm:setFxField(uuid, 1, 'period', { 1, 6 })   -- finer
      t.eq(h.vm:noteFx(uuid)[1].period[2], 6, 'period written to 1/6')
      t.eq(fxNoteCount(h, uuid), 6, 'finer period derives more fxNotes')
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
      local vels = {}
      for _, n in ipairs(h.fm:dump().notes) do
        if n.derived == uuid then vels[#vels + 1] = n.vel end
      end
      table.sort(vels, function(a, b) return a > b end)
      t.deepEq(vels, { 100, 90, 80, 70 }, 'tile 0 carries the host vel; later tiles ramp by -10')
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
    name = 'addFxStage appends a stage, preserving the earlier ones',
    run = function(harness)
      local h = harness.mk()
      addHost(h, { { kind = 'retrig', period = { 1, 4 }, ramp = 0 } })
      local uuid = hostUuid(h)
      h.vm:addFxStage(uuid, { kind = 'vibrato', period = { 1, 2 }, depth = 30, onset = 1 })
      local k = byKind(h.vm:noteFx(uuid))
      t.truthy(k.retrig and k.vibrato, 'retrig and vibrato co-resident')
      t.eq(k.vibrato.depth, 30, 'vibrato seeded from its default')
    end,
  },

  {
    name = 'removeFxStage drops one stage; last removal clears fx',
    run = function(harness)
      local h = harness.mk()
      addHost(h, { { kind = 'retrig',  period = { 1, 4 }, ramp = 0 },
                   { kind = 'vibrato', period = { 1, 2 }, depth = 30, onset = 1 } })
      local uuid = hostUuid(h)
      h.vm:removeFxStage(uuid, 1)
      local fx = h.vm:noteFx(uuid)
      t.eq(#fx, 1, 'retrig removed, vibrato kept')
      t.eq(fx[1].kind, 'vibrato', 'the survivor is vibrato')
      h.vm:removeFxStage(uuid, 1)
      t.falsy(h.vm:noteFx(uuid), 'emptying clears fx entirely (no empty list)')
    end,
  },

  {
    name = 'moveFxStage swaps adjacent stages, reordering the series',
    run = function(harness)
      local h = harness.mk()
      addHost(h, { { kind = 'arp',        period = { 1, 4 }, dir = 'up' },
                   { kind = 'velPattern', pattern = { 100, 55 } } })
      local uuid = hostUuid(h)
      h.vm:moveFxStage(uuid, 2, -1)                      -- pull velPattern ahead of arp
      local fx = h.vm:noteFx(uuid)
      t.eq(fx[1].kind, 'velPattern', 'velPattern now leads')
      t.eq(fx[2].kind, 'arp',        'arp follows')
      t.falsy(h.vm:moveFxStage(uuid, 1, -1), 'moving the head earlier is a no-op')
    end,
  },

  {
    name = 'addFxStage appends a second stage of an existing kind (duplicates allowed)',
    run = function(harness)
      local h = harness.mk()
      addHost(h, { { kind = 'velPattern', pattern = { 100, 55 } } })
      local uuid = hostUuid(h)
      h.vm:addFxStage(uuid, { kind = 'velPattern', pattern = { 100, 55, 70 } })
      local fx = h.vm:noteFx(uuid)
      t.eq(#fx, 2, 'two velPattern stages coexist')
      t.eq(fx[2].pattern[3], 70, 'the appended stage keeps its own params')
    end,
  },

  {
    name = 'addFxStage seeds slide alongside vibrato (continuous kinds coexist)',
    run = function(harness)
      local h = harness.mk()
      addHost(h, { { kind = 'vibrato', period = { 1, 2 }, depth = 30, onset = 1 } })
      local uuid = hostUuid(h)
      h.vm:addFxStage(uuid, { kind = 'slide', over = { 1, 2 }, target = 'next' })
      local k = byKind(h.vm:noteFx(uuid))
      t.truthy(k.vibrato and k.slide, 'vibrato and slide co-resident -- both sum offline into pb seats')
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
      local function pbSeatCount()
        local n = 0
        for _, c in ipairs(h.fm:dump().ccs) do
          if c.evType == 'pb' then n = n + 1 end
        end
        return n
      end
      t.truthy(pbSeatCount() >= 3, 'a fixed slide seats a pb stream with no next-note lookup')
      h.vm:setFxField(uuid, 1, 'target', 'next')
      t.eq(pbSeatCount(), 0, "target='next' with no following note yields no seats")
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
    name = 'a vibrato entry on a lane-1 host seats a pb stream',
    run = function(harness)
      local h = harness.mk()
      addHost(h, nil, 1)
      local uuid = hostUuid(h)
      h.vm:setNoteFx(uuid, { { kind = 'vibrato', period = { 1, 2 }, depth = 30, onset = 0 } })
      local n = 0
      for _, c in ipairs(h.fm:dump().ccs) do
        if c.evType == 'pb' then n = n + 1 end
      end
      t.truthy(n >= 4, 'the view path realises vibrato as a densified pb seat stream')
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

  {
    name = 'a parked host cell routes to the parked backing at its onset row only',
    run = function(harness)
      local h = harness.mk()
      addHost(h, { { kind = 'retrig', period = { 1, 4 }, ramp = 0 } })
      h.vm:setGridSize(80, 40)
      local ci = lane1Idx(h)
      local col = h.vm.grid.cols[ci]
      t.eq(col.cellKind[0], 'parked', 'onset row tagged parked')
      t.falsy(col.cellKind[1], 'tail rows untagged: adds inside the span stay plain')
      h.ec:setPos(0, ci, 1)
      local host = h.vm:fxHostAtCursor()
      t.eq(host, hostUuid(h), 'the caret resolves the parked host by uuid')
      t.truthy(h.vm:noteFx(host), 'the resolved host carries its fx')
      t.eq(h.vm:fxHostForEdit(), hostUuid(h), 'Super-X addresses the parked host by uuid')
    end,
  },

  {
    name = 'note-host augment: cc cells under the window tag parked (route to the off-take base)',
    run = function(harness)
      local h = harness.mk()
      generators.kinds.ccCap = {
        expand = function(host) return { notes = {}, delta = {
          { ppq = host.window[1], val = 0,  shape = 'step' },
          { ppq = 60,             val = 20, shape = 'step' },
          { ppq = host.window[2], val = 0,  shape = 'step' },
        } } end,
        mode = 'augment', dest = 10, label = 'CcCap', defaults = {}, fields = {},
      }
      h.tm:addEvent({ evType = 'cc', ppq = 0, chan = 1, cc = 10, val = 30 }); h.tm:flush()
      addHost(h, { { kind = 'ccCap' } })   -- an augment host: stays on-take, parks its base cc off-take
      h.vm:setGridSize(80, 40)

      local ci
      for i, c in ipairs(h.vm.grid.cols) do
        if c.midiChan == 1 and c.type == 'cc' and c.cc == 10 then ci = i end
      end
      t.truthy(ci, 'the parked base cc still shows a cc 10 column')
      t.eq(h.vm.grid.cols[ci].cellKind[0], 'parked',
        'the authored base cc under the note-host window routes to the off-take stash, not plain tm')

      local ni = lane1Idx(h)
      t.falsy(h.vm.grid.cols[ni].cellKind[0], 'the augment host note itself stays plain -- it is not parked')
      generators.kinds.ccCap = nil
    end,
  },

  {
    -- The chain writes ride undo but mint no point of their own: unblocked, an fx edit
    -- rewinds as a passenger of whatever edit follows it.
    name = 'each chain verb mints one labelled undo point',
    run = function(harness)
      local h = harness.mk()
      addHost(h, nil)
      h.vm:setGridSize(80, 40)
      local uuid = hostUuid(h)

      -- Only the outermost block mints a point; count depth so nested ones don't inflate.
      local depth, points = 0, {}
      local realBegin, realEnd = h.reaper.Undo_BeginBlock, h.reaper.Undo_EndBlock
      h.reaper.Undo_BeginBlock = function() depth = depth + 1 end
      h.reaper.Undo_EndBlock = function(label)
        depth = depth - 1
        if depth == 0 then points[#points + 1] = label end
      end

      h.vm:addFxStage(uuid, { kind = 'retrig', period = { 1, 4 }, ramp = 0 })
      h.vm:setFxField(uuid, 1, 'ramp', 20)
      h.vm:removeFxStage(uuid, 1)

      h.reaper.Undo_BeginBlock, h.reaper.Undo_EndBlock = realBegin, realEnd
      t.deepEq(points, { 'Continuum: Add FX stage', 'Continuum: Edit FX', 'Continuum: Delete FX stage' },
               'add / edit / delete each land as their own labelled undo point')
    end,
  },
}
