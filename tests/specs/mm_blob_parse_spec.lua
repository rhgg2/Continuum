-- Golden pin for midiBlob.parse against real REAPER MIDI_GetAllEvts blobs.
--
-- Fixtures are captured by tests/spikes/spike_capture_blobs.lua: each carries
-- a raw blob plus the per-event API decode mm:load consumes today. parse(blob)
-- must reproduce notes/ccs/texts exactly -- including the 0-based per-type idx,
-- note-off pairing, cc-shape-from-flags, and CCBZ tension folded onto its cc
-- while staying out of the text index space.

local t = require('support')
local midiBlob = require('midiBlob')
local fixtures = require('fixtures.midi_blobs')

local function byName(name)
  for _, f in ipairs(fixtures) do if f.name == name then return f end end
end

local tests = {}

for _, f in ipairs(fixtures) do
  tests[#tests + 1] = {
    name = 'parse reproduces ground truth: ' .. f.name,
    run = function()
      local notes, ccs, texts = midiBlob.parse(f.blob)
      t.deepEq(notes, f.notes, f.name .. ' notes')
      t.deepEq(ccs,   f.ccs,   f.name .. ' ccs')
      t.deepEq(texts, f.texts, f.name .. ' texts')
    end,
  }
end

tests[#tests + 1] = {
  name = 'bezier CCBZ folds onto its cc and stays out of the text index space',
  run = function()
    local f = byName('bezier_sidecar')
    local _, ccs, texts = midiBlob.parse(f.blob)
    local bez
    for _, c in ipairs(ccs) do if c.shape == 'bezier' then bez = c end end
    t.truthy(bez, 'a bezier cc was parsed')
    t.eq(bez.tension, 0.5, 'tension decoded from the CCBZ float')
    for _, x in ipairs(texts) do
      t.eq(x.msg:sub(1, 5) ~= 'CCBZ ', true, 'no CCBZ leaked into texts')
    end
  end,
}

return tests
