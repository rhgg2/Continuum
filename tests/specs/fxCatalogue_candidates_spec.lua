-- fxCatalogue.candidates: the rows whose plugin covers a need. A need is the
-- least ports a candidate must carry, in a graph node's ports shape:
-- { audio = { ins, outs }, midi = { ins, outs } }, any part absent meaning 0.
-- A plugin covers a need where each of its counts is at least the need's.
--
-- Audio counts are the entry's ports, in stereo pairs. A row whose key has no
-- entry, or an entry without ports, is unprobed and passes every audio count.
-- MIDI counts come from the resolved traits (docs/fxCatalogue.md § Traits):
-- midi in 1 where midiIn holds, else 0, and likewise midi out. So authored
-- traits beat a JSFX's parse, a VST's 'i' mark gives midi in, and an unauthored
-- VST defaults to both. Traits resolve only for a need that asks for MIDI, so
-- no JSFX source is read for the others.
--
-- The result is a fresh array in the rows' order; the catalogue arrives as ds
-- holds it (nil reads empty), and neither it nor the rows is written.
local t           = require('support')
local harness     = require('harness')
local fxCatalogue = require('fxCatalogue')
local util        = require('util')

local VST3DIR = '/Library/Audio/Plug-Ins/VST3/'

-- The parse memo lives for the whole run, so these paths are this spec's own.
local JSFX = {
  ['candidates/both']  = 'desc:b\n@block\nwhile (midirecv(o,a,b)) ( midisend(o,a,b); );\n',
  ['candidates/plain'] = 'desc:p\n@sample\nspl0 *= 1;\n',
  ['candidates/liar']  = 'desc:l\n@block\nwhile (midirecv(o,a,b)) ( midisend(o,a,b); );\n',
}

local ROWS = {
  { name = 'JS: Both',           ident = 'candidates/both' },   -- midi both ways, 1/1
  { name = 'JS: Plain',          ident = 'candidates/plain' },  -- no midi, 1/1
  { name = 'VST3i: Keys (Acme)', ident = VST3DIR .. 'Keys.vst3' },  -- instrument, 0 in / 1 out
  { name = 'VST3: Bare (Acme)',  ident = VST3DIR .. 'Bare.vst3' },  -- no entry
  { name = 'VST3: Mute (Acme)',  ident = VST3DIR .. 'Mute.vst3' },  -- authored midiOut false, 2/1
  { name = 'VST3: Wide (Acme)',  ident = VST3DIR .. 'Wide.vst3' },  -- 1 in / 3 out
  { name = 'VST3: Used (Acme)',  ident = VST3DIR .. 'Used.vst3' },  -- usage, no ports
  { name = 'JS: Liar',           ident = 'candidates/liar' },   -- parses midi in, authored false, 1/1
}
local ALL = { 'JS: Both', 'JS: Plain', 'VST3i: Keys (Acme)', 'VST3: Bare (Acme)', 'VST3: Mute (Acme)',
              'VST3: Wide (Acme)', 'VST3: Used (Acme)', 'JS: Liar' }

local CATALOGUE = {
  n = 4,
  entries = {
    ['candidates/both']  = { ports = { ins = 1, outs = 1 } },
    ['candidates/plain'] = { ports = { ins = 1, outs = 1 } },
    ['Keys.vst3']        = { ports = { ins = 0, outs = 1 } },
    ['Mute.vst3']        = { ports = { ins = 2, outs = 1 }, traits = { midiOut = false } },
    ['Wide.vst3']        = { ports = { ins = 1, outs = 3 } },
    ['Used.vst3']        = { usage = { s = 1, n0 = 1 } },
    ['candidates/liar']  = { ports = { ins = 1, outs = 1 }, traits = { midiIn = false } },
  },
}

-- The installed rows and the catalogue as ds holds it, over a fresh fake.
local function fixture(opts)
  opts = opts or {}
  local h = harness.mk()
  local installed = util.clone(ROWS)
  for _, row in ipairs(opts.extraRows or {}) do util.add(installed, row) end
  h.reaper:setInstalledFx(installed)
  for path, content in pairs(JSFX) do h.reaper:setJsfx(path, content) end
  if opts.catalogue ~= false then h.ds:assign('fxCatalogue', util.deepClone(CATALOGUE)) end
  return fxCatalogue.installed(), h.ds:get('fxCatalogue'), h
end

local function names(rows)
  local out = {}
  for i, row in ipairs(rows) do out[i] = row.name end
  return out
end

local function candidates(need, opts)
  local rows, catalogue = fixture(opts)
  return names(fxCatalogue.candidates(catalogue, rows, need))
end

return {
  {
    name = 'the empty need admits every row, in order, as a fresh array of the rows themselves',
    run = function()
      local rows, catalogue = fixture()
      t.eq(#rows, #ALL, 'precondition: every row installed')
      local got = fxCatalogue.candidates(catalogue, rows, {})
      t.deepEq(names(got), ALL)
      t.truthy(got ~= rows, 'a fresh array')
      for i, row in ipairs(got) do t.eq(row, rows[i], 'the caller\'s row table') end
    end,
  },
  {
    name = 'an audio need admits the rows whose ports cover it, and every unprobed row',
    run = function()
      local allButKeys = util.filter(ALL, function(name) return name ~= 'VST3i: Keys (Acme)' end)
      t.deepEq(candidates({ audio = { ins = 1, outs = 1 } }), allButKeys, 'splice: the instrument has no in')
      t.deepEq(candidates({ audio = { ins = 1 } }), allButKeys, 'branch: absent outs are 0')
      t.deepEq(candidates({ audio = { ins = 2, outs = 1 } }),
        { 'VST3: Bare (Acme)', 'VST3: Mute (Acme)', 'VST3: Used (Acme)' }, 'a count equal to the need covers it')
      t.deepEq(candidates({ audio = { outs = 3 } }),
        { 'VST3: Bare (Acme)', 'VST3: Wide (Acme)', 'VST3: Used (Acme)' })
      t.deepEq(candidates({ audio = { ins = 0, outs = 1 } }), ALL, 'a zero count asks nothing')
    end,
  },
  {
    name = 'a midi need admits the rows whose resolved traits give each port it asks for',
    run = function()
      t.deepEq(candidates({ midi = { ins = 1, outs = 1 } }),
        { 'JS: Both', 'VST3i: Keys (Acme)', 'VST3: Bare (Acme)', 'VST3: Wide (Acme)', 'VST3: Used (Acme)' },
        'splice: Plain parses neither, Mute is authored without out, Liar without in')
      t.deepEq(candidates({ midi = { ins = 1 } }),
        { 'JS: Both', 'VST3i: Keys (Acme)', 'VST3: Bare (Acme)', 'VST3: Mute (Acme)', 'VST3: Wide (Acme)',
          'VST3: Used (Acme)' },
        'branch: Mute has a midi in')
    end,
  },
  {
    name = 'authored traits beat the JSFX parse',
    run = function()
      local need = { midi = { ins = 1 } }
      local rows, catalogue = fixture()
      t.eq(fxCatalogue.traits(nil, 'JS', 'candidates/liar').midiIn, true, 'precondition: Liar parses midi in')
      local liar = util.filter(rows, function(row) return row.key == 'candidates/liar' end)
      t.eq(#liar, 1, 'precondition: one Liar row')
      t.deepEq(names(fxCatalogue.candidates(catalogue, liar, need)), {})
      t.deepEq(names(fxCatalogue.candidates(nil, liar, need)), { 'JS: Liar' }, 'unauthored, the parse admits')
    end,
  },
  {
    name = 'a need over audio and midi admits only rows covering both',
    run = function()
      t.deepEq(candidates({ audio = { ins = 2, outs = 1 }, midi = { outs = 1 } }),
        { 'VST3: Bare (Acme)', 'VST3: Used (Acme)' },
        'Mute covers the audio but not the midi; Both the midi but not the audio')
    end,
  },
  {
    name = 'a nil catalogue leaves every row unprobed, its traits from parse, mark and default',
    run = function()
      t.deepEq(candidates({ audio = { ins = 2, outs = 3 } }, { catalogue = false }), ALL)
      t.deepEq(candidates({ audio = { ins = 2, outs = 3 }, midi = { ins = 1, outs = 1 } }, { catalogue = false }),
        { 'JS: Both', 'VST3i: Keys (Acme)', 'VST3: Bare (Acme)', 'VST3: Mute (Acme)', 'VST3: Wide (Acme)',
          'VST3: Used (Acme)', 'JS: Liar' },
        'only Plain parses short of midi')
    end,
  },
  {
    name = 'the catalogue and rows are unwritten',
    run = function()
      local rows, catalogue = fixture()
      local rowsBefore, catalogueBefore = util.deepClone(rows), util.deepClone(catalogue)
      for _, need in ipairs({ {}, { audio = { ins = 2, outs = 1 } }, { midi = { ins = 1, outs = 1 } } }) do
        fxCatalogue.candidates(catalogue, rows, need)
      end
      t.deepEq(rows, rowsBefore)
      t.deepEq(catalogue, catalogueBefore)
    end,
  },
  {
    -- An unseeded path is a read the fake can watch; the memo would hide a second one.
    name = 'no JSFX source is read unless the need asks for midi',
    run = function()
      local unread = { name = 'JS: Unread', ident = 'candidates/unread' }
      local rows, catalogue, h = fixture({ extraRows = { unread } })
      local reads = {}
      setmetatable(h.reaper._state.jsfx, { __index = function(_, path) util.add(reads, path) end })
      fxCatalogue.candidates(catalogue, rows, {})
      fxCatalogue.candidates(catalogue, rows, { audio = { ins = 1, outs = 1 } })
      t.deepEq(reads, {})
      fxCatalogue.candidates(catalogue, rows, { midi = { ins = 1 } })
      t.deepEq(reads, { 'candidates/unread' }, 'precondition: a midi need reads it')
    end,
  },
}
