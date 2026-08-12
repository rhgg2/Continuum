-- The undo label sits on the verb, not on the command. A command registered
-- with registerAll's tuple form labels its own body; where that body only opens
-- a modal, the edit lands in the callback frames later, outside the block. So
-- the verbs below carry their labels themselves, and every entry point -- key,
-- menu, confirm callback, patternEditor's own registration -- picks one up.

local t    = require('support')
local util = require('util')

-- util.atomic reads reaper.Undo_BeginBlock at call time, so a stub installed
-- after the wrap still counts. Outermost blocks only: an inner block (the
-- hideExtraCol inside unautomateParam) collapses into the verb's.
local function collectLabels(h)
  local depth, out = 0, {}
  h.reaper.Undo_BeginBlock = function() depth = depth + 1 end
  h.reaper.Undo_EndBlock   = function(label)
    depth = depth - 1
    if depth == 0 then util.add(out, label) end
  end
  return out
end

----- Quantize

-- One note 5 ppq past row 2 (logPerRow 60 at rpb 4), so every quantize verb
-- has a real move to make: onset back to 120, either as intent or as delay.
local function offGridTake(harness)
  local h = harness.mk{
    seed = {
      notes = {
        { ppq = 125, endppq = 245, ppqL = 125, endppqL = 245,
          chan = 1, pitch = 60, vel = 100, detune = 0, delay = 0,
          lane = 1, rpb = 4 },
      },
    },
    config = { take = { rowPerBeat = 4 } },
  }
  h.vm:setGridSize(80, 40)
  return h
end

-- Plain quantize takes the raw onset back to the row; keep-realised moves only
-- the logical one and leaves the raw where it sounded, delay absorbing the gap.
local QUANTIZE_VERBS = {
  { verb = 'quantizeAll',                   label = 'Continuum: Quantize',                    ppq = 120, ppqL = 120 },
  { verb = 'quantizeSelection',             label = 'Continuum: Quantize',                    ppq = 120, ppqL = 120 },
  { verb = 'quantizeKeepRealisedAll',       label = 'Continuum: Quantize (keep realised)',    ppq = 125, ppqL = 120 },
  { verb = 'quantizeKeepRealisedSelection', label = 'Continuum: Quantize (keep realised)',    ppq = 125, ppqL = 120 },
}

----- Automation columns

local NOTE = { ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100,
               detune = 0, delay = 0, lane = 1 }

local BINDING = { busCode = 0, trackGuid = '{DST}', fxGuid = '{FX-1}',
                  param = 3, scale = 1, offset = 0, label = 'Cutoff' }

local function ccColIndex(h, cc)
  for i, col in ipairs(h.vm.grid.cols) do
    if col.type == 'cc' and col.cc == cc then return i end
  end
end

return {

  {
    name = 'every quantize verb opens one labelled block -- whole-take scope included',
    run = function(harness)
      for _, v in ipairs(QUANTIZE_VERBS) do
        local h = offGridTake(harness)
        local labels = collectLabels(h)
        h.ec:setPos(2, 1, 1)   -- over the note: the selection scopes' region
        h.vm[v.verb](h.vm)

        t.deepEq(labels, { v.label }, v.verb .. ' opens one block, labelled')
        local n = h.fm:dump().notes[1]
        t.eq(n.ppq,  v.ppq,  v.verb .. ' left the raw onset at ' .. v.ppq)
        t.eq(n.ppqL, v.ppqL, v.verb .. ' moved the logical onset inside that block')
      end
    end,
  },

  {
    name = 'unautomateParam labels its own block -- the confirm callback lands outside the command',
    run = function(harness)
      local h = harness.mk{
        seed = {
          notes = { NOTE },
          ccs = { { ppq = 0,   chan = 1, evType = 'cc', cc = 110, val = 64 },
                  { ppq = 240, chan = 1, evType = 'cc', cc = 110, val = 80 } },
        },
        data   = { extraColumns = { [1] = { notes = 1, ccs = { [110] = true } } },
                   paramAutomation = { [1] = { [110] = BINDING } } },
      }
      h.vm:setGridSize(80, 40)
      h.ec:setPos(0, ccColIndex(h, 110), 1)
      local labels = collectLabels(h)
      h.vm:unautomateParam()

      t.deepEq(labels, { 'Continuum: Remove automation' },
               'one block: the nested hideExtraCol collapsed into it')
      t.falsy(ccColIndex(h, 110), 'the column went inside that block')
    end,
  },

  {
    name = 'hideExtraCol labels its own block',
    run = function(harness)
      local h = harness.mk{
        seed = { notes = { NOTE } },
        data = { extraColumns = { [1] = { notes = 1, ccs = { [110] = true } } },
                 paramAutomation = { [1] = { [110] = BINDING } } },
      }
      h.vm:setGridSize(80, 40)
      h.ec:setPos(0, ccColIndex(h, 110), 1)
      local labels = collectLabels(h)
      h.vm:hideExtraCol()

      t.deepEq(labels, { 'Continuum: Hide column' }, 'one block, labelled')
      t.falsy(ccColIndex(h, 110), 'the column went inside that block')
    end,
  },

}
