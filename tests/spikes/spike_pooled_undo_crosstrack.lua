-- Repro: REAPER undo cannot see pooled-MIDI edits when the pool's source is the
-- native CreateNewMIDIItemInProj object AND a sibling sits on another track.
-- Run in an EMPTY project tab; read the console.
--   sick pair:   only g1 mints — g2/g3 produce no undo point at all.
--   healed pair: identity SetItemStateChunk on the native original; all mint.

local function msg(s) reaper.ShowConsoleMsg(s .. '\n') end

local function freshGuids(chunk)
  return (chunk
    :gsub('(IGUID%s+){[^}]+}',      function(pre) return pre .. reaper.genGuid('') end)
    :gsub('(%f[%w]GUID%s+){[^}]+}', function(pre) return pre .. reaper.genGuid('') end))
end

local function setFirstVel(take, vel)
  local _, blob = reaper.MIDI_GetAllEvts(take, '')
  local pos, parts, edited = 1, {}, nil
  while pos <= #blob do
    local offset, flag, m, nextPos = string.unpack('i4Bs4', blob, pos)
    if not edited and #m == 3 and m:byte(1) & 0xF0 == 0x90 and m:byte(3) > 0 then
      m = m:sub(1, 2) .. string.char(vel); edited = true
    end
    parts[#parts+1] = string.pack('i4Bs4', offset, flag, m)
    pos = nextPos
  end
  reaper.MIDI_SetAllEvts(take, table.concat(parts))
  reaper.MIDI_Sort(take)
end

-- native original on track A, chunk-attached pooled clone on track B
local function crossTrackPair()
  local idx = reaper.CountTracks(0)
  reaper.InsertTrackAtIndex(idx, false)
  local trackA = reaper.GetTrack(0, idx)
  reaper.InsertTrackAtIndex(idx + 1, false)
  local trackB = reaper.GetTrack(0, idx + 1)
  local native = reaper.CreateNewMIDIItemInProj(trackA, 0, 4, true)
  local take = reaper.GetActiveTake(native)
  reaper.MIDI_InsertNote(take, false, false, 0, 960, 1, 60, 100, false)
  reaper.MIDI_Sort(take)
  local _, chunk = reaper.GetItemStateChunk(native, '', false)
  local clone = reaper.AddMediaItemToTrack(trackB)
  reaper.SetItemStateChunk(clone, freshGuids(chunk), false)
  return native, clone, trackB
end

local function mintRun(name, editItem, track)
  for gestureIdx, vel in ipairs({ 70, 50, 30 }) do
    local take = reaper.GetActiveTake(editItem)
    reaper.Undo_BeginBlock()
    setFirstVel(take, vel)
    reaper.MarkTrackItemsDirty(track, editItem)
    reaper.Undo_EndBlock(name .. ' g' .. gestureIdx, -1)
    local top = reaper.Undo_CanUndo2(0)
    local expected = name .. ' g' .. gestureIdx
    msg(('%-8s g%d: %s  (undo top: %s)'):format(
      name, gestureIdx, top == expected and 'minted' or 'NO POINT', top))
  end
end

msg('--- cross-track pooled undo ---')
local native, clone, trackB = crossTrackPair()
mintRun('sick', clone, trackB)

local native2, clone2, trackB2 = crossTrackPair()
local _, c = reaper.GetItemStateChunk(native2, '', false)
reaper.SetItemStateChunk(native2, c, false)   -- the heal
mintRun('healed', clone2, trackB2)
