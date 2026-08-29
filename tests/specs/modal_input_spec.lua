-- The modal claiming from the keyQueue (design/keyQueue.md § Ownership).
-- The real modalHost is driven here over the real queue, a chrome whose style pushes
-- are inert, and a controllable imgui -- the production instantiation, with the frame's
-- owner named as the coordinator names it.
--
-- The queue after the draw is the observable throughout: a press the modal acted on is
-- gone, and one it declined is still there. The callback's argument is the second, so a
-- claim firing the wrong branch shows as well as one firing no branch.
--
-- The fake text field reports its text and nothing else, so Enter reaches the prompt
-- renderer through the queue, as it does in production.

local t    = require('support')
local util = require('util')

local fakeImGui = t.imgui()
local pressed, curMods, typed = {}, 0, nil
local popupOpen, appearing   = false, false

fakeImGui.GetKeyMods      = function() return curMods end
fakeImGui.IsKeyPressed    = function(_, k) return pressed[k] == true end
fakeImGui.IsKeyDown       = function(_, k) return pressed[k] == true end
fakeImGui.IsAnyItemActive = function() return false end
fakeImGui.IsItemActive    = function() return false end

-- The popup's life as ImGui runs it: OpenPopup raises it and makes the next draw the
-- appearing one, BeginPopupModal answers whether it is up, CloseCurrentPopup drops it.
fakeImGui.OpenPopup         = function() popupOpen, appearing = true, true end
fakeImGui.IsPopupOpen       = function() return popupOpen end
fakeImGui.BeginPopupModal   = function() return popupOpen end
fakeImGui.CloseCurrentPopup = function() popupOpen = false end
fakeImGui.IsWindowAppearing = function() return appearing end

-- The field reports the text this frame typed, else the text it was handed.
fakeImGui.InputText          = function(_, _, buf) return typed ~= nil, typed or buf end
fakeImGui.GetStyleVar        = function() return 4, 4 end
fakeImGui.Viewport_GetCenter = function() return 0, 0 end
fakeImGui.GetWindowViewport  = function() return 'viewport' end
for _, name in ipairs({ 'Text', 'EndPopup', 'SetNextWindowPos', 'SetNextWindowSize',
                        'SetKeyboardFocusHere', 'PushStyleColor', 'PopStyleColor',
                        'PushStyleVar', 'PopStyleVar' }) do
  fakeImGui[name] = function() end
end

local fakeChrome = {
  colour           = function() return 0 end,
  pushChromeWindow = function() end,
  popChromeWindow  = function() end,
}

local ctx = {}
local kq, modalHost, answered

-- Rebind imgui to ours before loading: earlier specs' preloads cache a different
-- fake, so drop the imgui-capturing module and re-require (curveEditor idiom).
local function fresh()
  package.preload['imgui'] = function() return function(_) return fakeImGui end end
  package.loaded['imgui']  = nil
  pressed, curMods, typed, popupOpen, appearing, answered = {}, 0, nil, false, false, nil
  kq        = util.instantiate('keyQueue', { ctx = ctx })
  modalHost = util.instantiate('modalHost', { ctx = ctx, chrome = fakeChrome, keyQueue = kq })
end

-- One frame as the coordinator runs it: the fill names the owner from the modal's state
-- before anything draws, the tick follows, and the modal draws last.
local function frame(opts)
  opts = opts or {}
  pressed, curMods, typed = {}, opts.mods or 0, opts.typed
  for _, key in ipairs(opts.pressed or {}) do pressed[key] = true end
  kq:fill(modalHost:isOpen() and 'modal' or nil)
  modalHost:tick()
  modalHost:draw()
  appearing = false
end

local function openConfirm()
  modalHost:openConfirm{ title = 'Delete take', prompt = 'Delete the take? (y/n)',
                         callback = function(yes) answered = { yes = yes } end }
end

local function openPrompt(args)
  modalHost:openPrompt{ title = 'Rows per beat', prompt = '1-32',
                        buf      = args and args.buf or '',
                        resolve  = args and args.resolve,
                        callback = function(value) answered = { value = value } end }
end

return {
  {
    -- Y answers yes. The claim is the point: the same press reaches no reader after.
    name = 'the confirm modal takes the Y it answers yes on',
    run = function()
      fresh()
      openConfirm()
      frame{}
      t.eq(modalHost:isOpen(), true, 'the modal is up (precondition)')
      frame{ pressed = { fakeImGui.Key_Y } }
      t.deepEq(answered, { yes = true }, 'the callback was invoked with yes')
      t.eq(modalHost:isOpen(), false, 'and the modal closed')
      t.eq(kq:take(fakeImGui.Key_Y, nil, 'modal'), nil, 'the press was claimed')
    end,
  },

  {
    -- N and Escape are the same answer, and both are claimed where they act.
    name = 'the confirm modal takes its N and its Escape',
    run = function()
      for _, key in ipairs({ fakeImGui.Key_N, fakeImGui.Key_Escape }) do
        fresh()
        openConfirm()
        frame{}
        frame{ pressed = { key } }
        t.deepEq(answered, { yes = false }, 'the callback was invoked with no')
        t.eq(kq:take(key, nil, 'modal'), nil, 'the press was claimed')
      end
    end,
  },

  {
    -- A key the renderer does not act on is left where it was, so the claims above are
    -- claims and not a queue the draw empties.
    name = 'a press the confirm modal does not act on stays in the queue',
    run = function()
      fresh()
      openConfirm()
      frame{}
      frame{ pressed = { fakeImGui.Key_Q } }
      t.eq(modalHost:isOpen(), true, 'the modal is still up')
      t.eq(answered, nil, 'and nothing was answered')
      t.truthy(kq:take(fakeImGui.Key_Q, nil, 'modal'), 'the press is still in the queue')
    end,
  },

  {
    -- The prompt commits the buffer as the field last reported it, so a keystroke on the
    -- frame before Enter is in what commits.
    name = 'the prompt takes the Enter it commits on, and commits what was typed',
    run = function()
      fresh()
      openPrompt()
      frame{}
      frame{ typed = 'ab' }
      frame{ pressed = { fakeImGui.Key_Enter } }
      t.deepEq(answered, { value = 'ab' }, 'the callback was invoked with the buffer')
      t.eq(kq:take(fakeImGui.Key_Enter, nil, 'modal'), nil, 'the Enter was claimed')
    end,
  },

  {
    -- Escape abandons: the modal goes, the callback does not run, and the press is gone.
    name = 'the prompt takes its Escape, and abandons',
    run = function()
      fresh()
      openPrompt()
      frame{}
      frame{ typed = 'ab' }
      t.eq(modalHost:isOpen(), true, 'the modal is up (precondition)')
      frame{ pressed = { fakeImGui.Key_Escape } }
      t.eq(modalHost:isOpen(), false, 'the modal closed')
      t.eq(answered, nil, 'without invoking the callback')
      t.eq(kq:take(fakeImGui.Key_Escape, nil, 'modal'), nil, 'and the Escape was claimed')
    end,
  },

  {
    -- A resolving prompt commits what it previewed, and the keypad's Enter commits as the
    -- main one does.
    name = 'a resolving prompt takes KeypadEnter, and commits the resolved value',
    run = function()
      fresh()
      openPrompt{ resolve = function(buf) return buf:upper() end }
      frame{}
      frame{ typed = 'pb' }
      frame{ pressed = { fakeImGui.Key_KeypadEnter } }
      t.deepEq(answered, { value = 'PB' }, 'the resolved value committed')
      t.eq(kq:take(fakeImGui.Key_KeypadEnter, nil, 'modal'), nil, 'and the KeypadEnter was claimed')
    end,
  },

  {
    -- The frame the modal opens on: the walk claimed the press before it invoked the
    -- command, so the key that raised the modal is not in the queue for the modal to read.
    name = 'the press that opened the modal is gone by the time it draws',
    run = function()
      fresh()
      pressed, curMods = { [fakeImGui.Key_Y] = true }, 0
      kq:fill(nil)
      modalHost:tick()
      t.truthy(kq:take(fakeImGui.Key_Y, nil, nil), 'the walk claims the press it dispatches on')
      openConfirm()                    -- as the command the walk invoked does, mid-frame
      modalHost:draw()
      appearing = false
      t.eq(modalHost:isOpen(), true, 'the modal stayed up on its appearing frame')
      t.eq(answered, nil, 'and answered nothing')
    end,
  },
}
