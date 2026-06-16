local t    = require('support')
local util = require('util')

local function roundtrip(v)
  return util.prettyUnserialise(util.prettySerialise(v))
end

return {
  {
    name = 'prettySerialise: scalars round-trip through load()',
    run = function()
      t.eq(roundtrip(42),      42)
      t.eq(roundtrip(-1.5),   -1.5)
      t.eq(roundtrip(true),    true)
      t.eq(roundtrip(false),   false)
      t.eq(roundtrip('hello'), 'hello')
      t.eq(roundtrip(''),      '')
    end,
  },
  {
    name = 'prettySerialise: nested tables and float arrays round-trip',
    run = function()
      t.deepEq(roundtrip({ a = { b = { c = 1 } }, d = 2 }),
                         { a = { b = { c = 1 } }, d = 2 })
      t.deepEq(roundtrip({ 0, 0, 0, 1 }),      { 0, 0, 0, 1 })
      t.deepEq(roundtrip({ 0.5, 1.0, 2.25 }),  { 0.5, 1.0, 2.25 })
    end,
  },
  {
    name = 'prettySerialise: edge-whitespace and control strings survive',
    run = function()
      for _, s in ipairs({ '  lead/trail  ', 'line\nbreak', 'tab\there',
                           '\0\1\31\127', 'quote"inside', 'back\\slash' }) do
        t.eq(roundtrip(s), s, 'string survives: ' .. string.format('%q', s))
      end
    end,
  },
  {
    name = 'prettySerialise: dotted and keyword keys are quoted, not bare',
    run = function()
      local emitted = util.prettySerialise({ ['palette.base.zone0'] = { 0, 0, 0, 1 } })
      t.truthy(emitted:find('%["palette%.base%.zone0"%]'), 'dotted key quoted')
      t.deepEq(roundtrip({ ['palette.base.zone0'] = { 0, 0, 0, 1 }, ['end'] = 1, ['for'] = 2 }),
                         { ['palette.base.zone0'] = { 0, 0, 0, 1 }, ['end'] = 1, ['for'] = 2 })
    end,
  },
  {
    name = 'prettySerialise: util.OPEN (inf) round-trips by value',
    run = function()
      local v = roundtrip({ endppqL = util.OPEN, ppqL = 0 })
      t.eq(v.endppqL, util.OPEN, 'open sentinel survives as math.huge')
      t.eq(v.ppqL, 0)
      t.eq(roundtrip(-math.huge), -math.huge)
    end,
  },
  {
    name = 'prettySerialise: nan emits 0/0 and reads back as a nan',
    run = function()
      t.truthy(util.prettySerialise(0/0):find('0/0', 1, true), 'nan emitted as 0/0')
      local n = util.prettyUnserialise('return 0/0')
      t.truthy(n ~= n, 'reads back as a nan')
    end,
  },
  {
    name = 'prettySerialise: mixed array + sparse integer keys round-trip',
    run = function()
      t.deepEq(roundtrip({ 1, 2, 3, label = 'x', [9] = 'sparse' }),
                         { 1, 2, 3, label = 'x', [9] = 'sparse' })
    end,
  },
  {
    name = 'prettyUnserialise: bad chunk returns nil + error, never raises',
    run = function()
      local v, err = util.prettyUnserialise('return {')   -- syntax error
      t.eq(v, nil)
      t.truthy(err, 'load error surfaced so the store can refuse to overwrite')
      t.eq(util.prettyUnserialise('return 1 + 1'), 2)     -- arithmetic needs no env
    end,
  },
  {
    name = 'prettySerialise: output is a `return` chunk',
    run = function()
      t.truthy(util.prettySerialise({ x = 1 }):match('^return '), 'starts with return')
    end,
  },
}
