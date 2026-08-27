-- See docs/patternEditor.md for the model.

--contract: OWNS ps/cm/ds/eventMeta + mm/tm/gm/tv/cmgr + gridPane
--contract: RECEIVES host facade + chrome/gui/modalHost
--contract: checkout take parks on scratch, never slot-registered; close deletes it directly
--contract: bind/unbind pass skipGuard -- the mini stack must never touch the host's guardedTrack
--contract: real gm over an empty groups key -- every edit falls through to tm, wash is empty
--contract: no paramAutomation -- nullPa stands in for tv's structural pa handle
--contract: mini cmgr binds only the pattern-editing keymap subset; rest stay inert
--contract: edits write through on every mini rebuild -- readback strips to the whitelist, deepEq-guarded via the commit callback
--contract: Esc/Cancel restore the open snapshot; Enter/Commit close on the current store
--contract: Save/Load run a named copy shelf on host ds; a Load reopens the checkout in place
--contract: `armed` gates out the open/close rebuilds
local util    = require 'util'
local scratch = require 'scratch'

if not reaper.ImGui_GetBuiltinPath then
  return reaper.MB('ReaImGui is not installed or too old.', 'My script', 0)
end
package.path = reaper.ImGui_GetBuiltinPath() .. '/?.lua;' .. package.path
local ImGui        = require 'imgui' '0.10'
local keyDispatch  = require 'keyDispatch'
local manifest     = require 'manifest'

local facade, chrome, gui, modalHost, hostDs =
  (...).facade, (...).chrome, (...).gui, (...).modalHost, (...).hostDs
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
  { tm = tm, cm = cm, ds = ds, cmgr = cmgr, gm = gm, pa = nullPa, facade = facade,
    masterChannel = false })

local pe = {}
local item, poolGuid           -- set between open and close; nil while dormant
local editBody, commitFn       -- live body metadata + write-back closure; nil while dormant
local openSnapshot             -- body as opened; Esc/Cancel restore it. A Load replaces editBody, never this
local editPoly = false         -- kind opt-in: poly authors overlapping note lanes, mono pins everything to lane 1
local lastWritten              -- last body committed; deepEq-compared to skip a no-op write-through
local armed = false            -- gate write-through to genuine edits, not open/close rebuilds
local swallowInput = false     -- one-shot: drop the keystroke that launched the modal, so its press-edge (Enter=commit, ←→) isn't re-read here
local pendingAction            -- 'commit'|'cancel'|{save=name}|{load=name} set by a toolbar widget in draw; handleInput drains it next

-- Note entry and command dispatch both self-suppress while a toolbar widget holds focus, mirroring
-- the main grid (trackerRender: inputAllowed folds focusState.acceptCmds). item==nil means dormant.
local function acceptInput()
  return item ~= nil and not ImGui.IsAnyItemActive(ctx)
     and not chrome.pickerIsActive()
end

local gridPane = util.instantiate('gridPane', {
  cm = cm, cmgr = cmgr, chrome = chrome, gui = gui, tv = tv, chordEntry = false,
  inputAllowed = acceptInput,
})

----- Editing surface -- bind the pattern-editing subset of the tracker keymap

-- tv already registered the tracker command bodies against this cmgr; unbound commands are
-- inert, so only the editing subset below is live.
local EDIT_COMMANDS = {
  'cursorUp', 'cursorDown', 'cursorLeft', 'cursorRight', 'colLeft', 'colRight',
  'channelLeft', 'channelRight', 'goTop', 'goBottom', 'pageUp', 'pageDown',
  'noteOff', 'inputOctaveUp', 'inputOctaveDown', 'inputSampleUp', 'inputSampleDown',
  'shrinkNote', 'growNote', 'nudgeBack', 'nudgeForward', 'eventShiftLeft', 'eventShiftRight',
  'delete', 'deleteSel', 'interpolate',
  'selectUp', 'selectDown', 'selectLeft', 'selectRight', 'selectClear', 'selectAll',
  'cut', 'copy', 'paste', 'duplicateDown',
  'nudgeCoarseUp', 'nudgeCoarseDown', 'nudgeFineUp', 'nudgeFineDown',
  'scaleHalf', 'scaleDouble', 'doubleRPB', 'halveRPB', 'incRPB', 'decRPB',
}

-- Keys come from the tracker manifest: edit commands above, the Ctrl+digit
-- advBy series (auto-step), and the lane pair (unbound until a poly editor opens).
local miniScope = cmgr:scope('tracker')
local wanted    = { addNoteLane = true, hideExtraCol = true }
for _, name in ipairs(EDIT_COMMANDS) do wanted[name] = true end
for i = 0, 9 do wanted['advBy' .. i] = true end

local subset = {}
for _, entry in ipairs(manifest.tracker) do
  if wanted[entry.name] then util.add(subset, entry) end
end
cmgr:installManifest({ tracker = subset }, ImGui)
cmgr:loadOverrides(ImGui)   -- user rebinds (global tier) apply to the mini editor too
cmgr:push(miniScope)        -- single-purpose cmgr: the tracker scope stays active for its life

-- Add/remove note lane: not inherited from tv's registerAll (those bodies live on the page cmgr),
-- so register locally. See docs/patternEditor.md § Lane commands for why hideExtraCol, not removeOrHideCol.
miniScope:register('addNoteLane',  function() tv:addExtraCol('note') end)
miniScope:register('hideExtraCol', function() tv:hideExtraCol() end)

-- Lane editing is poly-only: bind the pair's keys (Ctrl+Right/Left) while a poly editor
-- is open, clear otherwise; held from the installed keymap so a rebind rides along.
local laneKeys = { addNoteLane  = cmgr:keysFor('addNoteLane'),
                   hideExtraCol = cmgr:keysFor('hideExtraCol') }

local function setLaneCommands(on)
  miniScope:bind('addNoteLane',  on and laneKeys.addNoteLane  or nil)
  miniScope:bind('hideExtraCol', on and laneKeys.hideExtraCol or nil)
end

----- Materialise the stored body onto the bound checkout take

-- Specs are park-shaped (logical-only). Route through the authoring add -- the same tm:addEvent tv's edit.add
-- reaches -- so materialised notes are editable exactly like typed ones: logical ppq in, ppqL/endppqL and a uuid stamped, rpb like an authored note (tv stamps currentRpb), flush commits.
local function materialiseNotes(specs)
  local rpb = cm:get('rowPerBeat')
  for _, s in ipairs(specs or {}) do
    tm:addEvent{ evType = 'note', chan = 1, rpb = rpb,
                 ppq = s.ppq, endppq = s.endppq,
                 pitch = s.pitch, vel = s.vel,
                 lane = editPoly and (s.lane or 1) or 1, detune = s.detune or 0, delay = s.delay or 0,
                 intentCents = s.intentCents, sample = s.sample }
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

-- Read channel 1 back through tm and rebuild the whitelisted body -- the field pick IS the whitelist: notes drop fx/chan and fix lane 1, a curve normalises the pb column's cents to bipolar.
-- lengthPpq/root ride the open snapshot (no bound command edits them); rpb reads live, so a toolbar change persists with the body rather than dying with the checkout take.
local function readbackBody()
  local cols = (tm:getChannel(1) or {}).columns or {}
  if editBody.kind == 'curve' then
    local points = {}
    if editBody.domain == 'cc' then
      local col = cols.ccs and cols.ccs[CURVE_CC]
      for _, e in ipairs(col and col.events or {}) do
        util.add(points, { ppq = e.ppq, val = e.val, shape = e.shape, tension = e.tension })
      end
    else
      for _, e in ipairs(cols.pb and cols.pb.events or {}) do
        util.add(points, { ppq = e.ppq, val = (e.val + (e.detune or 0)) / 1000,
                           shape = e.shape, tension = e.tension })
      end
    end
    return { kind = 'curve', domain = editBody.domain, display = editBody.display,
             lengthPpq = editBody.lengthPpq, rpb = cm:get('rowPerBeat'), points = points }
  end
  local specs = {}
  for laneIdx, col in ipairs(cols.notes or {}) do
    local colSpecs = {}
    for _, e in ipairs(col.events) do
      if e.evType ~= 'pa' then
        local endppq = (e.endppq == nil or e.endppq == util.OPEN) and editBody.lengthPpq or e.endppq
        util.add(colSpecs, { lane = editPoly and laneIdx or 1, ppq = e.ppq, endppq = endppq,
                             pitch = e.pitch, vel = e.vel,
                             detune = e.detune or 0, delay = e.delay or 0,
                             intentCents = e.intentCents, sample = e.sample })
      end
    end
    -- A lane is monophonic, so within its own column a note's tail ends at the next onset: clip so an
    -- OPEN/over-long ceiling never serialises as an overlap. The trailing note keeps its lengthPpq cap.
    table.sort(colSpecs, function(a, b) return a.ppq < b.ppq end)
    for i = 1, #colSpecs - 1 do
      colSpecs[i].endppq = math.min(colSpecs[i].endppq, colSpecs[i + 1].ppq)
    end
    for _, s in ipairs(colSpecs) do util.add(specs, s) end
  end
  -- Stable (lane, ppq) order -> deepEq no-op on reopen. Mono has one column, so this is a ppq sort.
  table.sort(specs, function(a, b)
    if a.lane ~= b.lane then return a.lane < b.lane end
    return a.ppq < b.ppq
  end)
  return { kind = 'notes', lengthPpq = editBody.lengthPpq, root = editBody.root,
           rpb = cm:get('rowPerBeat'), specs = specs }
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
  if not util.deepEq(lastWritten, openSnapshot) then commitFn(openSnapshot) end
  close(false)
end

----------- PUBLIC

--contract: mint a checkout take on scratch, materialise `body`, bind the mini tm; `commit(newBody)` is the write-back
--contract: snapshots the body and arms write-through once materialised (open/close rebuilds stay silent)
--contract: an empty body (no lengthPpq) defaults its loop to one bar of the checkout take
function pe:open(body, commit, poly)
  if item then return end
  editPoly = poly or false

  item = reaper.CreateNewMIDIItemInProj(scratch.track(), 0, 1, true)
  local take = reaper.GetActiveTake(item)
  tm:bindTake(take, { skipGuard = true })   -- bindTake keys cm to the take; no separate setContext
  poolGuid = mm:poolGuid()
  local resolution = mm:resolution()

  body = util.deepClone(body)
  body.lengthPpq = body.lengthPpq or 4 * resolution
  body.rpb = body.rpb or 4
  -- Seed the ticker from the body, before materialise stamps each event's rpb. Track tier (as
  -- tv:setRowPerBeat writes) so a later toolbar change isn't shadowed by a more specific tier.
  cm:set('track', 'rowPerBeat', body.rpb)
  -- Curve bodies extend the live loop by one row so the endL anchor at ppq=lengthPpq is a reachable
  -- interior row, not the boundary ctx:ppqToRow clamps to phantom numRows. see docs/patternEditor.md
  local loopPpq = body.lengthPpq
  if body.kind == 'curve' then loopPpq = loopPpq + 1  end
  mm:setLength(loopPpq / resolution)
  editBody, commitFn, lastWritten, openSnapshot = body, commit, body, body
  if body.kind == 'curve' then
    body.domain = body.domain or 'normalized'
    -- pe:draw renders its own full-size curve editor; suppress gridPane's auto lane strip so the
    -- global-tier `laneStrip.visible` toggle can't gate the curve pane. see docs/patternEditor.md
    cm:set('take', 'laneStrip.visible', false)
    -- Substrate column per domain, display flags, then body.
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
    -- A poly editor opens with as many note columns as the body's deepest authored lane (>=1); a mono
    -- editor forces exactly one, so a multi-lane body flattens onto lane 1. Empty stays typeable.
    local noteCols = 1
    if editPoly then
      for _, s in ipairs(body.specs or {}) do noteCols = math.max(noteCols, s.lane or 1) end
    end
    ds:assign('extraColumns', { [1] = { notes = noteCols } })
    setLaneCommands(editPoly)
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
  setLaneCommands(false)
  eventMeta:dropPool(poolGuid)
  tm:bindTake(nil, { skipGuard = true })
  reaper.DeleteTrackMediaItem(scratch.track(), item)
  item, poolGuid, editBody, commitFn, lastWritten, openSnapshot = nil, nil, nil, nil, nil, nil
  editPoly = false
end

function pe:isOpen()      return item ~= nil      end
function pe:currentTake() return tm:currentTake() end

----- Library copy shelf -- named bodies on the host ds; Save/Load only

-- The shelf lives on the HOST ds (project scope): the mini stack never writes a project tier, and a
-- shelf edit re-realises nothing (a copy shelf, not live sharing). see docs/patternEditor.md § The copy shelf
local function shelf() return hostDs:get('fxPatterns') or {} end

local function saveShelf(name)
  local s = shelf()
  s[name] = readbackBody()   -- the whitelisted shape, so a later write-through deepEqs clean against it
  hostDs:assign('fxPatterns', s)
end

local function deleteShelf(name)
  local s = shelf()
  s[name] = nil
  hostDs:assign('fxPatterns', s)
end

local function maxLane(body)
  local m = 1
  for _, s in ipairs(body.specs or {}) do m = math.max(m, s.lane or 1) end
  return m
end

-- Load offers only bodies this editor can materialise: matching kind, curve domain, and (mono) single-lane,
-- so lanes 2..N are never silently crushed onto lane 1.
local function shelfMatches(body)
  if body.kind ~= editBody.kind then return false end
  if editBody.kind == 'curve' then return (body.domain or 'normalized') == editBody.domain end
  if not editPoly then return maxLane(body) == 1 end
  return true
end

-- Rematerialise a shelf body in place: reopen the checkout on it, keep the modal-open snapshot as
-- the cancel target, then push the loaded body at the param by hand. see docs/patternEditor.md § The copy shelf
local function loadShelf(name)
  local body = shelf()[name]
  if not body then return end
  local commit, snapshot, poly = commitFn, openSnapshot, editPoly
  pe:close()
  pe:open(body, commit, poly)
  openSnapshot = snapshot
  lastWritten  = readbackBody()
  commitFn(lastWritten)
end

-- Sorted matching-kind shelf names as picker items; shared by Save and Load.
local function shelfItems()
  local names = {}
  for name, body in pairs(shelf()) do
    if shelfMatches(body) then util.add(names, name) end
  end
  table.sort(names)
  local items = {}
  for _, name in ipairs(names) do util.add(items, { label = name, key = name }) end
  return items
end

-- Save and Load are both drawPickers over the matching-kind shelf names; no confirm needed since an
-- explicit pick/typed-name is itself the confirmation. see docs/patternEditor.md § The copy shelf
local function drawSave()
  chrome.drawPicker{ kind = 'peSave', buttonLabel = 'Save', items = shelfItems(),
                     onPick   = function(name) pendingAction = { save = name } end,
                     onCreate = function(name) pendingAction = { save = name } end }
end

-- Only Load manages the shelf: its rows carry the two-press delete, Save's stay plain.
-- see docs/patternEditor.md § The copy shelf
local function drawLoad()
  chrome.drawPicker{ kind = 'peShelf', buttonLabel = 'Load', items = shelfItems(),
                     onPick   = function(name) pendingAction = { load = name } end,
                     onDelete = function(name) pendingAction = { delete = name } end }
end

----- Modal editing surface

-- Modal chrome (title bar + padding) height, measured once in draw so launch sizes exactly.
local modalChrome
-- Rows the last launch sized the modal for; pe:draw snaps the first-ever window to fit them exactly.
local launchRows

-- The mini editor owns the keyboard whenever its popup is up. acceptCmds is refreshed each frame in
-- handleInput so command dispatch pauses while a toolbar widget (RPB stepper, buttons) holds focus.
local miniFocus = { acceptCmds = true, suppressKbd = false, pageSuppressed = false }

-- Mini toolbar: a copy of the tracker RPB ticker plus Commit/Cancel.
-- see docs/patternEditor.md § Write-through commit for the button/pendingAction handoff.
local function drawToolbar()
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_FramePadding, 6, 2)   -- match the main toolbar's element height (coordinator pushes the same)
  ImGui.AlignTextToFramePadding(ctx)
  chrome.headingLabel('RPB')
  ImGui.SameLine(ctx, 0, 8)
  local changed, n = chrome.numberStepper('rpb', cm:get('rowPerBeat'), { min = 1, max = 32, align = 'center' })
  if changed then tv:setRowPerBeat(n) end
  ImGui.SameLine(ctx, 0, 12); chrome.verticalSeparator(); ImGui.SameLine(ctx, 0, 12)
  if ImGui.Button(ctx, 'Commit##peCommit') then pendingAction = 'commit' end
  ImGui.SameLine(ctx, 0, 6)
  if ImGui.Button(ctx, 'Cancel##peCancel') then pendingAction = 'cancel' end
  ImGui.SameLine(ctx, 0, 12); chrome.verticalSeparator(); ImGui.SameLine(ctx, 0, 12)
  drawSave()
  ImGui.SameLine(ctx, 0, 6)
  drawLoad()
  ImGui.PopStyleVar(ctx, 1)
end

--contract: draw pass -- toolbar row, grid fills the region below; popup sizes to fit
function pe:draw()
  drawToolbar()
  ImGui.Dummy(ctx, 0, 4)   -- gap so the grid bg fill clears the toolbar

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
  if pendingAction then
    local action = pendingAction; pendingAction = nil
    if     action == 'commit' then close(false)
    elseif action == 'cancel' then cancel(close)
    elseif action.save   then saveShelf(action.save)
    elseif action.delete then deleteShelf(action.delete)
    else   loadShelf(action.load) end
    return { consumed = true, commandHeld = {} }
  end
  gridPane:handleMouse()
  miniFocus.acceptCmds = acceptInput()   -- pause command dispatch while a toolbar widget holds focus
  local kr = keyDispatch.dispatchKeys(miniFocus, cmgr, ctx)
  gridPane:handleKeys(kr)
  -- A picker popup consumes its own Esc/Enter, but IsKeyPressed can't see that (two input streams);
  -- gate the fallback on the same pickerIsActive acceptInput folds, so the key can't double-fire.
  if not kr.consumed and not chrome.pickerIsActive() then
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
function pe:launch(body, commit, poly)
  if self:open(body, commit, poly) then
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
                + gui.fontSize.ui + 2 * fpadY + 4   -- toolbar row (a frame height) + its gap
    end
    local title = body.kind == 'curve' and 'Curve editor' or 'Note editor'
    modalHost:open{ kind = 'patternEditor', title = title,
                    size = { vw * 0.72, gridPane:heightForRows(rows) + chromeH },
                    -- NoNav: kill ImGui's keyboard-nav highlight; else it flits between the toolbar
                    -- buttons on arrow keys and steals them from the grid. see gridPane focus model.
                    flags = ImGui.WindowFlags_NoNav,
                    onClose = function() self:close() end }
  end
end

return pe
