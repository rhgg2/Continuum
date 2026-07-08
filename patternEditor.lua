-- See docs/patternEditor.md for the model.

--contract: OWNS ps/cm/ds/eventMeta + mm/tm/gm/tv/cmgr + gridPane
--contract: RECEIVES host facade + main ds + chrome/gui/modalHost
--contract: checkout take parks on scratch, never slot-registered; close deletes it directly
--contract: bind/unbind pass skipGuard -- the mini stack must never touch the host's guardedTrack
--contract: real gm over an empty groups key -- every edit falls through to tm, wash is empty
--contract: no paramAutomation -- nullPa stands in for tv's structural pa handle
--contract: mini cmgr binds only the pattern-editing keymap subset; rest stay inert
local util    = require 'util'
local scratch = require 'scratch'

if not reaper.ImGui_GetBuiltinPath then
  return reaper.MB('ReaImGui is not installed or too old.', 'My script', 0)
end
package.path = reaper.ImGui_GetBuiltinPath() .. '/?.lua;' .. package.path
local ImGui        = require 'imgui' '0.10'
local keyDispatch  = require 'keyDispatch'
local pageBindings = require 'pageBindings'

local facade, mainDs, chrome, gui, modalHost =
  (...).facade, (...).ds, (...).chrome, (...).gui, (...).modalHost
local ctx = gui.ctx

----- Own stack -- the harness `mk` shape, wired to the real shared facade

-- The mini tracker authors raw notes/pb; it never automates fx params. tv needs a
-- pa handle for paramBinding (per-column draw) and cc-node apply, so hand it a null one.
local nullPa = { binding = function() end, apply = function() end }

local ps        = util.instantiate('pextStore')
local cm        = util.instantiate('configManager',  { ps = ps })
local ds        = util.instantiate('dataStore',      { ps = ps })
local eventMeta = util.instantiate('eventMeta',      { ps = ps })
local mm        = util.instantiate('midiManager',    { take = nil, eventMeta = eventMeta })
local tm        = util.instantiate('trackerManager', { mm = mm, cm = cm, ds = ds })
local gm        = util.instantiate('groupManager',   { tm = tm, ds = ds })
local cmgr      = util.instantiate('commandManager', { cm = cm })
local tv        = util.instantiate('trackerView',
  { tm = tm, cm = cm, ds = ds, cmgr = cmgr, gm = gm, pa = nullPa, facade = facade })

local pe = {}
local item, poolGuid   -- set between open and close; nil while dormant

local gridPane = util.instantiate('gridPane', {
  cm = cm, cmgr = cmgr, chrome = chrome, gui = gui, tv = tv,
  inputAllowed = function() return item ~= nil end,
})

----- Editing surface -- bind the pattern-editing subset of the tracker keymap

-- tv already registered the tracker command bodies against this cmgr; unbound commands are
-- inert, so only the editing subset below is live. see design/fx-patterns.md § Editing surface
local EDIT_COMMANDS = {
  'cursorUp', 'cursorDown', 'cursorLeft', 'cursorRight', 'colLeft', 'colRight',
  'channelLeft', 'channelRight', 'goTop', 'goBottom', 'pageUp', 'pageDown',
  'noteOff', 'inputOctaveUp', 'inputOctaveDown', 'inputSampleUp', 'inputSampleDown',
  'shrinkNote', 'growNote', 'nudgeBack', 'nudgeForward', 'eventShiftLeft', 'eventShiftRight',
  'delete', 'deleteSel', 'interpolate',
  'selectUp', 'selectDown', 'selectLeft', 'selectRight', 'selectClear',
  'cut', 'copy', 'paste', 'duplicateDown',
  'nudgeCoarseUp', 'nudgeCoarseDown', 'nudgeFineUp', 'nudgeFineDown',
  'scaleHalf', 'scaleDouble', 'doubleRPB', 'halveRPB', 'incRPB', 'decRPB',
}

local miniScope = cmgr:scope('tracker')
for _, name in ipairs(EDIT_COMMANDS) do
  local keys = pageBindings.tracker[name]
  if keys then miniScope:bind(name, keys) end
end
cmgr:loadOverrides(ImGui)   -- user rebinds (global tier) apply to the mini editor too
cmgr:push(miniScope)        -- single-purpose cmgr: the tracker scope stays active for its life

----- Materialise the stored body onto the bound checkout take

-- Specs are park-shaped (logical-only). Route through the authoring add -- the same
-- tm:addEvent tv's edit.add reaches -- so materialised notes are editable exactly like
-- typed ones: addEvent takes logical ppq, stamps ppqL/endppqL, files a uuid. rpb rides
-- like an authored note (tv stamps currentRpb); flush commits. see design/fx-patterns.md § Editing surface
local function materialiseNotes(specs)
  local rpb = cm:get('rowPerBeat')
  for _, s in ipairs(specs or {}) do
    tm:addEvent{ evType = 'note', chan = 1, rpb = rpb,
                 ppq = s.ppqL, endppq = s.endppqL,
                 pitch = s.pitch, vel = s.vel,
                 lane = s.lane or 1, detune = s.detune or 0, delay = s.delay or 0,
                 sample = s.sample }
  end
end

-- Curve points are bipolar -1..+1; the pb column authors in cents, full-scale
-- at the take's pbRange. Commit (P3 step e) normalises back by the same factor.
local function materialiseCurve(points)
  local rpb = cm:get('rowPerBeat')
  local fullScaleCents = cm:get('pbRange') * 100
  for _, p in ipairs(points or {}) do
    tm:addEvent{ evType = 'pb', chan = 1, ppq = p.ppq, rpb = rpb,
                 val = p.val * fullScaleCents, shape = p.shape, tension = p.tension }
  end
end

-- Throwaway until the authoring UI (P3.5): a one-bar two-note demo so Super-Shift-E
-- has something to open. ppq rides the take's resolution -- a hardcoded value would be
-- a sliver of a beat under a higher-resolution project. Deleted with openPatternEditor.
local DEMO = 'demo'
local function seedDemo(resolution)
  mainDs:assign('fxPatterns', { [DEMO] = {
    kind = 'notes', lengthPpq = 4 * resolution,
    specs = {
      { lane = 1, ppqL = 0,          endppqL = resolution,     pitch = 60, vel = 100, detune = 0, delay = 0 },
      { lane = 1, ppqL = resolution, endppqL = 2 * resolution, pitch = 64, vel = 100, detune = 0, delay = 0 },
    },
  } })
  return DEMO
end

----------- PUBLIC

--contract: mint a checkout take on scratch, materialise `name`'s body, bind the mini tm
--contract: a nil `name` seeds the throwaway demo; an unknown one tears the mint back down (net no-op)
function pe:open(name)
  if item then return end

  item = reaper.CreateNewMIDIItemInProj(scratch.track(), 0, 1, true)
  local take = reaper.GetActiveTake(item)
  tm:bindTake(take, { skipGuard = true })   -- bindTake keys cm to the take; no separate setContext
  poolGuid = mm:poolGuid()
  local resolution = mm:resolution()

  if not name then name = seedDemo(resolution) end
  local body = (mainDs:get('fxPatterns') or {})[name]
  if not body then                          -- unknown name: undo the mint, stay dormant
    tm:bindTake(nil, { skipGuard = true })
    reaper.DeleteTrackMediaItem(scratch.track(), item)
    item, poolGuid = nil, nil
    return
  end

  mm:setLength(body.lengthPpq / resolution)
  if body.kind == 'curve' then materialiseCurve(body.points)
  else                         materialiseNotes(body.specs) end
  tm:flush()   -- authoring stages into tm; flush drives the one mm:modify + rebuild
  return name
end

--contract: sweep the pool metadata (write-through, so leaks without this)
--contract: unbind the mini tm, delete the checkout item
function pe:close()
  if not item then return end
  eventMeta:dropPool(poolGuid)
  tm:bindTake(nil, { skipGuard = true })
  reaper.DeleteTrackMediaItem(scratch.track(), item)
  item, poolGuid = nil, nil
end

function pe:isOpen()      return item ~= nil      end
function pe:currentTake() return tm:currentTake() end

----- Modal editing surface

-- The mini editor owns the keyboard whenever its popup is up; there is no picker or
-- palette to gate, so acceptCmds is always on.
local miniFocus = { acceptCmds = true, suppressKbd = false, pageSuppressed = false }

--contract: draw pass -- the grid fills a viewport fraction; the auto-resize popup sizes to it
function pe:draw()
  local vw, vh = ImGui.Viewport_GetWorkSize(ImGui.GetWindowViewport(ctx))
  gridPane:draw(vw * 0.7, vh * 0.6)
end

--contract: input pass -- mouse, dispatch against mini cmgr, note entry; unconsumed Esc/Enter close
--contract: returns the dispatch result kr = { consumed, commandHeld }
function pe:handleInput(close)
  gridPane:handleMouse()
  local kr = keyDispatch.dispatchKeys(miniFocus, cmgr, ctx)
  gridPane:handleKeys(kr)
  if not kr.consumed
     and (ImGui.IsKeyPressed(ctx, ImGui.Key_Escape)
       or ImGui.IsKeyPressed(ctx, ImGui.Key_Enter)
       or ImGui.IsKeyPressed(ctx, ImGui.Key_KeypadEnter)) then
    close(false)
  end
  return kr
end

modalHost:registerKind('patternEditor', function(_, close)
  pe:draw()
  pe:handleInput(close)
end)

--contract: production entry -- mint the checkout and raise the editing modal; onClose sweeps it
function pe:launch(name)
  local opened = self:open(name)
  if item then modalHost:open{ kind = 'patternEditor', title = opened,
                               onClose = function() self:close() end } end
end

return pe
