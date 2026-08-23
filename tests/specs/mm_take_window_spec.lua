-- Integration spec: real midiManager + fakeReaper. Pins mm's length and
-- time-signature reads to the source rather than the item. A head-trimmed
-- instance starts inside its source, and tm's ppq frame runs from the source
-- origin, so anything measured from D_POSITION is out by the head.
-- See docs/arrangeManager.md § The take's window.

local t = require('support')

local realMM = require('realMidiManager')()

-- The shape am:trimHead leaves: the item start walked headQN forward with
-- D_STARTOFFS to match, so source ppq 0 sits headQN before the item.
-- Tempo 60 makes the fake's seconds and QN agree across both time frames.
local function headTrimmed(headQN, sourceQN, renderedQN)
  local fakeReaper = require('fakeReaper').new()
  _G.reaper = fakeReaper
  fakeReaper:setTempo(60)
  local take, item = 'take-window', 'item-window'
  fakeReaper:bindTake(take, item, 'track-window', sourceQN)
  fakeReaper.SetMediaItemInfo_Value(item, 'D_POSITION', headQN)
  fakeReaper.SetMediaItemInfo_Value(item, 'D_LENGTH', renderedQN or (sourceQN - headQN))
  fakeReaper.SetMediaItemTakeInfo_Value(take, 'D_STARTOFFS', headQN)
  fakeReaper:seedMidi(take, { ccs = {}, texts = {} })
  local mm = realMM(nil)
  mm:load(take)
  return mm, fakeReaper, item
end

local function itemRange(fakeReaper, item)
  local pos = fakeReaper.GetMediaItemInfo_Value(item, 'D_POSITION')
  return pos, pos + fakeReaper.GetMediaItemInfo_Value(item, 'D_LENGTH')
end

return {
  {
    name = 'setLength sizes the source from its origin: the item ends head QN sooner',
    run = function()
      local mm, fakeReaper, item = headTrimmed(4, 16)

      mm:setLength(8)

      local startQN, endQN = itemRange(fakeReaper, item)
      t.eq(startQN, 4, 'the start edge holds')
      t.eq(endQN,   8, 'the item ends where the source does, not 8 QN past its start')
      t.eq(mm:length(), 8 * mm:resolution(), 'the source is the length asked for')
    end,
  },
  {
    name = 'a source shrunk inside the head leaves a zero-length item, never a backwards one',
    run = function()
      local mm, fakeReaper, item = headTrimmed(4, 16)

      mm:setLength(2)

      local startQN, endQN = itemRange(fakeReaper, item)
      t.eq(startQN, 4, 'the start edge holds')
      t.eq(endQN,   4, 'the end floors at the start')
    end,
  },
  {
    name = 'timeSigs spans the whole source, so markers in the head and past the end land',
    run = function()
      -- Source [0,16), item [4,10): a marker at each of head, window and tail.
      local mm, fakeReaper = headTrimmed(4, 16, 6)
      fakeReaper:addTimeSigMarker(2,  3, 4)
      fakeReaper:addTimeSigMarker(8,  5, 8)
      fakeReaper:addTimeSigMarker(12, 7, 8)

      local sigs = mm:timeSigs()
      local ppqPerQN = mm:resolution()

      t.eq(#sigs, 4, 'the prevailing sig plus all three markers')
      t.deepEq(sigs[1], { ppq = 0,             num = 4, denom = 4 }, 'prevailing sig at the origin')
      t.deepEq(sigs[2], { ppq = 2  * ppqPerQN, num = 3, denom = 4 }, 'marker inside the head')
      t.deepEq(sigs[3], { ppq = 8  * ppqPerQN, num = 5, denom = 8 }, 'marker inside the window')
      t.deepEq(sigs[4], { ppq = 12 * ppqPerQN, num = 7, denom = 8 }, 'marker inside the tail')
    end,
  },
}
