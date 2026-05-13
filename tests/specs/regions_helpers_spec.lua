-- Pure helpers for the region primitive. See regions.lua for the model.

local t = require('support')
local R = require('regions')

local function noteCol(chan, lane) return { type='note', midiChan=chan, lane=lane } end
local function ccCol  (chan, cc)   return { type='cc',   midiChan=chan, cc=cc } end
local function pbCol  (chan)       return { type='pb',   midiChan=chan } end
local function pcCol  (chan)       return { type='pc',   midiChan=chan } end
local function atCol  (chan)       return { type='at',   midiChan=chan } end

return {
  ----- colKey

  { name = 'colKey: note encodes chan, lane, part', run = function()
      t.eq(R.colKey(noteCol(1, 2),  'pitch'), 'note:1:2:pitch')
      t.eq(R.colKey(noteCol(16, 4), 'vel'),   'note:16:4:vel')
      t.eq(R.colKey(noteCol(1, 1),  'delay'), 'note:1:1:delay')
  end },

  { name = 'colKey: cc / pb / pc / at have no part suffix', run = function()
      t.eq(R.colKey(ccCol(3, 74), 'val'), 'cc:3:74')
      t.eq(R.colKey(pbCol(5),     'pb'),  'pb:5')
      t.eq(R.colKey(pcCol(5),     'val'), 'pc:5')
      t.eq(R.colKey(atCol(5),     'val'), 'at:5')
  end },

  { name = 'colKey: unknown col.type raises', run = function()
      local ok = pcall(R.colKey, { type='zzz', midiChan=1 }, 'val')
      t.eq(ok, false)
  end },

  ----- parseColKey: round-trip with colKey

  { name = 'parseColKey: note round-trip', run = function()
      t.deepEq(R.parseColKey('note:1:2:pitch'),
               { type='note', chan=1, lane=2, part='pitch' })
      t.deepEq(R.parseColKey('note:16:4:vel'),
               { type='note', chan=16, lane=4, part='vel' })
  end },

  { name = 'parseColKey: cc round-trip', run = function()
      t.deepEq(R.parseColKey('cc:3:74'),
               { type='cc', chan=3, cc=74 })
  end },

  { name = 'parseColKey: pb / pc / at', run = function()
      t.deepEq(R.parseColKey('pb:5'), { type='pb', chan=5 })
      t.deepEq(R.parseColKey('pc:5'), { type='pc', chan=5 })
      t.deepEq(R.parseColKey('at:5'), { type='at', chan=5 })
  end },

  ----- Parts set ops

  { name = 'partsUnion: empty cases', run = function()
      t.deepEq(R.partsUnion({}, {}), {})
      t.deepEq(R.partsUnion({a=true}, {}), {a=true})
      t.deepEq(R.partsUnion({}, {a=true}), {a=true})
  end },

  { name = 'partsUnion: idempotent', run = function()
      t.deepEq(R.partsUnion({a=true, b=true}, {a=true, b=true}),
               {a=true, b=true})
  end },

  { name = 'partsUnion: merges disjoint and overlapping', run = function()
      t.deepEq(R.partsUnion({a=true, b=true}, {b=true, c=true}),
               {a=true, b=true, c=true})
  end },

  { name = 'partsDifference: removes intersection', run = function()
      t.deepEq(R.partsDifference({a=true, b=true, c=true}, {b=true}),
               {a=true, c=true})
  end },

  { name = 'partsDifference: self yields empty', run = function()
      t.deepEq(R.partsDifference({a=true, b=true}, {a=true, b=true}), {})
  end },

  { name = 'partsDifference: disjoint preserves', run = function()
      t.deepEq(R.partsDifference({a=true}, {b=true}), {a=true})
  end },

  { name = 'partsIsEmpty / partsCount', run = function()
      t.eq(R.partsIsEmpty({}),         true)
      t.eq(R.partsIsEmpty({a=true}),   false)
      t.eq(R.partsCount({}),                       0)
      t.eq(R.partsCount({a=true, b=true, c=true}), 3)
  end },

  { name = 'partsCopy is a deep copy', run = function()
      local src = { ['note:1:1:pitch'] = true }
      local cp  = R.partsCopy(src)
      src['note:1:1:vel'] = true
      t.eq(cp['note:1:1:vel'], nil)
  end },

  ----- Region predicates and seed

  { name = 'containsCell: half-open ppq window', run = function()
      local r = R.seed(100, 200, { ['note:1:1:pitch'] = true })
      t.eq(R.containsCell(r, 'note:1:1:pitch',  99), false)
      t.eq(R.containsCell(r, 'note:1:1:pitch', 100), true)
      t.eq(R.containsCell(r, 'note:1:1:pitch', 199), true)
      t.eq(R.containsCell(r, 'note:1:1:pitch', 200), false)
  end },

  { name = 'containsCell: part not in set', run = function()
      local r = R.seed(0, 1000, { ['note:1:1:pitch'] = true })
      t.eq(R.containsCell(r, 'note:1:1:vel', 500), false)
  end },

  { name = 'seed: parts deep-copied (caller may mutate input)', run = function()
      local p = { ['note:1:1:pitch'] = true }
      local r = R.seed(0, 10, p)
      p['note:1:1:vel'] = true
      t.eq(r.parts['note:1:1:vel'], nil)
      t.eq(r.parts['note:1:1:pitch'], true)
      t.eq(r.ppqLo, 0)
      t.eq(r.ppqHi, 10)
  end },
}
