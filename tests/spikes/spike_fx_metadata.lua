-- spike_fx_metadata.lua
--
-- Verification spike for design/wiring-implicit-graph.md § Decoration.
-- Run as a ReaScript action on a SCRATCH project.
--
-- Question: where can per-FX metadata (an fx-node's position) live so it
-- survives the things REAPER does to FX? The design hypothesises a per-FX
-- SetNamedConfigParm "ext" channel but flags it unverified — the API docs
-- list only a FIXED key set, with no arbitrary-ext equivalent to the
-- track/item P_EXT mechanism. So we probe THREE candidate channels:
--
--   C1  arbitrary FX named-config key   SetNamedConfigParm(tr, fx, "ext.ctm…")
--   C2  track P_EXT keyed by FX GUID     GetSetMediaTrackInfo_String P_EXT:…
--   C3  renamed_name field abuse         SetNamedConfigParm(tr, fx, "renamed_name")
--
-- against five survival conditions:
--
--   R  round-trip            write then read back in-session
--   C  in chunk              value appears in GetTrackStateChunk (→ survives save)
--   U  undo                  a later overwrite, undone, restores the value
--   T  track duplicate       copy reachable from the duplicated track
--   M  FX move to new track  TrackFX_CopyToTrack(move=true) — the crux
--
-- M is the load-bearing one: compile freely re-places FX onto emergent
-- tracks, so a channel that does NOT travel with the FX (C2) orphans the
-- position on every recompile.
--
-- Phase A (first run):  runs R/C/U/T/M for all three channels on scratch
--                       tracks, lays down one probe FX, prints the table.
-- Phase B (second run): re-reads the probe after save+reload, confirms the
--                       channels that claimed persistence actually persist,
--                       and that the FX GUID (C2's key) is stable.
--
-- Between runs: save (Ctrl-S), close REAPER, reopen, re-run. Phase + the
-- probe GUID carry across via ExtState ("ctm_fxspike"). Phase B cleans up.

local reaper = reaper
local fmt    = string.format

local VAL    = "pos:120,40|@ctmspike"
local VAL2   = "pos:999,999|@ctmspike"
local MARKER = "ctmspike"
local PROBE_FX = "ReaEQ"   -- stock VST, present on every install

----- Output

local function out(s) reaper.ShowConsoleMsg(tostring(s) .. "\n") end

local results = {}
local function record(tag, status, detail)
  results[#results+1] = { tag = tag, status = status }
  out(fmt("%-7s  %-4s  %s", tag, status, detail or ""))
end
local function pass(tag, d) record(tag, "PASS", d) end
local function fail(tag, d) record(tag, "FAIL", d) end
local function info(tag, d) record(tag, "INFO", d) end

----- ExtState (carries phase + probe GUID across the restart)

local NS = "ctm_fxspike"
local function getES(k)    return reaper.GetExtState(NS, k) end
local function setES(k, v) reaper.SetExtState(NS, k, v, false) end
local function clearES(k)  reaper.DeleteExtState(NS, k, false) end

----- Track / FX helpers

local function findTrack(name)
  for i = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, i)
    local _, n = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
    if n == name then return tr end
  end
end

local function ensureTrack(name)
  local tr = findTrack(name)
  if tr then return tr end
  reaper.InsertTrackAtIndex(reaper.CountTracks(0), true)
  tr = reaper.GetTrack(0, reaper.CountTracks(0) - 1)
  reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", name, true)
  return tr
end

local function deleteTrack(name)
  local tr = findTrack(name)
  if tr then reaper.DeleteTrack(tr) end
end

-- Fresh track carrying exactly one probe FX. Returns track, fxIdx, guid.
local function freshProbe(name)
  local tr = ensureTrack(name)
  while reaper.TrackFX_GetCount(tr) > 0 do reaper.TrackFX_Delete(tr, 0) end
  local fxIdx = reaper.TrackFX_AddByName(tr, PROBE_FX, false, -1)
  return tr, fxIdx, reaper.TrackFX_GetFXGUID(tr, fxIdx)
end

local function chunkHas(track, needle)
  local _, chunk = reaper.GetTrackStateChunk(track, "", false)
  return chunk and chunk:find(needle, 1, true) ~= nil
end

----- Channel adapters: write(track, fxIdx, guid, val) / read → ok, value

local C1_KEYS = { "ext.ctm.spike", "ctm.spike", "user.ctm.spike" }

-- C1 probes several spellings; remembers the first that takes a write.
local c1Key = nil
local function c1Write(track, fxIdx, _guid, val)
  for _, key in ipairs(C1_KEYS) do
    if reaper.TrackFX_SetNamedConfigParm(track, fxIdx, key, val) then
      c1Key = key
      return true
    end
  end
  return false
end
local function c1Read(track, fxIdx)
  if not c1Key then return false end
  return reaper.TrackFX_GetNamedConfigParm(track, fxIdx, c1Key)
end

local function c2Pkey(guid) return "P_EXT:ctm.fxmeta." .. guid end
local function c2Write(track, _fxIdx, guid, val)
  return reaper.GetSetMediaTrackInfo_String(track, c2Pkey(guid), val, true)
end
local function c2Read(track, _fxIdx, guid)
  return reaper.GetSetMediaTrackInfo_String(track, c2Pkey(guid), "", false)
end

local function c3Write(track, fxIdx, _guid, val)
  return reaper.TrackFX_SetNamedConfigParm(track, fxIdx, "renamed_name", val)
end
local function c3Read(track, fxIdx)
  return reaper.TrackFX_GetNamedConfigParm(track, fxIdx, "renamed_name")
end

local CHANNELS = {
  { id = "C1", name = "fx-namedcfg",  write = c1Write, read = c1Read },
  { id = "C2", name = "track-P_EXT",  write = c2Write, read = c2Read },
  { id = "C3", name = "renamed_name", write = c3Write, read = c3Read },
}

----- Conditions (each on its own fresh track, so they don't interfere)

local function condR(ch)
  local tr, fxIdx, guid = freshProbe("ctm_fxspike_R")
  local wrote = ch.write(tr, fxIdx, guid, VAL)
  if not wrote then fail(ch.id .. ".R", "write rejected (channel unavailable)"); return false end
  local ok, got = ch.read(tr, fxIdx, guid)
  if ok and got == VAL then pass(ch.id .. ".R", "read back exact")
  else fail(ch.id .. ".R", fmt("ok=%s got=%q", tostring(ok), tostring(got))) end
  return wrote
end

local function condC(ch)
  local tr, fxIdx, guid = freshProbe("ctm_fxspike_C")
  if not ch.write(tr, fxIdx, guid, VAL) then info(ch.id .. ".C", "skipped (no write)"); return end
  if chunkHas(tr, MARKER) then pass(ch.id .. ".C", "value serialises into track chunk")
  else fail(ch.id .. ".C", "marker absent from chunk — will NOT survive save") end
end

-- MUST NOT run inside an enclosing Undo block: REAPER undo blocks are
-- reference-counted, so nested Begin/End coalesce and DoUndo2 would hit an
-- unrelated prior point. Run this before opening any outer block.
local function condU(ch)
  if ch.id == "C1" and not c1Key then info(ch.id .. ".U", "skipped (no write)"); return end

  reaper.Undo_BeginBlock()
  local tr, fxIdx, guid = freshProbe("ctm_fxspike_U")
  ch.write(tr, fxIdx, guid, VAL)
  reaper.Undo_EndBlock("ctm_fxspike U setup", -1)

  reaper.Undo_BeginBlock()
  ch.write(tr, fxIdx, guid, VAL2)
  reaper.Undo_EndBlock("ctm_fxspike U mutate", -1)
  reaper.Undo_DoUndo2(0)

  -- Three outcomes: (a) mutate rode undo → value back to VAL; (b) mutate
  -- created no undo point so DoUndo2 ate the setup block → track gone;
  -- (c) DoUndo2 was inert → still VAL2. (b)/(c) both mean a standalone
  -- metadata write is not independently undoable.
  if not reaper.ValidatePtr2(0, tr, "MediaTrack*") then
    info(ch.id .. ".U", "standalone write created no undo point (DoUndo2 ate setup)")
    return
  end
  local ok, got = ch.read(tr, fxIdx, guid)
  if ok and got == VAL then pass(ch.id .. ".U", "write rode undo — prior value restored")
  elseif got == VAL2 then info(ch.id .. ".U", "undo inert — standalone write not undoable")
  else fail(ch.id .. ".U", fmt("after undo: ok=%s got=%q", tostring(ok), tostring(got))) end
  deleteTrack("ctm_fxspike_U")
end

local function condT(ch)
  local tr, fxIdx, guid = freshProbe("ctm_fxspike_T")
  if not ch.write(tr, fxIdx, guid, VAL) then info(ch.id .. ".T", "skipped (no write)"); return end

  reaper.SetOnlyTrackSelected(tr)
  reaper.Main_OnCommand(40062, 0)  -- Track: Duplicate tracks
  local dup = reaper.GetSelectedTrack(0, 0)
  if not dup or dup == tr then fail(ch.id .. ".T", "could not locate duplicated track"); return end

  -- The dup's FX has a NEW guid; C2 keyed by the ORIGINAL guid still finds
  -- the (now orphaned) entry — data travels, key desyncs. Report by-orig
  -- and by-new separately so the desync is visible.
  local newGuid = reaper.TrackFX_GetFXGUID(dup, 0)
  local okOrig, gotOrig = ch.read(dup, 0, guid)
  local okNew,  gotNew  = ch.read(dup, 0, newGuid)
  if okNew and gotNew == VAL then
    pass(ch.id .. ".T", "value reachable by current key on the copy")
  elseif okOrig and gotOrig == VAL then
    info(ch.id .. ".T", "data copied but keyed by ORIGINAL guid (key desync on dup)")
  else
    fail(ch.id .. ".T", fmt("orig=%q new=%q", tostring(gotOrig), tostring(gotNew)))
  end
  reaper.DeleteTrack(dup)
end

local function condM(ch)
  local tr, fxIdx, guid = freshProbe("ctm_fxspike_M")
  if not ch.write(tr, fxIdx, guid, VAL) then info(ch.id .. ".M", "skipped (no write)"); return end
  local dest = ensureTrack("ctm_fxspike_M_dest")
  while reaper.TrackFX_GetCount(dest) > 0 do reaper.TrackFX_Delete(dest, 0) end

  reaper.TrackFX_CopyToTrack(tr, fxIdx, dest, 0, true)  -- is_move = true
  local movedGuid = reaper.TrackFX_GetFXGUID(dest, 0)
  -- C2 lives on the SOURCE track; after a move the dest has no entry. Read
  -- on dest by both old + moved guid; both should miss for C2 — that miss
  -- IS the finding (position orphaned when compile relocates the FX).
  local okOld, gotOld = ch.read(dest, 0, guid)
  local okNew, gotNew = ch.read(dest, 0, movedGuid)
  if (okNew and gotNew == VAL) or (okOld and gotOld == VAL) then
    pass(ch.id .. ".M", fmt("travelled with the FX (guid %s)", movedGuid == guid and "preserved" or "changed"))
  else
    fail(ch.id .. ".M", "lost on FX move — does NOT travel with the FX")
  end
  deleteTrack("ctm_fxspike_M_dest")
end

----- Phase A

local function cleanupScratch()
  for _, suffix in ipairs({ "R", "C", "U", "T", "M", "M_dest" }) do
    deleteTrack("ctm_fxspike_" .. suffix)
  end
end

local function layProbe()
  local tr, fxIdx, guid = freshProbe("ctm_fxspike_probe")
  setES("probeGuid", guid)
  for _, ch in ipairs(CHANNELS) do ch.write(tr, fxIdx, guid, VAL) end
end

local function runPhaseA()
  reaper.ShowConsoleMsg("")
  out("===== fx-metadata spike — phase A =====")
  out(fmt("channels: C1=fx-namedcfg  C2=track-P_EXT  C3=renamed_name"))
  out("")

  -- Undo tests first, OUTSIDE any enclosing block (see condU note).
  for _, ch in ipairs(CHANNELS) do condU(ch) end
  out("")

  for _, ch in ipairs(CHANNELS) do
    out(fmt("----- %s (%s)", ch.id, ch.name))
    local available = condR(ch)
    condC(ch)
    if available or ch.id == "C2" then  -- C2 always "writes"; gate the rest on R
      condT(ch)
      condM(ch)
    end
    out("")
  end

  layProbe()
  cleanupScratch()
  setES("phase", "B")
  if c1Key then setES("c1Key", c1Key) end

  reaper.UpdateArrange()

  out("Phase A done. For phase B: save (Ctrl-S), close REAPER, reopen, re-run.")
end

----- Phase B

local function runPhaseB()
  reaper.ShowConsoleMsg("")
  out("===== fx-metadata spike — phase B (after save+reload) =====")
  reaper.Undo_BeginBlock()

  local tr = findTrack("ctm_fxspike_probe")
  c1Key = getES("c1Key") ~= "" and getES("c1Key") or nil
  local storedGuid = getES("probeGuid")
  if not tr then
    fail("probe", "ctm_fxspike_probe track not found — was the project saved between phases?")
  else
    local liveGuid = reaper.TrackFX_GetFXGUID(tr, 0)
    if liveGuid == storedGuid then pass("guid", "FX GUID stable across save+reload (C2's key holds)")
    else fail("guid", fmt("GUID changed: %s → %s", storedGuid, liveGuid)) end

    for _, ch in ipairs(CHANNELS) do
      local ok, got = ch.read(tr, 0, storedGuid)
      if ok and got == VAL then pass(ch.id .. ".save", "survived save+reload")
      elseif ch.id == "C1" and not c1Key then info(ch.id .. ".save", "n/a (channel unavailable in phase A)")
      else fail(ch.id .. ".save", fmt("ok=%s got=%q", tostring(ok), tostring(got))) end
    end
  end

  deleteTrack("ctm_fxspike_probe")
  clearES("phase"); clearES("probeGuid"); clearES("c1Key")
  reaper.Undo_EndBlock("ctm_fxspike phase B", -1)
  reaper.UpdateArrange()
  out("Spike complete. Save again to drop the probe track from disk.")
end

----- Summary + main

local function summarise()
  out("")
  out("===== summary =====")
  local tally = { PASS = 0, FAIL = 0, INFO = 0 }
  for _, r in ipairs(results) do tally[r.status] = (tally[r.status] or 0) + 1 end
  out(fmt("PASS=%d  FAIL=%d  INFO=%d", tally.PASS, tally.FAIL, tally.INFO))
end

if getES("phase") == "B" then runPhaseB() else runPhaseA() end
summarise()
