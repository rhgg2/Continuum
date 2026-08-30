-- The cheat sheet claiming from the keyQueue (docs/keyQueue.md § Ownership).
-- The real overlay is driven here over a real command manager carrying a two-command
-- manifest, a chrome that reports no toolbar or status rects, and a controllable
-- imgui whose drawing calls are inert -- the production instantiation, with the
-- frame's owner named as the coordinator names it.
--
-- The queue after the draw is the observable throughout: a press the sheet acted on
-- is gone, one it declined is still there, and the frame the sheet opened on -- which
-- no owner holds -- leaves its presses for the readers underneath.
--
-- Edit mode is reached the way a user reaches it, by clicking a keycap chip. The
-- click coordinates are the box layout's, so a chip is found at the first row of the
-- only box, a little inside the body rect this spec anchors.

local t    = require('support')
local util = require('util')

local fakeImGui = t.imgui()
local pressed, curMods, mouse = {}, 0, nil

-- Named before keyQueue loads: the fill enumerates the Key_* names the shim table
-- holds at that moment, and this one is here to be a key cmgr has no token for.
local NO_TOKEN_KEY = fakeImGui.Key_KeypadAdd

fakeImGui.GetKeyMods      = function() return curMods end
fakeImGui.IsKeyDown       = function(_, k) return pressed[k] == true end
fakeImGui.IsKeyPressed    = function(_, k) return pressed[k] == true end
fakeImGui.IsAnyItemActive = function() return false end
-- The char queue answers as ReaImGui's does: a flag, then the character.
local queuedChar = nil
fakeImGui.GetInputQueueCharacter = function(_, idx)
  if queuedChar and idx == 0 then return true, queuedChar end
  return false, 0
end
fakeImGui.GetForegroundDrawList  = function() return 'dl' end
fakeImGui.GetTextLineHeight = function() return 14 end
fakeImGui.GetWindowPos      = function() return 0, 0 end
fakeImGui.GetWindowSize     = function() return 800, 600 end
fakeImGui.CalcTextSize      = function(_, s) return 8 * #tostring(s), 14 end
fakeImGui.IsMouseClicked    = function(_, button) return mouse ~= nil and button == 0 end
fakeImGui.GetMousePos       = function() return mouse and mouse.x or -1, mouse and mouse.y or -1 end
for _, name in ipairs({ 'DrawList_AddRectFilled', 'DrawList_AddRect',
                        'DrawList_AddText', 'DrawList_AddLine' }) do
  fakeImGui[name] = function() end
end

-- cmgr resolves keycap glyphs per platform; headless there is no host to ask.
_G.reaper.GetOS = _G.reaper.GetOS or function() return 'OSX64' end

local fakeChrome = {
  colour       = function() return 0 end,
  toolbarRects = function() return {} end,
  statusRects  = function() return {} end,
}

local ctx = {}
local kq, cmgr, help

local function noop() end

-- Rebind imgui to ours before loading: earlier specs' preloads cache a different
-- fake, so drop the imgui-capturing modules and re-require (curveEditor idiom).
local function fresh()
  package.preload['imgui'] = function() return function(_) return fakeImGui end end
  for _, m in ipairs({ 'imgui', 'help', 'keyQueue', 'commandManager' }) do
    package.loaded[m] = nil
  end
  kq   = util.instantiate('keyQueue', { ctx = ctx })
  cmgr = util.instantiate('commandManager',
                          { cm = util.instantiate('configManager', { ps = util.instantiate('pextStore') }) })
  cmgr:registerAll{ alpha = noop, beta = noop }
  cmgr:installManifest({ global = { Grid = {
    { name = 'alpha', label = 'Alpha', keys = { 'A' } },
    { name = 'beta',  label = 'Beta',  keys = { 'B' } },
  } } }, fakeImGui)
  help = util.instantiate('help', { ctx = ctx, chrome = fakeChrome, cmgr = cmgr, keyQueue = kq })
  help:registerPage('tracker', { { group = 'Grid', anchor = 'body', place = 'flow' } })
  help:setPage('tracker')
  help:toggle()
end

-- One frame as the coordinator runs it: the fill names the owner from the sheet's
-- state before anything draws, then the page anchors its body and the sheet draws.
local function frame(opts)
  opts = opts or {}
  pressed, curMods, mouse, queuedChar = {}, opts.mods or 0, opts.mouse, opts.char
  for _, key in ipairs(opts.pressed or {}) do pressed[key] = true end
  kq:fill(help:isOpen() and 'help' or nil)
  help:beginFrame()
  help:anchor('body', 0, 0, 400, 400)
  help:draw()
end

local CHIP = { x = 20, y = 35 }   -- inside the first row's keycap chip of the only box

-- Focus the first row, then arm its chip for capture: two clicks on the same chip,
-- as docs/help.md § Editing describes.
local function captureFirstChip()
  frame{}                  -- lay the boxes out, so the chip has a hit rect
  frame{ mouse = CHIP }    -- first click focuses the row
  frame{ mouse = CHIP }    -- second click re-captures the chip
end

return {
  {
    -- Dismissal acts on any press at all, so it claims whatever it found: the press
    -- that closed the sheet reaches no reader on the page underneath.
    name = 'a press dismisses the sheet, and the sheet claims it',
    run = function()
      fresh()
      frame{ pressed = { fakeImGui.Key_Z } }
      t.eq(help:isOpen(), false, 'the sheet closed on the press')
      t.eq(kq:take(fakeImGui.Key_Z, nil, 'help'), nil, 'and claimed it')
    end,
  },

  {
    -- The char queue is the route for a layout key the shim has no constant for, and
    -- dismissal reads it as a second source. An empty queue is no press: the sheet
    -- stays up over the frames where nothing at all is typed.
    name = 'a queued character dismisses; an empty character queue does not',
    run = function()
      fresh()
      frame{}
      t.eq(help:isOpen(), true, 'a frame with no input at all leaves the sheet up')
      frame{ char = 233 }
      t.eq(help:isOpen(), false, 'and a character closes it')
    end,
  },

  {
    -- The frame F1 opens on: the fill named no owner, since the sheet was not up when
    -- the presses arrived, so anything struck alongside stays for its own reader.
    name = 'the frame the sheet opened on leaves a press alone',
    run = function()
      fresh()
      help:close()
      pressed, curMods, mouse = { [fakeImGui.Key_Z] = true }, 0, nil
      kq:fill(nil)
      help:beginFrame()
      help:toggle()                    -- as the F1 command does, mid-frame
      help:anchor('body', 0, 0, 400, 400)
      help:draw()
      t.eq(help:isOpen(), true, 'the sheet stayed up')
      t.truthy(kq:take(fakeImGui.Key_Z), 'and the press is still in the queue')
    end,
  },

  {
    -- A focused row suspends dismissal, and its Escape steps back out. Both readings
    -- are of the same press, so the Escape that left edit mode is claimed too.
    name = 'edit mode holds the sheet open, and claims the Escape that leaves it',
    run = function()
      fresh()
      frame{}
      frame{ mouse = CHIP }
      frame{ pressed = { fakeImGui.Key_Z } }
      t.eq(help:isOpen(), true, 'a focused row suspends dismissal (precondition)')
      t.truthy(kq:take(fakeImGui.Key_Z, nil, 'help'), 'so that press was left alone')

      frame{ pressed = { fakeImGui.Key_Escape } }
      t.eq(kq:take(fakeImGui.Key_Escape, nil, 'help'), nil, 'edit mode claimed the Escape')
      frame{ pressed = { fakeImGui.Key_Z } }
      t.eq(help:isOpen(), false, 'and dismissal is live again')
    end,
  },

  {
    -- Capture binds the chord it took. The mask rides on the press, so a chord binds
    -- as one; here a bare key, which the row then reads under.
    name = 'capture takes the press it binds',
    run = function()
      fresh()
      captureFirstChip()
      frame{ pressed = { fakeImGui.Key_C } }
      t.deepEq(cmgr:keyLabelList('alpha', fakeImGui), { 'C' }, 'the captured chord replaced the chip')
      t.eq(kq:take(fakeImGui.Key_C, nil, 'help'), nil, 'and the press was claimed')
    end,
  },

  {
    -- The mask rides on the press, so a chord binds as the chord it was struck as.
    -- The oracle is the label cmgr gives that chord, asked for directly.
    name = 'capture binds under the mask the press carried',
    run = function()
      fresh()
      captureFirstChip()
      frame{ pressed = { fakeImGui.Key_C }, mods = fakeImGui.Mod_Shift }
      local chord = cmgr:keyLabel({ fakeImGui.Key_C, fakeImGui.Mod_Shift }, fakeImGui)
      t.truthy(chord ~= cmgr:keyLabel({ fakeImGui.Key_C }, fakeImGui),
               'the chord reads differently from the bare key (precondition)')
      t.deepEq(cmgr:keyLabelList('alpha', fakeImGui), { chord }, 'the row bound the chord')
    end,
  },

  {
    -- A binding is persisted as a token, so a key with no token name is no chord.
    -- Capture hands that press back and stays armed.
    name = 'a key with no binding token goes back to the queue',
    run = function()
      fresh()
      captureFirstChip()
      frame{ pressed = { NO_TOKEN_KEY } }
      t.deepEq(cmgr:keyLabelList('alpha', fakeImGui), { 'A' }, 'the row kept its chord')
      t.truthy(kq:take(NO_TOKEN_KEY, nil, 'help'), 'and the press is still in the queue')

      frame{ pressed = { fakeImGui.Key_C } }
      t.deepEq(cmgr:keyLabelList('alpha', fakeImGui), { 'C' }, 'capture was still armed')
    end,
  },

  {
    -- A captured chord already spoken for raises the conflict prompt, which takes its
    -- two keys: Escape abandons the capture, Enter moves the chord across.
    name = 'the conflict prompt takes its Escape',
    run = function()
      fresh()
      captureFirstChip()
      frame{ pressed = { fakeImGui.Key_B } }
      t.deepEq(cmgr:keyLabelList('beta', fakeImGui), { 'B' }, 'the victim still holds the chord (precondition)')

      frame{ pressed = { fakeImGui.Key_Escape } }
      t.eq(kq:take(fakeImGui.Key_Escape, nil, 'help'), nil, 'the prompt claimed the Escape')
      t.deepEq(cmgr:keyLabelList('alpha', fakeImGui), { 'A' }, 'and nothing was rebound')
    end,
  },

  {
    name = 'the conflict prompt takes its Enter, and reassigns',
    run = function()
      fresh()
      captureFirstChip()
      frame{ pressed = { fakeImGui.Key_B } }
      frame{ pressed = { fakeImGui.Key_Enter } }
      t.eq(kq:take(fakeImGui.Key_Enter, nil, 'help'), nil, 'the prompt claimed the Enter')
      t.deepEq(cmgr:keyLabelList('alpha', fakeImGui), { 'B' }, 'the chord moved to the row being edited')
      t.eq(#cmgr:keysFor('beta'), 0, 'and the victim lost it')
    end,
  },
}
