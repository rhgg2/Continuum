-- Note entry taking its presses from the keyQueue (design/keyQueue.md § Claiming).
-- gridPane's edit-key scan is driven directly here: the real grid pane over the
-- harness's tracker view, a real command manager and a real queue filled from a
-- controllable imgui -- the production instantiation, with the host's gates as
-- constants.
--
-- The queue after the pass is the observable throughout. A press note entry acted
-- on is gone; one it declined is still there; and a press another reader claimed
-- first never reaches it at all, which is what retires the old commandHeld table.

local t    = require('support')
local util = require('util')

local fakeImGui = t.imgui()
_G.reaper.ImGui_GetBuiltinPath = _G.reaper.ImGui_GetBuiltinPath or function() return '/stub' end

local pressed, repeating, curMods = {}, {}, 0
fakeImGui.GetKeyMods   = function() return curMods end
fakeImGui.IsKeyDown    = function(_, k) return pressed[k] == true end
fakeImGui.IsKeyPressed = function(_, k, wantRepeat)
  if pressed[k] then return true end
  return wantRepeat == true and repeating[k] == true
end
fakeImGui.IsMouseClicked  = function() return false end
fakeImGui.IsMouseDown     = function() return false end
fakeImGui.IsWindowHovered = function() return false end
fakeImGui.IsAnyItemActive = function() return false end
fakeImGui.PushFont     = function() end
fakeImGui.PopFont      = function() end
fakeImGui.CalcTextSize = function() return 8, 14 end
fakeImGui.GetStyleVar  = function() return 4, 4 end

local fakeChrome = setmetatable({}, { __index = function() return function() end end })
local fakeGui    = { ctx = {}, font = 'grid', uiFont = 'ui', fontSize = { ui = 13, grid = 13 } }

local kq   -- the frame's queue, rebuilt per pane and refilled per setKeys

-- A pressed key is down and fresh; a repeating one models ImGui's autorepeat tick,
-- where the press answers only the repeat-tolerant reading.
local function setKeys(opts)
  pressed, repeating, curMods = {}, {}, opts.mods or 0
  for _, k in ipairs(opts.pressed   or {}) do pressed[k]   = true end
  for _, k in ipairs(opts.repeating or {}) do repeating[k] = true end
  kq:fill(opts.owner)
end

-- Rebind imgui to ours before loading the pane: earlier specs' preloads cache a
-- different fake, so drop the imgui-capturing modules and re-require.
local function newPane(h)
  package.preload['imgui'] = function() return function(_) return fakeImGui end end
  for _, m in ipairs({ 'imgui', 'gridPane', 'curveEditor', 'painter' }) do package.loaded[m] = nil end
  kq = util.instantiate('keyQueue', { ctx = fakeGui.ctx })
  return util.instantiate('gridPane', {
    cm = h.cm, cmgr = h.cmgr, chrome = fakeChrome, gui = fakeGui, tv = h.vm,
    keyQueue = kq, chordEntry = true,
    inputAllowed = function() return true end,
  })
end

local function mk(harness)
  local h = harness.mk{ config = { take = { currentOctave = 4 } } }
  h.vm:setGridSize(80, 40)
  h.ec:setPos(2, 2, 1)   -- row 2 = ppq 120, chan-1 lane-1 pitch stop
  return h, newPane(h)
end

local function letterKey(ch) return fakeImGui.Key_A + (string.byte(ch) - string.byte('a')) end

-- Onset lookup straight from tm, as the chord/value specs do.
local function noteAt(h, lane, ppq)
  local laneCol = h.tm:getChannel(1).columns.notes[lane]
  for _, evt in ipairs(laneCol and laneCol.events or {}) do
    if evt.ppq == ppq then return evt end
  end
end

return {
  {
    -- The plain case: one fresh press of a note key writes the note at the cursor
    -- and leaves the queue empty, so no later reader can act on it a second time.
    name = 'a fresh press enters at the cursor, and the press is claimed',
    run = function(harness)
      local h, pane = mk(harness)
      setKeys{ pressed = { letterKey('z') } }
      pane:handleKeys()
      t.eq(noteAt(h, 1, 120).pitch, 60, 'the note key wrote C at the cursor row')
      t.eq(kq:take(letterKey('z')), nil, 'and note entry claimed its press')
    end,
  },

  {
    -- What the old commandHeld table did. A key bound to a command and to note entry
    -- alike (say '.') is claimed by the dispatcher before the body draws, so by the
    -- time note entry scans there is nothing left to enter.
    name = 'a press another reader claimed first never enters',
    run = function(harness)
      local h, pane = mk(harness)
      setKeys{ pressed = { letterKey('z') } }
      t.truthy(kq:take(letterKey('z')), 'the earlier reader took the press (precondition)')
      pane:handleKeys()
      t.eq(noteAt(h, 1, 120), nil, 'nothing was entered at the cursor')
    end,
  },

  {
    -- Only the newest edit key autorepeats; without that a held chord re-enters all
    -- its keys interleaved. A repeat of any other key is declined, and declining
    -- means handing the press back.
    name = 'only the last key typed autorepeats; other repeats go back to the queue',
    run = function(harness)
      local h, pane = mk(harness)
      setKeys{ pressed = { letterKey('z') } }
      pane:handleKeys()
      t.truthy(noteAt(h, 1, 120), 'the fresh press entered (precondition)')

      local row = h.ec:row()
      setKeys{ repeating = { letterKey('x') } }
      pane:handleKeys()
      t.eq(h.ec:row(), row, 'a repeat of a stale key entered nothing')
      t.truthy(kq:take(letterKey('x')), 'and its press is still in the queue')

      setKeys{ repeating = { letterKey('z') } }
      pane:handleKeys()
      t.truthy(h.ec:row() > row, 'a repeat of the last key typed enters again')
      t.eq(kq:take(letterKey('z')), nil, 'claiming the press it acted on')
    end,
  },

  {
    -- The chord gesture runs with Shift held, so the Backspace that steps it back
    -- arrives carrying Shift. Note entry claims at the frame's mask, not at none.
    name = 'Backspace steps the chord back, claiming at the frame\'s modifiers',
    run = function(harness)
      local h, pane = mk(harness)
      setKeys{ pressed = { letterKey('z') }, mods = fakeImGui.Mod_Shift }
      pane:handleKeys()
      t.truthy(h.vm:chordActive(), 'the strike armed the chord (precondition)')
      t.truthy(noteAt(h, 1, 120), 'and struck its note')

      setKeys{ pressed = { fakeImGui.Key_Backspace }, mods = fakeImGui.Mod_Shift }
      pane:handleKeys()
      t.eq(noteAt(h, 1, 120), nil, 'Backspace took the struck note back')
      t.eq(kq:take(fakeImGui.Key_Backspace, fakeImGui.Mod_Shift), nil, 'claiming the press at Shift')
    end,
  },
}
