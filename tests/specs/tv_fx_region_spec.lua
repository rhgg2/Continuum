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

  ----- B3 step 4: parked events are editable off-take through the leaf-edit facade

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
      t.eq(stash[1].ppqL, 0, 'logical onset captured from the cursor row')
      t.eq(stash[1].ppq, nil, 'no realised ppq -- the stash is logical-only')
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
          { ppqL = host.window[1], val = 100, shape = 'square' },
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
      local stash = h.ds:get('fxParkedCC') or {}
      t.eq(#stash, 1, 'one parked cc in the stash')
      t.truthy(stash[1].val > 30, 'its value was nudged up off the take')

      h.ec:setPos(0, ci, 1)
      h.cmgr:invoke('delete')
      generators.kinds.ccRep = nil
      t.eq(#(h.ds:get('fxParkedCC') or {}), 0, 'delete removed the parked cc from the stash')
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
}
