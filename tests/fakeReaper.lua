-- In-memory stand-in for the REAPER API. Covers just the surface touched
-- by configManager, trackerManager, and viewManager; midiManager's MIDI
-- calls are bypassed by using the fake midiManager instead.

local M = {}

function M.new()
  local r = {}
  local state = {
    cursorTime   = 0,
    precise      = 0,
    tempoBPM     = 120,
    ppqPerQN     = 240,
    projExt      = {},
    trackExt     = {},
    takeExt      = {},
    globalExt    = {},
    itemForTake  = {},
    trackForItem = {},
    calls        = {},
    console      = {},
    messages     = {},
    gmem         = {},
  }
  r._state = state

  -- Page-loading factories (samplePage/trackerPage/swingEditor/curveEditor)
  -- guard their chunks on this; without it, util.instantiate fires the
  -- "ReaImGui not installed" path on every call. Specs that need a real
  -- ImGui surface still preload `imgui` themselves; this just clears the gate.
  function r.ImGui_GetBuiltinPath() return '/stub' end

  -- Config storage

  function r.GetProjExtState(_proj, section, key)
    local v = state.projExt[section .. '/' .. key]
    if v then return 1, v end
    return 0, ''
  end

  function r.SetProjExtState(_proj, section, key, value)
    state.projExt[section .. '/' .. key] = value
  end

  function r.GetSetMediaTrackInfo_String(track, key, value, setNew)
    local k = tostring(track) .. '/' .. key
    if setNew then state.trackExt[k] = value; return true, value end
    return true, state.trackExt[k] or ''
  end

  function r.GetSetMediaItemTakeInfo_String(take, key, value, setNew)
    if key == 'P_NAME' then
      if setNew then state.takeName[take] = value; return true, value end
      return true, state.takeName[take] or ''
    end
    local k = tostring(take) .. '/' .. key
    if setNew then state.takeExt[k] = value; return true, value end
    return true, state.takeExt[k] or ''
  end

  function r.GetTakeGUID(take) return '{take:' .. tostring(take) .. '}' end

  function r.GetMediaItemTake_Item(take) return state.itemForTake[take] end
  function r.GetMediaItemTrack(item)     return state.trackForItem[item] end
  function r.GetMediaItemTake_Track(take)
    return state.trackForItem[state.itemForTake[take]]
  end

  -- Track FX list (used by probeTrackerMode in continuum.lua).
  state.fxByTrack = {}
  function r.TrackFX_GetCount(track)
    return #(state.fxByTrack[track] or {})
  end
  function r.TrackFX_GetFXName(track, idx)
    local names = state.fxByTrack[track] or {}
    return names[idx + 1] ~= nil, names[idx + 1] or ''
  end
  state.fxParams = {}
  function r.TrackFX_SetParam(track, fxIdx, paramIdx, value)
    local k = tostring(track) .. '/' .. fxIdx .. '/' .. paramIdx
    state.fxParams[k] = value
    state.calls[#state.calls + 1] = { fn = 'TrackFX_SetParam',
      track = track, fxIdx = fxIdx, paramIdx = paramIdx, value = value }
    return true
  end
  function r.TrackFX_GetParam(track, fxIdx, paramIdx)
    return state.fxParams[tostring(track) .. '/' .. fxIdx .. '/' .. paramIdx] or 0
  end

  -- FX GUID — sm:tick uses change of GUID to detect FX-removed-and-re-added
  -- so per-instance state can be reset. Tests can re-seat via setFxGuid.
  state.fxGuids = {}
  function r.TrackFX_GetFXGUID(track, _fxIdx)
    return state.fxGuids[track] or ('{guid:' .. tostring(track) .. '}')
  end

  -- Project track list (used by listSamplerTracks in continuum.lua).
  -- Tests register tracks via setProjectTracks(names) — order matters
  -- because GetTrack(_, i) is index-based.
  state.projectTracks = {}
  state.trackNames    = {}
  function r.CountTracks(_proj)             return #state.projectTracks end
  function r.GetTrack(_proj, i)             return state.projectTracks[i + 1] end
  function r.GetTrackName(track)
    local n = state.trackNames[track]
    return n ~= nil, n or ''
  end

  -- Track media items (used by arrangeManager). Each track holds an
  -- ordered list of opaque item tokens; each item carries pos/len in
  -- seconds, an active take, and (for MIDI) a pool guid that fakes
  -- POOLEDEVTS in the item state chunk.
  state.itemsByTrack    = {}    -- track → { item, ... }
  state.itemPos         = {}    -- item  → seconds
  state.itemLen         = {}    -- item  → seconds
  state.activeTake      = {}    -- item  → take
  state.poolByItem      = {}    -- item  → guid string (MIDI pool)
  state.takeIsMidi      = {}    -- take  → bool
  state.takeName        = {}    -- take  → string
  state.takeSrc         = {}    -- take  → src token (e.g. filename for audio)
  state.srcFile         = {}    -- src   → filename string
  function r.CountTrackMediaItems(track) return #(state.itemsByTrack[track] or {}) end
  function r.GetTrackMediaItem(track, i) return (state.itemsByTrack[track] or {})[i + 1] end
  function r.GetActiveTake(item)         return state.activeTake[item] end
  function r.TakeIsMIDI(take)            return state.takeIsMidi[take] == true end
  function r.GetTakeName(take)           return state.takeName[take] end
  function r.GetMediaItemTake_Source(take) return state.takeSrc[take] end
  function r.GetMediaSourceFileName(src) return state.srcFile[src] or tostring(src) end
  function r.GetItemStateChunk(item, _, _)
    local guid = state.poolByItem[item]
    if not guid then return true, '' end
    return true, '<ITEM\n  <SOURCE MIDI\n    POOLEDEVTS ' .. guid .. '\n  >\n>'
  end
  function r.GetMediaItemInfo_Value(item, parm)
    if parm == 'D_POSITION' then return state.itemPos[item] or 0 end
    if parm == 'D_LENGTH'   then return state.itemLen[item] or 0 end
    return 0
  end
  -- Spec convenience: D_POSITION/D_LENGTH are seconds in REAPER;
  -- the fake treats one second as one QN at 60 BPM so tests can
  -- author positions directly in QN.
  function r.TimeMap2_timeToQN(_proj, t) return t end
  function r.DeleteTrackMediaItem(track, item)
    local list = state.itemsByTrack[track] or {}
    for i, it in ipairs(list) do
      if it == item then table.remove(list, i); return true end
    end
    return false
  end
  local guidN = 0
  function r.genGuid(_s) guidN = guidN + 1; return '{guid-' .. guidN .. '}' end

  -- Production-side item creators. Mirror the REAPER surface that
  -- arrangeManager calls on dropInstance. Tokens are fresh tables and
  -- register into the same state.* tables the spec-side addItem helper
  -- uses, so seeded and dropped items coexist in tracksTakes output.
  local function attachItem(track)
    local list = state.itemsByTrack[track]
    if not list then list = {}; state.itemsByTrack[track] = list end
    local item = { __item = #list + 1, track = track }
    list[#list+1] = item
    state.trackForItem[item] = track
    return item
  end
  function r.CreateNewMIDIItemInProj(track, qnStart, qnEnd, _qnIn)
    -- Fake treats 1s == 1QN (TimeMap2_timeToQN is identity); qnIn flag is
    -- informational. CreateNew returns (item, take) and auto-pools the
    -- take into a fresh POOLEDEVTS guid — that's the seam dropInstance
    -- harvests on first drop.
    local item = attachItem(track)
    state.itemPos[item] = qnStart
    state.itemLen[item] = math.max(0, (qnEnd or qnStart) - qnStart)
    local take = { __take = 'mt' .. tostring(item.__item), item = item }
    state.activeTake[item]  = take
    state.itemForTake[take] = item
    state.takeIsMidi[take]  = true
    state.takeName[take]    = ''
    state.poolByItem[item]  = r.genGuid('')
    return item, take
  end
  function r.AddMediaItemToTrack(track)
    local item = attachItem(track)
    state.itemPos[item] = 0
    state.itemLen[item] = 0
    return item
  end
  function r.AddTakeToMediaItem(item)
    local take = { __take = 'at' .. tostring(item.__item), item = item }
    state.activeTake[item]  = take
    state.itemForTake[take] = item
    state.takeIsMidi[take]  = false
    state.takeName[take]    = ''
    return take
  end
  function r.PCM_Source_CreateFromFile(path)
    local src = { __src = path }
    state.srcFile[src] = path
    return src
  end
  function r.SetMediaItemTake_Source(take, src)
    state.takeSrc[take] = src
    return true
  end
  function r.SetMediaItemInfo_Value(item, parm, value)
    if parm == 'D_POSITION' then state.itemPos[item] = value
    elseif parm == 'D_LENGTH' then state.itemLen[item] = value end
    return true
  end
  -- Round-trip POOLEDEVTS via the chunk. Only the guid is preserved;
  -- the surrounding XML shape is regenerated on every read.
  function r.SetItemStateChunk(item, chunk, _isUndo)
    local guid = chunk and chunk:match('POOLEDEVTS%s+({[^}]+})')
    if guid then state.poolByItem[item] = guid end
    return true
  end
  -- Identity inverse to TimeMap2_timeToQN — the fake treats QN and
  -- seconds 1:1, so audio drops compute the same numbers either way.
  function r.TimeMap2_QNToTime(_proj, qn) return qn end

  -- Spec helper: seed one item on a track. Returns the item token.
  -- opts = { take, isMidi, pos, len, poolGuid?, srcFile?, takeName? }
  function r:addItem(track, opts)
    local item = opts.item or { __item = #(state.itemsByTrack[track] or {}) + 1, track = track }
    local list = state.itemsByTrack[track]
    if not list then list = {}; state.itemsByTrack[track] = list end
    list[#list+1] = item
    state.itemPos[item]    = opts.pos or 0
    state.itemLen[item]    = opts.len or 1
    state.activeTake[item] = opts.take
    state.itemForTake[opts.take]  = item
    state.trackForItem[item]      = track
    state.takeIsMidi[opts.take]   = opts.isMidi == true
    state.takeName[opts.take]     = opts.takeName or ''
    if opts.isMidi then
      state.poolByItem[item] = opts.poolGuid or ('{pool-' .. tostring(opts.take) .. '}')
    elseif opts.srcFile then
      state.takeSrc[opts.take] = opts.srcFile
      state.srcFile[opts.srcFile] = opts.srcFile
    end
    return item
  end

  -- Transport / cursor

  function r.GetCursorPosition() return state.cursorTime end

  function r.SetEditCurPos(time)
    state.cursorTime = time
    state.calls[#state.calls + 1] = { fn = 'SetEditCurPos', time = time }
  end

  function r.MIDI_GetPPQPosFromProjTime(_take, time)
    return time * (state.tempoBPM / 60) * state.ppqPerQN
  end

  function r.MIDI_GetProjTimeFromPPQPos(_take, ppq)
    return ppq / state.ppqPerQN / (state.tempoBPM / 60)
  end

  function r.Main_OnCommand(cmd, flag)
    state.calls[#state.calls + 1] = { fn = 'Main_OnCommand', cmd = cmd, flag = flag }
  end

  -- Audition / UI

  function r.StuffMIDIMessage(mode, b1, b2, b3)
    state.calls[#state.calls + 1] = { fn = 'StuffMIDIMessage', mode = mode, b1 = b1, b2 = b2, b3 = b3 }
  end

  function r.time_precise() return state.precise end

  function r.ShowMessageBox(msg, title, btn)
    state.messages[#state.messages + 1] = { msg = msg, title = title, btn = btn }
    return 1
  end

  function r.SetExtState(section, key, value)
    state.globalExt[section .. '/' .. key] = value
  end

  function r.GetExtState(section, key)
    return state.globalExt[section .. '/' .. key] or ''
  end

  function r.ShowConsoleMsg(msg)
    state.console[#state.console + 1] = msg
    if os.getenv('CTM_TEST_VERBOSE') then io.write(msg) end
  end

  -- MIDI take store. Created lazily on first reference. Each list keeps
  -- entries 1-indexed internally; the REAPER API surface converts to 0-index
  -- on read/write/delete.
  --
  -- Insertion order is preserved between MIDI_DisableSort and MIDI_Sort; on
  -- Sort, notes/ccs/texts each restabilise by ppq using a stable sort. Text
  -- events fold sysex (eventtype = -1) and notation (eventtype = 15) into
  -- one stream — same as the real REAPER API surface.
  state.takeMidi = {}
  local function midi(take)
    local m = state.takeMidi[take]
    if not m then
      m = { notes = {}, ccs = {}, texts = {}, sortDisabled = false }
      state.takeMidi[take] = m
    end
    return m
  end

  local function stableSort(list)
    for i, e in ipairs(list) do e.__order = i end
    table.sort(list, function(a, b)
      if a.ppq ~= b.ppq then return a.ppq < b.ppq end
      return a.__order < b.__order
    end)
    for _, e in ipairs(list) do e.__order = nil end
  end

  function r.MIDI_CountEvts(take)
    local m = midi(take)
    return true, #m.notes, #m.ccs, #m.texts
  end

  function r.MIDI_GetNote(take, i)
    local n = midi(take).notes[i + 1]
    if not n then return false end
    return true, n.selected or false, n.muted or false, n.ppq, n.endppq, n.chan, n.pitch, n.vel
  end

  function r.MIDI_GetCC(take, i)
    local c = midi(take).ccs[i + 1]
    if not c then return false end
    return true, c.selected or false, c.muted or false, c.ppq, c.chanmsg, c.chan, c.msg2, c.msg3
  end

  function r.MIDI_GetCCShape(take, i)
    local c = midi(take).ccs[i + 1]
    if not c then return false end
    return true, c.shape or 0, c.tension or 0
  end

  function r.MIDI_GetTextSysexEvt(take, i)
    local e = midi(take).texts[i + 1]
    if not e then return false end
    return true, e.selected or false, e.muted or false, e.ppq, e.eventtype, e.msg
  end

  function r.MIDI_DisableSort(take) midi(take).sortDisabled = true end
  function r.MIDI_Sort(take)
    local m = midi(take)
    stableSort(m.notes)
    stableSort(m.ccs)
    stableSort(m.texts)
    m.sortDisabled = false
  end

  -- Real REAPER cascade-removes a note's notation event (eventtype = 15)
  -- when the note is deleted. Notation sits at the note's onset and encodes
  -- its 0-based chan + pitch; modelling the cascade is what shifts the
  -- shared text stream and desyncs any cached uuidIdx — the surface this
  -- spec/fix turn on.
  function r.MIDI_DeleteNote(take, i)
    local m = midi(take)
    local n = m.notes[i + 1]
    table.remove(m.notes, i + 1)
    if n then
      for ti, e in ipairs(m.texts) do
        local c0, p = e.eventtype == 15 and e.msg:match('^NOTE%s+(%d+)%s+(%d+)%s+custom')
        if c0 and e.ppq == n.ppq and tonumber(c0) == n.chan and tonumber(p) == n.pitch then
          table.remove(m.texts, ti)
          break
        end
      end
    end
    return true
  end
  function r.MIDI_DeleteCC(take, i)
    table.remove(midi(take).ccs, i + 1)
    return true
  end
  function r.MIDI_DeleteTextSysexEvt(take, i)
    table.remove(midi(take).texts, i + 1)
    return true
  end

  function r.MIDI_InsertTextSysexEvt(take, _selected, muted, ppq, eventtype, msg)
    local m = midi(take)
    m.texts[#m.texts + 1] = { ppq = ppq, eventtype = eventtype, msg = msg, muted = muted }
    if not m.sortDisabled then stableSort(m.texts) end
    return true
  end

  function r.MIDI_SetTextSysexEvt(take, i, _selected, muted, ppq, eventtype, msg, _sortIn)
    local e = midi(take).texts[i + 1]
    if not e then return false end
    if muted     ~= nil then e.muted     = muted     end
    if ppq       ~= nil then e.ppq       = ppq       end
    if eventtype ~= nil then e.eventtype = eventtype end
    if msg       ~= nil then e.msg       = msg       end
    return true
  end

  function r.MIDI_InsertNote(take, _selected, muted, ppq, endppq, chan, pitch, vel, _sortIn)
    local m = midi(take)
    m.notes[#m.notes + 1] = { ppq = ppq, endppq = endppq, chan = chan,
                              pitch = pitch, vel = vel, muted = muted }
    if not m.sortDisabled then stableSort(m.notes) end
    return true
  end
  function r.MIDI_SetNote(take, i, _selected, muted, ppq, endppq, chan, pitch, vel, _sortIn)
    local n = midi(take).notes[i + 1]
    if not n then return false end
    if muted  ~= nil then n.muted  = muted  end
    if ppq    ~= nil then n.ppq    = ppq    end
    if endppq ~= nil then n.endppq = endppq end
    if chan   ~= nil then n.chan   = chan   end
    if pitch  ~= nil then n.pitch  = pitch  end
    if vel    ~= nil then n.vel    = vel    end
    return true
  end

  function r.MIDI_InsertCC(take, _selected, muted, ppq, chanmsg, chan, msg2, msg3)
    local m = midi(take)
    m.ccs[#m.ccs + 1] = { ppq = ppq, chanmsg = chanmsg, chan = chan,
                          msg2 = msg2, msg3 = msg3, muted = muted }
    if not m.sortDisabled then stableSort(m.ccs) end
    return true
  end
  function r.MIDI_SetCC(take, i, _selected, muted, ppq, chanmsg, chan, msg2, msg3, _sortIn)
    local c = midi(take).ccs[i + 1]
    if not c then return false end
    if muted   ~= nil then c.muted   = muted   end
    if ppq     ~= nil then c.ppq     = ppq     end
    if chanmsg ~= nil then c.chanmsg = chanmsg end
    if chan    ~= nil then c.chan    = chan    end
    if msg2    ~= nil then c.msg2    = msg2    end
    if msg3    ~= nil then c.msg3    = msg3    end
    return true
  end
  function r.MIDI_SetCCShape(take, i, shape, tension, _sortIn)
    local c = midi(take).ccs[i + 1]
    if not c then return false end
    c.shape = shape; c.tension = tension
    return true
  end

  -- Test helpers

  function r:setCursor(time)  state.cursorTime = time end
  function r:tick(dt)         state.precise = state.precise + dt end
  function r:setTempo(bpm)    state.tempoBPM = bpm end
  function r:bindTake(take, item, track)
    state.itemForTake[take]  = item
    state.trackForItem[item] = track
  end
  function r:setTrackFX(track, names)
    state.fxByTrack[track] = names
  end
  function r:setFxGuid(track, guid)
    state.fxGuids[track] = guid
  end
  function r:setProjectTracks(tracks)
    state.projectTracks = tracks
  end
  function r:setTrackName(track, name)
    state.trackNames[track] = name
  end
  -- gmem
  function r.gmem_attach(_ns) end
  function r.gmem_write(addr, val) state.gmem[addr] = val end
  function r.gmem_read(addr)  return state.gmem[addr] or 0 end

  function r:clearCalls()   state.calls = {} end
  function r:clearConsole() state.console = {} end
  function r:clearGmem()    state.gmem  = {} end

  -- Read a null-terminated string from the gmem flat array starting at base.
  function r:gmemString(base)
    local chars = {}
    local i = base
    while true do
      local b = state.gmem[i] or 0
      if b == 0 then break end
      chars[#chars + 1] = string.char(math.floor(b))
      i = i + 1
    end
    return table.concat(chars)
  end

  -- Bulk-seed a take's MIDI store. Mirrors the field shape REAPER returns.
  -- notes : { { ppq, endppq, chan, pitch, vel, [muted] }, ... }
  -- ccs   : { { ppq, chanmsg, chan, msg2, msg3, [muted], [shape], [tension] }, ... }
  -- texts : { { ppq, eventtype, msg, [muted] }, ... }
  function r:seedMidi(take, seed)
    local m = midi(take)
    m.notes = {}; m.ccs = {}; m.texts = {}
    for _, n in ipairs(seed.notes or {}) do m.notes[#m.notes+1] = { ppq = n.ppq, endppq = n.endppq,
        chan = n.chan, pitch = n.pitch, vel = n.vel, muted = n.muted } end
    for _, c in ipairs(seed.ccs or {})   do m.ccs[#m.ccs+1]     = { ppq = c.ppq, chanmsg = c.chanmsg,
        chan = c.chan, msg2 = c.msg2, msg3 = c.msg3, muted = c.muted, shape = c.shape, tension = c.tension } end
    for _, e in ipairs(seed.texts or {}) do m.texts[#m.texts+1] = { ppq = e.ppq, eventtype = e.eventtype,
        msg = e.msg, muted = e.muted } end
    stableSort(m.notes); stableSort(m.ccs); stableSort(m.texts)
  end

  function r:dumpMidi(take)
    local m = midi(take)
    return { notes = m.notes, ccs = m.ccs, texts = m.texts }
  end

  return r
end

return M
