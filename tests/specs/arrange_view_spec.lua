-- arrangeView: in-memory cursor/scroll + persisted beatPerRow, mirroring
-- the trackerView/editCursor split (cursor is transient, density persists).

local t    = require('support')
local util = require('util')

local function mkAv(harness)
  local h  = harness.mk()
  local am = util.instantiate('arrangeManager', { cm = h.cm, ds = h.ds })
  local av = util.instantiate('arrangeView',
    { cm = h.cm, cmgr = h.cmgr, am = am })
  return h, av
end

-- Build an av over a fake project. items: list of {track, name, pos, len?}.
-- Tracks are created in first-seen order; beatPerRow is 1 (1 row = 1 QN).
local function mkArrange(harness, items)
  local h = harness.mk()
  h.cm:set('project', 'arrangeBeatPerRow', 1)
  local order, seen = {}, {}
  for _, item in ipairs(items) do
    if not seen[item.track] then
      seen[item.track] = true; order[#order + 1] = item.track
      h.reaper:setTrackName(item.track, item.track)
    end
  end
  for _, item in ipairs(items) do
    h.reaper:addItem(item.track, { take = item.track .. '/' .. item.name,
      isMidi = true, pos = item.pos, len = item.len or 1, srcLen = item.srcLen,
      poolGuid = '{' .. item.track .. item.name .. '}' })
  end
  h.reaper:setProjectTracks(order)
  local em = util.instantiate('eventMeta', { ps = util.instantiate('pextStore') })
  local am = util.instantiate('arrangeManager',
    { cm = h.cm, ds = h.ds, tm = h.tm, eventMeta = em })
  local av = util.instantiate('arrangeView', { cm = h.cm, cmgr = h.cmgr, am = am })
  return h, av, am
end

local function takeAt(list, startQN)
  for _, take in ipairs(list) do if take.startQN == startQN then return take end end
end

-- One four-row take at rows 2..5, with four rows of source left over: enough
-- room for the head to walk in and for the tail to grow.
local function mkTrimmable(harness)
  local h, av, am = mkArrange(harness, {
    { track = 'tr1', name = 'a', pos = 2, len = 4, srcLen = 8 },
  })
  am:resizeTake(am:tracksTakes(0)[1], 4)   -- a finite natural, so a grow has somewhere to go
  h.cmgr:push('arrange')
  return h, av, am
end

-- Layout for the Shift+arrow cases: tr1 holds takes at rows 0, 1, 3 and 6, tr2 one at row 0.
local shiftNavItems = {
  { track = 'tr1', name = 'a', pos = 0 },
  { track = 'tr1', name = 'b', pos = 1 },
  { track = 'tr1', name = 'e', pos = 3 },
  { track = 'tr1', name = 'c', pos = 6 },
  { track = 'tr2', name = 'd', pos = 0 },
}

-- Layout for the Tab cases: tr1 holds takes at rows 0, 2 (four rows long) and 8; tr2 one at row 4.
local tabNavItems = {
  { track = 'tr1', name = 'a', pos = 0 },
  { track = 'tr1', name = 'b', pos = 2, len = 4 },
  { track = 'tr1', name = 'c', pos = 8 },
  { track = 'tr2', name = 'd', pos = 4 },
}

return {
  {
    name = 'cursor defaults to (0,0); setCursor clamps negatives and floors',
    run = function(harness)
      local _, av = mkAv(harness)
      t.eq(av:cursorRow(), 0); t.eq(av:cursorCol(), 0)
      av:setCursor(5.7, 3.4)
      t.eq(av:cursorRow(), 5); t.eq(av:cursorCol(), 3)
      av:setCursor(-1, -2)
      t.eq(av:cursorRow(), 0); t.eq(av:cursorCol(), 0)
    end,
  },

  -- The tracker's half of the return: it speaks project QN, av owns the row.
  {
    name = 'setCursorAt lands the caret on the row holding a project QN',
    run = function(harness)
      local _, av = mkAv(harness)
      av:setBeatPerRow(2)
      av:setCursorAt(1, 5)
      t.eq(av:cursorRow(), 2, 'five beats at two beats a row is row two')
      t.eq(av:cursorCol(), 1, "and the column is the instance's track")
    end,
  },

  {
    name = 'scroll defaults to (0,0); setGridSize alone does not move scroll',
    run = function(harness)
      local _, av = mkAv(harness)
      av:setGridSize(20, 4)
      local sr, sc = av:scroll()
      t.eq(sr, 0); t.eq(sc, 0)
    end,
  },

  {
    name = 'cursor moving below the visible band scrolls down to follow',
    run = function(harness)
      local _, av = mkAv(harness)
      av:setGridSize(10, 4)
      av:setCursor(15, 0)
      local sr = av:scroll()
      t.eq(sr, 6, 'scroll snaps to keep cursor on the last visible row (15 - 10 + 1)')
    end,
  },

  {
    name = 'cursor moving above the visible band scrolls up to follow',
    run = function(harness)
      local _, av = mkAv(harness)
      av:setGridSize(10, 4)
      av:setCursor(20, 0)
      av:setCursor(2, 0)
      local sr = av:scroll()
      t.eq(sr, 2, 'scroll catches up to the cursor when cursor jumps above the band')
    end,
  },

  {
    name = 'horizontal follow tracks cursorCol against gridCols',
    run = function(harness)
      local _, av = mkAv(harness)
      av:setGridSize(10, 3)
      av:setCursor(0, 7)
      local _, sc = av:scroll()
      t.eq(sc, 5, '7 - 3 + 1 = 5; cursor sits on rightmost visible col')
      av:setCursor(0, 1)
      _, sc = av:scroll()
      t.eq(sc, 1, 'cursor jumping left pulls scroll left')
    end,
  },

  {
    name = 'setGridSize shrinking the viewport re-follows the cursor in place',
    run = function(harness)
      local _, av = mkAv(harness)
      av:setGridSize(20, 8)
      av:setCursor(15, 6)
      local sr, sc = av:scroll()
      t.eq(sr, 0); t.eq(sc, 0)
      av:setGridSize(4, 2)
      sr, sc = av:scroll()
      t.eq(sr, 12, '15 - 4 + 1')
      t.eq(sc, 5,  '6 - 2 + 1')
    end,
  },

  {
    name = 'scrollBy pans the viewport without moving the cursor',
    run = function(harness)
      local _, av = mkAv(harness)
      av:setGridSize(10, 4)
      av:scrollBy(5, 2)
      local sr, sc = av:scroll()
      t.eq(sr, 5); t.eq(sc, 2)
      t.eq(av:cursorRow(), 0, 'cursor untouched by the wheel')
      t.eq(av:cursorCol(), 0)
    end,
  },

  {
    name = 'scrollBy clamps to >= 0 and cursor-nav re-follows the cursor',
    run = function(harness)
      local _, av = mkAv(harness)
      av:setGridSize(10, 4)
      av:scrollBy(-3, -3)
      local sr, sc = av:scroll()
      t.eq(sr, 0, 'row scroll floored at 0'); t.eq(sc, 0)
      av:scrollBy(20, 0)
      av:setCursor(2, 0)                 -- a deliberate cursor move pulls the viewport back
      sr = av:scroll()
      t.eq(sr, 2, 'cursor-nav re-follows, snapping scroll back onto the cursor')
    end,
  },

  {
    name = 'scroll-right stops once the last column is fully visible',
    run = function(harness)
      local _, av = mkAv(harness)
      av:setGridSize(10, 4)              -- 4 columns visible
      av:setMaxCol(10)                   -- 10 tracks → last index 9
      av:scrollBy(0, 50)
      local _, sc = av:scroll()
      t.eq(sc, 6, 'maxCol(9) - gridCols(4) + 1 = 6; col 9 sits fully at the right edge')
    end,
  },

  {
    name = 'a same-dims setGridSize after a wheel-scroll leaves scroll alone',
    run = function(harness)
      local _, av = mkAv(harness)
      av:setGridSize(10, 4)
      av:scrollBy(8, 0)
      av:setGridSize(10, 4)              -- per-frame push with unchanged dims
      local sr = av:scroll()
      t.eq(sr, 8, 'detached scroll survives the steady-state grid-size push')
    end,
  },

  {
    name = 'beatPerRow defaults to cm value; setter clamps minimum',
    run = function(harness)
      local h, av = mkAv(harness)
      t.eq(av:beatPerRow(), 4, 'cm default')
      av:setBeatPerRow(8)
      t.eq(av:beatPerRow(), 8)
      t.eq(h.cm:get('arrangeBeatPerRow'), 8, 'persists at project tier')
      av:setBeatPerRow(0)
      t.eq(av:beatPerRow(), 1/4, 'clamped to minimum 1/4')
    end,
  },

  {
    name = 'setBeatPerRow holds the cursor QN (zoom anchors on cursor) and clamps max',
    run = function(harness)
      local _, av = mkAv(harness)
      av:setCursor(8, 0)               -- QN 32 at the default 4 beats/row
      av:setBeatPerRow(8)
      t.eq(av:cursorRow(), 4, 'row halved so the cursor QN stays 32')
      t.eq(av:rowToQN(av:cursorRow()), 32)
      av:setBeatPerRow(2)
      t.eq(av:cursorRow(), 16, 'row scaled up; QN still 32')
      t.eq(av:rowToQN(av:cursorRow()), 32)
      av:setBeatPerRow(128)
      t.eq(av:beatPerRow(), 64, 'clamped to maximum 64')
    end,
  },

  {
    name = 'paletteSlot defaults nil; setter clamps to 0..61; nil clears',
    run = function(harness)
      local _, av = mkAv(harness)
      t.eq(av:paletteSlot(), nil)
      av:setPaletteSlot(5)
      t.eq(av:paletteSlot(), 5)
      av:setPaletteSlot(-1)
      t.eq(av:paletteSlot(), 0, 'negative clamps to 0')
      av:setPaletteSlot(99)
      t.eq(av:paletteSlot(), 61, 'over-max clamps to 61')
      av:setPaletteSlot(3.7)
      t.eq(av:paletteSlot(), 3, 'floored')
      av:setPaletteSlot(nil)
      t.eq(av:paletteSlot(), nil, 'nil clears')
    end,
  },

  {
    name = 'a prune takes the palette focus down with the slot it lost',
    run = function(harness)
      local _, av, am = mkArrange(harness, {
        { track = 'tr1', name = 'a', pos = 0 },
        { track = 'tr1', name = 'b', pos = 4 },
      })
      local doomed = takeAt(av:tracksTakes(0), 4)
      av:setPaletteSlot(doomed.slotIdx)
      am:deleteTake(doomed)           -- last instance: the slot parks rather than goes
      av:pruneSlots(0)
      t.eq(#av:trackSlots(0), 1, 'the parked slot went')
      t.eq(av:paletteSlot(), nil, 'the focus went with it')
    end,
  },

  {
    name = 'a prune leaves the palette focus alone when its slot still stands',
    run = function(harness)
      local _, av, am = mkArrange(harness, {
        { track = 'tr1', name = 'a', pos = 0 },
        { track = 'tr1', name = 'b', pos = 4 },
      })
      local liveSlot = takeAt(av:tracksTakes(0), 0).slotIdx
      av:setPaletteSlot(liveSlot)
      am:deleteTake(takeAt(av:tracksTakes(0), 4))
      av:pruneSlots(0)
      t.eq(av:paletteSlot(), liveSlot, 'the live slot keeps the focus')
    end,
  },

  {
    name = 'focus defaults nil; setFocus stores an opaque handle, nil clears',
    run = function(harness)
      local _, av = mkAv(harness)
      t.eq(av:focus(), nil)
      local handle = {}              -- opaque to av — stored, never read into
      av:setFocus(handle)
      t.eq(av:focus(), handle, 'stores the handle as-is')
      av:setFocus(nil)
      t.eq(av:focus(), nil, 'nil clears')
    end,
  },

  {
    name = 'no selection + on-screen cursor: edit acts on the cursor take, leaves it unselected',
    run = function(harness)
      local h = harness.mk()
      h.cm:set('project', 'arrangeBeatPerRow', 1)
      h.reaper:setTrackName('tr1', 'Track 1')
      h.reaper:addItem('tr1', { take = 'tr1/t1', isMidi = true, pos = 0, len = 1, poolGuid = '{p1}' })
      h.reaper:setProjectTracks{ 'tr1' }
      local am = util.instantiate('arrangeManager', { cm = h.cm, ds = h.ds, tm = h.tm })
      local av = util.instantiate('arrangeView', { cm = h.cm, cmgr = h.cmgr, am = am })
      h.cmgr:push('arrange')
      av:setGridSize(8, 4)          -- a measured viewport, so cursorOnScreen is meaningful
      av:setCursor(0, 0)            -- park the caret on the take; nothing selected
      h.cmgr:invoke('arrangeNudgeForward')
      local am2 = util.instantiate('arrangeManager', { cm = h.cm, ds = h.ds, tm = h.tm })
      t.eq(am2:tracksTakes(0)[1].startQN, 1, 'nudge acted on the take under the cursor')
      t.eq(av:focus(), nil, 'the take was acted on without becoming the selection')
    end,
  },

  {
    name = 'no selection + off-screen cursor: an edit is a no-op',
    run = function(harness)
      local h = harness.mk()
      h.cm:set('project', 'arrangeBeatPerRow', 1)
      h.reaper:setTrackName('tr1', 'Track 1')
      h.reaper:addItem('tr1', { take = 'tr1/t1', isMidi = true, pos = 0, len = 1, poolGuid = '{p1}' })
      h.reaper:setProjectTracks{ 'tr1' }
      local am = util.instantiate('arrangeManager', { cm = h.cm, ds = h.ds, tm = h.tm })
      local av = util.instantiate('arrangeView', { cm = h.cm, cmgr = h.cmgr, am = am })
      h.cmgr:push('arrange')
      av:setGridSize(8, 4)
      av:setCursor(0, 0)
      av:scrollBy(20, 0)            -- a wheel-pan strands the caret above the band
      h.cmgr:invoke('arrangeDeleteTake')
      local am2 = util.instantiate('arrangeManager', { cm = h.cm, ds = h.ds, tm = h.tm })
      t.eq(#am2:tracksTakes(0), 1, 'cursor off-screen, nothing selected — delete no-ops')
    end,
  },

  {
    name = 'a held selection wins over the cursor take',
    run = function(harness)
      local h = harness.mk()
      h.cm:set('project', 'arrangeBeatPerRow', 1)
      h.reaper:setTrackName('tr1', 'Track 1')
      h.reaper:addItem('tr1', { take = 'tr1/t1', isMidi = true, pos = 0, len = 1, poolGuid = '{p1}' })
      h.reaper:addItem('tr1', { take = 'tr1/t2', isMidi = true, pos = 4, len = 1, poolGuid = '{p2}' })
      h.reaper:setProjectTracks{ 'tr1' }
      local am = util.instantiate('arrangeManager', { cm = h.cm, ds = h.ds, tm = h.tm })
      local av = util.instantiate('arrangeView', { cm = h.cm, cmgr = h.cmgr, am = am })
      h.cmgr:push('arrange')
      local takes = av:tracksTakes(0)
      av:setFocus(takes[1].take)    -- select the take at row 0
      av:setGridSize(8, 4)
      av:setCursor(4, 0)            -- park the caret on the take at row 4
      h.cmgr:invoke('arrangeDeleteTake')
      local remain = util.instantiate('arrangeManager', { cm = h.cm, ds = h.ds, tm = h.tm }):tracksTakes(0)
      t.eq(#remain, 1, 'exactly one take deleted')
      t.eq(remain[1].startQN, 4, 'the selection was deleted, not the cursor take')
    end,
  },

  {
    name = 'lasso selects every take whose span intersects the swept rect',
    run = function(harness)
      local _, av = mkArrange(harness, {
        { track = 'tr1', name = 'a', pos = 0, len = 2 },   -- QN 0..2
        { track = 'tr2', name = 'b', pos = 1, len = 2 },   -- QN 1..3
        { track = 'tr1', name = 'c', pos = 8, len = 2 },   -- QN 8..10, below the band
      })
      av:setGridSize(16, 4)
      local a = takeAt(av:tracksTakes(0), 0)
      local c = takeAt(av:tracksTakes(0), 8)
      local b = takeAt(av:tracksTakes(1), 1)
      local cand = av:lassoCandidate({ mcol = 0, qn = 0 }, 1.5, 4)   -- cols 0..1.5, QN 0..4
      t.eq(#cand.takes, 2, 'two takes swept')
      t.eq(cand.set[a.take], true, 'tr1 take in band selected')
      t.eq(cand.set[b.take], true, 'tr2 take in band selected')
      t.eq(cand.set[c.take], nil,  'take below the band not selected')
    end,
  },

  {
    name = 'Shift+arrow selects every take the anchor-to-cursor rect covers',
    run = function(harness)
      local h, av = mkArrange(harness, shiftNavItems)
      h.cmgr:push('arrange')
      av:setGridSize(16, 4)
      av:setCursor(0, 0)
      h.cmgr:invoke('arrangeSelectDown')   -- anchor row 0, cursor row 1 -> QN 0..2
      local sel = av:selectionSet()
      t.eq(sel[takeAt(av:tracksTakes(0), 0).take], true, 'take at row 0 selected')
      t.eq(sel[takeAt(av:tracksTakes(0), 1).take], true, 'take at row 1 selected')
      t.eq(sel[takeAt(av:tracksTakes(0), 3).take], nil,  'take past the rect untouched')
      t.eq(sel[takeAt(av:tracksTakes(1), 0).take], nil,  'other column untouched')
      t.eq(av:cursorRow(), 1, 'the caret moved with the selection')
    end,
  },

  {
    name = 'Shift+arrow sideways widens the rect into the next column',
    run = function(harness)
      local h, av = mkArrange(harness, shiftNavItems)
      h.cmgr:push('arrange')
      av:setGridSize(16, 4)
      av:setCursor(0, 0)
      h.cmgr:invoke('arrangeSelectDown')
      h.cmgr:invoke('arrangeSelectRight')
      local sel = av:selectionSet()
      t.eq(#util.keys(sel), 3, 'both tr1 takes plus the tr2 take')
      t.eq(sel[takeAt(av:tracksTakes(1), 0).take], true, 'tr2 take swept in')
    end,
  },

  {
    name = 'Shift+arrow back toward the anchor drops what it uncovers',
    run = function(harness)
      local h, av = mkArrange(harness, shiftNavItems)
      h.cmgr:push('arrange')
      av:setGridSize(16, 4)
      av:setCursor(0, 0)
      h.cmgr:invoke('arrangeSelectDown')
      h.cmgr:invoke('arrangeSelectDown')   -- rows 0..2 -> QN 0..3
      t.eq(#util.keys(av:selectionSet()), 2, 'two takes under the grown rect')
      h.cmgr:invoke('arrangeSelectUp')
      h.cmgr:invoke('arrangeSelectUp')     -- back to rows 0..0 -> QN 0..1
      local sel = av:selectionSet()
      t.eq(#util.keys(sel), 1, 'the rect shrank back to one row')
      t.eq(sel[takeAt(av:tracksTakes(0), 0).take], true, 'the anchor row take is what is left')
    end,
  },

  {
    name = 'a plain cursor move ends the run, so the next Shift+arrow re-anchors',
    run = function(harness)
      local h, av = mkArrange(harness, shiftNavItems)
      h.cmgr:push('arrange')
      av:setGridSize(16, 4)
      av:setCursor(0, 0)
      h.cmgr:invoke('arrangeSelectDown')   -- rows 0..1 selected
      h.cmgr:invoke('arrangeCursorDown')   -- cursor to row 2, anchor dropped
      h.cmgr:invoke('arrangeSelectDown')   -- fresh anchor at row 2 -> QN 2..4
      local sel = av:selectionSet()
      t.eq(#util.keys(sel), 1, 'only the take under the new rect')
      t.eq(sel[takeAt(av:tracksTakes(0), 3).take], true, 'the take at row 3')
    end,
  },

  {
    name = 'a bare cursor move clears the selection',
    run = function(harness)
      local h, av = mkArrange(harness, shiftNavItems)
      h.cmgr:push('arrange')
      av:setGridSize(16, 4)
      av:setCursor(0, 0)
      h.cmgr:invoke('arrangeSelectDown')   -- rows 0..1 selected
      t.eq(#util.keys(av:selectionSet()), 2, 'two takes selected by the run')
      h.cmgr:invoke('arrangeCursorDown')
      t.eq(#util.keys(av:selectionSet()), 0, 'the arrow key took the selection with it')
    end,
  },

  {
    name = 'Home clears the selection like any other bare nav',
    run = function(harness)
      local h, av = mkArrange(harness, shiftNavItems)
      h.cmgr:push('arrange')
      av:setGridSize(16, 4)
      av:setCursor(0, 0)
      h.cmgr:invoke('arrangeSelectDown')
      h.cmgr:invoke('arrangeHome')
      t.eq(av:cursorRow(), 0, 'Home parked the caret at the top')
      t.eq(#util.keys(av:selectionSet()), 0, 'and cleared the selection')
    end,
  },

  {
    name = 'Tab walks down the column, stopping at each start and each free row after a take',
    run = function(harness)
      local h, av = mkArrange(harness, tabNavItems)
      h.cmgr:push('arrange')
      av:setGridSize(16, 4)
      av:setCursor(0, 0)
      h.cmgr:invoke('arrangeNextDrop')
      t.eq(av:cursorRow(), 1, 'the free row where the take at row 0 ends')
      h.cmgr:invoke('arrangeNextDrop')
      t.eq(av:cursorRow(), 2, 'on to the next start')
      h.cmgr:invoke('arrangeNextDrop')
      t.eq(av:cursorRow(), 6, 'over the four rows that take covers, to where it ends')
      h.cmgr:invoke('arrangeNextDrop')
      t.eq(av:cursorRow(), 8, 'the last start')
      h.cmgr:invoke('arrangeNextDrop')
      t.eq(av:cursorRow(), 9, 'and the free row after it — the append point')
      h.cmgr:invoke('arrangeNextDrop')
      t.eq(av:cursorRow(), 9, 'which holds the caret; no wrap')
    end,
  },

  {
    name = 'abutting takes collapse their shared boundary to one Tab stop',
    run = function(harness)
      local h, av = mkArrange(harness, { { track = 'tr1', name = 'a', pos = 0, len = 2 },
                                         { track = 'tr1', name = 'b', pos = 2, len = 2 } })
      h.cmgr:push('arrange')
      av:setGridSize(16, 4)
      av:setCursor(0, 0)
      h.cmgr:invoke('arrangeNextDrop')
      t.eq(av:cursorRow(), 2, "the second take's start, which is also the first take's end")
      h.cmgr:invoke('arrangeNextDrop')
      t.eq(av:cursorRow(), 4, 'the free row past the run')
    end,
  },

  {
    name = 'Shift+Tab walks back up, snapping to the start of the take it is inside',
    run = function(harness)
      local h, av = mkArrange(harness, tabNavItems)
      h.cmgr:push('arrange')
      av:setGridSize(16, 4)
      av:setCursor(4, 0)                   -- inside the take spanning rows 2..5
      h.cmgr:invoke('arrangePrevDrop')
      t.eq(av:cursorRow(), 2, 'the take under the caret pulls it to its own start')
      h.cmgr:invoke('arrangePrevDrop')
      t.eq(av:cursorRow(), 1, 'the free row above it, where the take at row 0 ends')
      h.cmgr:invoke('arrangePrevDrop')
      t.eq(av:cursorRow(), 0, 'then on to that take')
      h.cmgr:invoke('arrangePrevDrop')
      t.eq(av:cursorRow(), 0, 'the first take holds the caret; no wrap')
    end,
  },

  {
    name = 'Tab only sees the takes in the cursor column',
    run = function(harness)
      local h, av = mkArrange(harness, tabNavItems)
      h.cmgr:push('arrange')
      av:setGridSize(16, 4)
      av:setCursor(0, 1)
      h.cmgr:invoke('arrangeNextDrop')
      t.eq(av:cursorRow(), 4, "tr2's lone take, not tr1's at row 1 or 2")
      t.eq(av:cursorCol(), 1, 'and the column is unchanged')
      h.cmgr:invoke('arrangeNextDrop')
      t.eq(av:cursorRow(), 5, 'the free row after it')
      h.cmgr:invoke('arrangeNextDrop')
      t.eq(av:cursorRow(), 5, 'nothing below that in this column')
    end,
  },

  {
    name = 'Tab clears the selection like any other bare nav',
    run = function(harness)
      local h, av = mkArrange(harness, tabNavItems)
      h.cmgr:push('arrange')
      av:setGridSize(16, 4)
      av:setCursor(0, 0)
      h.cmgr:invoke('arrangeSelectDown')
      t.eq(#util.keys(av:selectionSet()), 1, 'the run selected the take at row 0')
      h.cmgr:invoke('arrangeNextDrop')
      t.eq(av:cursorRow(), 2, 'Tab still moved the caret')
      t.eq(#util.keys(av:selectionSet()), 0, 'and took the selection with it')
    end,
  },

  {
    name = "an edit's own cursor advance keeps the selection",
    run = function(harness)
      local h, av = mkArrange(harness, shiftNavItems)
      h.cmgr:push('arrange')
      av:setGridSize(16, 4)
      av:setCursor(6, 0)
      local take = takeAt(av:tracksTakes(0), 6).take
      av:setFocus(take)
      h.cmgr:invoke('arrangeNudgeForward')   -- take and caret both step a row
      t.eq(av:cursorRow(), 7, 'the caret followed the nudged take')
      t.eq(av:isSelected(take), true, 'which stays selected, ready for the next nudge')
    end,
  },

  {
    name = 'the pooled duplicate clears the selection and lands the caret on the copy',
    run = function(harness)
      local h, av = mkArrange(harness, { { track = 'tr1', name = 'a', pos = 0 } })
      h.cmgr:push('arrange')
      av:setGridSize(16, 4)
      av:setCursor(0, 0)
      local src = av:tracksTakes(0)[1].take
      av:setFocus(src)
      h.cmgr:invoke('arrangeDuplicateBelow')
      local am2   = util.instantiate('arrangeManager', { cm = h.cm, ds = h.ds, tm = h.tm })
      local takes = am2:tracksTakes(0)
      t.eq(#takes, 2, 'the clone landed at the append point')
      local copy = takeAt(takes, 1)
      t.truthy(copy, 'one row below the source')
      t.eq(av:isSelected(copy.take), false, 'the copy is not selected')
      t.eq(av:isSelected(src), false, 'nor is the source it was made from')
      t.eq(av:cursorRow(), 1, 'the caret advanced onto the copy')
    end,
  },

  {
    name = 'the band stands through a run and comes down on the next command',
    run = function(harness)
      local h, av = mkArrange(harness, shiftNavItems)
      h.cmgr:push('arrange')
      av:setGridSize(16, 4)
      av:setCursor(0, 0)
      h.cmgr:invoke('arrangeSelectDown')
      local band = av:selectBand()
      t.eq(band.colLo, 0, 'band starts at the cursor column')
      t.eq(band.colHi, 1, 'and covers that column whole')
      t.eq(band.qnLo,  0, 'top edge at the anchor row')
      t.eq(band.qnHi,  2, 'bottom edge past the cursor row')
      h.cmgr:invoke('arrangeSelectDown')
      t.eq(av:selectBand().qnHi, 3, 'a second Shift+arrow grows the same band')
      h.cmgr:invoke('arrangeAdvanceBy2')   -- touches neither cursor nor selection
      t.eq(av:selectBand(), nil, 'the band came down on the first other command')
      t.eq(#util.keys(av:selectionSet()), 2, 'the selection it made outlives it')
      h.cmgr:pop('arrange')   -- asserts if the band scope was left on the stack
    end,
  },

  {
    name = 'a click takes the band down without waiting for a command',
    run = function(harness)
      local h, av = mkArrange(harness, shiftNavItems)
      h.cmgr:push('arrange')
      av:setGridSize(16, 4)
      av:setCursor(0, 0)
      h.cmgr:invoke('arrangeSelectDown')
      av:setCursor(4, 0)                   -- the mouse path, not a command
      t.eq(av:selectBand(), nil, 'the band went with the cursor')
      h.cmgr:invoke('arrangeAdvanceBy2')
      h.cmgr:pop('arrange')   -- that command's bail popped the scope left behind
    end,
  },

  {
    name = 'dropBand takes the band down and pops its scope',
    run = function(harness)
      local h, av = mkArrange(harness, shiftNavItems)
      h.cmgr:push('arrange')
      av:setGridSize(16, 4)
      av:setCursor(0, 0)
      h.cmgr:invoke('arrangeSelectDown')
      av:dropBand()
      t.eq(av:selectBand(), nil, 'band down')
      h.cmgr:pop('arrange')   -- asserts unless the scope went with it
    end,
  },

  {
    name = 'a multi-selection deletes every selected take in one pass',
    run = function(harness)
      local h, av = mkArrange(harness, {
        { track = 'tr1', name = 'a', pos = 0 },
        { track = 'tr1', name = 'b', pos = 4 },
      })
      h.cmgr:push('arrange')
      av:setGridSize(8, 4)
      local takes = av:tracksTakes(0)
      av:setSelection{ takes[1].take, takes[2].take }
      h.cmgr:invoke('arrangeDeleteTake')
      local remain = util.instantiate('arrangeManager', { cm = h.cm, ds = h.ds, tm = h.tm }):tracksTakes(0)
      t.eq(#remain, 0, 'both selected takes gone')
      t.eq(next(av:selectionSet()), nil, 'selection cleared after delete')
    end,
  },

  {
    name = 'nudge refuses entirely when any selected take is blocked',
    run = function(harness)
      local h, av = mkArrange(harness, {
        { track = 'tr1', name = 'a', pos = 0 },   -- selected
        { track = 'tr1', name = 'b', pos = 1 },   -- selected
        { track = 'tr1', name = 'c', pos = 2 },   -- blocker, not selected
      })
      h.cmgr:push('arrange')
      av:setGridSize(8, 4)
      local takes = av:tracksTakes(0)
      av:setSelection{ takeAt(takes, 0).take, takeAt(takes, 1).take }
      h.cmgr:invoke('arrangeNudgeForward')   -- b would land on c@2 → refuse the lot
      local now = util.instantiate('arrangeManager', { cm = h.cm, ds = h.ds, tm = h.tm }):tracksTakes(0)
      t.eq(#now, 3, 'all three still present')
      t.eq(takeAt(now, 0) ~= nil, true, 'a stayed at 0')
      t.eq(takeAt(now, 1) ~= nil, true, 'b stayed at 1')
      t.eq(takeAt(now, 2) ~= nil, true, 'c stayed at 2')
    end,
  },

  {
    name = 'nudge slides a contiguous selected block without self-collision',
    run = function(harness)
      local h, av = mkArrange(harness, {
        { track = 'tr1', name = 'a', pos = 0 },
        { track = 'tr1', name = 'b', pos = 1 },
      })
      h.cmgr:push('arrange')
      av:setGridSize(8, 4)
      local takes = av:tracksTakes(0)
      av:setSelection{ takeAt(takes, 0).take, takeAt(takes, 1).take }
      h.cmgr:invoke('arrangeNudgeForward')   -- a→1, b→2; ordering must keep a off b
      local now = util.instantiate('arrangeManager', { cm = h.cm, ds = h.ds, tm = h.tm }):tracksTakes(0)
      t.eq(#now, 2, 'both takes survive')
      t.eq(takeAt(now, 1) ~= nil, true, 'first take moved to row 1')
      t.eq(takeAt(now, 2) ~= nil, true, 'second take moved to row 2')
    end,
  },

  {
    name = 'a single-target command no-ops on a multi-selection',
    run = function(harness)
      local h, av = mkArrange(harness, {
        { track = 'tr1', name = 'a', pos = 0 },
        { track = 'tr1', name = 'b', pos = 4 },
      })
      h.cmgr:push('arrange')
      av:setGridSize(8, 4)
      local takes = av:tracksTakes(0)
      av:setSelection{ takes[1].take, takes[2].take }
      h.cmgr:invoke('arrangeDuplicateBelow')
      local now = util.instantiate('arrangeManager', { cm = h.cm, ds = h.ds, tm = h.tm }):tracksTakes(0)
      t.eq(#now, 2, 'no copy made while two takes are selected')
    end,
  },

  {
    name = 'arrangeClearSelection empties the selection',
    run = function(harness)
      local h, av = mkArrange(harness, {
        { track = 'tr1', name = 'a', pos = 0 },
      })
      h.cmgr:push('arrange')
      av:setGridSize(8, 4)
      av:setSelection{ av:tracksTakes(0)[1].take }
      t.eq(next(av:selectionSet()) ~= nil, true, 'selection populated')
      h.cmgr:invoke('arrangeClearSelection')
      t.eq(next(av:selectionSet()), nil, 'cleared')
    end,
  },

  {
    name = 'addToSelection unions handles without duplicating a present one',
    run = function(harness)
      local _, av = mkArrange(harness, {
        { track = 'tr1', name = 'a', pos = 0 },
        { track = 'tr1', name = 'b', pos = 1 },
        { track = 'tr1', name = 'c', pos = 2 },
      })
      local takes = av:tracksTakes(0)
      av:setSelection{ takeAt(takes, 0).take }
      av:addToSelection{ takeAt(takes, 1).take, takeAt(takes, 0).take }   -- b new, a already in
      local set, n = av:selectionSet(), 0
      for _ in pairs(set) do n = n + 1 end
      t.eq(n, 2, 'a and b selected, a not doubled')
      t.eq(set[takeAt(takes, 1).take], true, 'b added')
    end,
  },

  {
    name = 'toggleSelected adds an absent handle and removes a present one',
    run = function(harness)
      local _, av = mkArrange(harness, {
        { track = 'tr1', name = 'a', pos = 0 },
        { track = 'tr1', name = 'b', pos = 1 },
      })
      local takes = av:tracksTakes(0)
      av:setSelection{ takeAt(takes, 0).take }
      av:toggleSelected(takeAt(takes, 1).take)   -- add b
      t.eq(av:isSelected(takeAt(takes, 1).take), true, 'b added')
      av:toggleSelected(takeAt(takes, 0).take)   -- remove a
      t.eq(av:isSelected(takeAt(takes, 0).take), false, 'a removed')
      t.eq(av:isSelected(takeAt(takes, 1).take), true, 'b remains')
    end,
  },

  {
    name = 'group drag slides the whole selection by one delta',
    run = function(harness)
      local h, av = mkArrange(harness, {
        { track = 'tr1', name = 'a', pos = 0 },
        { track = 'tr1', name = 'b', pos = 2 },
      })
      av:setGridSize(8, 4)
      local takes = av:tracksTakes(0)
      av:setSelection{ takeAt(takes, 0).take, takeAt(takes, 2).take }
      local press = { qn = 0, take = takeAt(takes, 0), mode = 'move', group = true }
      local cand  = av:dragCandidate(press, 2, true)   -- grab a@0, drag to QN 2 → delta +2
      t.eq(cand.fits, true, 'the block fits at the destination')
      av:commitDrag(press, cand)
      local now = util.instantiate('arrangeManager', { cm = h.cm, ds = h.ds, tm = h.tm }):tracksTakes(0)
      t.eq(takeAt(now, 2) ~= nil, true, 'a slid to 2')
      t.eq(takeAt(now, 4) ~= nil, true, 'b slid to 4')
    end,
  },

  {
    name = 'group drag refuses when a member would hit an outside take',
    run = function(harness)
      local _, av = mkArrange(harness, {
        { track = 'tr1', name = 'a', pos = 0 },   -- selected
        { track = 'tr1', name = 'b', pos = 1 },   -- selected
        { track = 'tr1', name = 'c', pos = 3 },   -- blocker, not selected
      })
      av:setGridSize(8, 4)
      local takes = av:tracksTakes(0)
      av:setSelection{ takeAt(takes, 0).take, takeAt(takes, 1).take }
      local press = { qn = 0, take = takeAt(takes, 0), mode = 'move', group = true }
      local cand  = av:dragCandidate(press, 2, true)   -- delta +2 → b@1 lands on c@3
      t.eq(cand.fits, false, 'a member collides, so the block is blocked')
    end,
  },

  {
    name = 'group drag with Alt duplicates the block and reselects the copies',
    run = function(harness)
      local h, av = mkArrange(harness, {
        { track = 'tr1', name = 'a', pos = 0 },
        { track = 'tr1', name = 'b', pos = 1 },
      })
      av:setGridSize(8, 4)
      local takes = av:tracksTakes(0)
      av:setSelection{ takeAt(takes, 0).take, takeAt(takes, 1).take }
      local press = { qn = 0, take = takeAt(takes, 0), mode = 'move', group = true, duplicate = true }
      local cand  = av:dragCandidate(press, 4, true)   -- delta +4
      t.eq(cand.fits, true, 'copies clear the originals that stay behind')
      av:commitDrag(press, cand)
      local now = util.instantiate('arrangeManager', { cm = h.cm, ds = h.ds, tm = h.tm }):tracksTakes(0)
      t.eq(#now, 4, 'two copies were added')
      t.eq(takeAt(now, 4) ~= nil and takeAt(now, 5) ~= nil, true, 'copies at 4 and 5')
      local n = 0; for _ in pairs(av:selectionSet()) do n = n + 1 end
      t.eq(n, 2, 'the selection now holds the two copies')
    end,
  },

  -- Loop to item (docs/arrangeView.md § Loop to item): the verb brackets the
  -- take under the grid cursor.
  {
    name = 'loop to item brackets the take under the arrange cursor',
    run = function(harness)
      local h, av, am = mkArrange(harness, {
        { track = 'tr1', name = 'a', pos = 0, len = 4 },
        { track = 'tr1', name = 'b', pos = 8, len = 4 },
      })
      h.cmgr:push('arrange')
      av:setCursor(9, 0)
      h.cmgr:invoke('arrangeLoopToItem')
      t.deepEq({ am:loopRangeQN() }, { 8, 12 }, 'the loop brackets the take under the cursor')
      t.eq(h.reaper.GetSetRepeat(-1), 1, 'repeat on, so the range loops')
      t.eq(am:editCursorQN(), 8, 'the edit cursor moved to the span start')

      av:setCursor(5, 0)                 -- a row in the gap between the two takes
      h.cmgr:invoke('arrangeLoopToItem')
      t.deepEq({ am:loopRangeQN() }, { 8, 12 }, 'a gap gives the verb nothing to bracket')
    end,
  },

  {
    name = 'loop to item takes the selection over the cursor, and spans a block',
    run = function(harness)
      local h, av, am = mkArrange(harness, {
        { track = 'tr1', name = 'a', pos = 0,  len = 4 },
        { track = 'tr1', name = 'b', pos = 8,  len = 4 },
        { track = 'tr1', name = 'c', pos = 16, len = 4 },
      })
      h.cmgr:push('arrange')
      local takes = av:tracksTakes(0)
      av:setSelection{ takeAt(takes, 8).take }
      av:setCursor(0, 0)                 -- caret on a, selection held on b
      h.cmgr:invoke('arrangeLoopToItem')
      t.deepEq({ am:loopRangeQN() }, { 8, 12 }, 'the held selection wins over the cursor take')

      av:setSelection{ takeAt(takes, 8).take, takeAt(takes, 16).take }
      h.cmgr:invoke('arrangeLoopToItem')
      t.deepEq({ am:loopRangeQN() }, { 8, 20 }, 'a block brackets from its first start to its last end')
    end,
  },

  {
    name = 'a cursor-driven replace leaves nothing selected',
    run = function(harness)
      local h, av, am = mkArrange(harness, {
        { track = 'tr1', name = 'a', pos = 0, len = 2 },
        { track = 'tr1', name = 'b', pos = 8, len = 1 },
      })
      av:setCursor(0, 0)                 -- caret on a, nothing selected
      h.cmgr:push('arrange')
      h.cmgr:invoke('arrangeReplaceMode')
      h.cmgr:invoke('drop1')             -- b's slot stands in for a
      t.eq(takeAt(am:tracksTakes(0), 0).slotIdx, 1, 'the replace happened')
      t.deepEq(av:selectionSet(), {}, 'and left the selection as it found it — empty')
    end,
  },

  {
    name = 'a replace of a selected take hands the selection to the replacement',
    run = function(harness)
      local h, av, am = mkArrange(harness, {
        { track = 'tr1', name = 'a', pos = 0, len = 2 },
        { track = 'tr1', name = 'b', pos = 8, len = 1 },
      })
      local before = takeAt(am:tracksTakes(0), 0).take
      av:setSelection{ before }
      av:setCursor(0, 0)
      h.cmgr:push('arrange')
      h.cmgr:invoke('arrangeReplaceMode')
      h.cmgr:invoke('drop1')
      local after = takeAt(am:tracksTakes(0), 0).take
      t.deepEq(av:selectionSet(), { [after] = true },
               'the replacement is selected, the take it displaced is gone')
    end,
  },

  {
    name = 'a replace of a selection away from the cursor leaves the cursor alone',
    run = function(harness)
      local h, av, am = mkArrange(harness, {
        { track = 'tr1', name = 'a', pos = 0, len = 4 },
        { track = 'tr1', name = 'b', pos = 8, len = 1 },
      })
      av:setSelection{ takeAt(am:tracksTakes(0), 0).take }
      av:setCursor(20, 0)                -- parked far below what is selected
      h.cmgr:push('arrange')
      h.cmgr:invoke('arrangeReplaceMode')
      h.cmgr:invoke('drop1')             -- a one-row slot stands in for a four-row take
      t.eq(av:cursorRow(), 20, 'the cursor never sat inside the take replaced')
    end,
  },

  -- Advance mode (Ctrl-`): the drop advance reads as the take's own length
  -- rather than arrangeAdvanceBy rows.
  {
    name = 'with advance-by-length armed, a drop advances by the take it placed',
    run = function(harness)
      local h, av, am = mkArrange(harness, {
        { track = 'tr1', name = 'a', pos = 8, len = 3 },   -- slot 0, three rows long
      })
      h.cm:set('project', 'arrangeAdvanceBy', 1)
      am:tracksTakes(0)                  -- materialise the pool into its slot
      av:setGridSize(16, 4)
      av:setCursor(0, 0)
      h.cmgr:push('arrange')
      h.cmgr:invoke('arrangeAdvanceMode')
      h.cmgr:invoke('drop0')
      t.eq(av:cursorRow(), 3, 'the caret sits on the end edge of what it placed, not one row down')
    end,
  },

  {
    name = 'advance-by-length reads the clipped length, not the slot length',
    run = function(harness)
      local h, av, am = mkArrange(harness, {
        { track = 'tr1', name = 'a', pos = 8, len = 3 },   -- slot 0, three rows long
        { track = 'tr1', name = 'b', pos = 2, len = 1 },   -- truncates the drop at row 2
      })
      am:tracksTakes(0)
      av:setGridSize(16, 4)
      av:setCursor(0, 0)
      h.cmgr:push('arrange')
      h.cmgr:invoke('arrangeAdvanceMode')
      h.cmgr:invoke('drop0')
      t.eq(av:cursorRow(), 2, 'the caret stopped where the neighbour cut the placement short')
    end,
  },

  {
    name = 'a second Ctrl-` puts the drop advance back on arrangeAdvanceBy',
    run = function(harness)
      local h, av, am = mkArrange(harness, {
        { track = 'tr1', name = 'a', pos = 8, len = 3 },
      })
      h.cm:set('project', 'arrangeAdvanceBy', 2)
      am:tracksTakes(0)
      av:setGridSize(16, 4)
      av:setCursor(0, 0)
      h.cmgr:push('arrange')
      h.cmgr:invoke('arrangeAdvanceMode')
      h.cmgr:invoke('arrangeAdvanceMode')
      h.cmgr:invoke('drop0')
      t.eq(av:cursorRow(), 2, 'back to the fixed step')
    end,
  },

  -- Resize arming (docs/arrangeView.md § Nudge and resize): the caret standing
  -- on a target's start row moves the head, anywhere else moves the tail, and
  -- an edit never changes which of the two is armed.
  {
    name = 'the caret on a start row moves the head down, holding the end still',
    run = function(harness)
      local h, av, am = mkTrimmable(harness)
      av:setCursor(2, 0)
      h.cmgr:invoke('arrangeEdgeDown')
      local tk = am:tracksTakes(0)[1]
      t.eq(tk.startQN,  3, 'the start edge walked down a row')
      t.eq(tk.lengthQN, 3, 'the end held, so a row less is rendered')
      t.eq(av:cursorRow(), 3, 'the caret rode the head down, so the head stays armed')
    end,
  },

  {
    name = 'the split key cuts the take at the caret and leaves the caret on the lower half',
    run = function(harness)
      local h, av, am = mkTrimmable(harness)
      av:setCursor(4, 0)
      h.cmgr:invoke('arrangeSplit')
      local takes = am:tracksTakes(0)
      t.eq(#takes, 2, 'one take became two')
      t.eq(takeAt(takes, 2).lengthQN, 2, 'the upper half ends at the caret')
      t.eq(takeAt(takes, 4).lengthQN, 2, 'the lower half runs to where the whole one did')
      t.eq(av:cursorRow(), 4, 'the caret holds, so it stands on the new start row')
    end,
  },

  {
    name = 'a split on the start row has nothing to cut',
    run = function(harness)
      local h, av, am = mkTrimmable(harness)
      av:setCursor(2, 0)
      h.cmgr:invoke('arrangeSplit')
      t.eq(#am:tracksTakes(0), 1, 'the take is left whole')
    end,
  },

  {
    name = 'the caret off the start row moves the tail, leaving the head alone',
    run = function(harness)
      local h, av, am = mkTrimmable(harness)
      av:setCursor(3, 0)
      h.cmgr:invoke('arrangeEdgeDown')
      local tk = am:tracksTakes(0)[1]
      t.eq(tk.startQN,  2, 'the start edge held')
      t.eq(tk.lengthQN, 5, 'the tail grew a row')
      t.eq(av:cursorRow(), 3, 'a tail move leaves the caret alone')
    end,
  },

  {
    name = 'Up on the start row hands back a row of head, taking the caret with it',
    run = function(harness)
      local h, av, am = mkTrimmable(harness)
      am:trimHead(am:tracksTakes(0)[1], 2)      -- two rows of head: the take starts at row 4
      av:setCursor(4, 0)
      h.cmgr:invoke('arrangeEdgeUp')
      local tk = am:tracksTakes(0)[1]
      t.eq(tk.startQN,  3, 'the start edge walked up a row')
      t.eq(tk.lengthQN, 3, 'and a row more of source is rendered')
      t.eq(av:cursorRow(), 3, 'the caret rode the head up')
    end,
  },

  {
    name = 'a head at the origin refuses to grow, and the caret holds',
    run = function(harness)
      local h, av, am = mkTrimmable(harness)
      av:setCursor(2, 0)
      h.cmgr:invoke('arrangeEdgeUp')
      local tk = am:tracksTakes(0)[1]
      t.eq(tk.startQN,  2, 'nothing above the origin to hand back')
      t.eq(tk.lengthQN, 4, 'and the refusal does not fall through to the tail')
      t.eq(av:cursorRow(), 2, 'a refusal leaves the caret on the start row')
    end,
  },

  {
    name = 'the take under the cursor carries the source its box hides',
    run = function(harness)
      local h, av = mkTrimmable(harness)
      av:setCursor(2, 0)
      h.cmgr:invoke('arrangeEdgeDown')          -- walk the head in one row
      av:setCursor(3, 0)
      local tk = av:cursorTake()
      t.eq(tk.startQN - tk.originQN, 1, 'one row of source skipped above the head')
      t.eq(tk.tailQN, 4, 'and four rows left below the cut')
      av:setCursor(9, 0)
      t.eq(av:cursorTake(), nil, 'empty space has no take to report')
    end,
  },

  {
    name = 'a head trim is floored at one rendered row',
    run = function(harness)
      local h, av, am = mkTrimmable(harness)
      am:resizeTake(am:tracksTakes(0)[1], 1)    -- down to a single rendered row
      av:setCursor(2, 0)
      h.cmgr:invoke('arrangeEdgeDown')
      local tk = am:tracksTakes(0)[1]
      t.eq(tk.startQN,  2, 'the take would render nothing, so the head holds')
      t.eq(tk.lengthQN, 1)
      t.eq(av:cursorRow(), 2, 'and so does the caret')
    end,
  },

  {
    name = 'a tail shrink never parks the caret on the head row',
    run = function(harness)
      local h, av, am = mkArrange(harness, {
        { track = 'tr1', name = 'a', pos = 0, len = 2 },
      })
      h.cmgr:push('arrange')
      av:setCursor(1, 0)
      h.cmgr:invoke('arrangeEdgeUp')
      t.eq(am:tracksTakes(0)[1].lengthQN, 1, 'the tail came up a row')
      t.eq(av:cursorRow(), 1, 'the caret stops on the end edge rather than the start row')
      h.cmgr:invoke('arrangeEdgeUp')
      t.eq(am:tracksTakes(0)[1].lengthQN, 1, 'floored at one row, so still the tail that is armed')
      t.eq(av:cursorRow(), 1)
    end,
  },

  {
    name = 'the armed edge is decided once, from the take the caret stands on',
    run = function(harness)
      local h, av, am = mkArrange(harness, {
        { track = 'tr1', name = 'a', pos = 2, len = 2 },
        { track = 'tr1', name = 'b', pos = 6, len = 2 },
      })
      h.cmgr:push('arrange')
      local takes = am:tracksTakes(0)
      av:setSelection{ takes[1].take, takes[2].take }
      av:setCursor(6, 0)                        -- the start row of the second take
      h.cmgr:invoke('arrangeEdgeDown')
      local after = am:tracksTakes(0)
      t.eq(after[1].startQN, 3, 'the whole selection trims its head')
      t.eq(after[2].startQN, 7)
      t.eq(av:cursorRow(), 7, 'the caret follows the take it armed')
    end,
  },

  {
    name = 'qnToRow / rowToQN are inverses through beatPerRow',
    run = function(harness)
      local _, av = mkAv(harness)
      av:setBeatPerRow(4)
      t.eq(av:qnToRow(16), 4)
      t.eq(av:rowToQN(4), 16)
      av:setBeatPerRow(8)
      t.eq(av:qnToRow(16), 2)
      t.eq(av:rowToQN(2), 16)
    end,
  },
}
