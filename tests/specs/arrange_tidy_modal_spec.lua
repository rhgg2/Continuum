-- The tidy editor's modal body, drawn over a fake imgui. Two properties live here. The base
-- list's Add path: ReaImGui hands a buffer back only on a frame its InputText returns true,
-- so a field flagged EnterReturnsTrue reads blank to every gesture but Enter. And the keys the
-- body claims: an Enter belongs to whichever reader acts on it -- the field the press
-- deactivates, else the footer -- and a claimed press is gone (docs/keyQueue.md § Claiming).
local t    = require('support')
local util = require('util')

-- Key and modifier constants are explicit; the flags and style vars the body reads auto-vivify
-- to distinct numbers, and every function it calls is set below.
local fakeImGui = t.imgui()

-- The frame the body draws over: what stands in the new-base field, the button label reading
-- as pressed, the field this frame's press deactivates and whether it was edited, the text a
-- named field reads back, and the keys pressed with the modifiers held.
local typed, clicked       = '', nil
local deactivating, edited = nil, false
local renaming             = nil    -- { label, text }: the field a test has typed into
local pressed, frameMods   = {}, 0
local lastItem             = nil    -- the item drawn most recently; the IsItem* reads answer for it

for _, name in ipairs({ 'AlignTextToFramePadding', 'Text', 'TextDisabled', 'SameLine', 'Separator',
  'PushStyleVar', 'PopStyleVar', 'PushStyleColor', 'PopStyleColor', 'PushFont', 'PopFont',
  'SetNextItemWidth', 'SetCursorPosX', 'EndChild', 'PushID', 'PopID' }) do
  fakeImGui[name] = function() end
end
fakeImGui.GetStyleVar                = function() return 0, 0 end
fakeImGui.GetFrameHeight             = function() return 20 end
fakeImGui.GetFrameHeightWithSpacing  = function() return 24 end
fakeImGui.CalcTextSize               = function() return 20 end
fakeImGui.GetWindowWidth             = function() return 400 end
fakeImGui.IsWindowAppearing          = function() return false end
-- A field deactivating this frame was active when the frame began, which is what a reader
-- asking after a live field sees.
fakeImGui.IsAnyItemActive            = function() return deactivating ~= nil end
fakeImGui.GetKeyMods                 = function() return frameMods end
fakeImGui.IsKeyPressed               = function(_, key) return pressed[key] == true end
fakeImGui.IsItemDeactivated          = function() return deactivating ~= nil and lastItem == deactivating end
fakeImGui.IsItemDeactivatedAfterEdit = function() return edited and lastItem == deactivating end
fakeImGui.CreateFunctionFromEEL      = function() return {} end
fakeImGui.Attach                     = function() end
-- The row list is a child window; refusing it leaves the base list as the frame's whole content.
fakeImGui.BeginChild = function() return false end
fakeImGui.Button     = function(_, label) return label == clicked end
-- A named rename field reads back the text typed into it; the others sit untouched.
fakeImGui.InputText  = function(_, label, value)
  lastItem = label
  if renaming and renaming.label == label then return true, renaming.text end
  return false, value
end
fakeImGui.InputTextWithHint = function(_, label, _, value, flags)
  lastItem = label
  local onEnterOnly = flags == fakeImGui.InputTextFlags_EnterReturnsTrue
  local committed   = onEnterOnly and pressed[fakeImGui.Key_Enter]
                   or (not onEnterOnly and typed ~= value)
  if committed then return true, typed end
  return false, value
end

package.preload['imgui'] = function() return function(_) return fakeImGui end end
for _, m in ipairs({ 'imgui', 'painter' }) do package.loaded[m] = nil end
_G.reaper.ImGui_GetBuiltinPath = function() return '/stub' end

-- arrangeRender holds chrome for its house widgets; the base list draws none of them.
local fakeChrome = setmetatable({}, { __index = function() return function() end end })

-- Two slots on one track: enough for seedTidy to hand back a base and an assignment.
local tidyItems = {
  { track = 'tr1', name = 'a', pos = 0, takeName = 'Bassline' },
  { track = 'tr1', name = 'b', pos = 4, takeName = 'Bassline (var 3)' },
}

local modalKeyQueue   -- the queue the body under test claims from; drawFrame fills it

-- Build the tidy modal's body over a real av, and return it with the state openTidyModal seeds.
local function mkTidyModal(harness)
  local h = harness.mk()
  h.cm:set('project', 'arrangeBeatPerRow', 1)
  h.reaper:setTrackName('tr1', 'tr1')
  for _, item in ipairs(tidyItems) do
    h.reaper:addItem(item.track, { take = item.track .. '/' .. item.name, isMidi = true,
      pos = item.pos, len = 1, takeName = item.takeName,
      poolGuid = '{' .. item.track .. item.name .. '}' })
  end
  h.reaper:setProjectTracks({ 'tr1' })
  local em = util.instantiate('eventMeta', { ps = util.instantiate('pextStore') })
  local am = util.instantiate('arrangeManager',
    { cm = h.cm, ds = h.ds, tm = h.tm, eventMeta = em })
  local av = util.instantiate('arrangeView', { cm = h.cm, cmgr = h.cmgr, am = am })

  local kinds = {}
  modalKeyQueue  = util.instantiate('keyQueue', {})
  -- The body's commit and cancel claims are modalHost's own, so the fake delegates them to a
  -- real host over the same queue.
  local realHost = util.instantiate('modalHost', { keyQueue = modalKeyQueue })
  local modalHost = {
    open         = function() end,
    openConfirm  = function() end,
    openPrompt   = function() end,
    registerKind = function(_, kind, fn) kinds[kind] = fn end,
    takeEnter    = function() return realHost:takeEnter()  end,
    takeEscape   = function() return realHost:takeEscape() end,
  }
  local help = util.instantiate('help', { chrome = fakeChrome, cmgr = h.cmgr })
  util.instantiate('arrangeRender', { cm = h.cm, cmgr = h.cmgr, chrome = fakeChrome,
                                      modalHost = modalHost, help = help, av = av })
  local bases, assignment = av:seedTidy(0)
  return kinds.tidyTrack,
         { trackIdx = 0, bases = bases, assignment = assignment, newBase = '' }
end

-- One frame of the open modal, as the coordinator and modalHost run it: the fill names the
-- frame's owner before anything draws, then the body draws over the state it holds, with a
-- close recording what it was called with.
local function drawFrame(body, s, opts)
  opts = opts or {}
  typed, clicked               = opts.typed or '', opts.clicked
  deactivating, edited         = opts.deactivating, opts.edited or false
  renaming                     = opts.renaming
  pressed, frameMods, lastItem = {}, opts.mods or 0, nil
  for _, key in ipairs(opts.pressed or {}) do pressed[key] = true end
  modalKeyQueue:fill('modal')
  local closed
  body(s, function(invoke, ...) closed = { invoke, ... } end)
  return closed
end

local function holds(bases, name)
  for _, base in ipairs(bases) do if base == name then return true end end
  return false
end

return {
  {
    name = 'the Add button appends the base standing in the field',
    run = function(harness)
      local body, s = mkTidyModal(harness)
      drawFrame(body, s, { typed = 'Drums', clicked = 'Add' })
      t.truthy(holds(s.bases, 'Drums'), 'the typed base joined the list')
      t.eq(s.newBase, '', 'and the field is cleared for the next one')
    end,
  },

  -- Enter in the new-base field adds the base, and that field claims the press, so the
  -- footer below reads a queue without it.
  {
    name = 'Enter in the new-base field appends it too, and leaves the tidy open',
    run = function(harness)
      local body, s = mkTidyModal(harness)
      local closed = drawFrame(body, s, { typed = 'Drums', deactivating = '##newBase',
                                          pressed = { fakeImGui.Key_Enter } })
      t.truthy(holds(s.bases, 'Drums'), 'the typed base joined the list')
      t.eq(s.newBase, '', 'and the field is cleared for the next one')
      t.eq(closed, nil, 'the tidy did not commit behind it')
      t.eq(modalKeyQueue:take(fakeImGui.Key_Enter, nil, 'modal'), nil, 'the field claimed the Enter')
    end,
  },

  {
    name = 'an untouched field adds nothing',
    run = function(harness)
      local body, s = mkTidyModal(harness)
      drawFrame(body, s, { clicked = 'Add' })
      t.eq(#s.bases, 1, 'only the seeded base is listed')
    end,
  },

  -- With no field to consume it, the Enter is the footer's. A key the body acts on is gone
  -- from the queue afterwards, one it does not act on is still there.
  {
    name = 'the footer Enter commits the assignment, and claims the press',
    run = function(harness)
      local body, s = mkTidyModal(harness)
      local closed = drawFrame(body, s, { pressed = { fakeImGui.Key_Enter, fakeImGui.Key_Q } })
      t.eq(closed[1], true, 'the modal closed, invoking its callback')
      t.eq(closed[2], s.assignment, 'with the assignment the rows hold')
      t.eq(modalKeyQueue:take(fakeImGui.Key_Enter, nil, 'modal'), nil, 'the Enter was claimed')
      t.truthy(modalKeyQueue:take(fakeImGui.Key_Q, nil, 'modal'),
               'a key the body does not act on is still in the queue')
    end,
  },

  {
    name = 'Escape drops the edit, and claims the press',
    run = function(harness)
      local body, s = mkTidyModal(harness)
      local closed = drawFrame(body, s, { pressed = { fakeImGui.Key_Escape } })
      t.eq(closed[1], false, 'the modal closed without invoking the callback')
      t.eq(modalKeyQueue:take(fakeImGui.Key_Escape, nil, 'modal'), nil, 'the Escape was claimed')
    end,
  },

  -- A rename lands when the field deactivates, and the Enter that deactivated it belongs to
  -- that field. Two frames, as the user types and then commits.
  {
    name = 'Enter committing a base rename leaves the tidy open',
    run = function(harness)
      local body, s = mkTidyModal(harness)
      local base = s.bases[1]
      t.truthy(base, 'the track seeds a base to rename (precondition)')

      drawFrame(body, s, { renaming = { label = '##base1', text = 'Drums' } })
      t.eq(s.editing and s.editing.buf, 'Drums', 'the field holds the typed name (precondition)')

      local closed = drawFrame(body, s, { deactivating = '##base1', edited = true,
                                          pressed = { fakeImGui.Key_Enter } })
      t.truthy(holds(s.bases, 'Drums'), 'the rename landed')
      t.eq(holds(s.bases, base), false, 'and the name it replaced is gone')
      t.eq(closed, nil, 'the tidy did not commit behind it')
      t.eq(modalKeyQueue:take(fakeImGui.Key_Enter, nil, 'modal'), nil, 'the field claimed the Enter')
    end,
  },
}
