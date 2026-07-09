-- design/fx-patterns.md P3.5: write-through commit; curve normalises pb thousandths back to bipolar.
-- Drives the real edit -> flush -> rebuild -> write-through path against a fake imgui.

local t    = require('support')
local util = require('util')

-- Controllable imgui. The fake must mirror real ImGui's CONTIGUOUS key enum:
-- gridPane derives its edit-key table by arithmetic (Key_A + i, Key_0 + d,
-- Key_Keypad0 + d), so the letter/digit ranges must be contiguous and disjoint
-- from the named control keys. A touch-order id would let Key_Enter land in a
-- letter slot and spuriously trigger note entry -- a fake artifact, not a bug.
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

local function setKeys(keys, mods)
  pressed, down, curMods = {}, {}, mods or 0
  for _, k in ipairs(keys or {}) do pressed[k] = true; down[k] = true end
end

local fakeChrome    = setmetatable({}, { __index = function() return function() end end })
local fakeGui       = { ctx = {}, font = 'grid', uiFont = 'ui', fontSize = { ui = 13 } }
local fakeModalHost = { registerKind = function() end, open = function() end }

local function loadPE(deps)
  package.preload['imgui'] = function() return function(_) return fakeImGui end end
  for _, m in ipairs({ 'imgui', 'keyDispatch', 'pageBindings', 'curveEditor', 'painter' }) do
    package.loaded[m] = nil
  end
  return util.instantiate('patternEditor', deps)
end

local fakeFacade = { get = function(name)
  if name == 'arrange' then
    return { ownerTrack = function(take) return reaper.GetMediaItemTake_Track(take) end }
  end
end }

local function notesBody()
  return {
    kind = 'notes', lengthPpq = 960, root = 60,
    specs = {
      { lane = 1, ppqL = 0,   endppqL = 240, pitch = 60, vel = 100, detune = 0, delay = 0 },
      { lane = 1, ppqL = 240, endppqL = 480, pitch = 64, vel = 100, detune = 0, delay = 0 },
    },
  }
end

local function curveBody()
  return {
    kind = 'curve', lengthPpq = 960,
    points = {
      { ppq = 0,   val = 0,    shape = 'linear' },
      { ppq = 480, val = 1,    shape = 'linear' },   -- +1 exercises full-scale thousandths (pbRange 10)
      { ppq = 960, val = -0.5, shape = 'linear' },
    },
  }
end

-- cc-domain curve: points ride a fixed scratch cc verbatim (0..127), no normalisation.
local function ccCurveBody()
  return {
    kind = 'curve', domain = 'cc', display = 'cc14', lengthPpq = 960,
    points = {
      { ppq = 0,   val = 0,   shape = 'linear' },
      { ppq = 480, val = 100, shape = 'linear' },
      { ppq = 960, val = 64,  shape = 'linear' },
    },
  }
end

-- Open the editor on `body`, capturing each write-through commit; get() reads the latest.
local function withEditor(harness, body)
  local h  = harness.mk()
  local committed = body
  local pe = loadPE{ facade = fakeFacade, chrome = fakeChrome, gui = fakeGui, modalHost = fakeModalHost }
  pe:open(body, function(b) committed = b end)
  return h, pe, function() return committed end
end

-- Delete the event under the (default row-0) cursor via the real dispatch path.
local function pressDelete(pe)
  setKeys({ fakeImGui.Key_Period }, fakeImGui.Mod_None)
  pe:handleInput(function() end)
end

local function approx(a, b) return math.abs(a - b) < 0.02 end

return {
  {
    name = 'a checkout edit writes through the commit callback, stripped to the whitelist',
    run = function(harness)
      local h, pe, get = withEditor(harness, notesBody())
      pressDelete(pe)

      local body = get()
      t.eq(#body.specs, 1, 'the deleted note is gone from the committed body')
      local spec = body.specs[1]
      t.eq(spec.ppqL, 240, 'the surviving note is the second spec')
      t.eq(spec.lane, 1,   'lane is fixed at 1')
      t.eq(spec.fx,   nil, 'no fx field leaks into the commit')
      t.eq(spec.chan, nil, 'no chan field leaks into the commit')
      t.eq(body.lengthPpq, 960, 'loop length rides the snapshot forward')
      t.eq(body.root,       60, 'root rides the snapshot forward')
    end,
  },

  {
    name = 'a curve edit persists as normalised bipolar points, not raw thousandths',
    run = function(harness)
      local h, pe, get = withEditor(harness, curveBody())
      pressDelete(pe)

      local pts = get().points
      t.eq(#pts, 2, 'the deleted breakpoint is gone from the persisted body')
      local hiFound, loFound = false, false
      for _, p in ipairs(pts) do
        t.truthy(math.abs(p.val) <= 1.01, 'val is bipolar, not raw thousandths')
        if approx(p.val, 1)    then hiFound = true end
        if approx(p.val, -0.5) then loFound = true end
      end
      t.truthy(hiFound, 'the +1 breakpoint round-trips to bipolar')
      t.truthy(loFound, 'the -0.5 breakpoint round-trips to bipolar')
    end,
  },

  {
    name = 'a cc-domain curve persists its points verbatim, echoing the domain',
    run = function(harness)
      local h, pe, get = withEditor(harness, ccCurveBody())
      pressDelete(pe)

      local body = get()
      t.eq(body.domain, 'cc', 'the cc domain rides the readback forward')
      local pts = body.points
      t.eq(#pts, 2, 'the deleted breakpoint is gone from the persisted body')
      local hiFound, loFound = false, false
      for _, p in ipairs(pts) do
        if approx(p.val, 100) then hiFound = true end
        if approx(p.val, 64)  then loFound = true end
      end
      t.truthy(hiFound, 'the 100 breakpoint round-trips verbatim, not normalised')
      t.truthy(loFound, 'the 64 breakpoint round-trips verbatim')
    end,
  },

  {
    name = 'Enter commits: the edit stays in the store',
    run = function(harness)
      local h, pe, get = withEditor(harness, notesBody())
      pressDelete(pe)
      setKeys({ fakeImGui.Key_Enter }, fakeImGui.Mod_None)
      pe:handleInput(function() end)
      t.eq(#get().specs, 1, 'commit keeps the deletion')
    end,
  },

  {
    name = 'Esc cancels: the store is restored to the open snapshot',
    run = function(harness)
      local h, pe, get = withEditor(harness, notesBody())
      pressDelete(pe)
      t.eq(#get().specs, 1, 'write-through recorded the edit')

      setKeys({ fakeImGui.Key_Escape }, fakeImGui.Mod_None)
      pe:handleInput(function() end)
      t.eq(#get().specs, 2, 'Esc restored both original specs')
    end,
  },

  {
    name = 'close does not clobber the committed body via the unbind rebuild',
    run = function(harness)
      local h, pe, get = withEditor(harness, notesBody())
      pressDelete(pe)
      pe:close()

      t.eq(#get().specs, 1, 'the unbind rebuild (armed=false) left the committed edit intact')
    end,
  },
}
