-- See docs/modalHost.md for the model.

--invariant: one modalHost per coordinator; threaded into every page that opens modals
--invariant: state.kind picks the render; built-ins are 'prompt' and 'confirm'; pages register custom kinds at load time
--shape: state = { kind, title, callback?, onClose?, flags?, ... per-kind fields }
--contract: render(state, close) draws inside an active BeginPopupModal; close(invoke, ...args) captures+clears state, closes popup, pcalls callback if invoke, then pcalls onClose unconditionally
local ImGui = require 'imgui' '0.10'

local ctx    = (...).ctx
local chrome = (...).chrome

local POPUP_ID = '###modalHost'

local kinds   = {}
local state   = nil
local wasOpen = false   -- snapshot at tick(); stays true across the closing frame

local function label() return (state and state.title or '') .. POPUP_ID end

local mh = {}

function mh:registerKind(kind, render) kinds[kind] = render end

function mh:open(s)
  state = s
  ImGui.OpenPopup(ctx, label())
end

function mh:openPrompt(args)
  self:open{
    kind     = 'prompt',
    title    = args.title,
    prompt   = args.prompt,
    callback = args.callback,
    resolve  = args.resolve,
    buf      = args.buf or '',
  }
end

function mh:openConfirm(args)
  self:open{
    kind     = 'confirm',
    title    = args.title,
    prompt   = args.prompt or ('No selection \xe2\x80\x94 ' .. args.title .. ' whole take? (y/n)'),
    callback = args.callback,
  }
end

function mh:isOpen() return state ~= nil end
function mh:wasOpenAtFrameStart() return wasOpen end

function mh:tick() wasOpen = (state ~= nil) end

function mh:draw()
  if not state then return end
  -- Self-heal: a callback opened a follow-up modal whose OpenPopup was
  -- cancelled by the enclosing CloseCurrentPopup. Re-open at top level.
  if not ImGui.IsPopupOpen(ctx, label()) then
    ImGui.OpenPopup(ctx, label())
  end
  local cx, cy = ImGui.Viewport_GetCenter(ImGui.GetWindowViewport(ctx))
  ImGui.SetNextWindowPos(ctx, cx, cy, ImGui.Cond_Appearing, 0.5, 0.5)

  chrome.pushChromeWindow()
  local flags = ImGui.WindowFlags_AlwaysAutoResize | (state.flags or 0)
  if ImGui.BeginPopupModal(ctx, label(), nil, flags) then
    local cb      = state.callback
    local onClose = state.onClose
    local function close(invoke, ...)
      -- Capture-then-clear before invoking: the callback may open a follow-up
      -- modal by calling mh:open, and we mustn't nil that out from under it.
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
  chrome.popChromeWindow()
end

----- Built-in renderers

mh:registerKind('confirm', function(s, close)
  ImGui.Text(ctx, s.prompt)
  if ImGui.IsKeyPressed(ctx, ImGui.Key_Y) or ImGui.IsKeyPressed(ctx, ImGui.Key_Enter) then
    close(true, true)
  elseif ImGui.IsKeyPressed(ctx, ImGui.Key_N) or ImGui.IsKeyPressed(ctx, ImGui.Key_Escape) then
    close(true, false)
  end
end)

mh:registerKind('prompt', function(s, close)
  if ImGui.IsWindowAppearing(ctx) then ImGui.SetKeyboardFocusHere(ctx) end
  ImGui.Text(ctx, s.prompt)
  if s.resolve then
    -- Live preview: no EnterReturnsTrue (buf would lag a keystroke). Read
    -- each frame, resolve for preview, detect Enter manually.
    local _, buf = ImGui.InputText(ctx, '##modal', s.buf)
    s.buf = buf
    local shown = s.resolve(buf)
    if shown ~= '' then ImGui.Text(ctx, '\xe2\x86\x92 ' .. shown) end
    if ImGui.IsKeyPressed(ctx, ImGui.Key_Enter)
    or ImGui.IsKeyPressed(ctx, ImGui.Key_KeypadEnter) then
      close(true, shown ~= '' and shown or buf)
    elseif ImGui.IsKeyPressed(ctx, ImGui.Key_Escape) then
      close(false)
    end
  else
    local rv, buf = ImGui.InputText(ctx, '##modal', s.buf,
      ImGui.InputTextFlags_EnterReturnsTrue)
    if rv then
      close(true, buf)
    elseif ImGui.IsKeyPressed(ctx, ImGui.Key_Escape) then
      close(false)
    else
      s.buf = buf
    end
  end
end)

return mh
