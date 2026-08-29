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

-- keyQueue enumerates the Key_* names the shim table holds, once, as it loads; the metatable
-- above mints them on touch, so mint every key a reader here can act on before that.
for i = 0, 25 do local _ = fakeImGui['Key_' .. string.char(65 + i)] end
for i = 0, 9  do local _, _ = fakeImGui['Key_' .. i], fakeImGui['Key_Keypad' .. i] end
for _, name in ipairs({ 'Enter', 'KeypadEnter', 'Escape', 'Backspace', 'Delete', 'Space',
                        'Period', 'Comma', 'Slash', 'Minus', 'Equal' }) do
  local _ = fakeImGui['Key_' .. name]
end

local kq   -- the frame's queue, rebuilt per loadPE and refilled per setKeys

local pressed, down, curMods = {}, {}, 0
fakeImGui.GetKeyMods      = function() return curMods end
fakeImGui.IsKeyPressed    = function(_, k) return pressed[k] == true end
fakeImGui.IsKeyDown       = function(_, k) return down[k] == true end
fakeImGui.IsMouseClicked  = function() return false end
fakeImGui.IsMouseDown     = function() return false end
fakeImGui.IsWindowHovered = function() return false end
fakeImGui.IsAnyItemActive = function() return false end   -- no toolbar widget active headless

-- The mini editor runs inside the modal the fill records as owner, and claims under that
-- name, so the queue each pass reads is filled as one. See docs/keyQueue.md § Ownership.
local function setKeys(keys, mods)
  pressed, down, curMods = {}, {}, mods or 0
  for _, k in ipairs(keys or {}) do pressed[k] = true; down[k] = true end
  kq:fill('modal')
end

local fakeChrome    = setmetatable({}, { __index = function() return function() end end })
local fakeGui       = { ctx = {}, font = 'grid', uiFont = 'ui', fontSize = { ui = 13 } }
local fakeModalHost = { registerKind = function() end, open = function() end }

local function loadPE(deps)
  package.preload['imgui'] = function() return function(_) return fakeImGui end end
  for _, m in ipairs({ 'imgui', 'keyDispatch', 'manifest', 'curveEditor', 'painter' }) do
    package.loaded[m] = nil
  end
  kq = util.instantiate('keyQueue', { ctx = fakeGui.ctx })
  deps.keyQueue = kq
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
      { lane = 1, ppq = 0,   endppq = 240, pitch = 60, vel = 100, detune = 0, delay = 0 },
      -- Written a semitone below where it sounds, which only a stamped intent can say:
      -- the readback cannot re-derive it (docs/tuning.md § The written step).
      { lane = 1, ppq = 240, endppq = 480, pitch = 64, vel = 100, detune = 0, delay = 0,
        intentCents = 6300 },
    },
  }
end

-- An OPEN first note followed by a finite one: readback must clip the open tail to the successor.
local function openNotesBody()
  return {
    kind = 'notes', lengthPpq = 960, root = 60,
    specs = {
      { lane = 1, ppq = 0,   endppq = util.OPEN, pitch = 60, vel = 100, detune = 0, delay = 0 },
      { lane = 1, ppq = 240, endppq = 480,       pitch = 64, vel = 100, detune = 0, delay = 0 },
    },
  }
end

-- Two overlapping notes on distinct lanes: a poly open keeps them apart; a mono open crushes them
-- onto lane 1, where the readback clip serialises them as a monophonic run.
local function polyNotesBody()
  return {
    kind = 'notes', lengthPpq = 960, root = 60,
    specs = {
      { lane = 1, ppq = 0,   endppq = 480, pitch = 60, vel = 100, detune = 0, delay = 0 },
      { lane = 2, ppq = 240, endppq = 720, pitch = 67, vel = 100, detune = 0, delay = 0 },
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
-- `poly` rides into pe:open: true authors overlapping lanes, absent/false pins everything to lane 1.
local function withEditor(harness, body, poly)
  local h  = harness.mk()
  local committed = body
  local pe = loadPE{ facade = fakeFacade, chrome = fakeChrome, gui = fakeGui, modalHost = fakeModalHost }
  pe:open(body, function(b) committed = b end, poly)
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
      local _, pe, get = withEditor(harness, notesBody())
      pressDelete(pe)

      local body = get()
      t.eq(#body.specs, 1, 'the deleted note is gone from the committed body')
      local spec = body.specs[1]
      t.eq(spec.ppq, 240, 'the surviving note is the second spec')
      t.eq(spec.lane, 1,   'lane is fixed at 1')
      t.eq(spec.fx,   nil, 'no fx field leaks into the commit')
      t.eq(spec.chan, nil, 'no chan field leaks into the commit')
      t.eq(spec.intentCents, 6300, 'the step the note was written on rides the round trip')
      t.eq(body.lengthPpq, 960, 'loop length rides the snapshot forward')
      t.eq(body.root,       60, 'root rides the snapshot forward')
    end,
  },

  {
    name = 'readback clips an OPEN note to its successor onset, not the loop length',
    run = function(harness)
      local _, pe, get = withEditor(harness, openNotesBody())
      -- Ctrl+= nudges the row-0 note's pitch: keeps both notes (and the OPEN tail) but fires a write-through.
      setKeys({ fakeImGui.Key_Equal }, fakeImGui.Mod_Ctrl)
      pe:handleInput(function() end)

      local specs = get().specs
      t.eq(#specs, 2, 'both notes survive the pitch nudge')
      t.eq(specs[1].endppq, 240, 'the OPEN note clips to the next onset, not lengthPpq (960)')
      t.eq(specs[2].endppq, 480, 'the trailing note keeps its authored ceiling')
    end,
  },

  {
    name = 'a curve edit persists as normalised bipolar points, not raw thousandths',
    run = function(harness)
      local _, pe, get = withEditor(harness, curveBody())
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
      local _, pe, get = withEditor(harness, ccCurveBody())
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
      local _, pe, get = withEditor(harness, notesBody())
      pressDelete(pe)
      setKeys({ fakeImGui.Key_Enter }, fakeImGui.Mod_None)
      pe:handleInput(function() end)
      t.eq(#get().specs, 1, 'commit keeps the deletion')
    end,
  },

  {
    name = 'Esc cancels: the store is restored to the open snapshot',
    run = function(harness)
      local _, pe, get = withEditor(harness, notesBody())
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
      local _, pe, get = withEditor(harness, notesBody())
      pressDelete(pe)
      pe:close()

      t.eq(#get().specs, 1, 'the unbind rebuild (armed=false) left the committed edit intact')
    end,
  },

  {
    name = 'a poly open keeps each authored lane through readback',
    run = function(harness)
      local _, pe, get = withEditor(harness, polyNotesBody(), true)
      -- Ctrl+= nudges the row-0 (lane 1) note's pitch: keeps both notes but fires a write-through.
      setKeys({ fakeImGui.Key_Equal }, fakeImGui.Mod_Ctrl)
      pe:handleInput(function() end)

      local specs = get().specs
      t.eq(#specs, 2, 'both authored notes survive')
      local lanes = {}
      for _, s in ipairs(specs) do lanes[s.lane] = true end
      t.truthy(lanes[1], 'the lane-1 note stays on lane 1')
      t.truthy(lanes[2], 'the lane-2 note stays on lane 2')
    end,
  },

  {
    name = 'the same body opened mono flattens every note onto lane 1',
    run = function(harness)
      local _, pe, get = withEditor(harness, polyNotesBody(), false)
      setKeys({ fakeImGui.Key_Equal }, fakeImGui.Mod_Ctrl)
      pe:handleInput(function() end)

      local specs = get().specs
      t.truthy(#specs >= 1, 'the notes survive the mono flatten')
      for _, s in ipairs(specs) do t.eq(s.lane, 1, 'every note collapses to lane 1') end
    end,
  },

  {
    -- At 8 rpb (resolution 960 -> 120 ppq rows) the ppq 0/240 specs sit on rows 0 and 2, so the
    -- row-0 cursor still deletes the first note: a surviving spec proves the seed took, not luck.
    name = 'the body rpb seeds the editor and rides readback',
    run = function(harness)
      local body = notesBody()
      body.rpb = 8
      local _, pe, get = withEditor(harness, body)
      pressDelete(pe)

      t.eq(get().rpb, 8, 'the authored rpb rides the committed body')
      t.eq(#get().specs, 1, 'the deleted note is gone from the committed body')
    end,
  },

  {
    name = 'a body with no rpb commits the default 4',
    run = function(harness)
      local _, pe, get = withEditor(harness, notesBody())
      pressDelete(pe)

      t.eq(get().rpb, 4, 'an unauthored rpb defaults to 4')
    end,
  },
}
