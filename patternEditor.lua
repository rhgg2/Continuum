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
local swallowInput = false     -- one-shot: drop the keystroke that launched the modal, so its press-edge (Enter=commit, ←→) isn't re-read here

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
-- Ctrl+digit advBy0..9 arm the auto-step; bind the generated series alongside the edit subset.
for i = 0, 9 do
  miniScope:bind('advBy' .. i, pageBindings.tracker['advBy' .. i])
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

-- Normalized substrate: pb column, points -1..+1 <-> thousandths (pbRange 10 makes +-1000 full-scale).
-- CC substrate: fixed scratch CURVE_CC, points 0..127 verbatim. Generator owns the real destination.
local CURVE_CC = 1

-- columnDisplay flags for the curve column, from the body's domain + display hint:
-- normalized -> pb thousandths (bipolar unless 'unipolar'); cc -> 14-bit unless 'cc7'.
local function curveDisplay(body)
  if body.domain == 'cc' then
    return { [1] = { ccs = { [CURVE_CC] = { ['14bit'] = body.display ~= 'cc7', label = body.label } } } }
  end
  return { [1] = { pb = { normalized = true, bipolar = body.display ~= 'unipolar', label = body.label } } }
end

local function materialiseCurve(body)
  local rpb = cm:get('rowPerBeat')
  for _, p in ipairs(body.points or {}) do
    if body.domain == 'cc' then
      tm:addEvent{ evType = 'cc', chan = 1, cc = CURVE_CC, ppq = p.ppq, rpb = rpb,
                   val = p.val, shape = p.shape, tension = p.tension }
    else
      tm:addEvent{ evType = 'pb', chan = 1, ppq = p.ppq, rpb = rpb,
                   val = p.val * 1000, shape = p.shape, tension = p.tension }
    end
  end
end

----- Write-through commit -- persist checkout edits back to the shared store

-- Read channel 1 back through tm and rebuild the whitelisted body: notes drop fx/chan and fix
-- lane 1, a curve normalises the pb column's cents to bipolar. lengthPpq/root ride the open
-- snapshot (no bound command edits them). The field pick IS the whitelist. see design/fx-patterns.md § checkout model
local function readbackBody()
  local cols = (tm:getChannel(1) or {}).columns or {}
  if editBody.kind == 'curve' then
    local points = {}
    if editBody.domain == 'cc' then
      local col = cols.ccs and cols.ccs[CURVE_CC]
      for _, e in ipairs(col and col.events or {}) do
        util.add(points, { ppq = e.ppqL, val = e.val, shape = e.shape, tension = e.tension })
      end
    else
      for _, e in ipairs(cols.pb and cols.pb.events or {}) do
        util.add(points, { ppq = e.ppqL, val = (e.val + (e.detune or 0)) / 1000,
                           shape = e.shape, tension = e.tension })
      end
    end
    return { kind = 'curve', domain = editBody.domain, display = editBody.display,
             lengthPpq = editBody.lengthPpq, points = points }
  end
  local specs = {}
  for _, col in ipairs(cols.notes or {}) do
    for _, e in ipairs(col.events) do
      if e.evType ~= 'pa' and e.ppqL ~= nil then
        local endppqL = (e.endppqL == nil or e.endppqL == util.OPEN) and editBody.lengthPpq or e.endppqL
        util.add(specs, { lane = 1, ppqL = e.ppqL, endppqL = endppqL,
                          pitch = e.pitch, vel = e.vel,
                          detune = e.detune or 0, delay = e.delay or 0, sample = e.sample })
      end
    end
  end
  table.sort(specs, function(a, b) return a.ppqL < b.ppqL end)   -- stable order -> deepEq no-op on reopen
  -- Lane 1 is the only lane, so a note's tail ends at the next onset: clip so an OPEN/over-long
  -- ceiling never serialises as an overlap. The trailing note keeps its lengthPpq cap.
  for i = 1, #specs - 1 do
    specs[i].endppqL = math.min(specs[i].endppqL, specs[i + 1].ppqL)
  end
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
  cm:set('track', 'rowPerBeat', 4)          -- reset to 4 rpb on open; track tier (as tv:setRowPerBeat writes) so a later change isn't shadowed
  poolGuid = mm:poolGuid()
  local resolution = mm:resolution()

  body = util.deepClone(body)
  body.lengthPpq = body.lengthPpq or 4 * resolution
  -- Curve bodies extend the live loop by one row so the endL anchor at ppq=lengthPpq is a reachable
  -- interior row, not the boundary ctx:ppqToRow clamps to phantom numRows. see docs/patternEditor.md
  local loopPpq = body.lengthPpq
  if body.kind == 'curve' then loopPpq = loopPpq + 1  end
  mm:setLength(loopPpq / resolution)
  editBody, commitFn, lastWritten = body, commit, body
  if body.kind == 'curve' then
    body.domain = body.domain or 'normalized'
    -- pe:draw renders its own full-size curve editor; suppress gridPane's auto lane strip so the
    -- global-tier `laneStrip.visible` toggle can't gate the curve pane. see docs/patternEditor.md
    cm:set('take', 'laneStrip.visible', false)
    -- Substrate column per domain, display flags, then body. see design/fx-patterns.md § Curve signature
    local col
    if body.domain == 'cc' then
      col = { notes = 0, ccs = { [CURVE_CC] = true } }
    else
      col = { notes = 0, pb = true }
      cm:set('take', 'pbRange', 10)
    end
    ds:assign('extraColumns',  { [1] = col })
    ds:assign('columnDisplay', curveDisplay(body))
    if #(body.points or {}) == 0 then
      -- Fresh curve: two linear zero anchors span the loop, so the pane opens non-empty and
      -- a grid-typed breakpoint inherits linear interpolation from its neighbour.
      body.points = { { ppq = 0, val = 0, shape = 'linear' },
                      { ppq = body.lengthPpq, val = 0, shape = 'linear' } }
    end
    materialiseCurve(body)
  else
    cm:set('take', 'laneStrip.visible', false)   -- note editor is grid-only; no curve pane
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

-- Modal chrome (title bar + padding) height, measured once in draw so launch sizes exactly.
local modalChrome
-- Rows the last launch sized the modal for; pe:draw snaps the first-ever window to fit them exactly.
local launchRows

-- The mini editor owns the keyboard whenever its popup is up; there is no picker or
-- palette to gate, so acceptCmds is always on.
local miniFocus = { acceptCmds = true, suppressKbd = false, pageSuppressed = false }

--contract: draw pass -- the grid fills a viewport fraction; the auto-resize popup sizes to it
function pe:draw()
  local x, y = ImGui.GetCursorScreenPos(ctx)
  local w, h = ImGui.GetContentRegionAvail(ctx)
  -- Measure the modal chrome (window height - content height) once so the next launch sizes
  -- exactly; chrome is constant, so measure-once suffices. First launch uses an estimate.
  if not modalChrome then
    -- First-ever open was sized from a chrome estimate; measure the real chrome now and snap the
    -- window to the exact height for launchRows, so an under-estimate can't clip the last row.
    local ww, wh = ImGui.GetWindowSize(ctx)
    modalChrome = wh - h
    ImGui.SetWindowSize(ctx, ww, gridPane:heightForRows(launchRows) + modalChrome)
  end
  -- The grid draws cells on transparent modal bg; back it with the tracker bg so it
  -- reads as the tracker, not the (deliberately distinct) modal surface.
  ImGui.DrawList_AddRectFilled(ImGui.GetWindowDrawList(ctx), x, y, x + w, y + h, chrome.colour('bg'))

  if editBody and editBody.kind == 'curve' then
    -- Curve is the hero, filling the width between a half-cell left inset and the grid; the grid rides
    -- the right at its exact intrinsic width, half a cell clear of the window edge. Both insets sit on
    -- the content fill above, so they read as grid bg. Draw grid first: its laneConsumed reset must not
    -- clobber the curve pane's.
    local gap       = 8
    local pad       = gridPane:cellWidth()
    local gridW     = gridPane:naturalWidth()
    local curveLeft = x + pad
    local gridLeft  = x + w - pad - gridW
    local curveW    = gridLeft - gap - curveLeft
    ImGui.SetCursorScreenPos(ctx, gridLeft, y)
    gridPane:draw(gridW, h)
    gridPane:drawCurveEditor{ x0 = curveLeft, yTop = y, w = curveW, h = h, endRow = tv:ppqToRow(editBody.lengthPpq) }
  else
    gridPane:draw(w, h)
  end

  -- Both panes draw via absolute coords, so neither grows the window to the content rect;
  -- reserve it as one item, else BeginPopupModal complains nothing follows the cursor move.
  ImGui.SetCursorScreenPos(ctx, x, y)
  ImGui.Dummy(ctx, w, h)
end

--contract: input pass -- mouse, dispatch against mini cmgr, note entry; unconsumed Esc cancels, Enter commits
--contract: returns the dispatch result kr = { consumed, commandHeld }
function pe:handleInput(close)
  if swallowInput then swallowInput = false; return { consumed = true, commandHeld = {} } end
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
    swallowInput = true   -- the launching key (Enter/←→) still has a live press-edge; skip the modal's first input pass so it isn't re-read as commit/nav
    local vw = ImGui.Viewport_GetWorkSize(ImGui.GetWindowViewport(ctx))
    -- Height fits the whole grid capped at 32 content rows (curve mode adds the endL terminal
    -- row), plus the modal chrome. Width stays a viewport fraction; both axes stay user-resizable.
    local maxRows = 32 + (body.kind == 'curve' and 1 or 0)
    local rows    = math.min(maxRows, math.max(1, tv.grid.numRows or 1))
    launchRows    = rows
    local chromeH = modalChrome
    if not chromeH then
      -- First-ever launch: no measured chrome yet, so over-estimate (title bar + padding + a row's
      -- cushion) to fit rather than clip; draw() then measures exactly and snaps the window.
      local _, wpadY = ImGui.GetStyleVar(ctx, ImGui.StyleVar_WindowPadding)
      local _, fpadY = ImGui.GetStyleVar(ctx, ImGui.StyleVar_FramePadding)
      chromeH = gui.fontSize.ui + 2 * (fpadY + 2) + 2 * wpadY + gridPane:cellHeight() * 1.5
    end
    local title = body.kind == 'curve' and 'Curve editor' or 'Note editor'
    modalHost:open{ kind = 'patternEditor', title = title,
                    size = { vw * 0.72, gridPane:heightForRows(rows) + chromeH },
                    onClose = function() self:close() end }
  end
end

return pe
