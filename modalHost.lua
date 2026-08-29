--invariant: one modalHost per coordinator; threaded into every page that opens modals
--invariant: state.kind picks the render; built-ins are 'prompt' and 'confirm'; pages register custom kinds at load time
--shape: state = { kind, title, callback?, onClose?, flags?, ... per-kind fields }
--contract: render(state, close) draws inside an active BeginPopupModal; close(invoke, ...args) captures+clears state, closes popup, pcalls callback if invoke, then pcalls onClose unconditionally
--contract: built-in renderers claim their keys under 'modal'; see docs/keyQueue.md § Ownership
local ImGui = require 'imgui' '0.10'

local ctx      = (...).ctx
local chrome   = (...).chrome
local keyQueue = (...).keyQueue

local POPUP_ID = '###modalHost'

local kinds   = {}
local state   = nil
local wasOpen = false   -- snapshot at tick(); stays true across the closing frame

local function label() return (state and state.title or '') .. POPUP_ID end

local modalHost = {}

function modalHost:registerKind(kind, render) kinds[kind] = render end

function modalHost:open(s)
  state = s
  ImGui.OpenPopup(ctx, label())
end

function modalHost:openPrompt(args)
  self:open{
    kind     = 'prompt',
    title    = args.title,
    prompt   = args.prompt,
    callback = args.callback,
    resolve  = args.resolve,
    buf      = args.buf or '',
    selectTo = args.selectTo,
  }
end

function modalHost:openConfirm(args)
  self:open{
    kind     = 'confirm',
    title    = args.title,
    prompt   = args.prompt or ('No selection \xe2\x80\x94 ' .. args.title .. ' whole take? (y/n)'),
    callback = args.callback,
  }
end

function modalHost:isOpen() return state ~= nil end
function modalHost:wasOpenAtFrameStart() return wasOpen end

function modalHost:tick() wasOpen = (state ~= nil) end

function modalHost:draw()
  if not state then return end
  -- Self-heal: a callback opened a follow-up modal whose OpenPopup was
  -- cancelled by the enclosing CloseCurrentPopup. Re-open at top level.
  if not ImGui.IsPopupOpen(ctx, label()) then
    ImGui.OpenPopup(ctx, label())
  end
  local cx, cy = ImGui.Viewport_GetCenter(ImGui.GetWindowViewport(ctx))
  ImGui.SetNextWindowPos(ctx, cx, cy, ImGui.Cond_Appearing, 0.5, 0.5)

  chrome.pushChromeWindow()
  -- A modal is always the focused window, so only the *Active title slot shows.
  ImGui.PushStyleColor(ctx, ImGui.Col_TitleBgActive, chrome.colour('modal.titleBg'))
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowRounding, 5)
  -- Title-bar height is font + FramePadding.y*2; pad it taller, then drop the
  -- override right after Begin so interior widgets keep normal padding.
  local padX, padY = ImGui.GetStyleVar(ctx, ImGui.StyleVar_FramePadding)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_FramePadding, padX, padY + 2)
  -- state.size opens the modal at that size, still user-resizable; the default is
  -- auto-resize-to-content (sizes to the interior widgets).
  if state.size then ImGui.SetNextWindowSize(ctx, state.size[1], state.size[2], ImGui.Cond_Appearing) end
  local flags = (state.size and 0 or ImGui.WindowFlags_AlwaysAutoResize) | (state.flags or 0)
  local opened = ImGui.BeginPopupModal(ctx, label(), nil, flags)
  ImGui.PopStyleVar(ctx, 1)
  if opened then
    local cb      = state.callback
    local onClose = state.onClose
    local function close(invoke, ...)
      -- Capture-then-clear before invoking: the callback may open a follow-up
      -- modal by calling modalHost:open, and we mustn't nil that out from under it.
      state = nil
      ImGui.CloseCurrentPopup(ctx)
      if invoke and cb then
        local ok, err = pcall(cb, ...)
        if not ok then
          reaper.ShowConsoleMsg('\nModal callback error: ' .. tostring(err) .. '\n')
        end
      end
      if onClose then pcall(onClose) end
    end
    local render = kinds[state.kind]
    if render then render(state, close)
    else error('modalHost: no renderer for kind ' .. tostring(state.kind)) end
    ImGui.EndPopup(ctx)
  else
    state = nil
  end
  ImGui.PopStyleVar(ctx, 1)
  ImGui.PopStyleColor(ctx, 1)
  chrome.popChromeWindow()
end

----- Built-in renderers

modalHost:registerKind('confirm', function(s, close)
  ImGui.Text(ctx, s.prompt)
  local mods = keyQueue:frameMods()
  if keyQueue:take(ImGui.Key_Y, mods, 'modal') or keyQueue:take(ImGui.Key_Enter, mods, 'modal') then
    close(true, true)
  elseif keyQueue:take(ImGui.Key_N, mods, 'modal') or keyQueue:take(ImGui.Key_Escape, mods, 'modal') then
    close(true, false)
  end
end)

modalHost:registerKind('prompt', function(s, close)
  if ImGui.IsWindowAppearing(ctx) then ImGui.SetKeyboardFocusHere(ctx) end
  ImGui.Text(ctx, s.prompt)
  -- selectTo opens the field with its first n characters selected, armed until
  -- the field goes active. see docs/chrome.md § Opening a field with a selection
  local selFlags, selCb = 0, nil
  if s.selectTo then selFlags, selCb = chrome.selectTo(s.selectTo) end
  -- The buffer is read every frame, so the preview below and the value Enter commits
  -- are the same text. EnterReturnsTrue would lag both a keystroke behind.
  local _, buf = ImGui.InputText(ctx, '##modal', s.buf, selFlags, selCb)
  if s.selectTo and ImGui.IsItemActive(ctx) then s.selectTo = nil end
  s.buf = buf
  local shown = s.resolve and s.resolve(buf) or ''
  if shown ~= '' then ImGui.Text(ctx, '\xe2\x86\x92 ' .. shown) end
  local mods = keyQueue:frameMods()
  if keyQueue:take(ImGui.Key_Enter, mods, 'modal')
  or keyQueue:take(ImGui.Key_KeypadEnter, mods, 'modal') then
    close(true, shown ~= '' and shown or buf)
  elseif keyQueue:take(ImGui.Key_Escape, mods, 'modal') then
    close(false)
  end
end)

return modalHost
