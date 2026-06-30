-- spike_capture_blobs.lua
--
-- Capture spike for the blob-based read path (design/MIDIUtils review).
-- Run as a ReaScript action on a SCRATCH project.
--
-- Builds a handful of MIDI takes with known event configurations, then for
-- each one captures BOTH:
--   * the raw MIDI_GetAllEvts blob (the bytes parseAllEvts will parse), and
--   * the per-event API ground truth (MIDI_GetNote/GetCC/GetCCShape/
--     GetTextSysexEvt), decoded into the exact record shape mm:load
--     currently produces.
--
-- The pair is the independent pin for the new parser: parseAllEvts(blob) must
-- reproduce the ground-truth records field-for-field, INCLUDING per-type idx.
-- The fake harness can't validate the new parser (it would share the same
-- format assumptions), so these come off real REAPER.
--
-- The third fixture (bezier_sidecar) settles the one open question: does
-- REAPER's text/sysex index space — what uuidIdx walks — INCLUDE the CCBZ
-- bezier meta event? The console raw-walk shows CCBZ in the byte stream; the
-- captured `texts` array shows whether the API surfaces it and at what idx.
--
-- Output: tests/fixtures/midi_blobs.lua (self-contained; defines its own
-- unhex helper and returns the fixture table). Adds + deletes one scratch
-- track ("ctm_capture_scratch"); wrapped in an undo block.

local reaper = reaper
local fmt = string.format

----- Output

local function out(s) reaper.ShowConsoleMsg(tostring(s) .. '\n') end

local function hex(s)            -- spaced, for console
  local t = {}
  for i = 1, #s do t[i] = fmt('%02X', s:byte(i)) end
  return table.concat(t, ' ')
end

local function hexc(s)           -- compact, for fixture storage
  return (hex(s):gsub(' ', ''))
end

----- Decode tables (mirror midiManager's, so ground truth = load's record shape)

local chanMsgEvTypes = { [0xA0] = 'pa', [0xB0] = 'cc', [0xC0] = 'pc', [0xD0] = 'at', [0xE0] = 'pb' }
local shapeNames     = { [0] = 'step', [1] = 'linear', [2] = 'slow',
                         [3] = 'fast-start', [4] = 'fast-end', [5] = 'bezier' }

----- Track / item helpers

local function findTrack(name)
  for i = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, i)
    local _, n = reaper.GetSetMediaTrackInfo_String(tr, 'P_NAME', '', false)
    if n == name then return tr end
  end
end

local function ensureTrack(name)
  local tr = findTrack(name)
  if tr then return tr end
  reaper.InsertTrackAtIndex(reaper.CountTracks(0), true)
  tr = reaper.GetTrack(0, reaper.CountTracks(0) - 1)
  reaper.GetSetMediaTrackInfo_String(tr, 'P_NAME', name, true)
  return tr
end

local function clearTrack(track)
  for i = reaper.CountTrackMediaItems(track) - 1, 0, -1 do
    reaper.DeleteTrackMediaItem(track, reaper.GetTrackMediaItem(track, i))
  end
end

local function newTake(track)
  local item = reaper.CreateNewMIDIItemInProj(track, 0, 8, false)
  return reaper.GetActiveTake(item)
end

----- Event insertion (all under one DisableSort/Sort bracket per take)

local function insNote(take, ppq, endppq, chan0, pitch, vel, sel, muted)
  reaper.MIDI_InsertNote(take, sel or false, muted or false, ppq, endppq, chan0, pitch, vel, true)
end

local function insCC(take, ppq, chanmsg, chan0, msg2, msg3, sel, muted)
  reaper.MIDI_InsertCC(take, sel or false, muted or false, ppq, chanmsg, chan0, msg2, msg3)
end

local function insText(take, ppq, eventtype, body)
  reaper.MIDI_InsertTextSysexEvt(take, false, false, ppq, eventtype, body)
end

-- Set a CC's shape by matching (ppq, msg2) after the sort settled its index.
local function setShape(take, ppq, msg2, shape, tension)
  local _, _, ccCount = reaper.MIDI_CountEvts(take)
  for i = 0, ccCount - 1 do
    local ok, _, _, p, _, _, m2 = reaper.MIDI_GetCC(take, i)
    if ok and p == ppq and m2 == msg2 then
      reaper.MIDI_SetCCShape(take, i, shape, tension or 0, true)
      return
    end
  end
end

----- Ground truth: per-event API, decoded into mm:load's record shape

local function groundTruth(take)
  local notes, ccs, texts = {}, {}, {}
  local _, noteCount, ccCount, textCount = reaper.MIDI_CountEvts(take)

  for i = 0, noteCount - 1 do
    local ok, _, muted, ppq, endppq, chan, pitch, vel = reaper.MIDI_GetNote(take, i)
    if ok then
      local n = { idx = i, evType = 'note', ppq = ppq, endppq = endppq,
                  chan = chan + 1, pitch = pitch, vel = vel }
      if muted then n.muted = true end
      notes[#notes + 1] = n
    end
  end

  for i = 0, ccCount - 1 do
    local ok, _, muted, ppq, chanmsg, chan, msg2, msg3 = reaper.MIDI_GetCC(take, i)
    if ok then
      local evType = chanMsgEvTypes[chanmsg] or ('chanmsg_' .. chanmsg)
      local c = { idx = i, ppq = ppq, evType = evType, chan = chan + 1 }
      if     evType == 'pa' then c.pitch, c.vel = msg2, msg3
      elseif evType == 'cc' then c.cc,    c.val = msg2, msg3
      elseif evType == 'pc' or evType == 'at' then c.val = msg2
      elseif evType == 'pb' then c.val = ((msg3 << 7) | msg2) - 8192
      end
      local _, shape, tension = reaper.MIDI_GetCCShape(take, i)
      c.shape = shapeNames[shape] or 'step'
      if c.shape == 'bezier' then c.tension = tension end
      if muted then c.muted = true end
      ccs[#ccs + 1] = c
    end
  end

  for i = 0, textCount - 1 do
    local ok, _, _, ppq, eventtype, msg = reaper.MIDI_GetTextSysexEvt(take, i)
    if ok then
      texts[#texts + 1] = { idx = i, ppq = ppq, eventtype = eventtype, msg = msg }
    end
  end

  return notes, ccs, texts
end

----- Console diagnostics: raw byte walk (excludes the 12-byte tail)

local function classify(b1, b3)
  if not b1 then return 'empty' end
  if b1 == 0xFF then return 'meta' end
  if b1 == 0xF0 then return 'sysex' end
  if b1 >= 0x90 and b1 < 0xA0 and (b3 or 0) ~= 0 then return 'note-on' end
  if b1 >= 0x80 and b1 < 0xA0 then return 'note-off' end
  if b1 >= 0xA0 and b1 < 0xF0 then return 'cc(' .. fmt('0x%02X', b1 & 0xF0) .. ')' end
  return 'other'
end

local function walkBlob(blob)
  local pos, ppq, n = 1, 0, #blob
  while pos < n - 12 do
    local offset, flags, msg, np = string.unpack('i4Bs4', blob, pos)
    ppq = ppq + offset
    local b1, b2, b3 = msg:byte(1), msg:byte(2), msg:byte(3)
    local label = classify(b1, b3)
    local extra = ''
    if b1 == 0xFF and b2 == 15 and msg:sub(3, 7) == 'CCBZ ' then extra = '  <<< CCBZ' end
    out(fmt('  ppq=%-6d flags=0x%02X shape=%d  %-10s  %s%s',
            ppq, flags, (flags >> 4) & 7, label, hex(msg), extra))
    pos = np
  end
end

----- Fixture serialisation (self-contained Lua source)

local function noteSrc(nt)
  local m = nt.muted and ', muted = true' or ''
  return fmt("      { idx = %d, evType = 'note', ppq = %d, endppq = %d, chan = %d, pitch = %d, vel = %d%s },",
             nt.idx, nt.ppq, nt.endppq, nt.chan, nt.pitch, nt.vel, m)
end

local function ccSrc(c)
  local p = { fmt('idx = %d', c.idx), fmt('ppq = %d', c.ppq),
              fmt("evType = '%s'", c.evType), fmt('chan = %d', c.chan) }
  if c.cc    then p[#p + 1] = fmt('cc = %d', c.cc) end
  if c.pitch then p[#p + 1] = fmt('pitch = %d', c.pitch) end
  if c.vel   then p[#p + 1] = fmt('vel = %d', c.vel) end
  if c.val   then p[#p + 1] = fmt('val = %d', c.val) end
  p[#p + 1] = fmt("shape = '%s'", c.shape)
  if c.tension then p[#p + 1] = fmt('tension = %.6g', c.tension) end
  if c.muted   then p[#p + 1] = 'muted = true' end
  return '      { ' .. table.concat(p, ', ') .. ' },'
end

local function textSrc(t)
  return fmt("      { idx = %d, ppq = %d, eventtype = %d, msg = unhex('%s') },",
             t.idx, t.ppq, t.eventtype, hexc(t.msg))
end

local function fixtureSrc(name, blob, notes, ccs, texts)
  local lines = { fmt('  {'), fmt("    name = '%s',", name),
                  fmt("    blob = unhex('%s'),", hexc(blob)), '    notes = {' }
  for _, n in ipairs(notes) do lines[#lines + 1] = noteSrc(n) end
  lines[#lines + 1] = '    },'
  lines[#lines + 1] = '    ccs = {'
  for _, c in ipairs(ccs) do lines[#lines + 1] = ccSrc(c) end
  lines[#lines + 1] = '    },'
  lines[#lines + 1] = '    texts = {'
  for _, t in ipairs(texts) do lines[#lines + 1] = textSrc(t) end
  lines[#lines + 1] = '    },'
  lines[#lines + 1] = '  },'
  return table.concat(lines, '\n')
end

----- Fixture builders. Each returns the take after a full DisableSort/Sort.

local function buildPlain(track)
  local take = newTake(track)
  reaper.MIDI_DisableSort(take)
  -- notes: overlapping onset (pair by pitch), a second chan, a muted note,
  -- a selected note (proves flag bit0 doesn't leak into muted/shape).
  insNote(take, 0,   240, 0, 60, 96)
  insNote(take, 0,   240, 0, 64, 80)
  insNote(take, 240, 480, 1, 67, 100)
  insNote(take, 480, 600, 0, 62, 70, false, true)   -- muted
  insNote(take, 600, 720, 0, 65, 88, true,  false)  -- selected
  -- ccs: every evType + a couple of shapes + a muted cc.
  insCC(take, 0,   0xB0, 0, 7,  100)   -- cc
  insCC(take, 480, 0xB0, 0, 7,  0)     -- cc (square shape stays 0)
  insCC(take, 0,   0xE0, 0, 0,  80)    -- pb -> val 2048
  insCC(take, 0,   0xC0, 0, 5,  0)     -- pc -> val 5
  insCC(take, 0,   0xD0, 0, 90, 0)     -- at -> val 90
  insCC(take, 0,   0xA0, 0, 64, 77)    -- pa -> pitch 64, vel 77
  insCC(take, 240, 0xB0, 1, 11, 33, false, true)  -- muted cc
  reaper.MIDI_Sort(take)
  setShape(take, 0, 7, 1, 0)    -- cc7@0 -> linear
  return take
end

local function buildSidecars(track)
  local take = newTake(track)
  reaper.MIDI_DisableSort(take)
  insNote(take, 0,   240, 0, 60, 96)
  insNote(take, 240, 480, 0, 62, 90)
  insText(take, 0,   15, 'NOTE 0 60 custom ctm_A')   -- notation sidecar
  insText(take, 240, 15, 'NOTE 0 62 custom ctm_B')
  insCC(take, 100, 0xB0, 0, 7, 64)
  insCC(take, 300, 0xB0, 0, 7, 96)
  insText(take, 100, -1, '\x7D\x52\x44\x4D\x01\x00\x07\x40\x00\x41')  -- '}RDM' cc sidecar
  insText(take, 300, -1, '\x7D\x52\x44\x4D\x01\x00\x07\x60\x00\x42')
  reaper.MIDI_Sort(take)
  return take
end

local function buildBezierSidecar(track)
  local take = newTake(track)
  reaper.MIDI_DisableSort(take)
  -- Two notes with matching notation (type 15) at their onsets, a beziered CC
  -- (emits a CCBZ FF-0F meta), and a cc sidecar (type -1). The notation at
  -- ppq 240 sits AFTER the CCBZ in the stream: capture showed CCBZ is not
  -- surfaced, so that notation must still land at the next contiguous idx.
  insNote(take, 0,   240, 0, 60, 96)
  insNote(take, 240, 480, 0, 62, 90)
  insText(take, 0,   15, 'NOTE 0 60 custom ctm_C')   -- notation, bound to note @0
  insText(take, 240, 15, 'NOTE 0 62 custom ctm_D')   -- notation, bound to note @240
  insText(take, 0,   -1, '\x7D\x52\x44\x4D\x01\x00\x07\x40\x00\x41')  -- cc sidecar @0
  insCC(take, 0,   0xB0, 0, 7, 64)
  insCC(take, 480, 0xB0, 0, 7, 0)
  reaper.MIDI_Sort(take)
  setShape(take, 0, 7, 5, 0.5)   -- cc7@0 -> bezier, tension 0.5 (emits CCBZ)
  return take
end

----- Driver

local FIXTURES = {
  { name = 'plain',          build = buildPlain },
  { name = 'sidecars',       build = buildSidecars },
  { name = 'bezier_sidecar', build = buildBezierSidecar },
}

local function fixturePath()
  local _, scriptPath = reaper.get_action_context()
  local function parent(p) return (p:gsub('[/\\]+[^/\\]*[/\\]*$', '')) end
  local testsDir = parent(parent(scriptPath))         -- .../tests/spikes -> .../tests
  local dir = testsDir .. '/fixtures'
  reaper.RecursiveCreateDirectory(dir, 0)
  return dir .. '/midi_blobs.lua'
end

local function run()
  reaper.ShowConsoleMsg('')
  out('===== capture MIDI blobs =====')
  reaper.Undo_BeginBlock()

  local track = ensureTrack('ctm_capture_scratch')
  clearTrack(track)

  local blocks = {}

  for _, fx in ipairs(FIXTURES) do
    local take = fx.build(track)
    local ok, blob = reaper.MIDI_GetAllEvts(take, '')
    if not ok then out('FAIL: MIDI_GetAllEvts on ' .. fx.name); break end
    local notes, ccs, texts = groundTruth(take)

    out('')
    out(fmt('----- %s : %d bytes, %d notes, %d ccs, %d texts',
            fx.name, #blob, #notes, #ccs, #texts))
    walkBlob(blob)
    out('  texts (per-event API index space):')
    for _, t in ipairs(texts) do
      out(fmt('    idx=%d ppq=%-6d type=%-3d %s', t.idx, t.ppq, t.eventtype, hex(t.msg)))
    end

    blocks[#blocks + 1] = fixtureSrc(fx.name, blob, notes, ccs, texts)
    clearTrack(track)
  end

  reaper.DeleteTrack(track)
  reaper.Undo_EndBlock('ctm capture blobs', -1)
  reaper.UpdateArrange()

  local header = table.concat({
    '-- AUTO-GENERATED by tests/spikes/spike_capture_blobs.lua — do not edit.',
    fmt('-- Real MIDI_GetAllEvts blobs + per-event API ground truth (REAPER %s).', reaper.GetAppVersion()),
    '-- Each entry: blob = raw bytes; notes/ccs/texts = the records mm:load',
    '-- currently produces. parseAllEvts(blob) must reproduce them, idx included.',
    '',
    "local function unhex(s) return (s:gsub('..', function(h) return string.char(tonumber(h, 16)) end)) end",
    '',
    'return {',
  }, '\n')
  local body = table.concat(blocks, '\n')
  local outPath = fixturePath()
  local f, err = io.open(outPath, 'w')
  if not f then out('FAIL: cannot write ' .. outPath .. ': ' .. tostring(err)); return end
  f:write(header .. '\n' .. body .. '\n}\n')
  f:close()

  out('')
  out('Wrote ' .. outPath)
  out('Review the raw-walk above against each "texts" list — esp. bezier_sidecar:')
  out('  if CCBZ appears in the texts index space, parseAllEvts must count it for uuidIdx.')
end

run()
