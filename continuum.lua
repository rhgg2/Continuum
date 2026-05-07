-- See docs/continuum.md for the model and API reference.

function loadModule(module)
  local info = debug.getinfo(1,'S')
  local script_path = info.source:match[[^@?(.*[\/])[^\/]-$]]
  require(script_path .. module)
end

loadModule('util')
loadModule('configManager')
loadModule('midiManager')
loadModule('trackerManager')
loadModule('commandManager')
loadModule('editCursor')
loadModule('trackerView')
loadModule('sampleManager')
loadModule('sampleView')
loadModule('swingEditor')
loadModule('curveEditor')
loadModule('trackerPage')
loadModule('samplePage')

local ImGui = require 'imgui' '0.10'

math.randomseed(os.time())

local function print(...)
  return util.print(...)
end

local function err_handler(err)
  reaper.ShowConsoleMsg('\nERROR:\n' .. tostring(err) .. '\n\n')
  reaper.ShowConsoleMsg(debug.traceback() .. '\n')
  reaper.defer(function() end)
end

local function run(fn)
  reaper.ClearConsole()
  xpcall(fn, err_handler)
end

-- Filesystem ops for slotStore. Stream-copy in 64KB chunks so big samples
-- don't allocate a single Lua string the size of the file. os.rename
-- fails across filesystems, so move falls back to copy+delete.
local function copyFileBytes(src, dst)
  local fin = io.open(src, 'rb');  if not fin  then return false end
  local fout = io.open(dst, 'wb'); if not fout then fin:close(); return false end
  while true do
    local chunk = fin:read(64 * 1024)
    if not chunk then break end
    fout:write(chunk)
  end
  fin:close(); fout:close()
  return true
end

local fileOps = {
  copy  = copyFileBytes,
  move  = function(src, dst)
    if os.rename(src, dst) then return true end
    if copyFileBytes(src, dst) then os.remove(src); return true end
    return false
  end,
  mkdir  = function(dir) reaper.RecursiveCreateDirectory(dir, 0) end,
  exists = function(path) return fs.exists(path) end,
  hash   = function(path) return fs.hashFile(path) end,
}

local function createImGui()
  local ctx   = ImGui.CreateContext('Continuum Tracker')
  ImGui.SetConfigVar(ctx, ImGui.ConfigVar_ViewportsNoDecoration, 0)
  -- Body drags must not move the window — only title-bar drags do.
  -- Lane-strip and grid drags otherwise propagate as a window move.
  ImGui.SetConfigVar(ctx, ImGui.ConfigVar_WindowsMoveFromTitleBarOnly, 1)
  -- macOS' system font is private (dot-prefixed) and not reachable by
  -- family name, so load SFNS.ttf directly. Other platforms resolve by name.
  local osName = reaper.GetOS()
  local font   = ImGui.CreateFont('Source Code Pro')
  local uiFont = (osName:find('OSX') or osName:find('mac'))
               and ImGui.CreateFontFromFile('/System/Library/Fonts/SFNS.ttf')
               or  ImGui.CreateFont(osName:find('Win') and 'Segoe UI' or 'sans-serif')
  ImGui.Attach(ctx, font)
  ImGui.Attach(ctx, uiFont)
  return ctx, font, uiFont
end

----- Chrome

-- Builds a `chrome` table threaded into every page. Owns the colour
-- cache (one per coordinator, invalidated on cm:configChanged), the
-- chrome push/pop pairs that paint the toolbar palette, and the
-- vertical separator helper. Closes over cm and ctx.
local function newChrome(cm, ctx)
  local cache = {}
  cm:subscribe('configChanged', function() cache = {} end)

  -- Walk the colour table from a starting cm key to a terminal atom.
  -- Entries: {r,g,b,a} atom | 'fullKey' alias | {'fullKey', a} alias-with-
  -- alpha-override. Outermost override wins; cycles raise with the chain.
  local function resolve(key)
    local seen, override = {}, nil
    while true do
      if seen[key] then
        seen[#seen+1] = key
        error('colour cycle: ' .. table.concat(seen, ' → '))
      end
      seen[#seen+1] = key; seen[key] = true
      local v = cm:get(key)
      if v == nil then error('unknown colour: ' .. key) end
      if type(v) == 'string' then
        key = v
      elseif type(v[1]) == 'string' then
        key      = v[1]
        override = override or v[2]
      else
        return v[1], v[2], v[3], override or v[4]
      end
    end
  end

  local function colour(name)
    name = name or 'text'
    if not cache[name] then
      local r, g, b, a = resolve('colour.' .. name)
      cache[name] = ImGui.ColorConvertDouble4ToU32(r, g, b, a)
    end
    return cache[name]
  end

  local function pushChromeStyles()
    ImGui.PushStyleVar(ctx, ImGui.StyleVar_FrameBorderSize, 1)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text,           colour('toolbar.text'))
    ImGui.PushStyleColor(ctx, ImGui.Col_Button,         colour('toolbar.button'))
    ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered,  colour('toolbar.buttonHover'))
    ImGui.PushStyleColor(ctx, ImGui.Col_ButtonActive,   colour('toolbar.buttonActive'))
    ImGui.PushStyleColor(ctx, ImGui.Col_FrameBg,        colour('toolbar.button'))
    ImGui.PushStyleColor(ctx, ImGui.Col_FrameBgHovered, colour('toolbar.buttonHover'))
    ImGui.PushStyleColor(ctx, ImGui.Col_FrameBgActive,  colour('toolbar.buttonActive'))
    ImGui.PushStyleColor(ctx, ImGui.Col_CheckMark,      colour('toolbar.checkMark'))
    ImGui.PushStyleColor(ctx, ImGui.Col_PopupBg,        colour('toolbar.popupBg'))
    ImGui.PushStyleColor(ctx, ImGui.Col_Border,         colour('toolbar.buttonBorder'))
  end

  local function popChromeStyles()
    ImGui.PopStyleColor(ctx, 10)
    ImGui.PopStyleVar(ctx, 1)
  end

  -- Window-shell additions on top of pushChromeStyles. Used by floating
  -- chrome surfaces (swing editor, modals): hairline window border,
  -- opaque parchment fill on window/title/popup backgrounds, and a
  -- separator that matches the chrome border. Surfaces use editor.bg
  -- (opaque pale); toolbar.bg is authored at 0.5 alpha and would bleed
  -- the grid through.
  local function pushChromeWindow()
    pushChromeStyles()
    ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowBorderSize, 1)
    ImGui.PushStyleColor(ctx, ImGui.Col_WindowBg,         colour('editor.bg'))
    ImGui.PushStyleColor(ctx, ImGui.Col_PopupBg,          colour('editor.bg'))
    ImGui.PushStyleColor(ctx, ImGui.Col_TitleBg,          colour('editor.bg'))
    ImGui.PushStyleColor(ctx, ImGui.Col_TitleBgActive,    colour('editor.bg'))
    ImGui.PushStyleColor(ctx, ImGui.Col_TitleBgCollapsed, colour('editor.bg'))
    ImGui.PushStyleColor(ctx, ImGui.Col_Separator,        colour('toolbar.buttonBorder'))
  end

  local function popChromeWindow()
    ImGui.PopStyleColor(ctx, 6)
    ImGui.PopStyleVar(ctx, 1)
    popChromeStyles()
  end

  -- reaper-imgui has no Separator(Vertical); draw a 1px vertical line
  -- via the window draw list and reserve a Dummy slot so SameLine works.
  local function verticalSeparator()
    local x, y = ImGui.GetCursorScreenPos(ctx)
    local h    = ImGui.GetFrameHeight(ctx)
    ImGui.DrawList_AddLine(ImGui.GetWindowDrawList(ctx),
      x, y, x, y + h, colour('separator'), 1)
    ImGui.Dummy(ctx, 1, h)
  end

  -- RAII wrapper for ImGui.BeginDisabled / EndDisabled: dropping the
  -- bracket-match removes a class of mismatched-pop bugs on early return.
  local function disabledIf(cond, fn)
    if cond then ImGui.BeginDisabled(ctx) end
    fn()
    if cond then ImGui.EndDisabled(ctx) end
  end

  -- Compact checkbox / radio for toolbar contexts: zero FramePadding
  -- shrinks the box to its glyph; the +3 cursorY nudge re-aligns the
  -- small box with framed siblings on the same row.
  local function checkbox(label, value)
    ImGui.PushStyleVar(ctx, ImGui.StyleVar_FramePadding, 0, 0)
    ImGui.SetCursorPosY(ctx, ImGui.GetCursorPosY(ctx) + 3)
    local changed, v = ImGui.Checkbox(ctx, label, value)
    ImGui.PopStyleVar(ctx, 1)
    return changed, v
  end

  local function radio(label, active)
    ImGui.PushStyleVar(ctx, ImGui.StyleVar_FramePadding, 0, 0)
    ImGui.SetCursorPosY(ctx, ImGui.GetCursorPosY(ctx) + 3)
    local pressed = ImGui.RadioButton(ctx, label, active)
    ImGui.PopStyleVar(ctx, 1)
    return pressed
  end

  -- Toolbar layout closure: caches each segment's last-frame width keyed
  -- by id, then before drawing segment N it peeks whether
  --   (previous right edge) + separator + cached(N) fits the row;
  -- if not, the leading SameLine is skipped and ImGui places N on a new
  -- row at the row's left margin. One-frame slop on size changes —
  -- acceptable for a toolbar.
  --
  -- Each segment: { id, render, visible? }. Segments wrap BeginGroup /
  -- EndGroup so GetItemRectMin/Max measures the whole segment, not just
  -- the trailing widget.
  local function makeToolbar()
    local widths = {}
    return function(segments)
      local startX = ImGui.GetCursorScreenPos(ctx)
      local availW = ImGui.GetContentRegionAvail(ctx)
      local rightX = startX + availW
      local lastEndX, first = startX, true
      for _, seg in ipairs(segments) do
        if not seg.visible or seg.visible() then
          local cachedW = widths[seg.id] or 0
          if not first then
            local sepW = 12 + 1 + 12
            if lastEndX + sepW + cachedW <= rightX then
              ImGui.SameLine(ctx, 0, 12)
              verticalSeparator()
              ImGui.SameLine(ctx, 0, 12)
            end
          end
          ImGui.BeginGroup(ctx)
          seg.render()
          ImGui.EndGroup(ctx)
          local minX = ImGui.GetItemRectMin(ctx)
          local maxX = ImGui.GetItemRectMax(ctx)
          widths[seg.id] = maxX - minX
          lastEndX, first = maxX, false
        end
      end
    end
  end

  return {
    colour            = colour,
    pushChromeStyles  = pushChromeStyles,
    popChromeStyles   = popChromeStyles,
    pushChromeWindow  = pushChromeWindow,
    popChromeWindow   = popChromeWindow,
    verticalSeparator = verticalSeparator,
    disabledIf        = disabledIf,
    checkbox          = checkbox,
    radio             = radio,
    makeToolbar       = makeToolbar,
  }
end

----- Keyboard router

-- Walk the cmgr keymap chain, fire the first binding pressed this frame,
-- and report whether any bound key is held with no modifier (so the page
-- can gate its raw character queue against held command keys with
-- different repeat timing).
--
-- A binding fires via cmgr:invoke; first-hit wins, hard-shadowing root.
-- A command may decline (return false) to release the key to the page;
-- we clear commandHeld in that case so the char queue sees it.
local function dispatchKeys(state, cmgr, ctx)
  if state.suppressKbd or not state.acceptCmds then
    return { consumed = false, commandHeld = false }
  end
  local commandHeld = false
  for _, keymap in ipairs(cmgr:keychain()) do
    for command, keys in pairs(keymap) do
      for _, spec in ipairs(keys) do
        local key, mods = cmgr:keySpec(spec, ImGui)
        if ImGui.IsKeyDown(ctx, key) and mods == ImGui.Mod_None then
          commandHeld = true
        end
        if ImGui.IsKeyPressed(ctx, key) and ImGui.GetKeyMods(ctx) == mods then
          if cmgr:invoke(command) == false then
            commandHeld = false
          else
            return { consumed = true, commandHeld = commandHeld }
          end
        end
      end
    end
  end
  return { consumed = false, commandHeld = commandHeld }
end

----- Coordinator

local CHROME_PAD_X, CHROME_PAD_Y = 8, 4

-- Owns ImGui Begin/End, the toolbar/statusBar bands, the mode switcher,
-- per-frame keyboard dispatch, and sampler upkeep. Pages contribute the
-- toolbar bits after the switcher, the body, and the status content.
-- sweptForTracker re-arms when trackerMode goes false: a fresh FX needs
-- a fresh push of every slot since @serialize starts empty.
local function newCoordinator(cm, cmgr, sm, take, ctx, font, uiFont)
  local pages, active = {}, nil
  local quitting = false
  local sweptForTracker, lastProjectPath = false, nil
  local chrome = newChrome(cm, ctx)

  local function tick()
    sm:probeMode(take, cm)
    local pp = reaper.GetProjectPath(0)
    if cm:get('trackerMode') then
      local track = reaper.GetMediaItemTake_Track(take)
      if lastProjectPath and lastProjectPath ~= pp then
        sm:migrate(pp, lastProjectPath, cm)
      end
      if not sweptForTracker then
        sm:setPrefix(pp)
        sm:sweep(track, cm)
        sweptForTracker = true
      end
      sm:readNames(track, cm)
    else
      sweptForTracker = false
    end
    lastProjectPath = pp
  end

  local function drawSwitcher()
    local function pageButton(label, name)
      local isActive = active == name
      if isActive then
        ImGui.PushStyleColor(ctx, ImGui.Col_Button, chrome.colour('toolbar.buttonActive'))
      end
      if ImGui.Button(ctx, label) and not isActive then
        cmgr:invoke('switchPage', name)
      end
      if isActive then ImGui.PopStyleColor(ctx, 1) end
    end
    pageButton('Tracker', 'tracker')
    ImGui.SameLine(ctx, 0, 4)
    pageButton('Sample',  'sample')
  end

  local function dispatch(state) return dispatchKeys(state, cmgr, ctx) end

  local function frame()
    tick()
    local page = pages[active]

    ImGui.PushFont(ctx, uiFont, 13)
    ImGui.PushStyleColor(ctx, ImGui.Col_WindowBg,     chrome.colour('bg'))
    ImGui.PushStyleColor(ctx, ImGui.Col_TitleBg,      chrome.colour('toolbar.bg'))
    ImGui.PushStyleColor(ctx, ImGui.Col_TitleBgActive,chrome.colour('toolbar.bg'))
    ImGui.PushStyleColor(ctx, ImGui.Col_ScrollbarBg,  chrome.colour('scrollBg'))
    ImGui.PushStyleColor(ctx, ImGui.Col_ScrollbarGrab,chrome.colour('scrollHandle'))

    ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowPadding, 0, 0)
    local visible, open = ImGui.Begin(ctx, 'Continuum', true,
      ImGui.WindowFlags_NoScrollbar
      | ImGui.WindowFlags_NoScrollWithMouse
      | ImGui.WindowFlags_NoDocking
      | ImGui.WindowFlags_NoNav
      | ImGui.WindowFlags_NoMove)
    ImGui.PopStyleVar(ctx)
    -- Active-item drags (e.g. the lane strip's curve editor) can otherwise
    -- accumulate auto-scroll on the parent window, pushing the grid below
    -- the visible region for the duration of the drag.
    if visible then ImGui.SetScrollY(ctx, 0); ImGui.SetScrollX(ctx, 0) end

    if visible and page then
      -- Toolbar band: switcher (coordinator) + page bits.
      ImGui.PushStyleColor(ctx, ImGui.Col_ChildBg, chrome.colour('toolbar.bg'))
      ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowPadding, CHROME_PAD_X, CHROME_PAD_Y)
      if ImGui.BeginChild(ctx, '##toolbar', 0, 0,
                          ImGui.ChildFlags_AutoResizeY | ImGui.ChildFlags_AlwaysUseWindowPadding,
                          ImGui.WindowFlags_NoScrollbar) then
        chrome.pushChromeStyles()
        ImGui.PushStyleVar(ctx, ImGui.StyleVar_FramePadding, 10, 3)
        drawSwitcher()
        ImGui.SameLine(ctx, 0, 12)
        chrome.verticalSeparator()
        ImGui.SameLine(ctx, 0, 12)
        page:renderToolbarBits(ctx)
        ImGui.PopStyleVar(ctx, 1)
        chrome.popChromeStyles()
      end
      ImGui.EndChild(ctx)
      ImGui.PopStyleVar(ctx)
      ImGui.PopStyleColor(ctx)

      -- Body region: reserve a fixed footer for the status bar; the
      -- page paints into the remaining viewport at (CHROME_PAD_X,
      -- toolbarBottom + CHROME_PAD_Y).
      local cursorY     = ImGui.GetCursorPosY(ctx)
      local availW0, availH = ImGui.GetContentRegionAvail(ctx)
      local footerH     = ImGui.GetFrameHeightWithSpacing(ctx) + 4
      local bodyH       = availH - footerH

      ImGui.Indent(ctx, CHROME_PAD_X)
      ImGui.SetCursorPosY(ctx, ImGui.GetCursorPosY(ctx) + CHROME_PAD_Y)
      page:renderBody(ctx,
        availW0 - CHROME_PAD_X * 2,
        bodyH   - CHROME_PAD_Y,
        dispatch)
      ImGui.Unindent(ctx, CHROME_PAD_X)

      -- Status band pinned to (toolbarBottom + bodyH); the parchment
      -- gap above is the leftover.
      ImGui.SetCursorPosY(ctx, cursorY + bodyH)
      ImGui.PushStyleColor(ctx, ImGui.Col_ChildBg, chrome.colour('statusBar.bg'))
      ImGui.PushStyleColor(ctx, ImGui.Col_Text,    chrome.colour('statusBar.text'))
      ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowPadding, CHROME_PAD_X + 4, CHROME_PAD_Y)
      if ImGui.BeginChild(ctx, '##statusBar', 0, footerH,
                          ImGui.ChildFlags_AlwaysUseWindowPadding,
                          ImGui.WindowFlags_NoScrollbar) then
        page:renderStatusBar(ctx)
      end
      ImGui.EndChild(ctx)
      ImGui.PopStyleVar(ctx)
      ImGui.PopStyleColor(ctx, 2)
    elseif visible then
      ImGui.Text(ctx, 'Select a MIDI item to begin.')
    end

    ImGui.End(ctx)

    if page and page.renderFloating then page:renderFloating(ctx) end

    ImGui.PopStyleColor(ctx, 5)
    ImGui.PopFont(ctx)

    if open and not quitting then reaper.defer(frame) end
  end

  ----- Public

  local self = {}

  function self:register(name, page)
    pages[name] = page
    if not active then self:setActive(name) end
  end

  function self:setActive(name)
    if active == name then return end
    if active and pages[active] then pages[active]:unbind() end
    active = name
    cmgr:setActive(name)
    if name == 'tracker' then
      pages.tracker:bind(take)
    elseif name == 'sample' then
      pages.sample:bind(reaper.GetMediaItemTake_Track(take))
    end
  end

  function self:togglePage()
    self:setActive(active == 'tracker' and 'sample' or 'tracker')
  end

  function self:quit() quitting = true end

  function self:chrome() return chrome end

  function self:run() frame() end

  return self
end

local function Main()
  local item = reaper.GetSelectedMediaItem(0, 0)
  if not item then
    reaper.ShowConsoleMsg('Please select a MIDI item.\n')
    return
  end

  local take = reaper.GetActiveTake(item)
  local mm   = newMidiManager(take)
  local cm   = newConfigManager()
  cm:setContext(take)
  local tm   = newTrackerManager(mm, cm)
  local cmgr = newCommandManager(cm)
  local vm   = newTrackerView(tm, cm, cmgr)
  local sm   = newSampleManager(fileOps)

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

  local ctx, font, uiFont = createImGui()
  local coord = newCoordinator(cm, cmgr, sm, take, ctx, font, uiFont)

  cmgr:scope('tracker'):register('loadSampleAtCurrentSlot', function()
    if not cm:get('trackerMode') then return end
    local rv, path = reaper.GetUserFileNameForRead('', 'Load sample into current slot', '')
    if rv and path ~= '' then
      sm:assign(reaper.GetMediaItemTake_Track(take),
                cm:get('currentSample'), path, reaper.GetProjectPath(0), cm)
    end
  end)

  -- Globals: transport wrappers, page switching, quit. Bound on root
  -- so any page picks them up unchanged.
  cmgr:registerAll{
    play       = function() reaper.Main_OnCommand(1007,  0) end,
    playPause  = function() reaper.Main_OnCommand(40073, 0) end,
    stop       = function() reaper.Main_OnCommand(1016,  0) end,
    switchPage = function(name) coord:setActive(name)      end,
    togglePage = function()     coord:togglePage()         end,
    quit       = function()     coord:quit()               end,
  }
  cmgr:bindAll{
    playPause  = { ImGui.Key_Space },
    stop       = { ImGui.Key_F8    },
    togglePage = { {ImGui.Key_Tab, ImGui.Mod_Super} },
    quit       = { ImGui.Key_Enter },
  }

  coord:register('tracker', newTrackerPage(vm, cm, cmgr, coord:chrome(), ctx, font, uiFont))
  coord:register('sample',  newSamplePage (sv, sm, cm, cmgr, coord:chrome(), ctx, uiFont))
  coord:run()
end

run(Main)
