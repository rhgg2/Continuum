-- arrangeView: in-memory cursor/scroll + persisted beatPerRow, mirroring
-- the trackerView/editCursor split (cursor is transient, density persists).

local t    = require('support')
local util = require('util')

local function mkAv(harness)
  local h  = harness.mk()
  local am = util.instantiate('arrangeManager', { cm = h.cm })
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
      isMidi = true, pos = item.pos, len = item.len or 1,
      poolGuid = '{' .. item.track .. item.name .. '}' })
  end
  h.reaper:setProjectTracks(order)
  local am = util.instantiate('arrangeManager', { cm = h.cm, tm = h.tm })
  local av = util.instantiate('arrangeView', { cm = h.cm, cmgr = h.cmgr, am = am })
  return h, av, am
end

local function takeAt(list, startQN)
  for _, take in ipairs(list) do if take.startQN == startQN then return take end end
end

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
      local am = util.instantiate('arrangeManager', { cm = h.cm, tm = h.tm })
      local av = util.instantiate('arrangeView', { cm = h.cm, cmgr = h.cmgr, am = am })
      h.cmgr:push('arrange')
      av:setGridSize(8, 4)          -- a measured viewport, so cursorOnScreen is meaningful
      av:setCursor(0, 0)            -- park the caret on the take; nothing selected
      h.cmgr:invoke('arrangeNudgeForward')
      local am2 = util.instantiate('arrangeManager', { cm = h.cm, tm = h.tm })
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
      local am = util.instantiate('arrangeManager', { cm = h.cm, tm = h.tm })
      local av = util.instantiate('arrangeView', { cm = h.cm, cmgr = h.cmgr, am = am })
      h.cmgr:push('arrange')
      av:setGridSize(8, 4)
      av:setCursor(0, 0)
      av:scrollBy(20, 0)            -- a wheel-pan strands the caret above the band
      h.cmgr:invoke('arrangeDeleteTake')
      local am2 = util.instantiate('arrangeManager', { cm = h.cm, tm = h.tm })
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
      local am = util.instantiate('arrangeManager', { cm = h.cm, tm = h.tm })
      local av = util.instantiate('arrangeView', { cm = h.cm, cmgr = h.cmgr, am = am })
      h.cmgr:push('arrange')
      local takes = av:tracksTakes(0)
      av:setFocus(takes[1].take)    -- select the take at row 0
      av:setGridSize(8, 4)
      av:setCursor(4, 0)            -- park the caret on the take at row 4
      h.cmgr:invoke('arrangeDeleteTake')
      local remain = util.instantiate('arrangeManager', { cm = h.cm, tm = h.tm }):tracksTakes(0)
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
      local remain = util.instantiate('arrangeManager', { cm = h.cm, tm = h.tm }):tracksTakes(0)
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
      local now = util.instantiate('arrangeManager', { cm = h.cm, tm = h.tm }):tracksTakes(0)
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
      local now = util.instantiate('arrangeManager', { cm = h.cm, tm = h.tm }):tracksTakes(0)
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
      local now = util.instantiate('arrangeManager', { cm = h.cm, tm = h.tm }):tracksTakes(0)
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
      local now = util.instantiate('arrangeManager', { cm = h.cm, tm = h.tm }):tracksTakes(0)
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
      local now = util.instantiate('arrangeManager', { cm = h.cm, tm = h.tm }):tracksTakes(0)
      t.eq(#now, 4, 'two copies were added')
      t.eq(takeAt(now, 4) ~= nil and takeAt(now, 5) ~= nil, true, 'copies at 4 and 5')
      local n = 0; for _ in pairs(av:selectionSet()) do n = n + 1 end
      t.eq(n, 2, 'the selection now holds the two copies')
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
