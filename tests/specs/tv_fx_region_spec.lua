-- Track B (note macros v2): the fx-region column + Super-X addressing. A region
-- renders as a tailed kind-badge in a per-channel fx column, and the v1 note-FX
-- editor addresses it by uuid. see docs/trackerView.md § Addressing a chain
local t    = require('support')
local util = require('util')
local generators = require('generators')

local sine30 = { { kind = 'sine', period = { 1, 4 }, depth = 30, onset = 0 } }
local arpUp = { { kind = 'arp', period = { 1, 4 }, dir = 'up' } }   -- discrete -> replace (parks)
-- A whole-tone trill, and a microtonal one whose alternation lands 30 cents off the step
-- it places on -- an off-step ghost over a lane whose own note stands on its step.
local trill200 = { { kind = 'trill', period = { 1, 4 }, cents = 200 } }
local trill130 = { { kind = 'trill', period = { 1, 4 }, cents = 130 } }

-- ~ A V: three stages, one short of the default 240-ppq window's four rows
-- Three voices stamped on each trigger: a chain that emits polyphony, so its derived
-- notes pack into lanes above the channel's one authored column.
local chord3 = { { kind = 'chordStamp', pattern = { kind = 'notes', specs = {
  { lane = 1, ppq = 0, endppq = 240, pitch = 60, vel = 100 },
  { lane = 2, ppq = 0, endppq = 240, pitch = 64, vel = 100 },
  { lane = 3, ppq = 0, endppq = 240, pitch = 67, vel = 100 },
} } } }

local chain3 = { { kind = 'sine', period = { 1, 4 }, depth = 30, onset = 0 },
                 { kind = 'arp',  period = { 1, 4 }, dir = 'up' },
                 { kind = 'velPattern', pattern = { 100, 55 } } }

local function injectRegion(h, over)
  local region = { uuid = 'fxr-1', chan = 1, startppq = 0, endppq = 240, fx = sine30 }
  for k, v in pairs(over or {}) do region[k] = v end
  h.ds:assign('fxRegions', { region })
  h.tm:rebuild()
end

-- Two producers, so a scoping case can ask which of them a ghost belongs to. Each entry
-- overrides the defaults injectRegion uses; the uuid is positional ('fxr-1', 'fxr-2', ...).
local function injectRegions(h, list)
  local regions = {}
  for i, over in ipairs(list) do
    local region = { uuid = 'fxr-' .. i, chan = 1, startppq = 0, endppq = 240, fx = sine30 }
    for k, v in pairs(over) do region[k] = v end
    util.add(regions, region)
  end
  h.ds:assign('fxRegions', regions)
  h.tm:rebuild()
end

local function noteAt(h, chan, ppq, pitch)
  h.tm:addEvent{ evType = 'note', ppq = ppq, endppq = ppq + 240, chan = chan, pitch = pitch,
                 vel = 100, detune = 0, delay = 0, lane = 1 }
  h.tm:flush()
end

local function fxColFor(h, chan)
  for i, c in ipairs(h.vm.grid.cols) do
    if c.type == 'fx' and c.midiChan == chan then return c, i end
  end
end

local function region(h, uuid)
  for _, r in ipairs(h.ds:get('fxRegions') or {}) do
    if r.uuid == uuid then return r end
  end
end

local function noteColIdx(h, chan, lane)
  for i, c in ipairs(h.vm.grid.cols) do
    if c.type == 'note' and c.midiChan == chan and c.lane == (lane or 1) then return i end
  end
end

local function ctsColIdx(h, chan, type, cc)
  for i, c in ipairs(h.vm.grid.cols) do
    if c.type == type and c.midiChan == chan and c.cc == cc then return i end
  end
end

local function addNote(h)
  h.tm:addEvent{ evType = 'note', ppq = 0, endppq = 240, chan = 1, pitch = 60,
                 vel = 100, detune = 0, delay = 0, lane = 1 }
  h.tm:flush()
end

local function authoredUuid(h)
  for _, n in ipairs(h.fm:dump().notes) do if not n.derived then return n.uuid end end
end

-- Pitches still sounding on the take (non-derived). Empty once a replace region has
-- parked the covered chord off-take.
local function authoredPitches(h)
  local out = {}
  for _, n in ipairs(h.fm:dump().notes) do
    if not n.derived then out[#out + 1] = n.pitch end
  end
  table.sort(out)
  return out
end

return {

  ----- The column: a region renders as a tailed kind-badge

  {
    name = 'a region materialises a per-channel fx column with a badge + tail',
    run = function(harness)
      local h = harness.mk()
      h.vm:setGridSize(80, 40)
      injectRegion(h)
      local col = fxColFor(h, 1)
      t.truthy(col, 'an fx column exists on the region channel')
      local cell = col.cells[0]
      t.truthy(cell and cell.uuid == 'fxr-1', 'the badge cell at the window start carries the region uuid')
      t.eq(col.tails[1].stack[0].glyph, '~', "the badge shows the primary kind's glyph, resolved at mint")
      t.eq(#col.tails, 1, 'one tail bracket spans the window')
      t.eq(col.tails[1].endRow, h.vm:ppqToRow(240, 1), 'the tail runs to the window end')
    end,
  },

  {
    name = 'a chain stacks its glyphs down the region rows in series order',
    run = function(harness)
      local h = harness.mk()
      h.vm:setGridSize(80, 40)
      injectRegion(h, { fx = chain3 })
      local col   = fxColFor(h, 1)
      local stack = col.tails[1].stack
      t.eq(stack[0].glyph, '~', 'stage one stays on the badge row')
      t.eq(stack[1].glyph, 'A', 'stage two takes the row below')
      t.eq(stack[2].glyph, 'V', 'stage three the row below that')
      t.falsy(stack[3], "the window's fourth row is past the end of a three-stage chain")
      t.falsy(col.tails[1].clipped, 'a chain that fits is not clipped')
      t.falsy(col.cells[1], 'the cell table holds one entry per region, not one per drawn row')
    end,
  },

  {
    name = 'a bypassed stage carries its flag down the stack',
    run = function(harness)
      local h = harness.mk()
      h.vm:setGridSize(80, 40)
      injectRegion(h, { fx = { chain3[1],
                               { kind = 'arp', period = { 1, 4 }, dir = 'up', bypass = true },
                               chain3[3] } })
      local stack = fxColFor(h, 1).tails[1].stack
      t.truthy(stack[1].bypass, "the bypassed stage's row is flagged")
      t.falsy(stack[0].bypass, 'a live stage carries no flag')
    end,
  },

  {
    name = 'a chain longer than the region clips at the last row and marks it',
    run = function(harness)
      local h = harness.mk()
      h.vm:setGridSize(80, 40)
      injectRegion(h, { fx = chain3, endppq = 120 })   -- two rows for three stages
      local col   = fxColFor(h, 1)
      local stack = col.tails[1].stack
      t.eq(stack[0].glyph, '~', 'stage one still draws on the badge row')
      t.eq(stack[1].glyph, '…', 'the last drawable row gives its glyph to the clip mark')
      t.truthy(col.tails[1].clipped, 'the tail records that the chain overran')
    end,
  },

  {
    name = 'a one-row region gives the clip mark the badge row',
    run = function(harness)
      local h = harness.mk()
      h.vm:setGridSize(80, 40)
      injectRegion(h, { fx = chain3, endppq = 60 })
      local col = fxColFor(h, 1)
      t.eq(col.tails[1].stack[0].glyph, '…', 'the clip mark displaces the primary kind, rather than lying')
      t.truthy(col.tails[1].clipped, 'the tail records that the chain overran')
    end,
  },

  {
    name = 'no region -> no fx column',
    run = function(harness)
      local h = harness.mk()
      h.vm:setGridSize(80, 40)
      h.tm:rebuild()
      t.falsy(fxColFor(h, 1), 'a channel with no region has no fx column')
    end,
  },

  {
    name = 'an empty-fx region renders no column (it is an inert husk)',
    run = function(harness)
      local h = harness.mk()
      h.vm:setGridSize(80, 40)
      injectRegion(h, { fx = {} })
      t.falsy(fxColFor(h, 1), 'a region with no kinds is not shown')
    end,
  },

  ----- Multi-column: overlapping regions pack into sibling fx columns (storage = precedence)

  {
    name = 'two overlapping regions pack into separate fx columns, each addressable',
    run = function(harness)
      local h = harness.mk()
      h.vm:setGridSize(80, 40)
      h.ds:assign('fxRegions', {
        { uuid = 'fxr-1', chan = 1, startppq = 0,   endppq = 240, fx = sine30 },
        { uuid = 'fxr-2', chan = 1, startppq = 120, endppq = 360, fx = arpUp },
      })
      h.tm:rebuild()

      local n = 0
      for _, c in ipairs(h.vm.grid.cols) do if c.type == 'fx' and c.midiChan == 1 then n = n + 1 end end
      t.eq(n, 2, 'two overlapping regions -> two fx columns')

      local function cellPos(uuid)
        for i, c in ipairs(h.vm.grid.cols) do
          if c.type == 'fx' then
            for row, cell in pairs(c.cells) do if cell.uuid == uuid then return i, row end end
          end
        end
      end
      local i1, r1 = cellPos('fxr-1')
      local i2, r2 = cellPos('fxr-2')
      t.truthy(i1 < i2, 'the first-storage region owns the leftmost (lane 1) fx column')
      h.ec:setPos(r1, i1, 1)
      t.eq(h.vm:fxHostForEdit(), 'fxr-1', 'the caret on lane 1 edits fxr-1')
      h.ec:setPos(r2, i2, 1)
      t.eq(h.vm:fxHostForEdit(), 'fxr-2', 'the caret on lane 2 edits fxr-2 -- addressable in its own column')
    end,
  },

  {
    name = 'two disjoint regions share one fx column (packed into lane 1)',
    run = function(harness)
      local h = harness.mk()
      h.vm:setGridSize(80, 40)
      h.ds:assign('fxRegions', {
        { uuid = 'fxr-1', chan = 1, startppq = 0,   endppq = 120, fx = sine30 },
        { uuid = 'fxr-2', chan = 1, startppq = 120, endppq = 240, fx = sine30 },
      })
      h.tm:rebuild()
      local n = 0
      for _, c in ipairs(h.vm.grid.cols) do if c.type == 'fx' and c.midiChan == 1 then n = n + 1 end end
      t.eq(n, 1, 'disjoint regions do not overlap -> one fx column holds both badges')
    end,
  },

  ----- Replace parking: members leave the take but stay the displayed chord

  {
    name = 'replace region: a parked note still renders in its note column',
    run = function(harness)
      local h = harness.mk()
      h.vm:setGridSize(80, 40)
      addNote(h)                    -- C4 over [0,240) in lane 1
      injectRegion(h, { fx = arpUp })   -- a discrete-replace region covering the note's span
      t.deepEq(authoredPitches(h), {}, 'the covered note is parked off the take')
      local idx = noteColIdx(h, 1)
      t.truthy(idx, 'the lane-1 note column survives the parking')
      local cell = h.vm.grid.cols[idx].cells[0]
      t.truthy(cell, 'the parked note still occupies row 0')
      t.eq(cell.pitch, 60, 'rendered with its authored pitch')
    end,
  },

  {
    name = 'replace region: a parked cc still renders in its cc column',
    run = function(harness)
      local h = harness.mk()
      h.vm:setGridSize(80, 40)
      h.tm:addEvent({ evType = 'cc', ppq = 0, chan = 1, cc = 74, val = 30 }); h.tm:flush()
      generators.kinds.ccRep = {
        expand = function(host) return { notes = {}, delta = {
          { ppq = host.window[1], val = 100, shape = 'step' },
        } } end,
        mode = 'replace', dest = 74, label = 'CcRep', defaults = {}, fields = {},
      }
      injectRegion(h, { fx = { { kind = 'ccRep' } } })   -- rebuild 1: parks the authored cc
      h.tm:rebuild()                                     -- rebuild 2: steady state (parked via prior, column absent)
      generators.kinds.ccRep = nil

      local col
      for _, c in ipairs(h.vm.grid.cols) do
        if c.type == 'cc' and c.midiChan == 1 and c.cc == 74 then col = c end
      end
      t.truthy(col, 'the cc 74 column survives the parking')
      local cell = col and col.cells[0]
      t.truthy(cell, 'the parked cc still occupies row 0 -- creating the region did not blank the lane')
      t.eq(cell.val, 30, 'rendered with its authored value')
    end,
  },

  ----- noteFx / setNoteFx generalise to region uuids

  {
    name = 'noteFx resolves a region uuid to its fx list',
    run = function(harness)
      local h = harness.mk()
      injectRegion(h)
      t.eq(h.vm:noteFx('fxr-1')[1].kind, 'sine', 'region fx returned by uuid')
    end,
  },

  {
    name = 'setNoteFx writes a region fx list back to ds',
    run = function(harness)
      local h = harness.mk()
      injectRegion(h)
      h.vm:setNoteFx('fxr-1', { { kind = 'arp', period = { 1, 4 }, dir = 'up' } })
      t.eq(h.ds:get('fxRegions')[1].fx[1].kind, 'arp', 'region.fx updated in ds')
    end,
  },

  {
    name = 'setNoteFx REMOVE deletes the region (a region is its fx)',
    run = function(harness)
      local h = harness.mk()
      injectRegion(h)
      h.vm:setNoteFx('fxr-1', util.REMOVE)
      t.eq(#(h.ds:get('fxRegions') or {}), 0, 'emptying a region removes it from ds')
    end,
  },

  {
    name = 'region fx: deselecting the last kind keeps a husk the editor can repopulate',
    run = function(harness)
      local h = harness.mk()
      injectRegion(h)                                        -- fxr-1 carrying sine
      h.vm:removeFxStage('fxr-1', 1)
      t.eq(#(h.ds:get('fxRegions') or {}), 1, 'the emptied region survives mid-edit as a husk')
      t.deepEq(h.ds:get('fxRegions')[1].fx, {}, 'with an empty fx list')
      h.vm:addFxStage('fxr-1', { kind = 'arp', period = { 1, 4 }, dir = 'up' })
      t.eq(#(h.ds:get('fxRegions') or {}), 1, 'the reselect writes back to the same region')
      t.eq(h.vm:noteFx('fxr-1')[1].kind, 'arp', 'the reselected kind landed on the region')
    end,
  },

  {
    name = 'setFxField edits one region fx field, leaving the region',
    run = function(harness)
      local h = harness.mk()
      injectRegion(h)
      h.vm:setFxField('fxr-1', 1, 'depth', 55)
      t.eq(h.ds:get('fxRegions')[1].fx[1].depth, 55, 'depth written to the region entry')
    end,
  },

  ----- Addressing: Super-X resolves the host under the caret (note OR region)

  {
    name = 'fxHostForEdit: caret on an fx cell returns the region uuid',
    run = function(harness)
      local h = harness.mk()
      h.vm:setGridSize(80, 40)
      injectRegion(h)
      local _, idx = fxColFor(h, 1)
      h.ec:setPos(0, idx, 1)
      t.eq(h.vm:fxHostForEdit(), 'fxr-1', 'the region under the caret is the edit host')
    end,
  },

  {
    name = 'fxHostForEdit: a selection mints a replace region over its span',
    run = function(harness)
      local h = harness.mk()
      h.vm:setGridSize(80, 40)
      h.tm:rebuild()
      h.ec:setSelection{ row1 = 0, row2 = 3, col1 = 1, col2 = 1, part1 = 'pitch', part2 = 'pitch' }
      local uuid = h.vm:fxHostForEdit()
      t.truthy(uuid, 'a host uuid is returned')
      local r = (h.ds:get('fxRegions') or {})[1]
      t.truthy(r and r.uuid == uuid, 'a region was minted and is the edit host')
      t.eq(r.chan, 1, 'on the selected channel')
      t.eq(r.startppq, h.vm:rowToPPQ(0, 1), 'window start = selection top')
      t.eq(r.endppq, h.vm:rowToPPQ(4, 1), 'window end = one row past the selection bottom (exclusive)')
      t.eq(#r.fx, 0, 'minted empty -- the editor fills the kinds')
    end,
  },

  {
    name = 'fxHostAtCursor: a selection does not mint -- cursor movement has no side effect',
    run = function(harness)
      local h = harness.mk()
      h.vm:setGridSize(80, 40)
      h.tm:rebuild()
      h.ec:setSelection{ row1 = 0, row2 = 3, col1 = 1, col2 = 1, part1 = 'pitch', part2 = 'pitch' }
      t.falsy(h.vm:fxHostAtCursor(), 'no host off a note, even under a selection')
      t.eq(#(h.ds:get('fxRegions') or {}), 0, 'and no region was minted (unlike fxHostForEdit)')
    end,
  },

  {
    name = 'fxHostAtCursor: caret anywhere in an fx region returns its uuid, nil past the tail',
    run = function(harness)
      local h = harness.mk()
      h.vm:setGridSize(80, 40)
      injectRegion(h, { endppq = 960 })
      local _, idx = fxColFor(h, 1)
      local tail = h.vm.grid.cols[idx].tails[1]
      h.ec:setPos(tail.startRow, idx, 1)
      t.eq(h.vm:fxHostAtCursor(), 'fxr-1', 'the badge row resolves the region, no selection branch')
      h.ec:setPos(tail.endRow - 1, idx, 1)
      t.eq(h.vm:fxHostAtCursor(), 'fxr-1', 'a mid-span row resolves the same region')
      h.ec:setPos(tail.endRow, idx, 1)
      t.falsy(h.vm:fxHostAtCursor(), 'past the tail resolves nothing')
    end,
  },

  {
    name = 'fxHostForEdit: off a note with no selection is nil; on a note, its uuid (v1)',
    run = function(harness)
      local h = harness.mk()
      h.vm:setGridSize(80, 40)
      addNote(h)
      local idx = noteColIdx(h, 1)
      h.ec:setPos(0, idx, 1)
      t.eq(h.vm:fxHostForEdit(), authoredUuid(h), 'the note uuid (v1 path) is preserved')
      h.ec:setPos(8, idx, 1)   -- empty row
      t.falsy(h.vm:fxHostForEdit(), 'no host off a note with no selection')
    end,
  },

  ----- Parked events are editable off-take through the leaf-edit facade

  {
    name = 'parked note: a pitch nudge edits the off-take stash and re-renders, still parked',
    run = function(harness)
      local h = harness.mk()
      h.vm:setGridSize(80, 40)
      addNote(h)                        -- C4 (60) over [0,240)
      injectRegion(h, { fx = arpUp })   -- a discrete-replace region parks it
      t.deepEq(authoredPitches(h), {}, 'parked off the take')
      h.ec:setPos(0, noteColIdx(h, 1), 1)
      h.cmgr:invoke('nudgeFineUp')      -- transpose +1
      local stash = h.ds:get('fxParked') or {}
      t.eq(#stash, 1, 'one parked note in the stash')
      t.eq(stash[1].pitch, 61, 'the stash pitch was edited (not the take)')
      t.deepEq(authoredPitches(h), {}, 'still parked -- the edit did not push it to the take')
      t.eq(h.tm:getChannel(1).parked[1].pitch, 61, 'the render cell shows the new pitch')
    end,
  },

  {
    name = 'parked note: delete removes it from the stash and does not restore it when the window moves off',
    run = function(harness)
      local h = harness.mk()
      h.vm:setGridSize(80, 40)
      addNote(h)
      injectRegion(h, { fx = arpUp })
      h.ec:setPos(0, noteColIdx(h, 1), 1)
      h.cmgr:invoke('delete')
      t.eq(#(h.ds:get('fxParked') or {}), 0, 'the parked note left the stash')
      injectRegion(h, { fx = arpUp, endppq = 60 })   -- shrink the window off the (now-deleted) note
      t.deepEq(authoredPitches(h), {}, 'a deleted parked note is not resurrected on the take')
    end,
  },

  {
    name = 'parked add: typing a note into a replace window stashes a logical spec, off the take',
    run = function(harness)
      local h = harness.mk{ config = { take = { currentOctave = 4 } } }
      h.vm:setGridSize(80, 40)
      injectRegion(h, { fx = arpUp })   -- replace window [0,240) over an empty channel
      local idx = noteColIdx(h, 1)
      h.ec:setPos(0, idx, 1)
      h.vm:editEvent(h.vm.grid.cols[idx], nil, 1, string.byte('z'), false)  -- 'z' = C4 = 60
      local stash = h.ds:get('fxParked') or {}
      t.eq(#stash, 1, 'the typed note went to the parked stash')
      t.eq(stash[1].pitch, 60, 'with the typed pitch')
      t.eq(stash[1].ppq, 0, 'logical onset captured from the cursor row')
      t.truthy(tostring(stash[1].uuid):match('^fxp%-'), 'a parked uuid was minted')
      t.deepEq(authoredPitches(h), {}, 'nothing entered the take')
    end,
  },

  {
    name = 'parked move-out: nudging a parked note past the window end restores it to the take',
    run = function(harness)
      local h = harness.mk()
      h.vm:setGridSize(80, 40)
      h.tm:addEvent{ evType = 'note', ppq = 60, endppq = 120, chan = 1, pitch = 60,
                     vel = 100, detune = 0, delay = 0, lane = 1 }
      h.tm:flush()
      injectRegion(h, { fx = arpUp, endppq = 120 })   -- covers [0,120): the ppq-60 note parks
      t.deepEq(authoredPitches(h), {}, 'the covered note is parked')
      h.ec:setPos(1, noteColIdx(h, 1), 1)             -- row 1 = ppq 60
      h.cmgr:invoke('nudgeForward')                   -- -> row 2 (ppq 120), past the window
      t.deepEq(authoredPitches(h), { 60 }, 'the note crossed back onto the take')
      t.eq(#(h.ds:get('fxParked') or {}), 0, 'and left the parked stash')
    end,
  },

  {
    name = 'parked cc: a value nudge edits the off-take cc stash; delete removes it',
    run = function(harness)
      local h = harness.mk()
      h.vm:setGridSize(80, 40)
      h.tm:addEvent({ evType = 'cc', ppq = 0, chan = 1, cc = 74, val = 30 }); h.tm:flush()
      generators.kinds.ccRep = {
        expand = function(host) return { notes = {}, delta = {
          { ppq = host.window[1], val = 100, shape = 'step' },
        } } end,
        mode = 'replace', dest = 74, label = 'CcRep', defaults = {}, fields = {},
      }
      injectRegion(h, { fx = { { kind = 'ccRep' } } })
      h.tm:rebuild()                                   -- steady state: cc parked, column present

      local ci
      for i, c in ipairs(h.vm.grid.cols) do
        if c.type == 'cc' and c.midiChan == 1 and c.cc == 74 then ci = i end
      end
      t.truthy(ci, 'the parked cc column exists')
      h.ec:setPos(0, ci, 1)
      h.cmgr:invoke('nudgeCoarseUp')                   -- bump the cc value
      local stash = {}
      for _, s in ipairs(h.ds:get('fxParked') or {}) do if s.evType == 'cc' then stash[#stash + 1] = s end end
      t.eq(#stash, 1, 'one parked cc in the stash')
      t.truthy(stash[1].val > 30, 'its value was nudged up off the take')

      h.ec:setPos(0, ci, 1)
      h.cmgr:invoke('delete')
      generators.kinds.ccRep = nil
      local ccStash = {}
      for _, s in ipairs(h.ds:get('fxParked') or {}) do if s.evType == 'cc' then ccStash[#ccStash + 1] = s end end
      t.eq(#ccStash, 0, 'delete removed the parked cc from the stash')
    end,
  },

  {
    name = 'parked pb: a value nudge edits the off-take pb stash; delete removes it',
    run = function(harness)
      local h = harness.mk()
      h.vm:setGridSize(80, 40)
      h.tm:addEvent({ evType = 'pb', ppq = 0, chan = 1, val = 40 }); h.tm:flush()
      generators.kinds.pbRep = {
        expand = function(host) return { notes = {}, delta = {
          { ppq = host.window[1], val = 50, shape = 'step' },
          { ppq = host.window[2], val = 0,  shape = 'step' },
        } } end,
        mode = 'replace', dest = 'pb', label = 'PbRep', defaults = {}, fields = {},
      }
      injectRegion(h, { fx = { { kind = 'pbRep' } } })
      h.tm:rebuild()                                   -- steady state: authored pb parked, column present

      local ci
      for i, c in ipairs(h.vm.grid.cols) do
        if c.type == 'pb' and c.midiChan == 1 then ci = i end
      end
      t.truthy(ci, 'the parked pb column exists (built from the parkedPb union)')
      local pbcol = h.vm.grid.cols[ci]
      local ev0
      for _, e in ipairs(pbcol.events) do if (e.ppq or 0) == 0 then ev0 = e end end
      h.ec:setPos(0, ci, 1)
      h.vm:editEvent(pbcol, ev0, 1, string.byte('-'), false)  -- negate the breakpoint: a real pb value edit
      local stash = {}
      for _, s in ipairs(h.ds:get('fxParked') or {}) do if s.evType == 'pb' then stash[#stash + 1] = s end end
      t.eq(#stash, 1, 'the pb stays parked off the take')
      t.eq(stash[1].val, -40, 'the edit routed to the off-take pb stash (40c -> -40c)')

      h.ec:setPos(0, ci, 1)
      h.cmgr:invoke('delete')
      generators.kinds.pbRep = nil
      local pbStash = {}
      for _, s in ipairs(h.ds:get('fxParked') or {}) do if s.evType == 'pb' then pbStash[#pbStash + 1] = s end end
      t.eq(#pbStash, 0, 'delete removed the parked pb from the stash')
    end,
  },

  {
    name = 'multi-select spanning a parked note and a take note: both edit under one rebuild',
    run = function(harness)
      local h = harness.mk()
      h.vm:setGridSize(80, 40)
      h.tm:addEvent{ evType = 'note', ppq = 0,   endppq = 60,  chan = 1, pitch = 60,
                     vel = 100, detune = 0, delay = 0, lane = 1 }
      h.tm:addEvent{ evType = 'note', ppq = 240, endppq = 300, chan = 1, pitch = 64,
                     vel = 100, detune = 0, delay = 0, lane = 1 }
      h.tm:flush()
      injectRegion(h, { fx = arpUp, endppq = 120 })   -- parks only the ppq-0 note
      t.deepEq(authoredPitches(h), { 64 }, 'only the in-window note parked')

      local rebuilds = 0
      h.tm:subscribe('rebuild', function() rebuilds = rebuilds + 1 end)
      local idx = noteColIdx(h, 1)
      h.ec:setSelection{ row1 = 0, row2 = 4, col1 = idx, col2 = idx,
                         part1 = 'pitch', part2 = 'pitch' }
      h.cmgr:invoke('nudgeFineUp')                     -- transpose both +1
      t.eq(rebuilds, 1, 'one rebuild for the whole multi-select flush (the staging guard)')
      t.deepEq(authoredPitches(h), { 65 }, 'the take note transposed to 65')
      t.eq((h.ds:get('fxParked') or {})[1].pitch, 61, 'the parked note transposed to 61 in the stash')
    end,
  },

  ----- Window editing: the note duration/position verbs act on the fx column

  {
    name = 'fx noteOff truncates the region tail to the cursor row',
    run = function(harness)
      local h = harness.mk()
      h.vm:setGridSize(80, 40)
      injectRegion(h)                          -- fxr-1 [0,240)
      local _, ci = fxColFor(h, 1)
      h.ec:setPos(2, ci, 1)                     -- row 2 = ppq 120
      h.cmgr:invoke('noteOff')
      local r = region(h, 'fxr-1')
      t.truthy(r, 'the region survives -- noteOff shortens, never deletes')
      t.eq(r.startppq, 0,   'onset unchanged')
      t.eq(r.endppq,  120,  'end truncated to the cursor row')
    end,
  },

  {
    name = 'fx noteOff finds the right region in its lane when cells are in storage, not ppq, order',
    run = function(harness)
      local h = harness.mk()
      h.vm:setGridSize(80, 40)
      h.ds:assign('fxRegions', {                             -- storage order != ppq order, same lane
        { uuid = 'fxr-2', chan = 1, startppq = 240, endppq = 360, fx = sine30 },
        { uuid = 'fxr-1', chan = 1, startppq = 0,   endppq = 120, fx = sine30 },
      })
      h.tm:rebuild()
      local _, ci = fxColFor(h, 1)
      h.ec:setPos(1, ci, 1)                                  -- row 1 = ppq 60, over fxr-1
      h.cmgr:invoke('noteOff')
      t.eq(region(h, 'fxr-1').endppq, 60,  'the covered region (fxr-1) shrank to the cursor row')
      t.eq(region(h, 'fxr-2').endppq, 360, 'the storage-first sibling in the lane is untouched')
    end,
  },

  {
    name = 'fx noteOff past the region tail grows it to the cursor row',
    run = function(harness)
      local h = harness.mk()
      h.vm:setGridSize(80, 40)
      injectRegion(h, { endppq = 120 })        -- fxr-1 [0,120)
      local _, ci = fxColFor(h, 1)
      h.ec:setPos(4, ci, 1)                     -- row 4 = ppq 240, past the [0,120) tail
      h.cmgr:invoke('noteOff')
      t.eq(region(h, 'fxr-1').endppq, 240, 'the tail grew to the cursor row')
    end,
  },

  {
    name = 'fx noteOff on the onset row is a no-op (deletion is the delete verb, not noteOff)',
    run = function(harness)
      local h = harness.mk()
      h.vm:setGridSize(80, 40)
      injectRegion(h)
      local _, ci = fxColFor(h, 1)
      h.ec:setPos(0, ci, 1)
      h.cmgr:invoke('noteOff')
      local r = region(h, 'fxr-1')
      t.truthy(r, 'the region is untouched')
      t.eq(r.endppq, 240, 'the window is unchanged')
    end,
  },

  {
    name = 'fx noteOff on the window end row re-opens it to the pattern length',
    run = function(harness)
      local h = harness.mk()
      h.vm:setGridSize(80, 40)
      injectRegion(h)                          -- fxr-1 [0,240), end row = 4
      local _, ci = fxColFor(h, 1)
      h.ec:setPos(4, ci, 1)                     -- cursor on the window's own end row
      h.cmgr:invoke('noteOff')
      t.eq(region(h, 'fxr-1').endppq, h.vm:rowToPPQ(h.vm.grid.numRows, 1),
           'the tail re-opens to the full pattern length')
    end,
  },

  {
    name = 'fx growNote / shrinkNote resize the region from its end',
    run = function(harness)
      local h = harness.mk()
      h.vm:setGridSize(80, 40)
      injectRegion(h)
      local _, ci = fxColFor(h, 1)
      h.ec:setPos(0, ci, 1)
      h.cmgr:invoke('growNote')
      t.eq(region(h, 'fxr-1').endppq, 300, 'grow extends the end by one row')
      h.cmgr:invoke('shrinkNote')
      t.eq(region(h, 'fxr-1').endppq, 240, 'shrink pulls it back a row')
    end,
  },

  {
    name = 'fx nudgeForward shifts the whole window and the caret follows',
    run = function(harness)
      local h = harness.mk()
      h.vm:setGridSize(80, 40)
      injectRegion(h, { startppq = 60, endppq = 180 })   -- rows 1..3
      local _, ci = fxColFor(h, 1)
      h.ec:setPos(1, ci, 1)
      h.cmgr:invoke('nudgeForward')
      local r = region(h, 'fxr-1')
      t.eq(r.startppq, 120, 'onset shifted +1 row')
      t.eq(r.endppq,   240, 'end shifted +1 row (duration preserved)')
      t.eq(h.ec:row(), 2,   'the caret tracked the shift')
    end,
  },

  {
    name = 'fx nudge keeps the moved region in its lane; the newly-overlapped sibling displaces right',
    run = function(harness)
      local h = harness.mk()
      h.vm:setGridSize(80, 40)
      h.ds:assign('fxRegions', {
        { uuid = 'fxr-1', chan = 1, startppq = 0,   endppq = 120, fx = sine30 },  -- storage-first
        { uuid = 'fxr-2', chan = 1, startppq = 180, endppq = 300, fx = sine30 },  -- storage-later, disjoint
      })
      h.tm:rebuild()
      local _, ci = fxColFor(h, 1)
      h.ec:setPos(3, ci, 1)                             -- on fxr-2 (onset row 3 = ppq 180)
      h.cmgr:invoke('nudgeBack')                        -- row 2 (ppq 120): still disjoint
      h.cmgr:invoke('nudgeBack')                        -- row 1 (ppq 60): now overlaps fxr-1
      local regions = h.ds:get('fxRegions')
      t.eq(regions[1].uuid, 'fxr-2', 'the moved region slid earlier in storage to keep its lane')
      t.eq(regions[2].uuid, 'fxr-1', 'the overlapped sibling is now storage-later (a higher lane)')
      local firstFx
      for _, c in ipairs(h.vm.grid.cols) do
        if c.type == 'fx' and c.midiChan == 1 then firstFx = firstFx or c end
      end
      t.truthy(firstFx.cells[1] and firstFx.cells[1].uuid == 'fxr-2', 'the moved region kept lane 1')
      t.eq(h.vm:fxHostForEdit(), 'fxr-2', 'the caret tracked to the moved region')
    end,
  },

  {
    name = 'fx nudge of an already-overlapping region keeps its own higher lane (no reorder)',
    run = function(harness)
      local h = harness.mk()
      h.vm:setGridSize(80, 40)
      h.ds:assign('fxRegions', {
        { uuid = 'fxr-1', chan = 1, startppq = 0, endppq = 240, fx = sine30 },  -- lane 1
        { uuid = 'fxr-2', chan = 1, startppq = 0, endppq = 240, fx = sine30 },  -- lane 2 (overlaps)
      })
      h.tm:rebuild()
      local i2
      for i, c in ipairs(h.vm.grid.cols) do
        if c.type == 'fx' and c.midiChan == 1 then i2 = i end   -- last fx col = lane 2
      end
      h.ec:setPos(0, i2, 1)                             -- on fxr-2's lane-2 column
      h.cmgr:invoke('nudgeForward')
      local regions = h.ds:get('fxRegions')
      t.eq(regions[1].uuid, 'fxr-1', 'storage order held -- fxr-1 stays lane 1')
      t.eq(regions[2].uuid, 'fxr-2', 'the moved region kept its own lane 2')
      t.eq(h.vm:fxHostForEdit(), 'fxr-2', 'the caret tracked to the moved region')
    end,
  },

  {
    name = 'fx nudge that makes an overlap disjoint tracks the caret across the column merge',
    run = function(harness)
      local h = harness.mk()
      h.vm:setGridSize(80, 40)
      h.ds:assign('fxRegions', {
        { uuid = 'fxr-1', chan = 1, startppq = 0, endppq = 120, fx = sine30 },  -- lane 1
        { uuid = 'fxr-2', chan = 1, startppq = 0, endppq = 120, fx = sine30 },  -- lane 2 (overlap -> 2 cols)
      })
      h.tm:rebuild()
      local i2
      for i, c in ipairs(h.vm.grid.cols) do
        if c.type == 'fx' and c.midiChan == 1 then i2 = i end   -- last fx col = lane 2 = fxr-2
      end
      h.ec:setPos(0, i2, 1)
      h.cmgr:invoke('nudgeForward')    -- [0,120] -> [60,180], still overlaps
      h.cmgr:invoke('nudgeForward')    -- [60,180] -> [120,240], now disjoint: 2 cols collapse to 1
      local n = 0
      for _, c in ipairs(h.vm.grid.cols) do if c.type == 'fx' and c.midiChan == 1 then n = n + 1 end end
      t.eq(n, 1, 'the now-disjoint regions share one fx column')
      t.eq(h.vm:fxHostForEdit(), 'fxr-2', 'the caret tracked the moved region into the merged column')
    end,
  },

  {
    name = 'fx window edit on a disjoint region does not churn storage order',
    run = function(harness)
      local h = harness.mk()
      h.vm:setGridSize(80, 40)
      h.ds:assign('fxRegions', {
        { uuid = 'fxr-1', chan = 1, startppq = 0,   endppq = 60,  fx = sine30 },
        { uuid = 'fxr-2', chan = 1, startppq = 120, endppq = 180, fx = sine30 },
        { uuid = 'fxr-3', chan = 1, startppq = 240, endppq = 300, fx = sine30 },
      })
      h.tm:rebuild()
      local _, ci = fxColFor(h, 1)     -- all disjoint -> one shared column
      h.ec:setPos(2, ci, 1)            -- on fxr-2 (onset ppq 120 = row 2)
      h.cmgr:invoke('growNote')        -- [120,180] -> [120,240], still disjoint from fxr-3
      local order = {}
      for _, r in ipairs(h.ds:get('fxRegions')) do order[#order + 1] = r.uuid end
      t.deepEq(order, { 'fxr-1', 'fxr-2', 'fxr-3' }, 'storage order held -- no spurious reorder')
    end,
  },

  {
    name = 'fx nudgeBack refuses at the top grid edge (window unchanged)',
    run = function(harness)
      local h = harness.mk()
      h.vm:setGridSize(80, 40)
      injectRegion(h)                          -- [0,240), onset at row 0
      local _, ci = fxColFor(h, 1)
      h.ec:setPos(0, ci, 1)
      h.cmgr:invoke('nudgeBack')
      local r = region(h, 'fxr-1')
      t.eq(r.startppq, 0,   'onset held at the edge')
      t.eq(r.endppq,   240, 'window unchanged')
    end,
  },

  ----- Lane reorder: eventShiftLeft/right bumps the region a badge column, flipping storage precedence

  {
    name = 'fx eventShiftLeft swaps the region one lane left, flipping storage precedence',
    run = function(harness)
      local h = harness.mk()
      h.vm:setGridSize(80, 40)
      h.ds:assign('fxRegions', {
        { uuid = 'fxr-1', chan = 1, startppq = 0,   endppq = 240, fx = sine30 },  -- lane 1
        { uuid = 'fxr-2', chan = 1, startppq = 120, endppq = 360, fx = sine30 },  -- lane 2, overlaps
      })
      h.tm:rebuild()
      local _, i2 = fxColFor(h, 1)                       -- lane-1 col; lane-2 col is the next fx col
      local ci2
      for i = i2 + 1, #h.vm.grid.cols do
        if h.vm.grid.cols[i].type == 'fx' then ci2 = i; break end
      end
      h.ec:setPos(2, ci2, 1)                            -- on fxr-2 (onset row 2 = ppq 120)
      h.cmgr:invoke('eventShiftLeft')
      local regions = h.ds:get('fxRegions')
      t.eq(regions[1].uuid, 'fxr-2', 'the moved region is now storage-first (lane 1, higher precedence)')
      t.eq(regions[2].uuid, 'fxr-1', 'the sibling it passed is now storage-later (lane 2)')
      t.eq(regions[1].chan, 1, 'no channel leak -- the region stays on channel 1')
      t.eq(regions[2].chan, 1, 'nor does its sibling')
      local firstFx = fxColFor(h, 1)
      t.truthy(firstFx.cells[2] and firstFx.cells[2].uuid == 'fxr-2', 'the badge moved to the leftmost fx column')
      t.eq(h.vm:fxHostForEdit(), 'fxr-2', 'the caret tracked to the moved region')
    end,
  },

  {
    name = 'fx eventShiftRight swaps the region one lane right (the inverse move)',
    run = function(harness)
      local h = harness.mk()
      h.vm:setGridSize(80, 40)
      h.ds:assign('fxRegions', {
        { uuid = 'fxr-1', chan = 1, startppq = 0,   endppq = 240, fx = sine30 },  -- lane 1
        { uuid = 'fxr-2', chan = 1, startppq = 120, endppq = 360, fx = sine30 },  -- lane 2, overlaps
      })
      h.tm:rebuild()
      local _, ci1 = fxColFor(h, 1)
      h.ec:setPos(2, ci1, 1)                            -- on fxr-1 at the overlap row (ppq 120)
      h.cmgr:invoke('eventShiftRight')
      local regions = h.ds:get('fxRegions')
      t.eq(regions[1].uuid, 'fxr-2', 'fxr-1 dropped behind its sibling in storage')
      t.eq(regions[2].uuid, 'fxr-1', 'and now holds lane 2 (lower precedence)')
    end,
  },

  {
    name = 'fx eventShift is a no-op at the grid edge (lone region, nothing beside it)',
    run = function(harness)
      local h = harness.mk()
      h.vm:setGridSize(80, 40)
      injectRegion(h)                                   -- one region, one fx column
      local _, ci = fxColFor(h, 1)
      h.ec:setPos(0, ci, 1)
      h.cmgr:invoke('eventShiftLeft')                   -- target lane 0: refused
      h.cmgr:invoke('eventShiftRight')                  -- no lane-2 column: refused
      local regions = h.ds:get('fxRegions')
      t.eq(#regions, 1, 'still one region')
      t.eq(regions[1].uuid, 'fxr-1', 'storage untouched')
    end,
  },

  {
    name = 'fx eventShift no-ops when the adjacent lane is empty at the cursor row',
    run = function(harness)
      local h = harness.mk()
      h.vm:setGridSize(80, 40)
      h.ds:assign('fxRegions', {
        { uuid = 'fxr-1', chan = 1, startppq = 0,   endppq = 240, fx = sine30 },  -- lane 1
        { uuid = 'fxr-2', chan = 1, startppq = 120, endppq = 360, fx = sine30 },  -- lane 2, starts at row 2
      })
      h.tm:rebuild()
      local _, ci1 = fxColFor(h, 1)
      h.ec:setPos(0, ci1, 1)                            -- on fxr-1 at row 0 -- lane 2 is empty here
      h.cmgr:invoke('eventShiftRight')
      local order = {}
      for _, r in ipairs(h.ds:get('fxRegions')) do order[#order + 1] = r.uuid end
      t.deepEq(order, { 'fxr-1', 'fxr-2' }, 'no reorder -- nothing beside the cursor to swap with')
    end,
  },

  ----- Time/duration edits on a parked note route to the logical stash

  {
    name = 'parked note: noteOff shortens its tail in the stash, stays parked',
    run = function(harness)
      local h = harness.mk()
      h.vm:setGridSize(80, 40)
      addNote(h)                              -- C4 [0,240)
      injectRegion(h, { fx = arpUp })         -- parks it, window [0,240)
      local idx = noteColIdx(h, 1)
      h.ec:setPos(2, idx, 1)                  -- row 2 = ppq 120, past onset
      h.cmgr:invoke('noteOff')
      local stash = h.ds:get('fxParked') or {}
      t.eq(#stash, 1, 'still one parked note')
      t.eq(stash[1].endppq, 120, 'tail shortened to the cursor row')
      t.deepEq(authoredPitches(h), {}, 'still parked, not on take')
    end,
  },

  {
    name = 'parked note: a time nudge within the window retimes the stash, stays parked',
    run = function(harness)
      local h = harness.mk()
      h.vm:setGridSize(80, 40)
      addNote(h)                              -- C4 [0,240)
      injectRegion(h, { fx = arpUp })         -- parks it, window [0,240)
      local idx = noteColIdx(h, 1)
      h.ec:setPos(0, idx, 1)
      h.cmgr:invoke('nudgeForward')           -- row 0 -> row 1 (ppq 60), still in window
      local stash = h.ds:get('fxParked') or {}
      t.eq(#stash, 1, 'still one parked note')
      t.eq(stash[1].ppq, 60, 'onset moved to ppq 60 in the stash')
      t.deepEq(authoredPitches(h), {}, 'still parked, not on take')
    end,
  },

  ----- Copy / paste / delete: fx regions ride the rectangle clip (capture-by-onset, stack on paste)

  {
    name = 'fx copy captures a region by onset; the whole window rides, tail spilling past the band',
    run = function(harness)
      local h = harness.mk()
      h.vm:setGridSize(80, 40)
      injectRegion(h, { startppq = 180, endppq = 600 })   -- onset row 3, tail row 10
      local _, ci = fxColFor(h, 1)
      h.ec:setPos(2, ci, 1)
      h.ec:extendTo(4, ci, 1)                             -- band rows 2..4
      local clip = h.clipboard:collect()
      t.truthy(clip and clip.fxRegions, 'the clip carries the caught fx region')
      t.eq(#clip.fxRegions, 1, 'onset in band -> captured')
      local e = clip.fxRegions[1]
      t.eq(e.row, 1, 'row is band-relative (onset row 3 - r1 2)')
      t.eq(e.endRow, 8, 'full window rides -- endRow 10 - r1 2, spilling past the 3-row band')
      t.eq(e.chanDelta, 0, 'anchored to the rectangle left edge (same channel)')
      t.eq(e.fx[1].kind, 'sine', 'the fx chain rode along')
      e.fx[1].kind = 'arp'
      t.eq(region(h, 'fxr-1').fx[1].kind, 'sine', 'the clip deep-cloned -- mutating it does not touch ds')
    end,
  },

  {
    name = 'fx copy skips a region that only passes through the band (onset above it)',
    run = function(harness)
      local h = harness.mk()
      h.vm:setGridSize(80, 40)
      injectRegion(h, { startppq = 0, endppq = 600 })     -- onset row 0, spans to row 10
      local _, ci = fxColFor(h, 1)
      h.ec:setPos(4, ci, 1)
      h.ec:extendTo(6, ci, 1)                             -- band rows 4..6: region passes through, onset above
      t.falsy(h.clipboard:collect(), 'a region starting above the band is not captured, matching notes')
    end,
  },

  {
    name = 'fx copy + paste stacks a duplicate region at the cursor row, original intact',
    run = function(harness)
      local h = harness.mk()
      h.vm:setGridSize(80, 40)
      injectRegion(h)                                     -- fxr-1 [0,240), rows 0..4
      local _, ci = fxColFor(h, 1)
      h.ec:setPos(0, ci, 1)
      h.ec:extendTo(3, ci, 1)                             -- band rows 0..3
      h.cmgr:invoke('copy')
      h.ec:setPos(8, ci, 1)                               -- paste 8 rows down
      h.cmgr:invoke('paste')
      local regions = h.ds:get('fxRegions')
      t.eq(#regions, 2, 'the paste stacked a second region (no destination wipe)')
      t.eq(region(h, 'fxr-1').startppq, 0,   'the original onset is untouched')
      t.eq(region(h, 'fxr-1').endppq,   240, 'the original window is untouched')
      local pasted = region(h, 'fxr-2')
      t.truthy(pasted, 'the paste minted fxr-2')
      t.eq(pasted.startppq, h.vm:rowToPPQ(8, 1),  'onset landed at the cursor row')
      t.eq(pasted.endppq,   h.vm:rowToPPQ(12, 1), 'window length preserved (4 rows off the cursor)')
      t.eq(pasted.fx[1].kind, 'sine', 'the copied chain came with it')
    end,
  },

  {
    name = 'fx delete removes the region under the caret',
    run = function(harness)
      local h = harness.mk()
      h.vm:setGridSize(80, 40)
      injectRegion(h)                                     -- fxr-1 [0,240)
      local _, ci = fxColFor(h, 1)
      h.ec:setPos(2, ci, 1)                               -- mid-window, no selection
      h.cmgr:invoke('delete')
      t.eq(#(h.ds:get('fxRegions') or {}), 0, 'the region under the caret is gone')
    end,
  },

  {
    name = 'fx deleteSel drops every region the rectangle catches (onset in band), sparing the rest',
    run = function(harness)
      local h = harness.mk()
      h.vm:setGridSize(80, 40)
      h.ds:assign('fxRegions', {
        { uuid = 'fxr-1', chan = 1, startppq = 0,   endppq = 120, fx = sine30 },  -- onset row 0, in band
        { uuid = 'fxr-2', chan = 1, startppq = 120, endppq = 240, fx = sine30 },  -- onset row 2, in band
        { uuid = 'fxr-3', chan = 1, startppq = 480, endppq = 600, fx = sine30 },  -- onset row 8, out of band
      })
      h.tm:rebuild()
      local _, ci = fxColFor(h, 1)                        -- all disjoint -> one shared column
      h.ec:setPos(0, ci, 1)
      h.ec:extendTo(3, ci, 1)                             -- band rows 0..3
      h.cmgr:invoke('deleteSel')
      local left = {}
      for _, r in ipairs(h.ds:get('fxRegions') or {}) do left[#left + 1] = r.uuid end
      t.deepEq(left, { 'fxr-3' }, 'only the out-of-band region survives')
    end,
  },

  ----- Freeze (the tv seam; tm_fx_region_spec pins the conversion itself)

  {
    name = 'fx freeze promotes the region output to authored notes and drops the region',
    run = function(harness)
      local h = harness.mk()
      h.vm:setGridSize(80, 40)
      addNote(h)                                          -- the chord the arp replaces
      injectRegion(h, { fx = arpUp })
      t.deepEq(authoredPitches(h), {}, 'the covered chord is parked while the region lives')
      local _, ci = fxColFor(h, 1)
      h.ec:setPos(2, ci, 1)                               -- mid-window
      h.cmgr:invoke('freezeFxRegion')
      t.eq(#(h.ds:get('fxRegions') or {}), 0, 'the region is gone')
      t.truthy(#authoredPitches(h) > 0, 'the arp output stands as authored notes')
    end,
  },

  {
    name = 'fx freeze converts an fx-carrying note at the caret',
    run = function(harness)
      local h = harness.mk()
      h.vm:setGridSize(80, 40)
      h.tm:addEvent{ evType = 'note', ppq = 0, endppq = 240, chan = 1, pitch = 60,
                     vel = 100, detune = 0, delay = 0, lane = 1, fx = sine30 }
      h.tm:flush()
      local uuid = authoredUuid(h)
      h.ec:setPos(0, noteColIdx(h, 1), 1)                 -- caret on the host note
      h.cmgr:invoke('freezeFxRegion')
      t.falsy(h.vm:noteFx(uuid), 'the chain is gone from the host note')
      t.deepEq(authoredPitches(h), { 60 }, 'the note itself stays -- a pb chain destroys nothing')
    end,
  },

  {
    name = 'fx freeze declines on a plain note (no chain to freeze)',
    run = function(harness)
      local h = harness.mk()
      h.vm:setGridSize(80, 40)
      addNote(h)
      injectRegion(h)                                     -- sine: pb-augment, the note stays authored
      h.ec:setPos(0, noteColIdx(h, 1), 1)                 -- caret on the note, not the fx column
      h.cmgr:invoke('freezeFxRegion')
      t.truthy(region(h, 'fxr-1'), 'the region is untouched')
      t.deepEq(authoredPitches(h), { 60 }, 'so is the note')
    end,
  },

  {
    -- The keystroke consults tm's eligibility map before tv:freezeRegion's util.atomic wrap runs:
    -- refusals are silent, so a labelled empty undo entry would be the user's only signal that
    -- anything happened. see design/archive/fx-freeze.md § Eligibility gates
    name = 'fx freeze: a refused freeze opens no undo block; an eligible one opens exactly one',
    run = function(harness)
      local h = harness.mk()
      h.vm:setGridSize(80, 40)
      h.ds:assign('fxRegions', {   -- same-target overlap: each refuses the other
        { uuid = 'fxr-1', chan = 1, startppq = 0,   endppq = 240, fx = sine30 },
        { uuid = 'fxr-2', chan = 1, startppq = 120, endppq = 360, fx = sine30 },
      })
      h.tm:rebuild()
      local _, ci = fxColFor(h, 1)
      h.ec:setPos(0, ci, 1)

      -- util.atomic checks reaper.Undo_BeginBlock presence at call time, so a fixture stub installed
      -- after the wrap still counts. Outermost blocks only: inner blocks collapse into the verb's.
      local depth, blocks = 0, 0
      local realBegin, realEnd = h.reaper.Undo_BeginBlock, h.reaper.Undo_EndBlock
      h.reaper.Undo_BeginBlock = function()
        if depth == 0 then blocks = blocks + 1 end
        depth = depth + 1
      end
      h.reaper.Undo_EndBlock = function() depth = depth - 1 end

      local before = h.ds:get('fxRegions')
      h.cmgr:invoke('freezeFxRegion')
      t.eq(blocks, 0, 'the refusal declines before any undo block opens')
      t.deepEq(h.ds:get('fxRegions'), before, 'and both regions stand')

      h.ds:assign('fxRegions', {
        { uuid = 'fxr-1', chan = 1, startppq = 0, endppq = 240, fx = sine30 },
      })
      h.tm:rebuild()
      local _, soleCi = fxColFor(h, 1)
      h.ec:setPos(0, soleCi, 1)
      h.cmgr:invoke('freezeFxRegion')
      h.reaper.Undo_BeginBlock, h.reaper.Undo_EndBlock = realBegin, realEnd
      t.eq(blocks, 1, 'an eligible freeze opens exactly one block')
      t.eq(#(h.ds:get('fxRegions') or {}), 0, 'and it ran: the region is gone')
    end,
  },

  ----- Ghost display: a chain's derived notes light up while the caret sits on its host

  {
    name = 'ghostOverlay: no host under the caret returns nil, before any window query',
    run = function(harness)
      local h = harness.mk()
      h.vm:setGridSize(80, 40)
      addNote(h)
      injectRegion(h, { fx = arpUp })
      h.ec:setPos(20, noteColIdx(h, 1), 1)   -- below the region and the note alike
      t.eq(h.vm:ghostOverlay(), nil, 'nothing under the caret runs a chain, so there is nothing to overlay')
    end,
  },

  {
    name = 'ghostOverlay: a host lights its derived onsets on the lane column, with pitch and vel',
    run = function(harness)
      local h = harness.mk()
      h.vm:setGridSize(80, 40)
      addNote(h)                        -- C4 on lane 1
      h.tm:addEvent{ evType = 'note', ppq = 0, endppq = 240, chan = 1, pitch = 67,
                     vel = 90, detune = 0, delay = 0, lane = 2 }
      h.tm:flush()
      injectRegion(h, { fx = arpUp })   -- the arp interleaves both, all onto lane 1
      local idx = noteColIdx(h, 1)
      local _, ci = fxColFor(h, 1)
      h.ec:setPos(0, ci, 1)             -- on the region's own column: the chain there is what ghosts
      local ghosts = (h.vm:ghostOverlay() or {}).notes
      t.truthy(ghosts and ghosts[idx], 'the lane-1 column carries the ghosts')
      local pitches, vels = {}, {}
      for row = 0, 3 do
        local g = ghosts[idx][row]
        pitches[#pitches + 1] = g and g.pitch
        vels[#vels + 1]       = g and g.vel
      end
      t.deepEq(pitches, { 60, 67, 60, 67 }, 'the four onsets sit on rows 0-3')
      t.deepEq(vels, { 100, 90, 100, 90 }, 'each carrying the velocity it was given')
      t.eq(ghosts[idx][4], nil, 'and they stop where the host does')
      t.eq(ghosts[noteColIdx(h, 1, 2)], nil, 'lane 2 takes none -- the allocator put them all on lane 1')
      local _, fxIdx = fxColFor(h, 1)
      t.eq(ghosts[fxIdx], nil, 'note columns only')
    end,
  },

  {
    name = 'ghostOverlay: a derived note is named from the step its own intent stands on',
    run = function(harness)
      local h = harness.mk()
      h.vm:setGridSize(80, 40)
      -- Written C, sounding 60 cents sharp: far enough off that the step it sounds
      -- nearest is not the step it was written on.
      h.tm:addEvent{ evType = 'note', ppq = 0, endppq = 240, chan = 1, pitch = 60,
                     vel = 100, detune = 60, delay = 0, lane = 1, intentCents = 6000,
                     fx = trill200 }
      h.tm:flush()
      local idx = noteColIdx(h, 1)
      h.ec:setPos(0, idx, 1)   -- on the host's own cell: its chain is what ghosts
      local ghosts = (h.vm:ghostOverlay() or {}).notes
      t.truthy(ghosts and ghosts[idx], 'fixture check: the lane column carries the ghosts')
      t.eq((h.vm:noteLabel(ghosts[idx][0])), 'C-', 'the host tile keeps the name the host was written under')
      t.eq((h.vm:noteLabel(ghosts[idx][1])), 'D-', 'and the alternation names the step a tone above it')
      t.eq(h.vm:noteDeviation(ghosts[idx][1]), 60,
        'the gap it reports is the drift it inherited, not a rounding to the step it sounds nearest')
    end,
  },

  {
    name = 'a lane pops the readout column open for an off-step ghost, and closes it after',
    run = function(harness)
      local h = harness.mk()
      h.vm:setGridSize(80, 40)
      h.tm:addEvent{ evType = 'note', ppq = 0, endppq = 240, chan = 1, pitch = 60,
                     vel = 100, detune = 0, delay = 0, lane = 1, fx = trill130 }
      h.tm:flush()
      local idx = noteColIdx(h, 1)
      local col = h.vm.grid.cols[idx]
      t.falsy(col.showCents, 'fixture check: the lane\'s own note stands on its step, so it reserves nothing')
      local narrow = col.width

      h.ec:setPos(0, idx, 1)
      h.vm:reserveGhostReadout()
      t.truthy(col.showCents, 'the alternation stands 30 cents off its step, so the readout needs a column')
      t.eq(col.width, narrow + 1, 'which the lane takes for as long as the ghosts are on show')

      h.ec:setPos(20, idx, 1)   -- below the host: no chain under the caret, no ghosts
      h.vm:reserveGhostReadout()
      t.falsy(col.showCents, 'and gives back when the caret leaves the chain')
      t.eq(col.width, narrow, 'the lane standing as wide as its own notes ask')
    end,
  },

  {
    name = 'ghostOverlay: a host whose onsets lie outside the window answers empty, not nil',
    run = function(harness)
      local h = harness.mk()
      h.vm:setGridSize(80, 4)
      addNote(h)                                       -- the sole host note, [0,240)
      injectRegion(h, { fx = arpUp, endppq = 3840 })    -- the region runs on well past it
      local _, fxIdx = fxColFor(h, 1)
      h.ec:setPos(30, fxIdx, 1)   -- still inside the region; the viewport has scrolled off the onsets
      t.eq(h.vm:fxHostAtCursor(), 'fxr-1', 'fixture check: the region is still the host down here')
      local ghosts = (h.vm:ghostOverlay() or {}).notes
      t.truthy(ghosts, 'a resolved host always answers with a table')
      t.deepEq(ghosts, {}, 'empty, because every onset is above the window')
    end,
  },

  {
    name = 'ghostOverlay: a row carrying a real cell still reports its ghost -- precedence is the draw arm\'s',
    run = function(harness)
      local h = harness.mk()
      h.vm:setGridSize(80, 40)
      addNote(h)
      injectRegion(h, { fx = arpUp })
      local idx = noteColIdx(h, 1)
      local _, ci = fxColFor(h, 1)
      h.ec:setPos(0, ci, 1)
      t.truthy(h.vm.grid.cols[idx].cells[0], 'fixture check: row 0 carries the parked host cell')
      local ghosts = (h.vm:ghostOverlay() or {}).notes
      t.truthy(ghosts and ghosts[idx], 'the lane column carries ghosts')
      t.truthy(ghosts[idx][0], 'and reports one on the contested row too')
    end,
  },

  {
    name = 'ghostOverlay: the window is the viewport -- onsets below it are absent',
    run = function(harness)
      local h = harness.mk()
      h.vm:setGridSize(80, 4)
      h.tm:addEvent{ evType = 'note', ppq = 0, endppq = 960, chan = 1, pitch = 60,
                     vel = 100, detune = 0, delay = 0, lane = 1 }
      h.tm:flush()
      injectRegion(h, { fx = arpUp, endppq = 960 })   -- sixteen onsets, rows 0-15
      local idx = noteColIdx(h, 1)
      local _, ci = fxColFor(h, 1)
      h.ec:setPos(0, ci, 1)
      local ghosts = (h.vm:ghostOverlay() or {}).notes
      t.truthy(ghosts and ghosts[idx], 'the lane column carries ghosts')
      local rows = {}
      for row = 0, 15 do if ghosts[idx][row] then rows[#rows + 1] = row end end
      t.deepEq(rows, { 0, 1, 2, 3, 4 }, 'four visible rows plus one of slack; the other eleven stay out')
    end,
  },


  {
    name = 'ghostOverlay: a derived lane the channel does not carry shows nothing',
    run = function(harness)
      local h = harness.mk()
      h.vm:setGridSize(80, 40)
      addNote(h)                        -- the sole authored note, lane 1
      injectRegion(h, { fx = chord3 })   -- three voices: derived lanes 1-3
      local _, ci = fxColFor(h, 1)
      h.ec:setPos(0, ci, 1)
      local ghosts = (h.vm:ghostOverlay() or {}).notes
      t.eq(noteColIdx(h, 1, 2), nil, 'fixture check: the chain claimed no column for lane 2')
      local lit = 0
      for _ in pairs(ghosts) do lit = lit + 1 end
      t.eq(lit, 1, 'one column lights: the authored lane')
      t.eq(ghosts[noteColIdx(h, 1)][0].pitch, 60, 'carrying the voice the allocator put on lane 1')
    end,
  },

  {
    name = 'ghostOverlay: the lanes the user authored take the rest of the voices',
    run = function(harness)
      local h = harness.mk{ data = { extraColumns = { [1] = { notes = 3 } } } }
      h.vm:setGridSize(80, 40)
      addNote(h)
      injectRegion(h, { fx = chord3 })
      local _, ci = fxColFor(h, 1)
      h.ec:setPos(0, ci, 1)
      local ghosts = (h.vm:ghostOverlay() or {}).notes
      local pitches = {}
      for lane = 1, 3 do
        local col = noteColIdx(h, 1, lane)
        pitches[lane] = col and ghosts[col] and ghosts[col][0] and ghosts[col][0].pitch
      end
      t.deepEq(pitches, { 60, 64, 67 }, 'one voice per lane column, all on row 0')
    end,
  },

  ----- Ghost display: a chain's continuous curve, on the target column it claimed

  {
    name = 'ghostOverlay: a pb chain lights its curve on the column the channel carries',
    run = function(harness)
      local h = harness.mk{ data = { extraColumns = { [1] = { notes = 0, pb = true } } } }
      h.vm:setGridSize(80, 40)
      addNote(h)
      injectRegion(h, { fx = sine30 })   -- sine -> pb over [0,240): rows 0-3
      local _, fxIdx = fxColFor(h, 1)
      h.ec:setPos(0, fxIdx, 1)

      local pbIdx = ctsColIdx(h, 1, 'pb')
      t.truthy(pbIdx, 'fixture check: the channel carries a pb column of its own')
      local values = (h.vm:ghostOverlay() or {}).values
      t.truthy(values and values[pbIdx], 'the claimed column carries the curve')
      local rows = {}
      for row = 0, 6 do if values[pbIdx][row] then util.add(rows, row) end end
      t.deepEq(rows, { 0, 1, 2, 3 }, 'one value per row over the producer\'s window, and no further')
      t.eq(values[noteColIdx(h, 1)], nil, 'note columns take note ghosts, not values')
      t.eq(h.vm.grid.cols[pbIdx].cells[0], nil, 'and nothing entered the column: a ghost is not a cell')
    end,
  },

  {
    name = 'ghostOverlay: only the claimed target lights -- an authored cc beside it stays dark',
    run = function(harness)
      local h = harness.mk{ seed = { ccs = { { ppq = 0, chan = 1, evType = 'cc', cc = 10, val = 0 },
                                             { ppq = 0, chan = 1, evType = 'cc', cc = 74, val = 64 } } } }
      h.vm:setGridSize(80, 40)
      addNote(h)
      injectRegion(h, { fx = { { kind = 'sine', period = { 1, 4 }, depth = 32, dest = 10, onset = 0 } } })
      local _, fxIdx = fxColFor(h, 1)
      h.ec:setPos(0, fxIdx, 1)

      local values = (h.vm:ghostOverlay() or {}).values
      t.truthy(values[ctsColIdx(h, 1, 'cc', 10)], 'the claimed cc column carries the curve')
      t.eq(values[ctsColIdx(h, 1, 'cc', 74)], nil, 'the authored one the chain never touches stays dark')
    end,
  },

  {
    name = 'ghostOverlay: a kept producer still lights its curve after an edit elsewhere',
    run = function(harness)
      -- The claim comes off the census, not the emission: a producer outside the dirty interval
      -- is kept rather than re-run and emits no cc record, and its curve has to stand anyway.
      local h = harness.mk{ seed = { ccs = { { ppq = 0, chan = 1, evType = 'cc', cc = 10, val = 0 } } } }
      h.vm:setGridSize(80, 40)
      addNote(h)
      h.tm:addEvent{ evType = 'note', ppq = 1920, endppq = 2160, chan = 1, pitch = 64,
                     vel = 100, detune = 0, delay = 0, lane = 1 }
      h.tm:flush()
      injectRegion(h, { fx = { { kind = 'sine', period = { 1, 4 }, depth = 32, dest = 10, onset = 0 } } })
      local _, fxIdx = fxColFor(h, 1)
      h.ec:setPos(0, fxIdx, 1)
      t.truthy((h.vm:ghostOverlay() or {}).values[ctsColIdx(h, 1, 'cc', 10)], 'fixture check: the curve is up')

      local far
      for _, e in ipairs(h.tm:getChannel(1).columns.notes[1].events) do
        if e.ppq == 1920 then far = e end
      end
      h.tm:assignEvent(far, { pitch = 65 })
      h.tm:flush()

      h.ec:setPos(0, fxIdx, 1)
      local values = (h.vm:ghostOverlay() or {}).values
      t.truthy(values[ctsColIdx(h, 1, 'cc', 10)], 'the kept producer owns its target still')
    end,
  },

  {
    name = 'ghostOverlay: a note host lights its continuous claim as a region does',
    run = function(harness)
      local h = harness.mk{ seed = { ccs = { { ppq = 0, chan = 1, evType = 'cc', cc = 10, val = 0 } } } }
      h.vm:setGridSize(80, 40)
      h.tm:addEvent{ evType = 'note', ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100,
                     detune = 0, delay = 0, lane = 1,
                     fx = { { kind = 'sine', period = { 1, 4 }, depth = 32, dest = 10, onset = 0 } } }
      h.tm:flush()
      h.ec:setPos(0, noteColIdx(h, 1), 1)   -- on the host note itself
      local values = (h.vm:ghostOverlay() or {}).values
      t.truthy(values[ctsColIdx(h, 1, 'cc', 10)], 'the host claims cc 10 exactly as a region would')
    end,
  },

  {
    name = 'ghostOverlay: adding the column by hand is what makes the claim visible',
    run = function(harness)
      local h = harness.mk()
      h.vm:setGridSize(80, 40)
      addNote(h)
      injectRegion(h, { fx = { { kind = 'sine', period = { 1, 4 }, depth = 32, dest = 10, onset = 0 } } })
      local _, fxIdx = fxColFor(h, 1)
      h.ec:setPos(0, fxIdx, 1)
      t.eq(ctsColIdx(h, 1, 'cc', 10), nil, 'the claim alone materialises nothing')
      t.deepEq((h.vm:ghostOverlay() or {}).values, {}, 'so the curve has nowhere to land')

      h.vm:addExtraCol('cc', 10)
      local ccIdx = ctsColIdx(h, 1, 'cc', 10)
      t.truthy(ccIdx, 'the user\'s own column')
      local _, fxIdx2 = fxColFor(h, 1)
      h.ec:setPos(0, fxIdx2, 1)
      t.truthy((h.vm:ghostOverlay() or {}).values[ccIdx], 'and the curve lands in it')
    end,
  },

  {
    name = 'ghostOverlay: no host, no curve',
    run = function(harness)
      local h = harness.mk{ data = { extraColumns = { [1] = { notes = 0, pb = true } } } }
      h.vm:setGridSize(80, 40)
      addNote(h)
      injectRegion(h, { fx = sine30 })
      h.ec:setPos(0, ctsColIdx(h, 1, 'pb'), 1)   -- on the target column itself, which hosts nothing
      t.falsy(h.vm:fxHostAtCursor(), 'fixture check: a cts column is not a host')
      t.eq(h.vm:ghostOverlay(), nil, 'so the column stands empty, as it did before')
    end,
  },

  ----- Suppression: a replace park's originals give their rows to their own ghosts

  {
    name = 'ghostOverlay: a region host suppresses the parked chord it replaced, cells intact',
    run = function(harness)
      local h = harness.mk()
      h.vm:setGridSize(80, 40)
      addNote(h)                        -- C4 on lane 1
      h.tm:addEvent{ evType = 'note', ppq = 0, endppq = 240, chan = 1, pitch = 67,
                     vel = 90, detune = 0, delay = 0, lane = 2 }
      h.tm:flush()
      injectRegion(h, { fx = arpUp })   -- discrete replace: both notes park
      local parked = h.tm:getChannel(1).parked
      t.eq(#parked, 2, 'fixture check: the chord parked off-take')
      local _, ci = fxColFor(h, 1)
      h.ec:setPos(2, ci, 1)             -- caret in the fx column, mid-window
      local overlay = h.vm:ghostOverlay()
      t.truthy(overlay.hidden[parked[1]], 'the lane-1 original is suppressed')
      t.truthy(overlay.hidden[parked[2]], 'and so is the lane-2 one -- the whole picture, not one lane')
      local col = h.vm.grid.cols[noteColIdx(h, 1)]
      t.eq(col.cells[0], parked[1], 'col.cells is untouched: suppression is a draw-time overlay')
      t.eq(col.tails[1].evt, parked[1], 'the tail names its event, so the bracket goes with the cell')
    end,
  },

  {
    name = 'ghostOverlay: the host\'s own parked cell stays visible',
    run = function(harness)
      local h = harness.mk()
      h.vm:setGridSize(80, 40)
      h.tm:addEvent{ evType = 'note', ppq = 0, endppq = 240, chan = 1, pitch = 60,
                     vel = 100, detune = 0, delay = 0, lane = 1, fx = arpUp }
      h.tm:addEvent{ evType = 'note', ppq = 0, endppq = 240, chan = 2, pitch = 67,
                     vel = 90, detune = 0, delay = 0, lane = 1, fx = arpUp }
      h.tm:flush()
      local mine, other = h.tm:getChannel(1).parked[1], h.tm:getChannel(2).parked[1]
      t.truthy(mine and other, 'fixture check: both note hosts parked themselves')
      h.ec:setPos(0, noteColIdx(h, 1), 1)   -- caret on the host cell
      local overlay = h.vm:ghostOverlay()
      t.falsy(overlay.hidden[mine], 'the host keeps its cell -- it is the only way to edit the note')
      t.falsy(overlay.hidden[other], "and the chan-2 host's cell is its own chain's business, not this one's")
    end,
  },

  {
    name = 'ghostOverlay: nothing on the take is ever suppressed',
    run = function(harness)
      local h = harness.mk()
      h.vm:setGridSize(80, 40)
      addNote(h)
      injectRegion(h)                   -- sine: pb-augment, nothing parks
      local _, ci = fxColFor(h, 1)
      h.ec:setPos(0, ci, 1)
      local overlay = h.vm:ghostOverlay()
      t.deepEq(overlay.hidden, {}, 'an augment chain parks nothing, so it hides nothing')
    end,
  },

  ----- Scope: the overlay is one producer's realisation, not the take's

  {
    name = 'ghostOverlay: a chain on another channel keeps its ghosts to itself',
    run = function(harness)
      local h = harness.mk()
      h.vm:setGridSize(80, 40)
      noteAt(h, 1, 0, 60)
      noteAt(h, 2, 0, 64)
      injectRegions(h, { { fx = arpUp }, { chan = 2, fx = arpUp } })
      local _, ci = fxColFor(h, 1)
      h.ec:setPos(1, ci, 1)
      local ghosts = (h.vm:ghostOverlay() or {}).notes
      t.truthy(ghosts[noteColIdx(h, 1)], 'the chain the caret sits in lights its own lane column')
      t.eq(ghosts[noteColIdx(h, 2)], nil, "the chan-2 chain's output is not this one's realisation")
    end,
  },

  {
    name = 'ghostOverlay: a second chain further down the same channel stays dark',
    run = function(harness)
      local h = harness.mk()
      h.vm:setGridSize(80, 40)
      noteAt(h, 1, 0, 60)
      noteAt(h, 1, 960, 64)
      injectRegions(h, { { fx = arpUp }, { startppq = 960, endppq = 1200, fx = arpUp } })
      local _, ci = fxColFor(h, 1)
      h.ec:setPos(1, ci, 1)
      local ghosts = (h.vm:ghostOverlay() or {}).notes
      local idx, rows = noteColIdx(h, 1), {}
      for row = 0, 20 do
        if ghosts[idx] and ghosts[idx][row] then util.add(rows, row) end
      end
      t.deepEq(rows, { 0, 1, 2, 3 }, "one window's worth: the arp at rows 16-19 belongs to the other region")
    end,
  },

  {
    name = "ghostOverlay: another chain's parked originals are not this one's to suppress",
    run = function(harness)
      local h = harness.mk()
      h.vm:setGridSize(80, 40)
      noteAt(h, 1, 0, 60)
      noteAt(h, 1, 960, 64)
      injectRegions(h, { { fx = arpUp }, { startppq = 960, endppq = 1200, fx = arpUp } })
      local mine, theirs
      for _, cell in ipairs(h.tm:getChannel(1).parked) do
        if cell.ppq == 0 then mine = cell else theirs = cell end
      end
      t.truthy(mine and theirs, 'fixture check: each region parked the note it covers')
      local _, ci = fxColFor(h, 1)
      h.ec:setPos(1, ci, 1)
      local overlay = h.vm:ghostOverlay()
      t.truthy(overlay.hidden[mine], 'the original this chain stands in for gives up its row')
      t.falsy(overlay.hidden[theirs], 'the far one keeps its cell: no ghost is standing where it sits')
    end,
  },

  {
    name = "ghostOverlay: a second chain's curve claim does not light this one's column",
    run = function(harness)
      local h = harness.mk{ data = { extraColumns = { [1] = { notes = 0, pb = true } } } }
      h.vm:setGridSize(80, 40)
      noteAt(h, 1, 0, 60)
      noteAt(h, 1, 960, 64)
      injectRegions(h, { { fx = sine30 }, { startppq = 960, endppq = 1200, fx = sine30 } })
      local _, ci = fxColFor(h, 1)
      h.ec:setPos(1, ci, 1)
      local values = (h.vm:ghostOverlay() or {}).values
      local pbIdx, rows = ctsColIdx(h, 1, 'pb'), {}
      for row = 0, 20 do
        if values[pbIdx] and values[pbIdx][row] then util.add(rows, row) end
      end
      t.deepEq(rows, { 0, 1, 2, 3 }, "the caret's own window; the far sine's rows stay empty")
    end,
  },
}
