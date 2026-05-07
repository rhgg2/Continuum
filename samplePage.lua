-- See docs/samplePage.md for the model and API reference.
--
-- Sample-mode page: track picker (toolbar), three-pane browser+slots
-- (body), and a status line summarising the bound track. Owns rendering;
-- sampleView holds the model state (selected file, current folder,
-- track) and the action seams (audition, load).

loadModule('fs')

if not reaper.ImGui_GetBuiltinPath then
  return reaper.MB('ReaImGui is not installed or too old.', 'My script', 0)
end
package.path = reaper.ImGui_GetBuiltinPath() .. '/?.lua;' .. package.path
local ImGui = require 'imgui' '0.10'

local N_SLOTS = 64

local UP = '__up__'   -- sentinel path for the '..' navigation entry

function newSamplePage(sv, sm, cm, cmgr, chrome, ctxArg)
  local ctx          = ctxArg
  local pickerActive = false   -- a popup owned input this frame

  -- Page-local caches. Trims slab is per-frame, refreshed in renderBody;
  -- peaks/durations are file-keyed and persist across renders. peakCache
  -- entries are invalidated when the requested column count changes
  -- (window resize), so a strip at one width doesn't reuse a foreign one.
  local trims     = {}
  local peakCache = {}    -- absPath → { mins, maxs, cols, fs, frames, lenSec } or false
  local durCache  = {}    -- absPath → seconds or false
  local drag      = { handle = nil, slot = nil, startF = nil, endF = nil }

  -- Preview-in-place: when active, the JSFX slot has been swapped to a
  -- transient file; cm.slotEntries is untouched, so prevRel is read from
  -- there at trigger time and restored on revert. browserAtTrigger /
  -- slotAtTrigger snapshot the navigation state; any divergence (cursor
  -- move, slot focus change, click, page change, toggle off) reverts.
  local pip = { slot = nil, prevRel = nil, justTriggered = false,
                browserAtTrigger = nil, slotAtTrigger = nil }

  local function revertPreviewInPlace()
    if pip.slot == nil then return end
    local track = pip.track
    if pip.prevRel then sm:loadSlot(track, pip.slot, pip.prevRel)
    else                sm:unloadSlot(track, pip.slot) end
    pip.slot, pip.prevRel, pip.track = nil, nil, nil
    pip.browserAtTrigger, pip.slotAtTrigger = nil, nil
    pip.justTriggered = false
  end

  local function triggerPreviewInPlace(srcPath)
    local slot    = cm:get('currentSample')
    local entries = cm:get('slotEntries') or {}
    local prev    = entries[slot]
    local track   = sv:getTrack()
    if not sm:stageInto(track, slot, srcPath, reaper.GetProjectPath(0)) then return end
    pip.slot             = slot
    pip.prevRel          = prev and prev.path or nil
    pip.track            = track
    pip.browserAtTrigger = sv:getBrowserPath()
    pip.slotAtTrigger    = slot
    pip.justTriggered    = true
  end

  local function durFor(abs)
    local hit = durCache[abs]
    if hit ~= nil then return hit or nil end
    local src = reaper.PCM_Source_CreateFromFile(abs)
    if not src then durCache[abs] = false; return nil end
    local len = reaper.GetMediaSourceLength(src)
    reaper.PCM_Source_Destroy(src)
    durCache[abs] = len
    return len
  end

  -- PCM_Source_GetPeaks lays the buffer out as two blocks back-to-back:
  -- maxes (cols * nch floats), then mins (cols * nch floats). Channels
  -- are interleaved within each block per pixel. Fold to one per-pixel
  -- amplitude (max |max|, |min| across channels) and mirror at draw time.
  --
  -- Past ~3s of source, GetPeaks needs a built peak file. We drive
  -- BuildPeaks across frames: a fresh entry returns with frames/lenSec
  -- but no amps until the build finishes; the strip shows a flat line
  -- meanwhile. Width changes invalidate and restart.
  local function peakFor(abs, cols)
    local hit = peakCache[abs]
    if hit == false then return nil end
    if hit and hit.cols ~= cols then
      if hit.src then reaper.PCM_Source_Destroy(hit.src) end
      hit, peakCache[abs] = nil, nil
    end
    if hit and hit.amps then return hit end

    if not hit then
      local src = reaper.PCM_Source_CreateFromFile(abs)
      if not src then peakCache[abs] = false; return nil end
      local lenSec = reaper.GetMediaSourceLength(src)
      local fsRate = reaper.GetMediaSourceSampleRate(src)
      local nch    = reaper.GetMediaSourceNumChannels(src)
      hit = { src = src, cols = cols, fs = fsRate, nch = nch,
              frames = math.floor(lenSec * fsRate + 0.5), lenSec = lenSec,
              building = reaper.PCM_Source_BuildPeaks(src, 0) ~= 0 }
      peakCache[abs] = hit
    end

    if hit.building then
      if reaper.PCM_Source_BuildPeaks(hit.src, 1) == 0 then
        reaper.PCM_Source_BuildPeaks(hit.src, 2)
        hit.building = false
      else
        return hit
      end
    end

    local nch = hit.nch
    local buf = reaper.new_array(cols * nch * 2); buf.clear()
    reaper.PCM_Source_GetPeaks(hit.src, cols / hit.lenSec, 0, nch, cols, 0, buf)
    reaper.PCM_Source_Destroy(hit.src)
    hit.src = nil
    local minBase, amps = cols * nch, {}
    for i = 0, cols - 1 do
      local a = 0
      for c = 0, nch - 1 do
        local mx = math.abs(buf[i * nch + c + 1] or 0)
        local mn = math.abs(buf[minBase + i * nch + c + 1] or 0)
        if mx > a then a = mx end
        if mn > a then a = mn end
      end
      amps[i + 1] = a
    end
    hit.amps = amps
    return hit
  end

  -- Left pane: directory tree.
  -- Single-click sets currentFolder; double-click re-roots the tree there.
  local function drawTree(path)
    for _, sub in ipairs(fs.listDirs(path)) do
      local subPath = fs.join(path, sub)
      local open = ImGui.TreeNode(ctx, sub)
      if ImGui.IsItemClicked(ctx) then
        sv:setCurrentFolder(subPath)
      end
      if ImGui.IsItemHovered(ctx) and ImGui.IsMouseDoubleClicked(ctx, 0) then
        sv:setBrowseRoot(subPath)
      end
      if open then
        drawTree(subPath)
        ImGui.TreePop(ctx)
      end
    end
  end

  local function goUp()
    local root   = sv:browseRoot()
    local folder = sv:getCurrentFolder() or root
    if folder == root then return end
    local parent = fs.parent(folder)
    if parent == '' or #parent < #root then parent = root end
    sv:setBrowserItem(folder, true)   -- highlight the folder we just left
    sv:setCurrentFolder(parent ~= root and parent or nil)
  end

  -- Middle pane: unified keyboard-navigable list of '..', folders, and files.
  -- Arrow keys (no modifier) move the browser cursor. ImGui nav is disabled
  -- entirely so it doesn't produce a second focus rectangle.
  local function drawFiles(folder, root)
    local items = {}
    if folder ~= root then
      items[#items+1] = { isFolder = true, name = '▸ ..', path = UP }
    end
    for _, sub in ipairs(fs.listDirs(folder)) do
      items[#items+1] = { isFolder = true,  name = '▸ ' .. sub,
                          path = fs.join(folder, sub) }
    end
    for _, file in ipairs(fs.listAudioFiles(folder)) do
      local p   = fs.join(folder, file)
      local d   = durFor(p)
      local nm  = d and string.format('%s  %.2fs', file, d) or file
      items[#items+1] = { isFolder = false, name = nm, path = p }
    end

    local sel      = sv:getBrowserPath()
    local selMoved = false
    local selIdx   = nil
    for i, item in ipairs(items) do
      if item.path == sel then selIdx = i; break end
    end
    if not selIdx and #items > 0 then
      sv:setBrowserItem(items[1].path, items[1].isFolder)
      sel    = items[1].path
      selIdx = 1
    end

    if ImGui.IsKeyPressed(ctx, ImGui.Key_DownArrow)
        and ImGui.GetKeyMods(ctx) == ImGui.Mod_None then
      local next = items[math.min((selIdx or 0) + 1, #items)]
      if next then sv:setBrowserItem(next.path, next.isFolder); selMoved = true end
    elseif ImGui.IsKeyPressed(ctx, ImGui.Key_UpArrow)
        and ImGui.GetKeyMods(ctx) == ImGui.Mod_None then
      local prev = items[math.max((selIdx or #items + 1) - 1, 1)]
      if prev then sv:setBrowserItem(prev.path, prev.isFolder); selMoved = true end
    end

    sel = sv:getBrowserPath()
    for _, item in ipairs(items) do
      local isSelected = item.path == sel
      local selCol = isSelected and ImGui.GetStyleColor(ctx, ImGui.Col_Header) or 0x00000000
      ImGui.PushStyleColor(ctx, ImGui.Col_HeaderHovered, selCol)
      ImGui.PushStyleColor(ctx, ImGui.Col_HeaderActive,  selCol)
      local clicked = ImGui.Selectable(ctx, item.name, isSelected,
                                       ImGui.SelectableFlags_AllowDoubleClick)
      ImGui.PopStyleColor(ctx, 2)
      if clicked then
        sv:setBrowserItem(item.path, item.isFolder)
        if ImGui.IsMouseDoubleClicked(ctx, 0) then
          if item.path == UP   then goUp()
          elseif item.isFolder then sv:setCurrentFolder(item.path)
          elseif cm:get('previewInPlace') then triggerPreviewInPlace(item.path)
          else                      sv:auditionPath(item.path) end
        end
      end
      if isSelected and selMoved then ImGui.SetScrollHereY(ctx, 0.5) end
    end
  end

  local function drawSlots()
    local names   = cm:get('samplerNames') or {}
    local current = cm:get('currentSample')
    if not ImGui.BeginTable(ctx, '##slotsT', 2) then return end
    ImGui.TableSetupColumn(ctx, '##n', ImGui.TableColumnFlags_WidthFixed,   28)
    ImGui.TableSetupColumn(ctx, '##v', ImGui.TableColumnFlags_WidthStretch)
    for idx = 0, N_SLOTS - 1 do
      local isSelected = idx == current
      ImGui.TableNextRow(ctx)
      ImGui.TableSetColumnIndex(ctx, 0)
      local numStr   = tostring(idx)
      local tw, _    = ImGui.CalcTextSize(ctx, numStr)
      local aw, _    = ImGui.GetContentRegionAvail(ctx)
      ImGui.SetCursorPosX(ctx, ImGui.GetCursorPosX(ctx) + aw - tw)
      ImGui.TextDisabled(ctx, numStr)
      ImGui.TableSetColumnIndex(ctx, 1)
      local selCol = isSelected and ImGui.GetStyleColor(ctx, ImGui.Col_Header) or 0x00000000
      ImGui.PushStyleColor(ctx, ImGui.Col_HeaderHovered, selCol)
      ImGui.PushStyleColor(ctx, ImGui.Col_HeaderActive,  selCol)
      local trim    = trims[idx]
      local secs    = trim and trim.fs > 0 and (trim.frames / trim.fs)
      local nameStr = names[idx] or '(empty)'
      local label   = secs
        and string.format('%s  %.2fs##%d', nameStr, secs, idx)
        or  string.format('%s##%d',         nameStr,       idx)
      if ImGui.Selectable(ctx, label, isSelected,
                          ImGui.SelectableFlags_AllowDoubleClick) then
        cm:set('transient', 'currentSample', idx)
        sv:setSlotFocus()
        if ImGui.IsMouseDoubleClicked(ctx, 0) then sv:auditionSlot(idx) end
      end
      ImGui.PopStyleColor(ctx, 2)
    end
    ImGui.EndTable(ctx)
  end

  -- Bottom strip: native waveform + draggable start/end + numeric inputs +
  -- preview. Drag overrides what the slab reports for the focused slot
  -- this frame, so the markers track the cursor without round-trip lag;
  -- the slab catches up on the next JSFX block.
  local function drawStrip(stripW, stripH)
    local slot     = cm:get('currentSample')
    local entries  = cm:get('slotEntries') or {}
    local entry    = entries[slot]
    if not entry or not entry.path then
      ImGui.TextDisabled(ctx, '(no sample loaded in slot ' .. tostring(slot) .. ')')
      return
    end
    local pp  = reaper.GetProjectPath(0)
    local abs = pp .. '/' .. entry.path
    local cols = math.max(64, math.floor(stripW))
    local pk  = peakFor(abs, cols)
    if not pk then ImGui.TextDisabled(ctx, 'cannot read ' .. abs); return end

    local trim   = trims[slot]
    local frames = (trim and trim.frames) or pk.frames
    local liveDrag = drag.slot == slot and drag.handle
    local startF = liveDrag and drag.startF or (trim and trim.start) or 0
    local endF   = liveDrag and drag.endF   or (trim and trim['end']) or (frames - 2)

    local canvasH = math.max(40, stripH - 32)
    local x0, y0  = ImGui.GetCursorScreenPos(ctx)
    ImGui.InvisibleButton(ctx, '##wave', stripW, canvasH)
    local hovered, active = ImGui.IsItemHovered(ctx), ImGui.IsItemActive(ctx)

    local dl   = ImGui.GetWindowDrawList(ctx)
    local mid  = y0 + canvasH * 0.5
    local hh   = canvasH * 0.45
    ImGui.DrawList_AddRectFilled(dl, x0, y0, x0 + stripW, y0 + canvasH, 0x1A1A1AFF)
    if pk.amps then
      for i = 1, pk.cols do
        local x = x0 + (i - 1) * (stripW / pk.cols)
        -- Floor at 1px so near-silence still draws as a centre line
        -- rather than a zero-length segment that renders nothing.
        local h = math.max(1, (pk.amps[i] or 0) * hh)
        ImGui.DrawList_AddLine(dl, x, mid - h, x, mid + h, 0xC8C8C8FF, 1)
      end
    else
      ImGui.DrawList_AddLine(dl, x0, mid, x0 + stripW, mid, 0x808080FF, 1)
    end
    local function frameToX(fr) return x0 + (fr / frames) * stripW end
    local sx, ex = frameToX(startF), frameToX(endF)
    ImGui.DrawList_AddRectFilled(dl, sx, y0, ex, y0 + canvasH, 0x4080FF22)
    ImGui.DrawList_AddLine(dl, sx, y0, sx, y0 + canvasH, 0x40FF80FF, 2)
    ImGui.DrawList_AddLine(dl, ex, y0, ex, y0 + canvasH, 0xFF8040FF, 2)

    if active then
      local mx, _ = ImGui.GetMousePos(ctx)
      local fr    = math.max(0, math.min(frames - 1,
                       math.floor(((mx - x0) / stripW) * frames + 0.5)))
      if not drag.handle then
        drag.handle = math.abs(fr - startF) <= math.abs(fr - endF) and 'start' or 'end'
        drag.slot   = slot
      end
      if drag.handle == 'start' then
        fr = math.max(0, math.min(endF - 1, fr))
        drag.startF, drag.endF = fr, endF
      else
        fr = math.max(startF + 1, math.min(frames - 2, fr))
        drag.startF, drag.endF = startF, fr
      end
      sm:setTrim(sv:getTrack(), slot, drag.startF, drag.endF)
    elseif drag.handle then
      drag.handle, drag.slot, drag.startF, drag.endF = nil, nil, nil, nil
    end
    if hovered then ImGui.SetMouseCursor(ctx, ImGui.MouseCursor_ResizeEW) end

    local previewW = 70
    local iw       = math.max(60, (stripW - previewW - 24) * 0.5)
    ImGui.SetNextItemWidth(ctx, iw)
    local sChanged, ns = ImGui.InputInt(ctx, 'Start##trimStart', startF, 0, 0)
    if sChanged then
      sm:setTrim(sv:getTrack(), slot, math.max(0, math.min(endF - 1, ns)), endF)
    end
    ImGui.SameLine(ctx)
    ImGui.SetNextItemWidth(ctx, iw)
    local eChanged, ne = ImGui.InputInt(ctx, 'End##trimEnd', endF, 0, 0)
    if eChanged then
      sm:setTrim(sv:getTrack(), slot, startF, math.max(startF + 1, math.min(frames - 2, ne)))
    end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, 'Preview##strip', previewW, 0) then sv:auditionSlot(slot) end
  end

  ---------- PUBLIC

  local sp = {}

  -- Track picker — lists tracks carrying the Continuum Sampler FX.
  -- Selecting one rekeys cm (via sv:setTrack) so the slot list reflects
  -- that track's stored entries.
  function sp:renderToolbarBits(_)
    local tracks  = sv:listTracks()
    local current = sv:getTrack()
    local label   = '(no track)'
    for _, e in ipairs(tracks) do
      if e.track == current then label = e.name; break end
    end

    ImGui.AlignTextToFramePadding(ctx)
    ImGui.Text(ctx, 'Track:')
    ImGui.SameLine(ctx, 0, 8)
    ImGui.SetNextItemWidth(ctx, 240)
    if ImGui.BeginCombo(ctx, '##sampleTrack', label) then
      pickerActive = true
      for _, e in ipairs(tracks) do
        if ImGui.Selectable(ctx, e.name, e.track == current) then
          sv:setTrack(e.track)
        end
      end
      ImGui.EndCombo(ctx)
    end

    ImGui.SameLine(ctx, 0, 16)
    local pipChanged, pipOn = ImGui.Checkbox(ctx, 'Preview in place',
                                             cm:get('previewInPlace'))
    if pipChanged then
      cm:set('global', 'previewInPlace', pipOn)
      if not pipOn then revertPreviewInPlace() end
    end
    ImGui.SameLine(ctx, 0, 12)
    local aolChanged, aolOn = ImGui.Checkbox(ctx, 'Advance on load',
                                             cm:get('advanceOnLoad'))
    if aolChanged then cm:set('global', 'advanceOnLoad', aolOn) end
  end

  function sp:renderBody(_, w, h, dispatch)
    pickerActive = false
    local root   = sv:browseRoot()
    local folder = sv:getCurrentFolder() or root

    trims = sm:readTrims(sv:getTrack(), trims)

    chrome.pushChromeStyles()
    ImGui.PushStyleColor(ctx, ImGui.Col_ChildBg, chrome.colour('editor.bg'))

    local stripH = math.min(140, math.floor(h * 0.4))
    local topH   = h - stripH
    local treeW  = math.max(220, w * 0.25)
    local filesW = (w - treeW) * 0.55

    -- Left pane: tree with Up button header
    if ImGui.BeginChild(ctx, '##sampleTree', treeW, topH,
                        ImGui.ChildFlags_Borders) then
      local parent = fs.parent(root)
      chrome.disabledIf(parent == '', function()
        if ImGui.SmallButton(ctx, '↑##treeUp') then sv:setBrowseRoot(parent) end
      end)
      ImGui.SameLine(ctx, 0, 6)
      ImGui.TextDisabled(ctx, fs.basename(root))
      ImGui.Separator(ctx)
      drawTree(root)
    end
    ImGui.EndChild(ctx)

    ImGui.SameLine(ctx)

    -- Middle pane: folders + files. Dispatch browser shortcuts only when
    -- this child has keyboard focus, so they don't fire from the slots pane.
    local filesFocused = false
    if ImGui.BeginChild(ctx, '##sampleFiles', filesW, topH,
                        ImGui.ChildFlags_Borders,
                        ImGui.WindowFlags_NoNav) then
      filesFocused = ImGui.IsWindowFocused(ctx)
      drawFiles(folder, root)
    end
    ImGui.EndChild(ctx)

    -- Narrow column: action buttons
    ImGui.SameLine(ctx)
    if ImGui.BeginChild(ctx, '##loadBtnCol', 58, topH, ImGui.ChildFlags_None) then
      local bw, _    = ImGui.GetContentRegionAvail(ctx)
      local hasFile  = sv:getSelectedFile() ~= nil
      local entries  = cm:get('slotEntries') or {}
      local hasEntry = entries[cm:get('currentSample')] ~= nil

      chrome.disabledIf(not hasFile, function()
        if ImGui.Button(ctx, '>##load',  bw, 0) then sv:loadSelectedIntoCurrent() end
      end)

      chrome.disabledIf(not hasEntry, function()
        if ImGui.Button(ctx, 'Clear##slot', bw, 0) then sv:clearCurrentSlot() end
      end)

      chrome.disabledIf(not sv:canAuditionCurrent(), function()
        if ImGui.Button(ctx, 'Play##slot',  bw, 0) then sv:auditionCurrent() end
      end)

      if ImGui.Button(ctx, 'Stop##slot',  bw, 0) then sv:stopAudition() end
    end
    ImGui.EndChild(ctx)
    ImGui.SameLine(ctx)

    -- Right pane: slots — greyed when no sampler track is active
    local hasTrack = sv:getTrack() ~= nil
    chrome.disabledIf(not hasTrack, function()
      if ImGui.BeginChild(ctx, '##sampleSlots', 0, topH,
                          ImGui.ChildFlags_Borders) then
        drawSlots()
      end
      ImGui.EndChild(ctx)
    end)

    -- Bottom strip: native waveform + trim editor for the focused slot
    chrome.disabledIf(not hasTrack, function()
      if ImGui.BeginChild(ctx, '##sampleStrip', w, stripH,
                          ImGui.ChildFlags_Borders) then
        local sw, _ = ImGui.GetContentRegionAvail(ctx)
        drawStrip(sw, stripH)
      end
      ImGui.EndChild(ctx)
    end)

    if pip.slot ~= nil then
      if pip.justTriggered then
        pip.justTriggered = false
      elseif sv:getBrowserPath() ~= pip.browserAtTrigger
          or cm:get('currentSample') ~= pip.slotAtTrigger
          or ImGui.IsMouseClicked(ctx, 0) then
        revertPreviewInPlace()
      end
    end

    if dispatch then dispatch(self:focusState()) end
    ImGui.SetMouseCursor(ctx, ImGui.MouseCursor_Arrow)
    ImGui.PopStyleColor(ctx, 1)
    chrome.popChromeStyles()
  end

  function sp:renderStatusBar(_)
    local tracks = sv:listTracks()
    local cur    = sv:getTrack()
    local name   = '(no track)'
    for _, e in ipairs(tracks) do
      if e.track == cur then name = e.name; break end
    end
    local slot = cm:get('currentSample')
    local slotName = (cm:get('samplerNames') or {})[slot]
    ImGui.Text(ctx, string.format('Track: %s | Slot: %02X%s',
      name, slot, slotName and (' ' .. slotName) or ''))
  end

  function sp:bind(track)
    cm:clearTake()
    if track then sv:setTrack(track) end
  end

  function sp:unbind() revertPreviewInPlace() end

  -- A popup owns input this frame → suppress global shortcuts.
  function sp:focusState()
    if not ctx then return { suppressKbd = false, acceptCmds = false } end
    return {
      suppressKbd = pickerActive,
      acceptCmds  = (not pickerActive) and not ImGui.IsAnyItemActive(ctx),
    }
  end

  function sp:handleInput() end
  function sp:save()        end
  function sp:load()        end

  local sampler = cmgr:scope('sample')
  sampler:registerAll {
    browserUp      = goUp,
    browserPreview = function()
      if sv:isBrowserFolder() then
        local p = sv:getBrowserPath()
        if p == UP then goUp()
        elseif p then sv:setCurrentFolder(p) end
      else
        sv:auditionPath(sv:getSelectedFile())
      end
    end,
    browserAssign  = function()
      if sv:isBrowserFolder() then return end
      sv:loadSelectedIntoCurrent()
    end,
    slotNext = function()
      local cur = cm:get('currentSample')
      if cur < N_SLOTS - 1 then cm:set('transient', 'currentSample', cur + 1) end
    end,
    slotPrev = function()
      local cur = cm:get('currentSample')
      if cur > 0 then cm:set('transient', 'currentSample', cur - 1) end
    end,
  }
  sampler:bindAll {
    browserUp      = { { ImGui.Key_UpArrow,    ImGui.Mod_Ctrl  } },
    browserPreview = { { ImGui.Key_DownArrow,  ImGui.Mod_Ctrl  } },
    browserAssign  = { { ImGui.Key_RightArrow, ImGui.Mod_Ctrl  } },
    slotNext       = { { ImGui.Key_Period,     ImGui.Mod_Shift } },
    slotPrev       = { { ImGui.Key_Comma,      ImGui.Mod_Shift } },
  }

  return sp
end
