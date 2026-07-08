-- See docs/patternEditor.md for the model.

--contract: OWNS ps/cm/ds/eventMeta + mm/tm/gm/tv/cmgr + gridPane
--contract: RECEIVES host facade + chrome/gui/modalHost
--contract: checkout take parks on scratch, never slot-registered; close deletes it directly
--contract: bind/unbind pass skipGuard -- the mini stack must never touch the host's guardedTrack
--contract: real gm over an empty groups key -- every edit falls through to tm, wash is empty
--contract: no paramAutomation -- nullPa stands in for tv's structural pa handle
--contract: mini cmgr binds only the pattern-editing keymap subset; rest stay inert
--contract: edits write through on every mini rebuild -- readback strips to the whitelist, deepEq-guarded via the commit callback
--contract: Esc restores the open snapshot; Enter commits; `armed` gates out the open/close rebuilds
local util    = require 'util'
local scratch = require 'scratch'

if not reaper.ImGui_GetBuiltinPath then
  return reaper.MB('ReaImGui is not installed or too old.', 'My script', 0)
end
package.path = reaper.ImGui_GetBuiltinPath() .. '/?.lua;' .. package.path
local ImGui        = require 'imgui' '0.10'
local keyDispatch  = require 'keyDispatch'
local pageBindings = require 'pageBindings'

local facade, chrome, gui, modalHost =
  (...).facade, (...).chrome, (...).gui, (...).modalHost
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
local tm        = util.instantiate('trackerManager', { mm = mm, cm = cm, ds = ds, defaultNoteCols = 0 })
local gm        = util.instantiate('groupManager',   { tm = tm, ds = ds })
local cmgr      = util.instantiate('commandManager', { cm = cm })
local tv        = util.instantiate('trackerView',
  { tm = tm, cm = cm, ds = ds, cmgr = cmgr, gm = gm, pa = nullPa, facade = facade })

local pe = {}
local item, poolGuid           -- set between open and close; nil while dormant
local editBody, commitFn       -- open-snapshot body + write-back closure; nil while dormant
local lastWritten              -- last body committed; deepEq-compared to skip a no-op write-through
local armed = false            -- gate write-through to genuine edits, not open/close rebuilds

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
-- at the take's pbRange. readbackBody normalises back by the same factor on write-through.
local function materialiseCurve(points)
  local rpb = cm:get('rowPerBeat')
  local fullScaleCents = cm:get('pbRange') * 100
  for _, p in ipairs(points or {}) do
    tm:addEvent{ evType = 'pb', chan = 1, ppq = p.ppq, rpb = rpb,
                 val = p.val * fullScaleCents, shape = p.shape, tension = p.tension }
  end
end

----- Write-through commit -- persist checkout edits back to the shared store

-- Read channel 1 back through tm and rebuild the whitelisted body: notes drop fx/chan and fix
-- lane 1, a curve normalises the pb column's cents to bipolar. lengthPpq/root ride the open
-- snapshot (no bound command edits them). The field pick IS the whitelist. see design/fx-patterns.md § checkout model
local function readbackBody()
  local cols = (tm:getChannel(1) or {}).columns or {}
  if editBody.kind == 'curve' then
    local fullScaleCents = cm:get('pbRange') * 100
    local points = {}
    for _, e in ipairs(cols.pb and cols.pb.events or {}) do
      util.add(points, { ppq = e.ppqL, val = (e.val + (e.detune or 0)) / fullScaleCents,
                         shape = e.shape, tension = e.tension })
    end
    return { kind = 'curve', lengthPpq = editBody.lengthPpq, points = points }
  end
  local specs = {}
  for _, col in ipairs(cols.notes or {}) do
    for _, e in ipairs(col.events) do
      if e.evType ~= 'pa' and e.ppqL ~= nil then
        util.add(specs, { lane = 1, ppqL = e.ppqL, endppqL = e.endppqL,
                          pitch = e.pitch, vel = e.vel,
                          detune = e.detune or 0, delay = e.delay or 0, sample = e.sample })
      end
    end
  end
  table.sort(specs, function(a, b) return a.ppqL < b.ppqL end)   -- stable order -> deepEq no-op on reopen
  return { kind = 'notes', lengthPpq = editBody.lengthPpq, root = editBody.root, specs = specs }
end

-- Fires on every mini rebuild; `armed` gates out the open/close rebuilds (bindTake, the
-- materialise flush, the unbind) whose take is not yet/no longer the edited body.
local function writeThrough()
  if not armed then return end
  local body = readbackBody()
  if not util.deepEq(lastWritten, body) then
    lastWritten = body
    commitFn(body)
  end
end
tm:subscribe('rebuild', writeThrough)

-- Esc discards: write-through already made the param track the edits, so restore the open
-- snapshot with one guarded write. Enter needs no counterpart -- the param is already current.
local function cancel(close)
  armed = false
  if not util.deepEq(lastWritten, editBody) then commitFn(editBody) end
  close(false)
end

----------- PUBLIC

--contract: mint a checkout take on scratch, materialise `body`, bind the mini tm; `commit(newBody)` is the write-back
--contract: snapshots the body and arms write-through once materialised (open/close rebuilds stay silent)
--contract: an empty body (no lengthPpq) defaults its loop to one bar of the checkout take
function pe:open(body, commit)
  if item then return end

  item = reaper.CreateNewMIDIItemInProj(scratch.track(), 0, 1, true)
  local take = reaper.GetActiveTake(item)
  tm:bindTake(take, { skipGuard = true })   -- bindTake keys cm to the take; no separate setContext
  poolGuid = mm:poolGuid()
  local resolution = mm:resolution()

  body = util.deepClone(body)
  body.lengthPpq = body.lengthPpq or 4 * resolution
  mm:setLength(body.lengthPpq / resolution)
  editBody, commitFn, lastWritten = body, commit, body
  if body.kind == 'curve' then
    ds:assign('extraColumns', { [1] = { notes = 0, pb = true } })   -- force a pb column so an empty curve is editable
    materialiseCurve(body.points)
  else
    ds:assign('extraColumns', { [1] = { notes = 1 } })   -- force a note column so an empty pattern is typeable
    materialiseNotes(body.specs)
  end
  tm:flush()   -- authoring stages into tm; flush drives the one mm:modify + rebuild
  armed = true
  return true
end

--contract: sweep the pool metadata (write-through, so leaks without this)
--contract: unbind the mini tm, delete the checkout item
function pe:close()
  if not item then return end
  armed = false   -- before the unbind rebuild, else it writes an empty body over the store
  eventMeta:dropPool(poolGuid)
  tm:bindTake(nil, { skipGuard = true })
  reaper.DeleteTrackMediaItem(scratch.track(), item)
  item, poolGuid, editBody, commitFn, lastWritten = nil, nil, nil, nil, nil
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

--contract: input pass -- mouse, dispatch against mini cmgr, note entry; unconsumed Esc cancels, Enter commits
--contract: returns the dispatch result kr = { consumed, commandHeld }
function pe:handleInput(close)
  gridPane:handleMouse()
  local kr = keyDispatch.dispatchKeys(miniFocus, cmgr, ctx)
  gridPane:handleKeys(kr)
  if not kr.consumed then
    if ImGui.IsKeyPressed(ctx, ImGui.Key_Escape) then
      cancel(close)
    elseif ImGui.IsKeyPressed(ctx, ImGui.Key_Enter)
        or ImGui.IsKeyPressed(ctx, ImGui.Key_KeypadEnter) then
      close(false)
    end
  end
  return kr
end

modalHost:registerKind('patternEditor', function(_, close)
  pe:draw()
  pe:handleInput(close)
end)

--contract: production entry -- mint the checkout on `body` and raise the editing modal; onClose sweeps it
function pe:launch(body, commit)
  if self:open(body, commit) then
    modalHost:open{ kind = 'patternEditor', title = body.kind or 'pattern',
                    onClose = function() self:close() end }
  end
end

return pe
