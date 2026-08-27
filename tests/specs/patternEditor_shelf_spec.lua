-- design/fx-patterns.md P4: the library copy shelf -- Save/Load in the pattern-editor toolbar.
-- Save and Load are both chrome.drawPicker widgets, captured by kind through a fake chrome; gridPane
-- is swapped for an inert stub via util._stubs so pe:draw's toolbar runs without the grid render.

local t    = require('support')
local util = require('util')

-- Controllable imgui. Key_*/Mod_*/WindowFlags_*/StyleVar_* resolve to disjoint numeric ids via the
-- metatable (as in the write-through spec); functions the toolbar + popups touch are set explicitly.
local ctrlId, ctrlIds = 0, {}
local function keyId(name)
  local letter = name:match('^Key_([A-Z])$')
  if letter then return 500 + letter:byte() - ('A'):byte() end
  local digit = name:match('^Key_([0-9])$')
  if digit then return 600 + tonumber(digit) end
  local keypad = name:match('^Key_Keypad([0-9])$')
  if keypad then return 700 + tonumber(keypad) end
  if not ctrlIds[name] then ctrlId = ctrlId + 1; ctrlIds[name] = ctrlId end   -- < 500, disjoint
  return ctrlIds[name]
end
local fakeImGui = setmetatable({ Mod_None = 0 }, {
  __index = function(tbl, k) local id = keyId(k); rawset(tbl, k, id); return id end,
})
_G.reaper.ImGui_GetBuiltinPath = _G.reaper.ImGui_GetBuiltinPath or function() return '/stub' end

local pressed, down, curMods = {}, {}, 0
fakeImGui.GetKeyMods      = function() return curMods end
fakeImGui.IsKeyPressed    = function(_, k) return pressed[k] == true end
fakeImGui.IsKeyDown       = function(_, k) return down[k] == true end
fakeImGui.IsMouseClicked  = function() return false end
fakeImGui.IsMouseDown     = function() return false end
fakeImGui.IsWindowHovered = function() return false end
fakeImGui.IsAnyItemActive = function() return false end

-- Geometry: numbers so pe:draw's layout math runs; draws are no-ops.
for _, name in ipairs({ 'PushStyleVar', 'PopStyleVar', 'AlignTextToFramePadding', 'SameLine',
  'Text', 'SetKeyboardFocusHere', 'SetNextItemWidth', 'Dummy', 'SetWindowSize',
  'DrawList_AddRectFilled', 'SetCursorScreenPos', 'EndPopup' }) do
  fakeImGui[name] = function() end
end
fakeImGui.GetCursorScreenPos    = function() return 0, 0 end
fakeImGui.GetContentRegionAvail = function() return 200, 200 end
fakeImGui.GetWindowSize         = function() return 200, 260 end
fakeImGui.GetWindowDrawList     = function() return {} end
fakeImGui.IsWindowAppearing     = function() return false end

-- Button reads a per-frame queue the spec sets through frame() (Commit/Cancel are plain buttons).
local queuedButton
fakeImGui.Button = function(_, label)
  if label == queuedButton then queuedButton = nil; return true end
  return false
end

local function setKeys(keys, mods)
  pressed, down, curMods = {}, {}, mods or 0
  for _, k in ipairs(keys or {}) do pressed[k] = true; down[k] = true end
end

local capturedPickers = {}
local fakeChrome = setmetatable(
  { drawPicker = function(d) capturedPickers[d.kind] = d end },
  { __index = function() return function() end end })
local fakeGui       = { ctx = {}, font = 'grid', uiFont = 'ui', fontSize = { ui = 13 } }
local fakeModalHost = { registerKind = function() end, open = function() end }
local fakeFacade    = { get = function(name)
  if name == 'arrange' then
    return { ownerTrack = function(take) return reaper.GetMediaItemTake_Track(take) end }
  end
end }

-- Inert gridPane: pe:draw calls its geometry/draw methods but the shelf path reads none of it.
local fakeGridPane = setmetatable({}, { __index = function() return function() return 0 end end })

local function loadPE(deps)
  package.preload['imgui'] = function() return function(_) return fakeImGui end end
  for _, m in ipairs({ 'imgui', 'keyDispatch', 'manifest', 'curveEditor', 'painter' }) do
    package.loaded[m] = nil
  end
  util._stubs.gridPane = function() return fakeGridPane end
  local pe = util.instantiate('patternEditor', deps)
  util._stubs.gridPane = nil
  return pe
end

local function notesBody()
  return {
    kind = 'notes', lengthPpq = 960, root = 60,
    specs = {
      { lane = 1, ppq = 0,   endppq = 240, pitch = 60, vel = 100, detune = 0, delay = 0 },
      { lane = 1, ppq = 240, endppq = 480, pitch = 64, vel = 100, detune = 0, delay = 0 },
    },
  }
end

local function curveBody()
  return {
    kind = 'curve', lengthPpq = 960,
    points = { { ppq = 0, val = 0, shape = 'linear' }, { ppq = 960, val = 0, shape = 'linear' } },
  }
end

-- Open the editor on `body`, capturing each write-through commit; get() reads the latest. hostDs is
-- the harness ds (project scope), standing in for trackerPage's shared ds.
local function withEditor(harness, body, poly)
  local h = harness.mk()
  local committed = body
  local pe = loadPE{ facade = fakeFacade, chrome = fakeChrome, gui = fakeGui,
                     modalHost = fakeModalHost, hostDs = h.ds }
  pe:open(body, function(b) committed = b end, poly)
  return h, pe, function() return committed end
end

-- One draw frame: queue a button press / injected input text / held keys, then draw.
local function frame(pe, o)
  o = o or {}
  queuedButton = o.button
  setKeys(o.keys or {})
  pe:draw()
end

local function input(pe, keys)
  setKeys(keys or {})
  return pe:handleInput(function() end)
end

return {
  {
    name = 'Save stores a whitelisted copy on the host ds under a typed new name',
    run = function(harness)
      local h, pe = withEditor(harness, notesBody())
      frame(pe)                                  -- draw captures the save picker
      capturedPickers.peSave.onCreate('lead')    -- type a fresh name -> onCreate
      input(pe)                                  -- drain -> saveShelf

      local stored = (h.ds:get('fxPatterns') or {}).lead
      t.truthy(stored, 'the body landed under its name')
      t.eq(stored.kind, 'notes', 'kind rides across')
      t.eq(#stored.specs, 2, 'the whitelisted specs are stored')
      t.eq(stored.specs[1].chan, nil, 'no chan leaks into the shelf copy')
    end,
  },

  {
    name = 'Save over an existing name overwrites immediately, no confirm',
    run = function(harness)
      local h, pe = withEditor(harness, notesBody())
      h.ds:assign('fxPatterns', { lead = {
        kind = 'notes', lengthPpq = 960, root = 60,
        specs = { { lane = 1, ppq = 0, endppq = 240, pitch = 99, vel = 100, detune = 0, delay = 0 } },
      } })

      frame(pe)                                -- draw captures the save picker
      capturedPickers.peSave.onPick('lead')    -- pick the existing name -> pendingAction
      input(pe)                                -- drain -> saveShelf, no confirm frame

      local stored = h.ds:get('fxPatterns').lead
      t.eq(#stored.specs, 2, 'the editor body overwrote the divergent copy')
      t.eq(stored.specs[2].pitch, 64, 'it is the editor body, not the stored one')
    end,
  },

  {
    name = 'Load rematerialises the picked body; the param tracks it',
    run = function(harness)
      local h, pe, get = withEditor(harness, notesBody())
      h.ds:assign('fxPatterns', { small = {
        kind = 'notes', lengthPpq = 480, root = 60,
        specs = { { lane = 1, ppq = 0, endppq = 240, pitch = 72, vel = 90, detune = 0, delay = 0 } },
      } })

      frame(pe)                                    -- draw captures the load picker
      t.truthy(capturedPickers.peShelf, 'the load picker was drawn')
      capturedPickers.peShelf.onPick('small')      -- pick -> pendingAction
      input(pe)                        -- drain -> loadShelf

      local body = get()
      t.eq(#body.specs, 1, 'the loaded body rematerialised and reached the param')
      t.eq(body.specs[1].pitch, 72, 'it is the picked body')
    end,
  },

  {
    name = 'both pickers offer only matching kind, and matching domain for curves',
    run = function(harness)
      local function offeredKeys(picker)
        local offered = {}
        for _, it in ipairs(picker.items) do offered[it.key] = true end
        return offered
      end

      local h, notePe = withEditor(harness, notesBody())
      h.ds:assign('fxPatterns', {
        someNotes = { kind = 'notes', lengthPpq = 480, specs = {} },
        someCurve = { kind = 'curve', lengthPpq = 480, points = {} },
      })
      frame(notePe)
      local loadOffered = offeredKeys(capturedPickers.peShelf)
      t.truthy(loadOffered.someNotes, 'a notes body is offered to a notes editor')
      t.truthy(not loadOffered.someCurve, 'a curve body is filtered out by kind')
      local saveOffered = offeredKeys(capturedPickers.peSave)
      t.truthy(saveOffered.someNotes, 'Save offers the same matching-kind set as Load')
      t.truthy(not saveOffered.someCurve, 'Save filters the wrong kind out too')

      local h2, curvePe = withEditor(harness, curveBody())   -- domain defaults to normalized
      h2.ds:assign('fxPatterns', {
        norm = { kind = 'curve', lengthPpq = 480, points = {} },              -- normalized (domain nil)
        cc   = { kind = 'curve', domain = 'cc', lengthPpq = 480, points = {} },
      })
      frame(curvePe)
      local curveOffered = offeredKeys(capturedPickers.peShelf)
      t.truthy(curveOffered.norm, 'a normalized curve is offered to a normalized editor')
      t.truthy(not curveOffered.cc, 'a cc curve is filtered out by domain')
    end,
  },

  {
    name = 'Esc after a Load restores the modal-open snapshot, not the loaded body',
    run = function(harness)
      local h, pe, get = withEditor(harness, notesBody())   -- snapshot: 2 specs
      h.ds:assign('fxPatterns', { small = {
        kind = 'notes', lengthPpq = 480, root = 60,
        specs = { { lane = 1, ppq = 0, endppq = 240, pitch = 72, vel = 90, detune = 0, delay = 0 } },
      } })

      frame(pe)
      capturedPickers.peShelf.onPick('small')
      input(pe)
      t.eq(#get().specs, 1, 'the load took effect')

      input(pe, { fakeImGui.Key_Escape })
      t.eq(#get().specs, 2, 'Esc restored the modal-open snapshot, not the loaded body')
    end,
  },

  {
    name = 'a mono note param offers only single-lane bodies; a poly param offers multi-lane too',
    run = function(harness)
      local function offeredKeys(picker)
        local offered = {}
        for _, it in ipairs(picker.items) do offered[it.key] = true end
        return offered
      end
      local shelfBodies = {
        oneLane  = { kind = 'notes', lengthPpq = 480, specs = {
          { lane = 1, ppq = 0, endppq = 240, pitch = 60, vel = 100, detune = 0, delay = 0 } } },
        twoLanes = { kind = 'notes', lengthPpq = 480, specs = {
          { lane = 1, ppq = 0,   endppq = 240, pitch = 60, vel = 100, detune = 0, delay = 0 },
          { lane = 2, ppq = 120, endppq = 360, pitch = 67, vel = 100, detune = 0, delay = 0 } } },
      }

      local h, monoPe = withEditor(harness, notesBody(), false)
      h.ds:assign('fxPatterns', shelfBodies)
      frame(monoPe)
      local monoOffered = offeredKeys(capturedPickers.peShelf)
      t.truthy(monoOffered.oneLane, 'a single-lane body is offered to a mono param')
      t.truthy(not monoOffered.twoLanes, 'a multi-lane body is withheld from a mono param')

      local h2, polyPe = withEditor(harness, notesBody(), true)
      h2.ds:assign('fxPatterns', shelfBodies)
      frame(polyPe)
      local polyOffered = offeredKeys(capturedPickers.peShelf)
      t.truthy(polyOffered.oneLane,  'a poly param still offers single-lane bodies')
      t.truthy(polyOffered.twoLanes, 'a poly param also offers multi-lane bodies')
    end,
  },

  {
    name = 'Load offers a per-row delete that drops just that name; Save offers none',
    run = function(harness)
      local h, pe = withEditor(harness, notesBody())
      local function oneSpecBody(pitch)
        return { kind = 'notes', lengthPpq = 480, root = 60, specs = {
          { lane = 1, ppq = 0, endppq = 240, pitch = pitch, vel = 90, detune = 0, delay = 0 } } }
      end
      h.ds:assign('fxPatterns', { small = oneSpecBody(72), keep = oneSpecBody(65) })

      frame(pe)                                     -- draw captures both pickers
      t.eq(capturedPickers.peSave.onDelete, nil, 'Save manages nothing; it only overwrites')
      capturedPickers.peShelf.onDelete('small')     -- confirmed delete -> pendingAction
      input(pe)                                     -- drain -> deleteShelf

      local stored = h.ds:get('fxPatterns')
      t.eq(stored.small, nil, 'the deleted name is gone from the shelf')
      t.truthy(stored.keep, 'its sibling survives')
    end,
  },
}
