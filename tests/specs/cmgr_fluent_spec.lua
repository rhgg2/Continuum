-- A command is fluent or pathed, and the split is a judgement about how the command is
-- used rather than what it does, so nothing derives it. In the manifest a fluent command
-- shows only as one with no path, which reads the same as an oversight. The roster below
-- is the second witness: it names every command the menu does not reach, and the cases
-- assert that it partitions the manifest with the pathed entries. A command added without
-- a path and without a roster line therefore fails, naming itself.
--
-- A generated family is fluent by construction — its members are a parameterised keyboard
-- alphabet — so membership is the classification and the eighty-two are not named here.
-- See design/lotus-menu.md § Fluent and pathed.

local t        = require('support')
local util     = require('util')
local manifest = require('manifest')

-- Scope by scope, in the order manifest.lua declares them.
local fluent = {
  global = {
    'playPause', 'stop', 'beginPrefix', 'openMenu',
    -- Reached programmatically: a toolbar click, a dive, the editor's exit.
    'play', 'switchPage', 'closeEditor', 'diveToSampler',
  },
  tracker = {
    'cursorUp', 'cursorDown', 'cursorLeft', 'cursorRight',
    'goTop', 'goBottom', 'goLeft', 'goRight',
    'pageUp', 'pageDown', 'colLeft', 'colRight', 'channelLeft', 'channelRight',
    'prevTrack', 'nextTrack', 'prevTake', 'nextTake', 'prevInstance', 'nextInstance',
    'noteOff', 'shrinkNote', 'growNote', 'nudgeBack', 'nudgeForward',
    'eventShiftLeft', 'eventShiftRight', 'delete', 'deleteSel',
    'nudgeCoarseUp', 'nudgeCoarseDown', 'nudgeFineUp', 'nudgeFineDown',
    'selectUp', 'selectDown', 'selectLeft', 'selectRight',
    'cycleBlock', 'cycleVBlock', 'swapBlockEnds', 'selectClear',
    'incRPB', 'decRPB', 'groupInstPrev', 'groupInstNext',
    'inputOctaveUp', 'inputOctaveDown', 'inputSampleUp', 'inputSampleDown',
    'returnToArrange',
  },
  -- Leaving the mode and painting a column either way are reflexes, so the scope is
  -- fluent entire and the menu it leaves open is global's.
  region = {
    'regionExit', 'regionBail', 'regionPaintExtend', 'regionPaintShrink',
  },
  arrange = {
    'arrangeCursorUp', 'arrangeCursorDown', 'arrangeCursorLeft', 'arrangeCursorRight',
    'arrangePageUp', 'arrangePageDown', 'arrangeHome', 'arrangeEnd',
    'arrangeNextDrop', 'arrangePrevDrop',
    'arrangeSelectUp', 'arrangeSelectDown', 'arrangeSelectLeft', 'arrangeSelectRight',
    'arrangeClearSelection',
    'arrangeNudgeBack', 'arrangeNudgeForward', 'arrangeEdgeUp', 'arrangeEdgeDown',
    'arrangeDeleteAdvance', 'arrangeDeleteRetreat',
    -- Each mode reinterprets the drop that follows it, and the drops are fluent.
    'arrangeReplaceMode', 'arrangeAdvanceMode',
  },
  sample = {
    'browserUp', 'browserPreview', 'slotNext', 'slotPrev',
  },
  wiring = {
    'wiringClearSelection',
  },
  -- Opening the menu and stepping back out are the walk's own verbs, so neither is
  -- walked to.
  menu = {
    'menuBack',
  },
}

-- name -> the scope the roster files it under.
local function rostered()
  local out = {}
  for scope, names in pairs(fluent) do
    for _, name in ipairs(names) do out[name] = scope end
  end
  return out
end

-- Every declared command, paired with the scope declaring it. The tree declares menu
-- groups rather than commands, so the walk passes it over as installManifest does.
local function declared()
  local out = {}
  for scope, groups in pairs(manifest) do
    if scope ~= 'tree' then
      for _, entries in pairs(groups) do
        for _, entry in ipairs(entries) do util.add(out, { scope = scope, entry = entry }) end
      end
    end
  end
  return out
end

return {
  {
    -- Forward: the manifest is covered. A new command lands in none of the three
    -- buckets until someone decides which it belongs in.
    name = 'every declared command is pathed, generated, or named in the fluent roster',
    run = function()
      local roster, all = rostered(), declared()
      t.truthy(#all > 200, 'the manifest declares the whole surface')
      for _, item in ipairs(all) do
        local entry = item.entry
        t.truthy(entry.path or entry.family or roster[entry.name],
                 entry.name .. ' carries no path and the fluent roster does not name it' ..
                 ' — classify it, see design/lotus-menu.md § Fluent and pathed')
        if roster[entry.name] then
          t.eq(roster[entry.name], item.scope,
               entry.name .. ' is rostered under the scope that declares it')
        end
      end
    end,
  },

  {
    -- Backward: the roster holds nothing stale, and nothing classified twice. A command
    -- that gains a path must lose its roster line, so the two buckets stay disjoint.
    name = 'every rostered name is declared, and carries no path',
    run = function()
      local byName, count = {}, 0
      for _, item in ipairs(declared()) do byName[item.entry.name] = item.entry end
      for _, names in pairs(fluent) do
        for _, name in ipairs(names) do
          count = count + 1
          local entry = byName[name]
          t.truthy(entry, name .. ' is rostered as fluent, but no manifest declares it')
          t.falsy(entry and entry.path,
                  name .. ' is rostered as fluent, yet declares the menu path ' ..
                  tostring(entry and entry.path))
        end
      end
      t.truthy(count > 50, 'the roster names the fluent surface')
    end,
  },

  {
    -- What the exemption rests on: a family is fluent entire, so a member carrying a path
    -- would be a classification the roster never sees.
    name = 'a generated family member carries no path',
    run = function()
      local members = 0
      for _, item in ipairs(declared()) do
        local entry = item.entry
        if entry.family then
          members = members + 1
          t.falsy(entry.path, entry.name .. ' is a family member, yet declares a menu path')
        end
      end
      t.truthy(members > 50, 'the manifest mints its families')
    end,
  },
}
