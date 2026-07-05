-- test_setallevts_hang.lua
--
-- Does a per-event release survive a same-frame MIDI_SetAllEvts wipe?
--
-- SETUP
--   1. One track with a SUSTAINED instrument (organ / saw pad) so a hung
--      note rings audibly. Repeat OFF.
--   2. One MIDI item on it, >= 2 bars long, selected. Its content gets
--      overwritten by this script.
--   3. Set MODE below, run. Run once per mode, listen each time.
--
-- WHAT YOU HEAR
--   The item is rewritten to a single held C4 (60). Playback starts at the
--   item head; ~1 beat in, the trial fires and swaps the blob to D4 (62).
--   - 60 keeps ringing to the item end  -> the old note HUNG.
--   - 60 stops the instant the trial fires -> it was RELEASED cleanly.
--
-- READING THE RESULT
--   baseline    -> must HANG. Confirms the rig reproduces the bug.
--   same_frame  -> if it RELEASES, the fix is a tiny pre-pass. If it HANGS,
--                  the wipe cancels the release signal -> need split_frame.
--   split_frame -> release one frame, SetAllEvts the next. If this RELEASES
--                  but same_frame hung, the flush must straddle a frame.

local MODE = "baseline"   -- "baseline" | "same_frame" | "split_frame"

local function log(s) reaper.ShowConsoleMsg(s .. "\n") end

local item = reaper.GetSelectedMediaItem(0, 0)
if not item then log("select a MIDI item first"); return end
local take = reaper.GetActiveTake(item)
if not (take and reaper.TakeIsMIDI(take)) then log("active take isn't MIDI"); return end

local ppqPerQN = reaper.MIDI_GetPPQPosFromProjQN(take, 1) - reaper.MIDI_GetPPQPosFromProjQN(take, 0)
local SPAN     = math.floor(ppqPerQN * 8)   -- 2 bars of 4/4

local function evt(offset, msg) return string.pack('<i4Bi4', offset, 0, #msg) .. msg end
local function noteBlob(pitch)
  return evt(0,    string.char(0x90, pitch, 96))   -- note-on
      .. evt(SPAN, string.char(0x80, pitch, 0))    -- note-off
      .. evt(0,    string.char(0xB0, 0x7B, 0))     -- REAPER all-notes-off tail
end

-- Reset to a clean, sounding C4 and start playback from the item head.
reaper.MIDI_SetAllEvts(take, noteBlob(60))
reaper.MIDI_Sort(take)
reaper.SetEditCurPos(reaper.GetMediaItemInfo_Value(item, "D_POSITION"), false, false)
reaper.OnPlayButton()

local fired, splitPending = false, false

local function tick()
  if reaper.GetPlayState() & 1 ~= 1 then return reaper.defer(tick) end
  local ppq = reaper.MIDI_GetPPQPosFromProjTime(take, reaper.GetPlayPosition())

  if splitPending then                        -- split_frame: fire the wipe now
    reaper.MIDI_SetAllEvts(take, noteBlob(62))
    return log("split_frame: SetAllEvts one frame after release -- does 60 stop?")
  end
  if fired then return end                     -- baseline/same_frame done; let it ring

  local inside = ppq > ppqPerQN and ppq < SPAN - ppqPerQN
  if not inside then return reaper.defer(tick) end

  fired = true
  if MODE == "baseline" then
    reaper.MIDI_SetAllEvts(take, noteBlob(62))
    log("baseline: SetAllEvts only -- expect 60 HANGS to item end")
  elseif MODE == "same_frame" then
    reaper.MIDI_DeleteNote(take, 0)            -- release the sounding 60
    reaper.MIDI_SetAllEvts(take, noteBlob(62)) -- swap to 62, SAME frame
    log("same_frame: release + SetAllEvts, one frame -- does 60 stop?")
  elseif MODE == "split_frame" then
    reaper.MIDI_DeleteNote(take, 0)            -- release now
    splitPending = true                        -- SetAllEvts next frame
    reaper.defer(tick)
  end
end

reaper.defer(tick)
