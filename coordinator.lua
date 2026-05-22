-- See docs/coordinator.md for the model.

--invariant: owns the active tracker take; polls REAPER's selection each frame while tracker page is active (sticky on no-item or non-MIDI)
--invariant: no teardown path — quit() sets a flag that stops scheduling further defers; REAPER reclaims state on script unload
--invariant: errors inside the defer loop surface through the same xpcall frame because each iteration reschedules itself

local util  = require 'util'

if not reaper.ImGui_GetBuiltinPath then
  reaper.MB('ReaImGui is required. Install it via ReaPack.', 'Continuum', 0)
  return
end
package.path = reaper.ImGui_GetBuiltinPath() .. '/?.lua;' .. package.path
local ImGui = require 'imgui' '0.10'

local cm, cmgr, gui = (...).cm, (...).cmgr, (...).gui
local ctx, uiFont   = gui.ctx, gui.uiFont
local uiSize        = gui.fontSize.ui

local chrome = util.instantiate('chrome',
  { cm = cm, ctx = ctx, uiFontBold = gui.uiFontBold, uiSize = uiSize })

local CHROME_PAD_X, CHROME_PAD_Y = 8, 4

local pages, active = {}, nil
local quitting      = false
--contract: owns the active sampler track — the picker on samplePage delegates here, and first sample-page activation seeds the default from pages.sample:listTracks()
local samplerTrack  = nil
--contract: owns currentTake — refreshTakeFromReaper polls GetSelectedMediaItem→GetActiveTake→TakeIsMIDI, mutates currentTake only on a real MIDI take that differs (sticky on nothing-selected or non-MIDI), and returns true so the caller can rebind
local currentTake   = nil
--contract: external-mutation watcher — captured at end of every tracker-active frame; top-of-tick diff triggers tp:reloadFromReaper. Cleared on take swap (bind path is the reload). Nil disables the diff check (one-frame grace after swap/first activation).
local lastTakeHash  = nil

----- Keyboard router

-- Capture digits and '/' into the prefix buffer; Esc cancels. Returns
-- 'consumed' if a prefix-accumulating key fired this frame; nil otherwise
-- (so the normal keychain walk proceeds). The prefix is NOT finished here
-- on fall-through: dispatchKeys calls finishPrefix only at the moment a
-- bound command is about to fire, so idle frames don't kill the buffer.
-- In prefix mode, digit keys count even with Ctrl/Super held: holding the
-- chord open while typing a count is a natural reach, and any Ctrl-N or
-- Super-N command binding is overridden for the duration of prefix mode.
-- Shift/Alt still disqualify (Shift-digit emits a different char).
local function isDigitMods(mods)
  return (mods & ~(ImGui.Mod_Ctrl | ImGui.Mod_Super)) == 0
end

local function handlePrefixCapture(cmgr, ctx)
  if not cmgr:isPrefixActive() then return nil end
  local mods = ImGui.GetKeyMods(ctx)
  for d = 0, 9 do
    if ImGui.IsKeyPressed(ctx, ImGui.Key_0 + d) and isDigitMods(mods) then
      cmgr:appendPrefix(tostring(d)); return 'consumed'
    end
  end
  if ImGui.IsKeyPressed(ctx, ImGui.Key_Slash) and isDigitMods(mods) then
    cmgr:appendPrefix('/'); return 'consumed'
  end
  if ImGui.IsKeyPressed(ctx, ImGui.Key_Escape) then
    cmgr:cancelPrefix(); return 'consumed'
  end
  return nil
end

--shape: dispatchResult = { consumed: bool, commandHeld: bool }
--contract: returns early (no dispatch) when state.suppressKbd or not state.acceptCmds
--contract: state.pageSuppressed shrinks the walk to the root keymap only — body-region editors (swing, tuning) suppress page bindings without shadowing globals like playPause/quit
--contract: first-hit wins across the keychain; a command returning false declines and releases the key (clearing commandHeld) so the page char queue sees it
--contract: while cmgr:isPrefixActive(), digits and '/' are captured (no dispatch); Esc cancels; any other key freezes the prefix and falls through to the keychain walk so commands can consumePrefix()
local function dispatchKeys(state, cmgr, ctx)
  if state.suppressKbd or not state.acceptCmds then
    return { consumed = false, commandHeld = false }
  end
  local cap = handlePrefixCapture(cmgr, ctx)
  if cap == 'consumed' then
    return { consumed = true, commandHeld = false }
  end
  local commandHeld = false
  local keychain = state.pageSuppressed and { cmgr:rootKeymap() } or cmgr:keychain()
  for _, keymap in ipairs(keychain) do
    for command, keys in pairs(keymap) do
      for _, spec in ipairs(keys) do
        local key, mods = cmgr:keySpec(spec, ImGui)
        if ImGui.IsKeyDown(ctx, key) and mods == ImGui.Mod_None then
          commandHeld = true
        end
        if ImGui.IsKeyPressed(ctx, key) and ImGui.GetKeyMods(ctx) == mods then
          -- Freeze the prefix buffer immediately before invoke so
          -- pendingPrefix is set when invoke reads it as the first arg.
          if cmgr:isPrefixActive() and command ~= 'beginPrefix' then
            cmgr:finishPrefix()
          end
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

local function refreshTakeFromReaper()
  local item = reaper.GetSelectedMediaItem(0, 0)
  if not item then return false end
  local t = reaper.GetActiveTake(item)
  if not t or not reaper.TakeIsMIDI(t) then return false end
  if t == currentTake then return false end
  currentTake = t
  return true
end

local function takeMidiHash()
  if not currentTake then return nil end
  local ok, h = reaper.MIDI_GetHash(currentTake, false)
  return ok and h or nil
end

--contract: tick() runs once per frame before the page draws; setPrefix is republished only when the project path changes (one mailbox cell shared across instances)
--contract: tracker-active branch — take swap takes priority (clears the watcher so the post-bind end-of-frame capture is the new baseline); otherwise a hash diff signals an external mutation (REAPER Ctrl-Z, external script) and we reload the bound take
local function tick()
  if active == 'tracker' and pages.tracker then
    if refreshTakeFromReaper() then
      pages.tracker:bind(currentTake)
      lastTakeHash = nil
    elseif lastTakeHash then
      local h = takeMidiHash()
      if h and h ~= lastTakeHash then
        pages.tracker:reloadFromReaper()
        lastTakeHash = takeMidiHash()
      end
    end
  end
  if pages.sample and currentTake then pages.sample:tick(currentTake) end
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
  pageButton('T', 'tracker')
  ImGui.SameLine(ctx, 0, 4)
  pageButton('A', 'arrange')
  ImGui.SameLine(ctx, 0, 4)
  pageButton('S', 'sample')
end

local function dispatch(state) return dispatchKeys(state, cmgr, ctx) end

local function frame()
  tick()
  local page = pages[active]

  ImGui.PushFont(ctx, uiFont, uiSize)
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
    -- Toolbar band
    ImGui.PushStyleColor(ctx, ImGui.Col_ChildBg, chrome.colour('toolbar.bg'))
    ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowPadding, CHROME_PAD_X, CHROME_PAD_Y)
    if ImGui.BeginChild(ctx, '##toolbar', 0, 0,
                        ImGui.ChildFlags_AutoResizeY | ImGui.ChildFlags_AlwaysUseWindowPadding,
                        ImGui.WindowFlags_NoScrollbar | ImGui.WindowFlags_NoNav) then
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

  -- End-of-frame baseline for the external-mutation watcher: by now any
  -- user-triggered mutation this frame has flushed through mm:modify, so the
  -- hash reflects truth. Next frame's tick() diffs against this value; a
  -- difference can only have come from outside Continuum.
  if active == 'tracker' and currentTake then lastTakeHash = takeMidiHash() end

  if open and not quitting then reaper.defer(frame) end
end

---------- PUBLIC

--shape: page = { renderToolbarBits(ctx), renderBody(ctx,w,h,dispatch), renderStatusBar(ctx), bind(...), unbind(), [renderFloating(ctx)] }
--contract: pages must be registered via coord:register(name,page); first registered becomes active
local coord = {}

function coord:register(name, page)
  pages[name] = page
  if not active then self:setActive(name) end
end

--contract: setActive(name) is a no-op when name == active; otherwise unbinds the outgoing page, swaps cmgr scope, and binds the incoming page (tracker→currentTake, sample→samplerTrack, arrange→no-op since the page is project-wide)
function coord:setActive(name)
  if active == name then return end
  if active and pages[active] then
    pages[active]:unbind()
    cmgr:pop(active)
  end
  active = name
  cmgr:push(name)
  if name == 'tracker' then
    refreshTakeFromReaper()
    pages.tracker:bind(currentTake)
  elseif name == 'sample' then
    if samplerTrack == nil then
      local tracks = pages.sample:listTracks()
      samplerTrack = tracks[1] and tracks[1].track or nil
    end
    pages.sample:bind(samplerTrack)
  elseif name == 'arrange' then
    pages.arrange:bind()
  end
end

--contract: dive from the arrange page into a MIDI take — selects the item alone in REAPER so refreshTakeFromReaper reads it, then activates the tracker page (whose bind picks it up). Trusts the caller to pass a MIDI item; nil is a no-op.
function coord:diveToTake(item)
  if not item then return end
  reaper.SelectAllMediaItems(0, false)
  reaper.SetMediaItemSelected(item, true)
  self:setActive('tracker')
end

--contract: stores the active sampler track and re-binds the sample page if currently active; safe to call before sample page is registered (state stashes; bind happens on next activation)
function coord:setSamplerTrack(t)
  samplerTrack = t
  if active == 'sample' and pages.sample then
    pages.sample:bind(t)
  end
end

-- Cycle tracker → arrange → sample → tracker. Pages absent from the registry
-- are skipped so a partial wiring (e.g. tests with only one page) still cycles.
function coord:togglePage()
  local order = { 'tracker', 'arrange', 'sample' }
  local idx
  for i, name in ipairs(order) do if name == active then idx = i; break end end
  for step = 1, #order do
    local next = order[((idx or 0) + step - 1) % #order + 1]
    if pages[next] then self:setActive(next); return end
  end
end

--contract: invoke after firing a REAPER action that mutates the bound take from inside a frame (Ctrl-Z, Ctrl-Shift-Z). The watcher's end-of-frame baseline would otherwise absorb the mutation; this reloads now so tm/vm stay coherent with the take.
function coord:reloadAfterExternalMutation()
  if active == 'tracker' and pages.tracker and currentTake then
    pages.tracker:reloadFromReaper()
  end
end

function coord:quit()   quitting = true end
function coord:chrome() return chrome   end
function coord:run()    frame()         end

return coord
