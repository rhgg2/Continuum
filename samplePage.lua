-- See docs/samplePage.md for the model.
-- @noindex

--@map:invariant render-only: persistent state lives in sampleView (selection/folder/track), configManager (slotEntries, currentSample, previewInPlace), and sampleManager (JSFX); only frame-local caches and ephemeral drag/preview state live here
--@map:invariant slot index space is linear 0..N_SLOTS-1 (N_SLOTS=64); the slot grid is a 2-col ImGui table (right-aligned index, stretch label) — no row/col addressing
--@map:invariant strip coordinates are audio sample-frames (0..frames-1); pixel x is derived only at draw via frameToX, and InputInt round-trips frames directly
--@map:invariant peakCache/durCache are file-path-keyed and survive across frames; peakCache entries are dropped whenever the requested column count changes (window resize) so a strip never reuses peaks computed at a foreign width
--@map:invariant browser keyboard shortcuts (browserUp/Preview/Assign, slotNext/Prev) are dispatched only when the sample-scope is active in cmgr; the middle pane disables ImGui nav so its own arrow handling produces a single focus rectangle
--@map:invariant preview-in-place leaves cm:slotEntries untouched while the JSFX slot is staged to a transient file; sm:syncSlot pushes cm's truth back on revert
--@map:invariant drag.handle is set on the first active frame (closest of start/end to the mouse wins) and held until the button releases — the choice does not switch mid-drag

loadModule('fs')

if not reaper.ImGui_GetBuiltinPath then
  return reaper.MB('ReaImGui is not installed or too old.', 'My script', 0)
end
package.path = reaper.ImGui_GetBuiltinPath() .. '/?.lua;' .. package.path
local ImGui = require 'imgui' '0.10'

local N_SLOTS = 64

local UP = '__up__'   -- sentinel path for the '..' navigation entry

--@map:contract owns the sample substack: builds sm and sv internally; coord supplies only primitives + the take (per-frame, via tick) and a slot index (on demand, via loadSampleIntoSlot)
--@map:contract track-picker is a proxy — onPick routes through onPickTrack so coord owns the active sampler track; the page never picks its own track
function newSamplePage(cm, cmgr, chrome, gui, onPickTrack)
  local ctx    = gui.ctx
  local rename = nil
  local sm     = newSampleManager(fs.fileOps)
  local lastProjectPath = nil

  local sv
  sv = newSampleView(cm,
    function(slot, srcPath)
      return sm:assign(sv:getTrack(), slot, srcPath, reaper.GetProjectPath(0), cm)
    end,
    function(slot, bounds) return sm:previewSlot(sv:getTrack(), slot, bounds) end,
    function(path)         return sm:previewPath(sv:getTrack(), path)         end,
    function()             return sm:listTracks()                             end,
    function(slot)         return sm:clearSlot(sv:getTrack(), slot, cm)       end,
    function()             return sm:stopPreview(sv:getTrack())               end)

  --@map:shape peakCacheEntry = { src?=PCM_Source, cols=int, fs=number, nch=int, frames=int, lenSec=number, building=bool, amps?={number,...} } | false
  --@map:shape durCacheEntry  = number | false
  --@map:shape drag = { handle='start'|'end'|nil, slot=int|nil, startF=int|nil, endF=int|nil }
  local peakCache = {}
  local durCache  = {}
  local drag      = { handle = nil, slot = nil, startF = nil, endF = nil }

  --@map:shape pip = { slot=int|nil, track=track|nil, justTriggered=bool, browserAtTrigger=path|nil, slotAtTrigger=int|nil }

  local pip = { slot = nil, justTriggered = false,
                browserAtTrigger = nil, slotAtTrigger = nil }

  --@map:contract no-op when no preview is staged; otherwise restores the JSFX slot to cm's stored entry and clears all pip fields
  local function revertPreviewInPlace()
    if pip.slot == nil then return end
    sm:syncSlot(pip.track, pip.slot, cm)
    pip.slot, pip.track = nil, nil
    pip.browserAtTrigger, pip.slotAtTrigger = nil, nil
    pip.justTriggered = false
  end

  --@map:contract silently aborts if sm:stageInto fails (returns false); otherwise pip captures the nav state at trigger so any subsequent change reverts
  local function triggerPreviewInPlace(srcPath)
    local slot  = cm:get('currentSample')
    local track = sv:getTrack()
    if not sm:stageInto(track, slot, srcPath, reaper.GetProjectPath(0)) then return end
    pip.slot             = slot
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
  -- are interleaved within each block per pixel. Reduce to per-pixel
  -- (hi, lo) — signed max/min across channels — so the strip can draw
  -- asymmetrically and reveal DC offset or one-sided transients.
  --@map:contract returns nil for unreadable files (cached as false); returns an entry with hi=nil while peaks are still building (caller must draw a flat line); width-mismatched cache entries are dropped before re-reading
  local function peakFor(abs, cols)
    local hit = peakCache[abs]
    if hit == false then return nil end
    if hit and hit.cols ~= cols then
      if hit.src then reaper.PCM_Source_Destroy(hit.src) end
      hit, peakCache[abs] = nil, nil
    end
    if hit and hit.hi then return hit end

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
    local minBase, hi, lo = cols * nch, {}, {}
    for i = 0, cols - 1 do
      local h = buf[i * nch + 1] or 0
      local l = buf[minBase + i * nch + 1] or 0
      for c = 1, nch - 1 do
        local mx = buf[i * nch + c + 1] or 0
        local mn = buf[minBase + i * nch + c + 1] or 0
        if mx > h then h = mx end
        if mn < l then l = mn end
      end
      hi[i + 1], lo[i + 1] = h, l
    end
    hit.hi, hit.lo = hi, lo
    return hit
  end

  --@map:contract recursive walk; only descends into open TreeNodes — listDirs is not called for collapsed branches
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

  --@map:contract no-op at the browse root; otherwise highlights the folder being left so a subsequent down-arrow lands somewhere meaningful
  local function goUp()
    local root   = sv:browseRoot()
    local folder = sv:getCurrentFolder() or root
    if folder == root then return end
    local parent = fs.parent(folder)
    if parent == '' or #parent < #root then parent = root end
    sv:setBrowserItem(folder, true)   -- highlight the folder we just left
    sv:setCurrentFolder(parent ~= root and parent or nil)
  end

  --@map:contract items are ordered '..' (if not at root), then folders (alpha), then audio files; selection auto-snaps to items[1] when the prior selection isn't in the new list
  --@map:contract double-click semantics: '..' → goUp; folder → setCurrentFolder; file → triggerPreviewInPlace if previewInPlace is on, else auditionPath
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

  --@map:contract iterates all N_SLOTS rows whether populated or not (empty rows render as '(empty)'); single-click sets currentSample and slotFocus, double-click also auditions
  local function drawSlots()
    local entries = cm:get('slotEntries') or {}
    local current = cm:get('currentSample')
    local pp      = reaper.GetProjectPath(0)
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
      local entry   = entries[idx]
      if rename and rename.slot == idx then
        if rename.justOpened then ImGui.SetKeyboardFocusHere(ctx) end
        ImGui.SetNextItemWidth(ctx, -1)
        local rv, buf = ImGui.InputText(ctx, '##rename' .. idx, rename.buf,
                                        ImGui.InputTextFlags_EnterReturnsTrue
                                        | ImGui.InputTextFlags_AutoSelectAll)
        local active = ImGui.IsItemActive(ctx)
        if rv then
          sm:setName(sv:getTrack(), idx, buf, cm)
          rename = nil
        elseif ImGui.IsKeyPressed(ctx, ImGui.Key_Escape) then
          rename = nil
        elseif rename.justOpened then
          rename.buf, rename.justOpened = buf, nil
        elseif not active then
          rename = nil
        else
          rename.buf = buf
        end
      else
        local nameStr = (entry and entry.name) or '(empty)'
        local secs    = entry and entry.path and durFor(pp .. '/' .. entry.path)
        local label   = secs
          and string.format('%s  %.2fs##%d', nameStr, secs, idx)
          or  string.format('%s##%d',         nameStr,       idx)
        if ImGui.Selectable(ctx, label, isSelected,
                            ImGui.SelectableFlags_AllowDoubleClick) then
          cm:set('transient', 'currentSample', idx)
          sv:setSlotFocus()
          if ImGui.IsMouseDoubleClicked(ctx, 0) then sv:auditionSlot(idx) end
        end
      end
      ImGui.PopStyleColor(ctx, 2)
    end
    ImGui.EndTable(ctx)
  end

  -- Drag locally overrides start/end this frame so the markers track the
  -- cursor without round-trip lag; cm catches up on the next setTrim.
  --@map:contract early-returns when the focused slot is empty or the source can't be read; otherwise every code path through here calls sm:setTrim before frame end if the user changed start/end
  --@map:contract drag handle is held in `drag` across frames keyed by slot — switching to a different slot mid-drag implicitly drops the drag (liveDrag check fails)
  --@map:contract trim invariants enforced at write: 0 <= start <= end-1 and start+1 <= end <= frames-2 (last 2 frames reserved)
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

    local frames   = pk.frames
    local liveDrag = drag.slot == slot and drag.handle
    local startF   = liveDrag and drag.startF or entry.start  or 0
    local endF     = liveDrag and drag.endF   or entry['end'] or (frames - 2)

    local canvasH = math.max(40, stripH - 32)
    local x0, y0  = ImGui.GetCursorScreenPos(ctx)
    ImGui.InvisibleButton(ctx, '##wave', stripW, canvasH)
    local hovered, active = ImGui.IsItemHovered(ctx), ImGui.IsItemActive(ctx)

    local dl   = ImGui.GetWindowDrawList(ctx)
    local mid  = y0 + canvasH * 0.5
    local hh   = canvasH * 0.45
    ImGui.DrawList_AddRectFilled(dl, x0, y0, x0 + stripW, y0 + canvasH, 0x1A1A1AFF)
    if pk.hi then
      -- Quad-fill between adjacent columns: a per-column vertical bar
      -- leaves diagonal gaps when hi/lo step between neighbours; filling
      -- the envelope joins them up. 1px floor on each column so a
      -- near-silence span still draws a centre line.
      local cw = stripW / pk.cols
      local pYT = mid - (pk.hi[1] or 0) * hh
      local pYB = mid - (pk.lo[1] or 0) * hh
      if pYB - pYT < 1 then pYB = pYT + 1 end
      for i = 2, pk.cols do
        local x  = x0 + (i - 1) * cw
        local yT = mid - (pk.hi[i] or 0) * hh
        local yB = mid - (pk.lo[i] or 0) * hh
        if yB - yT < 1 then yB = yT + 1 end
        ImGui.DrawList_AddQuadFilled(dl, x - cw, pYT, x, yT,
                                         x, yB,       x - cw, pYB,
                                         0xC8C8C8FF)
        pYT, pYB = yT, yB
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
      sm:setTrim(sv:getTrack(), slot, drag.startF, drag.endF, cm)
    elseif drag.handle then
      drag.handle, drag.slot, drag.startF, drag.endF = nil, nil, nil, nil
    end
    if hovered then ImGui.SetMouseCursor(ctx, ImGui.MouseCursor_ResizeEW) end

    local previewW = 70
    local iw       = math.max(60, (stripW - previewW - 24) * 0.5)
    ImGui.SetNextItemWidth(ctx, iw)
    local sChanged, ns = ImGui.InputInt(ctx, 'Start##trimStart', startF, 0, 0)
    if sChanged then
      sm:setTrim(sv:getTrack(), slot, math.max(0, math.min(endF - 1, ns)), endF, cm)
    end
    ImGui.SameLine(ctx)
    ImGui.SetNextItemWidth(ctx, iw)
    local eChanged, ne = ImGui.InputInt(ctx, 'End##trimEnd', endF, 0, 0)
    if eChanged then
      sm:setTrim(sv:getTrack(), slot, startF, math.max(startF + 1, math.min(frames - 2, ne)), cm)
    end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, 'Preview##strip', previewW, 0) then sv:auditionSlot(slot) end
  end

  local toolbar  -- lazy: chrome may be nil at construction in tests

  --@map:shape ToolbarSegment = { id, render = fn(), visible? = fn() -> bool }
  local toolbarSegments = {
    {
      id = 'track',
      render = function()
        local tracks  = sv:listTracks()
        local current = sv:getTrack()
        local label   = '(no track)'
        local items   = {}
        for _, e in ipairs(tracks) do
          if e.track == current then label = e.name end
          items[#items + 1] = { label   = e.name,
                                key     = e.track,
                                current = e.track == current }
        end
        chrome.drawPicker {
          kind        = 'sampleTrack',
          heading     = 'Track',
          buttonLabel = label,
          width       = 240,
          items       = items,
          onPick      = function(t) onPickTrack(t) end,
        }
      end,
    },
    {
      id = 'previewOpts',
      render = function()
        local pipChanged, pipOn = chrome.checkbox('Preview in place',
                                                  cm:get('previewInPlace'))
        if pipChanged then
          cm:set('global', 'previewInPlace', pipOn)
          if not pipOn then revertPreviewInPlace() end
        end
        ImGui.SameLine(ctx, 0, 12)
        local aolChanged, aolOn = chrome.checkbox('Advance on load',
                                                  cm:get('advanceOnLoad'))
        if aolChanged then cm:set('global', 'advanceOnLoad', aolOn) end
      end,
    },
  }

  ---------- PUBLIC

  local sp = {}

  function sp:renderToolbarBits(_)
    chrome.resetPickerActive()
    toolbar = toolbar or chrome.makeToolbar()
    toolbar(toolbarSegments)
  end

  --@map:contract layout splits vertically (stripH = min(140, h*0.4)) then horizontally inside the top region (treeW = max(220, w*0.25); filesW = (w-treeW)*0.55); the right slots pane consumes the remainder
  --@map:contract whole body is wrapped in chrome.disabledIf(not isLive) — when the bound track has no live sampler FX the entire interactive surface is greyed and inert
  --@map:contract pip auto-revert is checked at end of body: justTriggered=true edge consumes the trigger frame, after which any browser/slot-focus change or stray mouse click reverts
  function sp:renderBody(_, w, h, dispatch)
    local root   = sv:browseRoot()
    local folder = sv:getCurrentFolder() or root
    local track  = sv:getTrack()
    local isLive = track and sm:isLive(track)

    chrome.pushChromeStyles()
    ImGui.PushStyleColor(ctx, ImGui.Col_ChildBg, chrome.colour('editor.bg'))

    chrome.disabledIf(not isLive, function()
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

    -- Middle pane: folders + files
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

    -- Right pane: slots
    if ImGui.BeginChild(ctx, '##sampleSlots', 0, topH,
                        ImGui.ChildFlags_Borders) then
      drawSlots()
    end
    ImGui.EndChild(ctx)

    -- Bottom strip: native waveform + trim editor for the focused slot
    if ImGui.BeginChild(ctx, '##sampleStrip', w, stripH,
                        ImGui.ChildFlags_Borders) then
      local sw, _ = ImGui.GetContentRegionAvail(ctx)
      drawStrip(sw, stripH)
    end
    ImGui.EndChild(ctx)
    end)   -- /chrome.disabledIf(not isLive)

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
    local entry = (cm:get('slotEntries') or {})[slot]
    local slotName = entry and entry.name
    ImGui.Text(ctx, string.format('Track: %s | Slot: %02X%s',
      name, slot, slotName and (' ' .. slotName) or ''))
  end

  --@map:contract bind forwards the track to sv (which re-keys cm via cm:setTrack); never touches cm:setContext — the tracker take stays bound for sm:probeMode
  function sp:bind(track)
    if track then sv:setTrack(track) end
  end

  --@map:contract listTracks proxies sm:listTracks via sv — coord queries this to seed its active sampler track on first activation
  function sp:listTracks() return sv:listTracks() end

  --@map:contract unbind reverts any preview-in-place but leaves cm and sv state alone — the next bind can resume on the same track
  function sp:unbind() revertPreviewInPlace() end

  --@map:contract tick runs every frame regardless of active page — sm needs the tracker take to maintain isTrackerMode and the gmem mailbox; project-path migration runs only on actual change
  function sp:tick(take)
    sm:probeMode(take, cm)
    local pp = reaper.GetProjectPath(0)
    if lastProjectPath ~= pp then
      sm:setPrefix(pp)
      if lastProjectPath then sm:migrate(pp, lastProjectPath, cm) end
    end
    sm:tick(cm)
    lastProjectPath = pp
  end

  --@map:contract opens a file dialog and assigns the chosen path to (take's track, slot); silent no-op on cancel; called by coord's tracker-scope command, not by sample-page UI
  function sp:loadSampleIntoSlot(take, slot)
    local rv, path = reaper.GetUserFileNameForRead('', 'Load sample into current slot', '')
    if rv and path ~= '' then
      sm:assign(reaper.GetMediaItemTake_Track(take), slot, path,
                reaper.GetProjectPath(0), cm)
    end
  end

  --@map:contract acceptCmds is also blocked by ImGui.IsAnyItemActive (e.g. an InputInt being edited) so trim-field typing doesn't trigger commands
  function sp:focusState()
    if not ctx then return { suppressKbd = false, acceptCmds = false } end
    local pa = chrome.pickerIsActive()
    return {
      suppressKbd = pa or rename ~= nil,
      acceptCmds  = (not pa) and not ImGui.IsAnyItemActive(ctx),
    }
  end

  function sp:handleInput() end
  function sp:save()        end
  function sp:load()        end

  --@map:invariant sample-scope command bindings: Ctrl+Up=browserUp, Ctrl+Down=browserPreview (descend folder or audition file), Ctrl+Right=browserAssign (load file into current slot), Shift+./Shift+,=slotNext/Prev (clamped to [0, N_SLOTS-1])
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
    slotRename = function()
      local idx = cm:get('currentSample')
      if not idx then return end
      local entries = cm:get('slotEntries') or {}
      local entry   = entries[idx]
      rename = { slot = idx, buf = (entry and entry.name) or '', justOpened = true }
    end,
  }
  sampler:bindAll {
    browserUp      = { { ImGui.Key_UpArrow,    ImGui.Mod_Ctrl  } },
    browserPreview = { { ImGui.Key_DownArrow,  ImGui.Mod_Ctrl  } },
    browserAssign  = { { ImGui.Key_RightArrow, ImGui.Mod_Ctrl  } },
    slotNext       = { { ImGui.Key_Period,     ImGui.Mod_Shift } },
    slotPrev       = { { ImGui.Key_Comma,      ImGui.Mod_Shift } },
    slotRename     = { { ImGui.Key_F2 } },
  }

  return sp
end
