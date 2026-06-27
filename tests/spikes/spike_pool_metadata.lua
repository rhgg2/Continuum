-- spike_pool_metadata.lua
--
-- Ground-truth proof for the diagnosis behind "parking a take on scratch
-- desyncs its notes from their metadata" (delete-the-last-copy variant).
--
-- The claim under test, in REAPER's own terms:
--
--   1. A note's uuid sidecar (type-15 note-notation text event,
--      "NOTE <chan> <pitch> custom ctm_<uuid>") lives in the *shared MIDI
--      source*. Two POOLED items therefore agree on every note's uuid.
--   2. The metadata blob keyed by that uuid (P_EXT:ctm_<uuid>) is *per-take*
--      extension data. It does NOT ride the pool. Editing it on one instance
--      leaves a pooled sibling stale.
--   3. MoveMediaItemToTrack (the park) is lossless for the moved take's OWN
--      ext-data — so the bug is the per-take/per-pool divergence, not the move.
--
-- Put together: author metadata on the bound instance, make a pooled copy,
-- edit the metadata, delete the authored instance, and the surviving copy is
-- parked carrying the note's uuid (pool-shared) but a stale/empty ctm_ blob
-- (per-take). The note is divorced from its metadata. That is the desync.
--
-- Run as a ReaScript action on a SCRATCH project. Single run, prints a verdict
-- table to the console, then deletes its own tracks (set CLEANUP=false to keep
-- the artifacts for manual inspection). All work is one undo block.

local reaper = reaper
local fmt    = string.format

local CLEANUP = true

----- Real persistence codec (so the blob format is Continuum's, not invented)

local here = debug.getinfo(1, 'S').source:match('^@?(.*)')
local root = here and here:match('^(.*)/tests/spikes/[^/]+$')
if root then package.path = root .. '/?.lua;' .. package.path end
local hasUtil, util = pcall(require, 'util')

local function ser(tbl)
  if hasUtil then return util.serialise(tbl, {}) end
  return fmt('detune\n%s', tostring(tbl.detune))
end
local function detuneOf(str)
  if not str then return nil end
  if hasUtil then local t = util.unserialise(str); return t and t.detune end
  return tonumber((str:match('detune%s*\n?%s*(%-?%d+)')))
end
local function b36(n) return hasUtil and util.toBase36(n) or tostring(n) end

----- Output

local function out(s) reaper.ShowConsoleMsg(tostring(s) .. '\n') end
local function banner(s) out(''); out('===== ' .. s) end
local function verdict(label, pass, detail)
  out(fmt('  [%s] %-34s %s', pass and 'PASS' or 'FAIL', label, detail or ''))
end

----- Take / pool helpers (raw API, mirroring midiManager + arrangeManager)

local CHAN0, PITCH, VEL = 0, 60, 100   -- C4, wire channel 0
local NOTE_PPQ, NOTE_END = 0, 240

local function poolGuidOf(item)
  local _, chunk = reaper.GetItemStateChunk(item, '', false)
  return chunk and chunk:match('POOLEDEVTS%s+({[^}]+})')
end

local function writeMeta(take, uuidTxt, tbl)
  reaper.GetSetMediaItemTakeInfo_String(take, 'P_EXT:ctm_' .. uuidTxt, ser(tbl), true)
  local ok, keys = reaper.GetSetMediaItemTakeInfo_String(take, 'P_EXT:ctm_keys', '', false)
  if not ok or not keys or not keys:find(uuidTxt, 1, true) then
    keys = (ok and keys ~= '') and (keys .. ',' .. uuidTxt) or uuidTxt
    reaper.GetSetMediaItemTakeInfo_String(take, 'P_EXT:ctm_keys', keys, true)
  end
end

local function authorNote(take, uuid, meta)
  reaper.MIDI_InsertNote(take, false, false, NOTE_PPQ, NOTE_END, CHAN0, PITCH, VEL, true)
  reaper.MIDI_InsertTextSysexEvt(take, false, false, NOTE_PPQ, 15,
    fmt('NOTE %d %d custom ctm_%s', CHAN0, PITCH, b36(uuid)))
  reaper.MIDI_Sort(take)
  writeMeta(take, b36(uuid), meta)
end

local function readMeta(take, uuidTxt)
  local ok, s = reaper.GetSetMediaItemTakeInfo_String(take, 'P_EXT:ctm_' .. uuidTxt, '', false)
  if ok and s and s ~= '' then return s end
  return nil
end

local function noteSidecarUuids(take)
  local found = {}
  local _, _, _, textCount = reaper.MIDI_CountEvts(take)
  for i = 0, textCount - 1 do
    local ok, _, _, _, et, msg = reaper.MIDI_GetTextSysexEvt(take, i)
    if ok and et == 15 then
      local u = msg:match('custom%s+ctm_(%S+)%s*$')
      if u then found[#found + 1] = u end
    end
  end
  return found
end

local function hasUuid(list, uuidTxt)
  for _, u in ipairs(list) do if u == uuidTxt then return true end end
  return false
end

-- Verbatim chunk clone keeping the same POOLEDEVTS guid → a pooled instance,
-- exactly as arrangeManager.cloneMidiItem(rePool=false) does it.
local function pooledCopy(track, srcItem, atQN)
  local _, chunk = reaper.GetItemStateChunk(srcItem, '', false)
  local item = reaper.CreateNewMIDIItemInProj(track, atQN, atQN + 1, true)
  reaper.SetItemStateChunk(item, chunk, false)
  reaper.SetMediaItemInfo_Value(item, 'D_POSITION', reaper.TimeMap2_QNToTime(0, atQN))
  return item
end

local function newTrack(name, parkLike)
  local idx = reaper.CountTracks(0)
  reaper.InsertTrackAtIndex(idx, false)
  local tr = reaper.GetTrack(0, idx)
  reaper.GetSetMediaTrackInfo_String(tr, 'P_NAME', name, true)
  if parkLike then
    reaper.SetMediaTrackInfo_Value(tr, 'B_SHOWINTCP', 0)
    reaper.SetMediaTrackInfo_Value(tr, 'B_SHOWINMIXER', 0)
    reaper.SetMediaTrackInfo_Value(tr, 'B_MUTE', 1)
  end
  return tr
end

----------- RUN

reaper.ClearConsole()
reaper.Undo_BeginBlock()

out('=== spike_pool_metadata: pooled note uuids vs per-take ctm_ metadata ===')
out(hasUtil and 'codec: real util.serialise' or 'codec: FALLBACK (util not found) — blob format approximated')

local home  = newTrack('ctm_pool_spike')
local park  = newTrack('ctm_pool_spike_scratch', true)
local U1, U9 = 1, 9        -- uuid 1 = pooled note; uuid 9 = the lossless-move control

-- A: the bound/authored instance.
local itemA = reaper.CreateNewMIDIItemInProj(home, 0, 1, true)
local takeA = reaper.GetActiveTake(itemA)
authorNote(takeA, U1, { evType = 'note', detune = -11 })

--------------------------------------------------------------------- Control
-- Claim 3: MoveMediaItemToTrack does not lose the moved take's own ext-data.
banner('Control: is the park (MoveMediaItemToTrack) itself lossless?')
local itemC = reaper.CreateNewMIDIItemInProj(home, 8, 9, true)   -- own fresh pool
local takeC = reaper.GetActiveTake(itemC)
authorNote(takeC, U9, { evType = 'note', detune = -77 })
reaper.MoveMediaItemToTrack(itemC, park)
local movedDetune = detuneOf(readMeta(takeC, b36(U9)))
verdict('moved take keeps own metadata', movedDetune == -77,
        fmt('detune after move = %s (authored -77)', tostring(movedDetune)))

----------------------------------------------------------- Claims 1 & 3
banner('Claim 1: are note uuid sidecars shared across a pooled copy?')
local itemB = pooledCopy(home, itemA, 2)
local takeB = reaper.GetActiveTake(itemB)
local gA, gB = poolGuidOf(itemA), poolGuidOf(itemB)
verdict('pool guids identical', gA ~= nil and gA == gB, fmt('A=%s  B=%s', tostring(gA), tostring(gB)))
verdict('note uuid present in copy', hasUuid(noteSidecarUuids(takeB), b36(U1)),
        fmt('copy sidecars = {%s}', table.concat(noteSidecarUuids(takeB), ',')))
local birthDetune = detuneOf(readMeta(takeB, b36(U1)))
out(fmt('   (pooled copy ctm_ at birth: detune = %s — chunk-clone %s carry P_EXT)',
        tostring(birthDetune), birthDetune ~= nil and 'DOES' or 'does NOT'))

------------------------------------------------------------------ Claim 2
banner('Claim 2: does editing metadata on A reach the pooled copy B?')
writeMeta(takeA, b36(U1), { evType = 'note', detune = -50 })   -- author detune after the copy exists
local aDetune = detuneOf(readMeta(takeA, b36(U1)))
local bDetune = detuneOf(readMeta(takeB, b36(U1)))
verdict('edit stayed local to A', aDetune == -50 and bDetune ~= -50,
        fmt('A=%s  B=%s', tostring(aDetune), tostring(bDetune)))

------------------------------------------------------- The bug, end to end
banner('THE BUG: delete the authored instance, park the survivor')
reaper.DeleteTrackMediaItem(home, itemA)     -- delete the last *authored* copy
reaper.MoveMediaItemToTrack(itemB, park)     -- deleteTake would park this survivor
local survivorUuids  = noteSidecarUuids(takeB)
local survivorDetune = detuneOf(readMeta(takeB, b36(U1)))
out(fmt('   survivor note carries uuid %s : %s', b36(U1),
        hasUuid(survivorUuids, b36(U1)) and 'YES (pool-shared)' or 'no'))
out(fmt('   survivor ctm_ metadata        : detune = %s', tostring(survivorDetune)))
out(fmt('   user authored                 : detune = -50'))
local desynced = hasUuid(survivorUuids, b36(U1)) and survivorDetune ~= -50
verdict('survivor desynced from metadata', desynced,
        desynced and 'note kept, authored detune lost/stale → DESYNC reproduced'
                 or  'no desync — diagnosis NOT confirmed')

banner('Verdict')
out('  Diagnosis confirmed iff: control PASS, claims 1/2 PASS, and the bug reproduces.')
out('  Confirmed = uuid sidecars ride the pool, ctm_ metadata does not.')

if CLEANUP then
  reaper.DeleteTrack(home)
  reaper.DeleteTrack(park)
  out('\n(cleaned up spike tracks; set CLEANUP=false to keep them)')
end

reaper.Undo_EndBlock('spike_pool_metadata', -1)
reaper.UpdateArrange()
