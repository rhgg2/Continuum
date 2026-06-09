local t    = require('support')
local util = require('util')

local function roundtrip(v)
  return util.unserialise(util.serialise(v))
end

return {
  {
    name = 'serialise: math.huge round-trips as the inf literal',
    run = function()
      t.eq(util.serialise(math.huge),  'inf')
      t.eq(util.serialise(-math.huge), '-inf')
      t.eq(roundtrip(math.huge),       math.huge)
      t.eq(roundtrip(-math.huge),     -math.huge)
    end,
  },
  {
    name = 'serialise: util.OPEN round-trips through a table value',
    run = function()
      -- The load-bearing case: endppqL = util.OPEN persisted in an
      -- extstate blob must come back == util.OPEN, not the string 'inf'.
      local v = roundtrip({ endppqL = util.OPEN, ppqL = 0 })
      t.eq(v.endppqL, util.OPEN, 'open sentinel survives by value')
      t.eq(v.ppqL, 0)
    end,
  },
  {
    name = 'serialise: nan emits the nan literal and parses back as a string',
    run = function()
      -- nan is intentionally lossy on the return trip: nan ~= nan would
      -- break any equality check the caller might rely on. We pin the
      -- wire form so it doesn't quietly drop into the string fall-through.
      t.eq(util.serialise(0/0), 'nan')
      t.eq(roundtrip(0/0),      'nan')
    end,
  },
  {
    name = 'serialise: finite numbers, booleans and strings keep their existing shapes',
    run = function()
      t.eq(roundtrip(42),       42)
      t.eq(roundtrip(-1.5),    -1.5)
      t.eq(roundtrip(true),     true)
      t.eq(roundtrip(false),    false)
      t.eq(roundtrip('hello'),  'hello')
      t.eq(roundtrip('inf-ish'), 'inf-ish')
    end,
  },
  {
    name = 'serialise: control bytes hex-escape so the wire form is NUL-free (REAPER ext-state transport)',
    run = function()
      -- util.key joins parts with \0; REAPER's ext-state API is C-string and
      -- truncates at the first NUL, so the wire form must carry no raw control bytes.
      local composite = util.key('{GUID-A}', '{GUID-B}')
      t.eq(roundtrip(composite), composite, 'NUL-joined composite key survives')
      t.eq(util.serialise(composite):find('\0'), nil, 'no raw NUL in wire form')

      local ctrl = '\0\1\9\13\31\127'
      t.eq(roundtrip(ctrl), ctrl, 'all control bytes round-trip')
      t.eq(util.serialise(ctrl):find('%c'), nil, 'no raw control byte in wire form')

      -- A literal backslash-x sequence must not collide with the \xHH escape.
      t.eq(roundtrip('\\x41'), '\\x41')
    end,
  },
}
