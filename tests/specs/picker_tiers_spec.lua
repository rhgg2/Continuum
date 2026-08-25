-- Chrome-level pin for the by-copy catalogue picker: `tierPicker` lists both tiers in full, so a
-- name held twice appears twice and neither copy hides the other, and `drawPicker` puts a create row
-- at the head of each declared group, so a typed name lands in the tier you point at rather than a
-- default nothing states. Recipe from picker_groups_spec, extended with picker_create_spec's Enter.
local t = require('support')

-- Constants (Key_*, *Flags_*, StyleVar_*) resolve to disjoint numeric ids via the metatable; the
-- functions drawPicker calls are set explicitly below.
local fakeImGui = setmetatable({ Mod_None = 0 }, {
  __index = function(tbl, k) local n = rawget(tbl, '##n') or 0; n = n + 1
    rawset(tbl, '##n', n); rawset(tbl, k, n); return n end,
})

-- The popup body in submission order: one entry per heading, row or rule. Rows also record the id
-- scope they were drawn under, ImGui faulting on two visible items that share an id.
local filterText, pressed, body, idStack = '', {}, {}, {}
for _, name in ipairs({ 'AlignTextToFramePadding', 'Text', 'SameLine', 'PushStyleVar', 'PopStyleVar',
  'PushStyleColor', 'PopStyleColor', 'OpenPopup', 'SetNextWindowPos', 'SetKeyboardFocusHere',
  'SetNextItemWidth', 'Attach', 'EndPopup', 'CloseCurrentPopup',
  'SetNextWindowSizeConstraints', 'SetCursorPosY', 'Dummy' }) do
  fakeImGui[name] = function() end
end
fakeImGui.PushID                = function(_, id) idStack[#idStack + 1] = id end
fakeImGui.PopID                 = function() idStack[#idStack] = nil end
fakeImGui.Button                = function() return true end   -- always "opening" so the popup runs
fakeImGui.GetItemRectMin        = function() return 0, 0 end
fakeImGui.GetItemRectMax        = function() return 0, 0 end
fakeImGui.GetStyleVar           = function() return 8, 4 end   -- window padding / item spacing
fakeImGui.GetCursorPosY         = function() return 0 end
fakeImGui.GetContentRegionAvail = function() return 200, 200 end
fakeImGui.GetCursorScreenPos    = function() return 0, 0 end
fakeImGui.GetTextLineHeight     = function() return 13 end
fakeImGui.CalcTextSize          = function() return 7, 13 end
fakeImGui.BeginPopup            = function() return true end
fakeImGui.IsWindowAppearing     = function() return true end   -- appearing parks the cursor at row 1
fakeImGui.CreateFunctionFromEEL = function() return {} end
fakeImGui.ColorConvertDouble4ToU32 = function() return 0 end   -- the popup pushes its own ink
fakeImGui.InputText             = function() return true, filterText end
fakeImGui.IsKeyPressed          = function(_, k) return pressed[k] == true end
fakeImGui.Separator             = function() body[#body + 1] = { rule = true } end
fakeImGui.TextDisabled          = function(_, label) body[#body + 1] = { heading = label } end
fakeImGui.Selectable            = function(_, label)
  body[#body + 1] = { row = label, scope = idStack[#idStack] }
  return false
end

package.preload['imgui'] = function() return function(_) return fakeImGui end end
for _, m in ipairs({ 'imgui', 'painter', 'chrome' }) do package.loaded[m] = nil end
_G.reaper.ImGui_GetBuiltinPath = function() return '/stub' end

local util = require('util')

local BULLET = ' \xe2\x80\xa2'   -- space + U+2022, the modified marker

local function mkChrome(h)
  local lib = util.instantiate('library', { cm = h.cm, synthetic = {} })
  return util.instantiate('chrome', { cm = h.cm, ctx = {}, uiSize = 12, lib = lib })
end

-- A catalogue with `wobble` in both tiers -- the case a resolved list could not show.
local function withCatalogue(harness, project, library)
  return harness.mk{ config = { project = { fxPatches = project },
                                global  = { fxPatches = library } } }
end

local function labels(items, tier)
  local out = {}
  for _, it in ipairs(items) do if it.tier == tier then out[#out + 1] = it.label end end
  return out
end

-- One picker frame over `items` under filter `text`, optionally pressing Enter. Returns what fired
-- -- { verb, key, tier } -- and the body it drew.
local function frame(chrome, items, text, opts)
  opts = opts or {}
  filterText, body, idStack = text or '', {}, {}
  pressed = opts.enter and { [fakeImGui.Key_Enter] = true } or {}
  local fired
  chrome.drawPicker{
    kind = 'test', buttonLabel = 'save', items = items, groups = chrome.tierGroups,
    onPick   = function(key, tier) fired = { verb = 'pick',   key = key,  tier = tier } end,
    onCreate = function(txt, tier) fired = { verb = 'create', key = txt,  tier = tier } end,
  }
  return fired, body
end

local function rowsDrawn(drawn)
  local out = {}
  for _, e in ipairs(drawn) do if e.row or e.heading then out[#out + 1] = e.heading or e.row end end
  return out
end

return {
  ----- tierPicker: the list itself

  {
    name = 'both tiers are listed in full, so a name held twice appears in each',
    run = function(harness)
      local h = withCatalogue(harness, { wobble = { 'p' }, alpha = { 'a' } },
                                       { wobble = { 'g' }, shelved = { 's' } })
      local items = mkChrome(h).tierPicker{ key = 'fxPatches' }

      t.deepEq(labels(items, 'project'), { 'alpha', 'wobble' .. BULLET },
               'the project tier entire, the divergent copy badged')
      t.deepEq(labels(items, 'global'), { 'shelved', 'wobble' },
               'and the library tier entire, the shadowed copy no longer hidden')
    end,
  },

  {
    name = 'a name held in both tiers draws two rows alike, each under its own id scope',
    run = function(harness)
      -- Identical bodies, so no bullet tells the two labels apart: the collision case exactly.
      local chrome = mkChrome(withCatalogue(harness, { wobble = { 'same' } }, { wobble = { 'same' } }))
      local _, drawn = frame(chrome, chrome.tierPicker{ key = 'fxPatches' }, '')

      local rows = {}
      for _, e in ipairs(drawn) do if e.row then rows[#rows + 1] = e end end
      t.eq(#rows, 2, 'the name draws once per tier')
      t.eq(rows[1].row, rows[2].row, 'under one label, neither copy hidden')
      t.deepEq({ rows[1].scope, rows[2].scope }, { 'project', 'global' },
               'scoped by group, ImGui faulting on two visible items sharing an id')
    end,
  },

  {
    name = 'each row names the tier and the group it was drawn from, and wears no prefix',
    run = function(harness)
      local h = withCatalogue(harness, { alpha = { 'a' } }, { shelved = { 's' } })
      local items = mkChrome(h).tierPicker{ key = 'fxPatches' }
      local byKey = {}
      for _, it in ipairs(items) do byKey[it.key] = it end

      t.eq(byKey.alpha.tier,    'project', 'a project row names its tier')
      t.eq(byKey.alpha.group,   'project', 'and groups under it')
      t.eq(byKey.shelved.tier,  'global',  'a library row names its own')
      t.eq(byKey.shelved.label, 'shelved', 'and wears no `+`: the heading says where it came from')
      t.eq(#items, 2, 'no Off row -- a catalogue of copies has nothing to turn off')
    end,
  },

  ----- drawPicker: a create row at the head of each group

  {
    name = 'a non-exact filter offers to create in either tier, the project one first',
    run = function(harness)
      local chrome = mkChrome(withCatalogue(harness, { wobble = { 'p' } }, { wobbly = { 'g' } }))
      local items  = chrome.tierPicker{ key = 'fxPatches' }
      local _, drawn = frame(chrome, items, 'wob')

      t.deepEq(rowsDrawn(drawn), { 'Project', '+ new: wob', 'wobble',
                                   'Library', '+ new: wob', 'wobbly' },
               'each group opens with its own create row, under its own heading')
    end,
  },

  {
    name = 'Enter on a typed name creates in the project tier, the cursor resting there',
    run = function(harness)
      local chrome = mkChrome(withCatalogue(harness, { wobble = { 'p' } }, {}))
      local items  = chrome.tierPicker{ key = 'fxPatches' }
      local fired  = frame(chrome, items, 'wob', { enter = true })

      t.eq(fired.verb, 'create', 'the cursor sits on a create row, not on the name it partly matches')
      t.eq(fired.key,  'wob',    'with the text as typed')
      t.eq(fired.tier, 'project', 'and the project tier, which leads the list')
    end,
  },

  {
    name = 'an exact filter suppresses only its own group\'s create row',
    run = function(harness)
      local chrome = mkChrome(withCatalogue(harness, { wobble = { 'p' } }, {}))
      local items  = chrome.tierPicker{ key = 'fxPatches' }

      -- Enter closes the popup before any row draws, so the body and the verb take a frame each.
      local _, drawn = frame(chrome, items, 'wobble')
      t.deepEq(rowsDrawn(drawn), { 'Project', 'wobble', 'Library', '+ new: wobble' },
               'the tier holding the name offers no create; the tier lacking it still does')

      local fired = frame(chrome, items, 'wobble', { enter = true })
      t.eq(fired.verb, 'pick',      'Enter overwrites the name it matched')
      t.eq(fired.tier, 'project',   'in the tier that row was drawn from')
    end,
  },

  {
    name = 'a declared tier with nothing in it still shows, so it can be created into',
    run = function(harness)
      local chrome = mkChrome(withCatalogue(harness, {}, { shelved = { 's' } }))
      local items  = chrome.tierPicker{ key = 'fxPatches' }
      local _, drawn = frame(chrome, items, '')

      t.deepEq(rowsDrawn(drawn), { 'Project', 'Library', 'shelved' },
               'an empty project tier is a heading with nothing under it, not a missing heading')
    end,
  },

  {
    name = 'the groups survive a filter, there being two create rows to tell apart',
    run = function(harness)
      local chrome = mkChrome(withCatalogue(harness, {}, {}))
      local items  = chrome.tierPicker{ key = 'fxPatches' }
      local _, drawn = frame(chrome, items, 'wob')

      t.deepEq(rowsDrawn(drawn), { 'Project', '+ new: wob', 'Library', '+ new: wob' },
               'two identical create rows would be a coin toss without the headings')
    end,
  },
}
