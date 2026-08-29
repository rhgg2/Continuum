-- The editor stack's three modals claiming from the keyQueue (design/keyQueue.md § Claiming).
-- The swing and temper New modals and the temper Import modal draw over a fake imgui and the
-- real queue, filled as the coordinator fills it, with the modal named as the frame's owner.
-- The claims run through a real modalHost built on the same queue, so what the tests exercise
-- is the production claim; the host wrapper only keeps the bodies the editors register.
--
-- Each draw has two observables: what the body closed with, and what is left in the queue. A
-- press the body acted on is gone, so the same Enter cannot reach a reader behind it. Every
-- keyboard test presses a letter alongside, which no body reads and which the fill puts ahead
-- of Enter and Escape: it stays in the queue, so a body claiming whatever heads the queue
-- rather than the key it names shows up here.
--
-- The button paths are here because ReaImGui hands a buffer back only on a frame the InputText
-- call returns true: a field flagged EnterReturnsTrue reads blank to every gesture but Enter,
-- and the Create button would then name nothing.
local t      = require('support')
local util   = require('util')
local tuning = require('tuning')

local fakeImGui = t.imgui()

-- What the user has typed into the name field, the button label reading as pressed, the keys
-- this frame reports as down, and whether a field went inactive under them.
local typed, clicked, pressed, deactivating = '', nil, {}, false

for _, name in ipairs({ 'AlignTextToFramePadding', 'Text', 'TextColored', 'TextDisabled',
  'SameLine', 'SetNextItemWidth', 'SetKeyboardFocusHere', 'PushID', 'PopID' }) do
  fakeImGui[name] = function() end
end
fakeImGui.IsWindowAppearing = function() return false end
fakeImGui.IsAnyItemActive   = function() return false end
fakeImGui.GetKeyMods        = function() return 0 end
fakeImGui.IsKeyPressed      = function(_, key) return pressed[key] == true end
fakeImGui.Button            = function(_, label) return label == clicked end
-- The New modals read their commit off the name field going inactive.
fakeImGui.IsItemDeactivated = function() return deactivating end
fakeImGui.InputText = function(_, _, value, flags)
  local onEnterOnly = flags == fakeImGui.InputTextFlags_EnterReturnsTrue
  local entered     = pressed[fakeImGui.Key_Enter] == true
  local committed   = onEnterOnly and entered or (not onEnterOnly and typed ~= value)
  if committed then return true, typed end
  return false, value
end
fakeImGui.InputTextMultiline = function(_, _, value) return false, value end

_G.reaper.ImGui_GetBuiltinPath = function() return '/stub' end

-- Both editors hold chrome for house widgets; these modals draw none of them.
local fakeChrome = setmetatable({}, { __index = function() return function() end end })
local fakeFacade = { get = function() return {} end, publish = function() end }

local ctx = {}
local kq                     -- the queue the editors under test claim from

-- Both editors over one harness, returning the modal bodies they registered. Rebind imgui to
-- ours before loading: earlier specs' preloads cache a different fake (modal_input_spec idiom).
local function mkEditors(harness)
  package.preload['imgui'] = function() return function(_) return fakeImGui end end
  for _, m in ipairs({ 'imgui', 'painter', 'swingEditor', 'temperEditor' }) do
    package.loaded[m] = nil
  end
  local h    = harness.mk()
  kq         = util.instantiate('keyQueue', { ctx = ctx })
  local real = util.instantiate('modalHost', { ctx = ctx, chrome = fakeChrome, keyQueue = kq })
  local kinds = {}
  local host = {
    open         = function() end,
    openConfirm  = function() end,
    registerKind = function(_, kind, fn) kinds[kind] = fn end,
    takeEnter    = function() return real:takeEnter()  end,
    takeEscape   = function() return real:takeEscape() end,
  }
  local lib = util.instantiate('library', { cm = h.cm,
    synthetic   = { swings = { identity = true }, tempers = { ['12EDO'] = true } },
    libraryForm = { tempers = tuning.unrooted } })
  local deps = { cm = h.cm, ds = h.ds, chrome = fakeChrome, ctx = ctx,
                 gui = { fontSize = { ui = 12 } }, facade = fakeFacade, lib = lib,
                 modalHost = host }
  util.instantiate('swingEditor', deps)
  util.instantiate('temperEditor', deps)
  return kinds
end

-- One frame of an open modal: the fill names the owner before anything draws, then the body
-- draws over the state its opener seeds, with a close recording what it was called with.
local function draw(harness, kind, opts)
  typed, clicked, pressed = opts.text or '', opts.clicked, {}
  for _, key in ipairs(opts.pressed or {}) do pressed[key] = true end
  -- Enter deactivates the field it lands in, unless the test says nothing was focused.
  deactivating = opts.deactivating ~= false and pressed[fakeImGui.Key_Enter] == true
  local kinds = mkEditors(harness)
  kq:fill('modal')
  local s, closed = { buf = '' }, nil
  kinds[kind](s, function(ok, name, temper) closed = { ok = ok, name = name, temper = temper } end)
  return closed, s
end

-- The presses a keyboard test makes: the gesture, plus a letter no body reads.
local function withLetter(key) return { key, fakeImGui.Key_A } end

local function letterRemains()
  t.truthy(kq:take(fakeImGui.Key_A, nil, 'modal'), 'the frame\'s other press is untouched')
end

return {
  {
    name = 'the Create button names the new swing from the field',
    run = function(harness)
      local closed = draw(harness, 'swingNew', { text = 'Groove', clicked = 'Create' })
      t.eq(closed and closed.name, 'Groove', 'the modal closed on the typed name')
    end,
  },

  {
    name = 'Enter in the field names it too, and is claimed',
    run = function(harness)
      local closed = draw(harness, 'swingNew',
                          { text = 'Groove', pressed = withLetter(fakeImGui.Key_Enter) })
      t.eq(closed and closed.name, 'Groove', 'the modal closed on the typed name')
      letterRemains()
      t.eq(kq:take(fakeImGui.Key_Enter, nil, 'modal'), nil, 'and the Enter it committed on is gone')
    end,
  },

  {
    name = 'the Create button names the new temper from the field',
    run = function(harness)
      local closed = draw(harness, 'temperNew', { text = 'Squiggle', clicked = 'Create' })
      t.eq(closed and closed.name, 'Squiggle', 'the modal closed on the typed name')
    end,
  },

  {
    name = 'Enter in the field names the temper too, and is claimed',
    run = function(harness)
      local closed = draw(harness, 'temperNew',
                          { text = 'Squiggle', pressed = withLetter(fakeImGui.Key_Enter) })
      t.eq(closed and closed.name, 'Squiggle', 'the modal closed on the typed name')
      letterRemains()
      t.eq(kq:take(fakeImGui.Key_Enter, nil, 'modal'), nil, 'and the Enter it committed on is gone')
    end,
  },

  {
    name = 'Escape cancels the new-swing modal, and is claimed',
    run = function(harness)
      local closed = draw(harness, 'swingNew',
                          { text = 'Groove', pressed = withLetter(fakeImGui.Key_Escape) })
      t.eq(closed and closed.ok, false, 'the modal closed without invoking')
      letterRemains()
      t.eq(kq:take(fakeImGui.Key_Escape, nil, 'modal'), nil, 'and the Escape it cancelled on is gone')
    end,
  },

  {
    name = 'Escape cancels the tuning import, and is claimed',
    run = function(harness)
      local closed = draw(harness, 'temperImport', { pressed = withLetter(fakeImGui.Key_Escape) })
      t.eq(closed and closed.ok, false, 'the modal closed without invoking')
      letterRemains()
      t.eq(kq:take(fakeImGui.Key_Escape, nil, 'modal'), nil, 'and the Escape it cancelled on is gone')
    end,
  },

  {
    -- The New modals read their commit off the name field going inactive, so an Enter arriving
    -- with nothing focused commits nothing, and is left for whatever else the modal draws.
    name = 'Enter with no field to deactivate leaves the modal alone',
    run = function(harness)
      local closed = draw(harness, 'temperNew', { text = 'Squiggle', deactivating = false,
                                                  pressed = withLetter(fakeImGui.Key_Enter) })
      t.eq(closed, nil, 'the modal stayed open')
      t.truthy(kq:take(fakeImGui.Key_Enter, nil, 'modal'), 'and the Enter is still in the queue')
    end,
  },

  {
    name = 'an empty field asks for a name rather than closing',
    run = function(harness)
      local closed, s = draw(harness, 'swingNew', { text = '', clicked = 'Create' })
      t.eq(closed, nil, 'the modal stayed open')
      t.eq(s.err, 'Name required.')
    end,
  },
}
