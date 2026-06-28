-- Track B (note macros v2): the fx-region column + Super-X addressing. A region
-- renders as a tailed kind-badge in a per-channel fx column, and the v1 note-FX
-- editor addresses it by uuid. see design/note-macros-v2.md § Authoring and editing the fx
local t    = require('support')
local util = require('util')
local generators = require('generators')

local vib30 = { { kind = 'vibrato', period = { 1, 4 }, depth = 30, onset = 0 } }
local arpUp = { { kind = 'arp', period = { 1, 4 }, dir = 'up' } }   -- discrete -> replace (parks)

local function injectRegion(h, over)
  local region = { uuid = 'fxr-1', chan = 1, startppq = 0, endppq = 240, fx = vib30 }
  for k, v in pairs(over or {}) do region[k] = v end
  h.ds:assign('fxRegions', { region })
  h.tm:rebuild()
end

local function fxColFor(h, chan)
  for i, c in ipairs(h.vm.grid.cols) do
    if c.type == 'fx' and c.midiChan == chan then return c, i end
  end
end

local function noteColIdx(h, chan)
  for i, c in ipairs(h.vm.grid.cols) do
    if c.type == 'note' and c.midiChan == chan and c.lane == 1 then return i end
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
      t.eq(cell.kind, 'vibrato', 'the badge shows the primary kind')
      t.eq(#col.tails, 1, 'one tail bracket spans the window')
      t.eq(col.tails[1].endRow, h.vm:ppqToRow(240, 1), 'the tail runs to the window end')
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
          { ppqL = host.window[1], val = 100, shape = 'square' },
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
      t.eq(h.vm:noteFx('fxr-1')[1].kind, 'vibrato', 'region fx returned by uuid')
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
      injectRegion(h)                                        -- fxr-1 carrying vibrato
      h.vm:setFxKindActive('fxr-1', { kind = 'vibrato' }, false)
      t.eq(#(h.ds:get('fxRegions') or {}), 1, 'the emptied region survives mid-edit as a husk')
      t.deepEq(h.ds:get('fxRegions')[1].fx, {}, 'with an empty fx list')
      h.vm:setFxKindActive('fxr-1', { kind = 'arp', period = { 1, 4 }, dir = 'up' }, true)
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
}
