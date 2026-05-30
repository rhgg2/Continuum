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
    projStateCount = 0,
    trackExt     = {},
    takeExt      = {},
    globalExt    = {},
    itemForTake  = {},
    trackForItem = {},
    playState    = 0,
    playTime     = 0,
    loopStart    = 0,
    loopEnd      = 0,
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

  function r.GetProjectStateChangeCount(_proj)
    return state.projStateCount
  end

  function r.GetSetMediaTrackInfo_String(track, key, value, setNew)
    local k = tostring(track) .. '/' .. key
    if setNew then
      state.trackExt[k] = value
      if key == 'P_NAME' then state.trackNames[track] = value end
      return true, value
    end
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
  -- Entries are either bare strings (seeded via setTrackFX, legacy sampler
  -- path) or {ident=...} tables (added via TrackFX_AddByName, wiring path).
  state.fxByTrack = {}
  state.fxIO      = {}   -- ident → {ins, outs, inPinNames?={..}, outPinNames?={..}}; ports = pins/2
  local function fxEntry(track, idx) return (state.fxByTrack[track] or {})[idx + 1] end
  local function fxIdentOf(entry)    return type(entry) == 'table' and entry.ident or entry end
  function r.TrackFX_GetCount(track)
    return #(state.fxByTrack[track] or {})
  end
  function r.TrackFX_GetFXName(track, idx)
    local entry = fxEntry(track, idx)
    return entry ~= nil, fxIdentOf(entry) or ''
  end
  function r.TrackFX_AddByName(track, ident, _recFx, _instantiate)
    local list = state.fxByTrack[track]
    if not list then list = {}; state.fxByTrack[track] = list end
    list[#list + 1] = { ident = ident }
    return #list - 1
  end
  function r.TrackFX_Delete(track, idx)
    table.remove(state.fxByTrack[track] or {}, idx + 1)
    -- Keep per-(track, fxIdx) guid map aligned: delete idx, shift higher down.
    local g = state.fxGuids[track]
    if g then
      local maxK = -1
      for k in pairs(g) do if k > maxK then maxK = k end end
      g[idx] = nil
      for k = idx + 1, maxK do g[k - 1] = g[k]; g[k] = nil end
    end
    return true
  end

  function r.TrackFX_CopyToTrack(srcTr, srcIdx, dstTr, dstIdx, isMove)
    local srcList = state.fxByTrack[srcTr]
    if not srcList or not srcList[srcIdx + 1] then return end
    local entry  = srcList[srcIdx + 1]
    local sg     = state.fxGuids[srcTr]
    local guid   = sg and sg[srcIdx] or nil
    if isMove then
      table.remove(srcList, srcIdx + 1)
      if sg then
        local maxK = -1
        for k in pairs(sg) do if k > maxK then maxK = k end end
        sg[srcIdx] = nil
        for k = srcIdx + 1, maxK do sg[k - 1] = sg[k]; sg[k] = nil end
      end
    else
      entry = type(entry) == 'string' and entry or { ident = entry.ident }
      guid  = nil
    end
    local dstList = state.fxByTrack[dstTr]
    if not dstList then dstList = {}; state.fxByTrack[dstTr] = dstList end
    table.insert(dstList, dstIdx + 1, entry)
    -- For same-track move, srcIdx and dstIdx live in the same list; the
    -- table.remove above already shifted things, and the table.insert sits
    -- the entry at dstIdx (1-based dstIdx+1), matching REAPER's contract
    -- ("destIdx is the target index after the source has been removed").
    if guid then
      local dg = state.fxGuids[dstTr]
      if not dg then dg = {}; state.fxGuids[dstTr] = dg end
      local maxK = -1
      for k in pairs(dg) do if k > maxK then maxK = k end end
      for k = maxK, dstIdx, -1 do dg[k + 1] = dg[k]; dg[k] = nil end
      dg[dstIdx] = guid
    end
    return true
  end
  function r.TrackFX_GetIOSize(track, idx)
    local io = state.fxIO[fxIdentOf(fxEntry(track, idx))] or { ins = 2, outs = 2 }
    return 1, io.ins, io.outs
  end
  function r.TrackFX_GetNamedConfigParm(track, idx, parm)
    local io = state.fxIO[fxIdentOf(fxEntry(track, idx))]
    local dir, pin = parm:match('^(in)_pin_(%d+)$')
    if not dir then dir, pin = parm:match('^(out)_pin_(%d+)$') end
    if dir and io then
      local names = io[dir == 'in' and 'inPinNames' or 'outPinNames']
      local v = names and names[tonumber(pin) + 1]
      if v then return true, v end
    end
    return false, ''
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

  -- Param-name surface for the wiring applier's setParam-by-name path. Tests
  -- seed via r:setFxParamNames(ident, { 'mode', 'gain', ... }).
  state.fxParamNames = {}
  function r.TrackFX_GetParamName(track, fxIdx, paramIdx)
    local ident = fxIdentOf(fxEntry(track, fxIdx))
    local names = state.fxParamNames[ident]
    if not names then return false, '' end
    local n = names[paramIdx + 1]
    if n == nil then return false, '' end
    return true, n
  end

  -- Track state chunk — minimal FXCHAIN round-trip used by the wm applier's
  -- per-FX MIDI routing surgery. Emits one <VST ...> block per non-JS fx
  -- (default flag byte 0x10, bus bytes zero) and one <JS ...> block per JS
  -- fx (no routing trailer). SetTrackStateChunk parses the chunk, picks the
  -- trailer line from each non-JS block, and stores routingBytes on the
  -- matching fx entry — what tests read back to verify a routing patch.
  local B64A = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
  local B64D = {}
  for i = 1, #B64A do B64D[B64A:byte(i)] = i - 1 end
  local function b64encode(s)
    local out, buf, bits = {}, 0, 0
    for i = 1, #s do
      buf  = (buf << 8) | s:byte(i)
      bits = bits + 8
      while bits >= 6 do
        bits = bits - 6
        local v = (buf >> bits) & 0x3F
        out[#out + 1] = B64A:sub(v + 1, v + 1)
        buf = buf & ((1 << bits) - 1)
      end
    end
    return table.concat(out)
  end
  local function b64decode(s)
    local out, buf, bits = {}, 0, 0
    for i = 1, #s do
      local v = B64D[s:byte(i)]
      if v then
        buf  = (buf << 6) | v
        bits = bits + 6
        if bits >= 8 then
          bits = bits - 8
          out[#out + 1] = string.char((buf >> bits) & 0xFF)
          buf = buf & ((1 << bits) - 1)
        end
      end
    end
    return table.concat(out)
  end
  function r.GetTrackStateChunk(track, _, _)
    local fxs = state.fxByTrack[track] or {}
    local lines = { '<TRACK', '  <FXCHAIN' }
    for _, fx in ipairs(fxs) do
      local ident = fxIdentOf(fx)
      if ident:sub(1, 3) == 'JS:' then
        lines[#lines + 1] = '  <JS ' .. ident .. ' ""'
        lines[#lines + 1] = '    0 0 0 -'
        lines[#lines + 1] = '  >'
      else
        local rb      = (type(fx) == 'table' and fx.routingBytes)
                        or { flag = 0x10, inBus = 0, outBus = 0 }
        local first   = b64encode(string.char(0, rb.flag, 0))
        local trailer = b64encode(string.char(0, 0, rb.flag, rb.inBus, rb.outBus, 0))
        lines[#lines + 1] = '  <VST "VST: ' .. ident .. '" stub.vst 0 "" 1 ""'
        lines[#lines + 1] = '    ' .. first
        lines[#lines + 1] = '    D34dB33f'
        lines[#lines + 1] = '    ' .. trailer
        lines[#lines + 1] = '  >'
      end
    end
    lines[#lines + 1] = '  >'
    lines[#lines + 1] = '>'
    return true, table.concat(lines, '\n') .. '\n'
  end
  function r.SetTrackStateChunk(track, chunk, _isUndo)
    local fxs = state.fxByTrack[track]
    if not fxs then return true end

    -- Walk blocks at depth 0, collecting the last base64 line inside each
    -- non-JS FX block. Mirrors findFxBlock's depth tracking in production.
    local chunkLines = {}
    for ln in chunk:gmatch('[^\n]+') do chunkLines[#chunkLines + 1] = ln end
    local trailers = {}
    local i = 1
    while i <= #chunkLines do
      local ln = chunkLines[i]:match('^%s*(.-)%s*$')
      local isFx = ln:match('^<VST%s')  or ln:match('^<CLAP%s') or ln:match('^<AU%s')
      local isJS = ln:match('^<JS%s')   or ln:match('^<JS$')
      if isFx or isJS then
        local depth, lastB64 = 1, nil
        i = i + 1
        while i <= #chunkLines and depth > 0 do
          local s = chunkLines[i]:match('^%s*(.-)%s*$')
          if s == '>' then
            depth = depth - 1
          elseif s:sub(1, 1) == '<' then
            depth = depth + 1
          elseif depth == 1 and s:match('^[A-Za-z0-9%+/=]+$') then
            lastB64 = s
          end
          i = i + 1
        end
        if isFx then trailers[#trailers + 1] = lastB64 end
      else
        i = i + 1
      end
    end

    -- Zip non-JS trailers with non-JS fxs in order. JS entries pass through.
    local tIdx = 1
    for j, fx in ipairs(fxs) do
      if fxIdentOf(fx):sub(1, 3) ~= 'JS:' then
        local trailer = trailers[tIdx]
        if trailer then
          local bytes = b64decode(trailer)
          if #bytes >= 6 then
            if type(fx) == 'string' then fx = { ident = fx }; fxs[j] = fx end
            fx.routingBytes = {
              flag   = bytes:byte(3),
              inBus  = bytes:byte(4),
              outBus = bytes:byte(5),
            }
          end
        end
        tIdx = tIdx + 1
      end
    end
    return true
  end

  -- FX GUID — sm:tick uses change of GUID to detect FX-removed-and-re-added
  -- so per-instance state can be reset. Wiring snapshot keys per-fx P_EXT by
  -- GUID, so each (track, fxIdx) gets its own stable guid; tests can
  -- re-seat via setFxGuid(track, idx?, guid).
  state.fxGuids = {}
  local fxGuidN = 0
  function r.TrackFX_GetFXGUID(track, fxIdx)
    local perTrack = state.fxGuids[track]
    if not perTrack then perTrack = {}; state.fxGuids[track] = perTrack end
    local g = perTrack[fxIdx]
    if not g then
      fxGuidN = fxGuidN + 1
      g = '{FX-' .. fxGuidN .. '}'
      perTrack[fxIdx] = g
    end
    return g
  end

  -- Project track list (used by listSamplerTracks in continuum.lua).
  -- Tests register tracks via setProjectTracks(names) — order matters
  -- because GetTrack(_, i) is index-based.
  state.projectTracks = {}
  state.trackNames    = {}
  function r.CountTracks(_proj)             return #state.projectTracks end
  function r.GetTrack(_proj, i)             return state.projectTracks[i + 1] end
  function r.ValidatePtr2(_proj, ptr, ctype)
    if ctype == 'MediaTrack*' then
      for _, t in ipairs(state.projectTracks) do if t == ptr then return true end end
      return false
    end
    return true
  end
  function r.GetTrackName(track)
    local n = state.trackNames[track]
    return n ~= nil, n or ''
  end
  -- Track selection + properties (arrange boot-cursor seed). IP_TRACKNUMBER
  -- is 1-based in REAPER; am:initialCursor subtracts 1 for the 0-based column.
  state.selectedTracks = {}
  function r.GetSelectedTrack(_proj, idx) return state.selectedTracks[idx + 1] end
  function r.GetMediaTrackInfo_Value(track, parm)
    if parm == 'IP_TRACKNUMBER' then
      for i, tr in ipairs(state.projectTracks) do
        if tr == track then return i end
      end
    end
    local k = tostring(track) .. '/' .. parm
    local v = state.trackValues and state.trackValues[k]
    if v ~= nil then return v end
    if parm == 'B_MAINSEND' then return 1 end
    if parm == 'D_VOL'      then return 1.0 end
    return 0
  end
  state.trackValues = {}
  function r.SetMediaTrackInfo_Value(track, parm, value)
    state.trackValues[tostring(track) .. '/' .. parm] = value
    return true
  end
  local insertedN = 0
  state.trackGuids = {}
  function r.InsertTrackAtIndex(idx, _wantDefaults)
    insertedN = insertedN + 1
    local track = { __track = 'scratch' .. insertedN }
    table.insert(state.projectTracks, idx + 1, track)
    state.trackGuids[track] = '{TR-' .. insertedN .. '}'
  end
  function r.GetTrackGUID(track)
    return state.trackGuids[track] or ('{TR-anon-' .. tostring(track) .. '}')
  end
  function r.PreventUIRefresh(_) end
  function r.Undo_BeginBlock() end
  function r.Undo_EndBlock2(_proj, _name, _flags) end
  state.master = { __track = 'master' }
  function r.GetMasterTrack(_proj) return state.master end
  function r.DeleteTrack(track)
    for i, t in ipairs(state.projectTracks) do
      if t == track then table.remove(state.projectTracks, i); break end
    end
    state.sendsByTrack[track] = nil
    for _, list in pairs(state.sendsByTrack) do
      for i = #list, 1, -1 do
        if list[i].dst == track then table.remove(list, i) end
      end
    end
    state.fxByTrack[track] = nil
    state.fxGuids[track]   = nil
  end

  -- Track sends. One record per send (category=0); receives (category<0)
  -- are derived by walking every track's sends. Each send is
  -- { dst, midiFlags, srcChan, dstChan }. Defaults match REAPER's new-send
  -- defaults: midiFlags=0 (all-midi enabled), srcChan=0 (stereo from ch 1),
  -- dstChan=0. Spec helpers shape audio-only / midi-only / both.
  state.sendsByTrack = {}
  local function sendsOf(track)
    local s = state.sendsByTrack[track]
    if not s then s = {}; state.sendsByTrack[track] = s end
    return s
  end
  function r.GetTrackNumSends(track, category)
    if category == 0 then return #sendsOf(track) end
    if category < 0 then
      local n = 0
      for _, list in pairs(state.sendsByTrack) do
        for _, snd in ipairs(list) do
          if snd.dst == track then n = n + 1 end
        end
      end
      return n
    end
    return 0
  end
  local function receiveAt(track, idx)
    local n = 0
    for src, list in pairs(state.sendsByTrack) do
      for _, snd in ipairs(list) do
        if snd.dst == track then
          if n == idx then return src, snd end
          n = n + 1
        end
      end
    end
  end
  function r.CreateTrackSend(srcTrack, dstTrack)
    local list = sendsOf(srcTrack)
    table.insert(list, { dst = dstTrack, midiFlags = 0, srcChan = 0, dstChan = 0 })
    return #list - 1
  end
  function r.RemoveTrackSend(track, category, idx)
    if category ~= 0 then return false end
    local list = state.sendsByTrack[track]
    if not list then return false end
    table.remove(list, idx + 1)
    return true
  end
  function r.SetTrackSendInfo_Value(track, category, idx, parm, value)
    if category ~= 0 then return false end
    local list = state.sendsByTrack[track]
    if not list then return false end
    local s = list[idx + 1]
    if not s then return false end
    if     parm == 'I_MIDIFLAGS' then s.midiFlags = value
    elseif parm == 'I_SRCCHAN'   then s.srcChan   = value
    elseif parm == 'I_DSTCHAN'   then s.dstChan   = value
    elseif parm == 'D_VOL'       then s.vol       = value
    elseif parm == 'I_SENDMODE'  then s.sendMode  = value
    elseif parm == 'B_MUTE'      then s.mute      = value == 1
    end
    return true
  end
  function r.GetTrackSendInfo_Value(track, category, idx, parm)
    local snd, src
    if category == 0 then
      snd = sendsOf(track)[idx + 1]; src = track
    elseif category < 0 then
      src, snd = receiveAt(track, idx)
    end
    if not snd then return 0 end
    if parm == 'P_DESTTRACK' then return snd.dst end
    if parm == 'P_SRCTRACK'  then return src end
    if parm == 'I_MIDIFLAGS' then return snd.midiFlags or 0 end
    if parm == 'I_SRCCHAN'   then return snd.srcChan   or 0 end
    if parm == 'I_DSTCHAN'   then return snd.dstChan   or 0 end
    if parm == 'D_VOL'       then return snd.vol       or 1.0 end
    if parm == 'I_SENDMODE'  then return snd.sendMode  or 0 end
    if parm == 'B_MUTE'      then return snd.mute and 1 or 0 end
    return 0
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
  state.srcLen          = {}    -- src   → length (QN for MIDI, sec for audio)
  state.srcIsQN         = {}    -- src   → true if MIDI (beat-based)
  function r.CountTrackMediaItems(track) return #(state.itemsByTrack[track] or {}) end
  function r.GetTrackMediaItem(track, i) return (state.itemsByTrack[track] or {})[i + 1] end
  function r.GetActiveTake(item)         return state.activeTake[item] end
  function r.TakeIsMIDI(take)            return state.takeIsMidi[take] == true end
  function r.GetTakeName(take)           return state.takeName[take] end
  function r.GetMediaItemTake_Source(take) return state.takeSrc[take] end
  function r.GetMediaSourceFileName(src) return state.srcFile[src] or tostring(src) end
  function r.GetMediaSourceLength(src)
    return state.srcLen[src] or math.huge, state.srcIsQN[src] == true
  end
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
    -- informational. Real REAPER returns the item only — the take is
    -- reached via GetActiveTake. The fresh POOLEDEVTS guid is the seam
    -- dropInstance harvests on first drop. Source length tracks the item
    -- length (REAPER mints a pooled source sized to the request), so
    -- relayout's source cap is meaningful for freshly-created items.
    local item = attachItem(track)
    local len  = math.max(0, (qnEnd or qnStart) - qnStart)
    state.itemPos[item] = qnStart
    state.itemLen[item] = len
    local take = { __take = 'mt' .. tostring(item.__item), item = item }
    state.activeTake[item]  = take
    state.itemForTake[take] = item
    state.takeIsMidi[take]  = true
    state.takeName[take]    = ''
    state.poolByItem[item]  = r.genGuid('')
    local src = { __midiSrc = take }
    state.takeSrc[take] = src
    state.srcLen[src]   = len
    state.srcIsQN[src]  = true
    return item
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
      local src = { __midiSrc = opts.take }
      state.takeSrc[opts.take] = src
      -- Mirror REAPER: CreateNewMIDIItemInProj sets the source length to
      -- the item length on creation. Tests that want a longer source can
      -- pass srcLen explicitly; the default = item length matches reality.
      state.srcLen[src]  = opts.srcLen or (opts.len or 1)
      state.srcIsQN[src] = true
    elseif opts.srcFile then
      state.takeSrc[opts.take] = opts.srcFile
      state.srcFile[opts.srcFile] = opts.srcFile
      state.srcLen[opts.srcFile]  = opts.srcLen or math.huge
      state.srcIsQN[opts.srcFile] = false
    end
    return item
  end

  -- Item selection (used by the coordinator dive). state.selectedItems
  -- is a set; GetSelectedMediaItem walks tracks in registration order.
  state.selectedItems = {}
  function r.SelectAllMediaItems(_proj, selected)
    if not selected then state.selectedItems = {}; return end
    for _, list in pairs(state.itemsByTrack) do
      for _, it in ipairs(list) do state.selectedItems[it] = true end
    end
  end
  function r.SetMediaItemSelected(item, selected)
    state.selectedItems[item] = selected and true or nil
  end
  function r.GetSelectedMediaItem(_proj, idx)
    local n = 0
    for _, track in ipairs(state.projectTracks) do
      for _, it in ipairs(state.itemsByTrack[track] or {}) do
        if state.selectedItems[it] then
          if n == idx then return it end
          n = n + 1
        end
      end
    end
    return nil
  end

  -- Transport / cursor

  function r.GetCursorPosition()        return state.cursorTime end
  function r.GetCursorPositionEx(_proj) return state.cursorTime end

  function r.SetEditCurPos(time)
    state.cursorTime = time
    state.calls[#state.calls + 1] = { fn = 'SetEditCurPos', time = time }
  end

  function r.GetPlayState()           return state.playState end
  function r.GetPlayPosition()        return state.playTime end
  function r.GetPlayPositionEx(_proj) return state.playTime end

  function r.GetSet_LoopTimeRange(isSet, _isLoop, startT, endT, _seek)
    if isSet then
      state.loopStart, state.loopEnd = startT, endT
      state.calls[#state.calls + 1] =
        { fn = 'GetSet_LoopTimeRange', startT = startT, endT = endT }
    end
    return state.loopStart, state.loopEnd
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

  -- Opaque event blobs by take. Production only needs a faithful
  -- round-trip (Get then Set on another take), not real parsing.
  state.midiBlob = state.midiBlob or {}
  function r.MIDI_GetAllEvts(take, _)
    return true, state.midiBlob[take] or ''
  end
  function r.MIDI_SetAllEvts(take, evts)
    state.midiBlob[take] = evts
    return true
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
  function r:setLoopRange(startT, endT) state.loopStart, state.loopEnd = startT, endT end
  function r:setPlay(playing, time)
    state.playState = playing and 1 or 0
    if time then state.playTime = time end
  end
  function r:tick(dt)         state.precise = state.precise + dt end
  function r:setTempo(bpm)    state.tempoBPM = bpm end
  function r:bindTake(take, item, track)
    state.itemForTake[take]  = item
    state.trackForItem[item] = track
  end
  function r:setTrackFX(track, names)
    state.fxByTrack[track] = names
  end
  function r:setFxIO(ident, io)
    state.fxIO[ident] = io
  end
  function r:setFxGuid(track, idx, guid)
    -- Two-arg call (track, guid) is legacy: pins fxIdx 0 to guid.
    if guid == nil then guid = idx; idx = 0 end
    local perTrack = state.fxGuids[track]
    if not perTrack then perTrack = {}; state.fxGuids[track] = perTrack end
    perTrack[idx] = guid
  end
  function r:setFxParamNames(ident, names)
    state.fxParamNames[ident] = names
  end
  function r:setProjectTracks(tracks)
    state.projectTracks = tracks
  end
  -- opts = { type='audio'|'midi'|'both' (default 'both'),
  --          srcChan?, dstChan?, midiFlags?, mute? }
  function r:addSend(srcTrack, dstTrack, opts)
    opts = opts or {}
    local kind = opts.type or 'both'
    local srcChan   = opts.srcChan
    local midiFlags = opts.midiFlags
    if kind == 'audio' then
      srcChan   = srcChan   or 0
      midiFlags = midiFlags or 31           -- low 5 bits = 31 → MIDI disabled
    elseif kind == 'midi' then
      srcChan   = srcChan   or -1           -- -1 → no audio send
      midiFlags = midiFlags or 0
    else
      srcChan   = srcChan   or 0
      midiFlags = midiFlags or 0
    end
    local list = sendsOf(srcTrack)
    list[#list + 1] = { dst = dstTrack, srcChan = srcChan,
                        dstChan = opts.dstChan or 0,
                        midiFlags = midiFlags, mute = opts.mute,
                        vol = opts.gain, sendMode = opts.sendMode }
    return #list - 1
  end
  function r:setSelectedTracks(tracks)
    state.selectedTracks = tracks
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
