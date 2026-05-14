-- Pure helpers for the region primitive. See regions.lua for the model.

local t = require('support')
local R = require('regions')
local util = require('util')

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

  ----- allocVuid

  { name = 'allocVuid: lazy-inits template; returns base36 "1" on first call', run = function()
      local r = { id = 1, parts = {} }
      local v = R.allocVuid(r)
      t.eq(v, '1')
      t.eq(r.template.eventCtr, 1)
      t.deepEq(r.template.events, {})
  end },

  { name = 'allocVuid: monotonic across calls; base36 rolls past digits', run = function()
      local r = { id = 1, parts = {} }
      local got = {}
      for _ = 1, 12 do got[#got+1] = R.allocVuid(r) end
      t.deepEq(got, {'1','2','3','4','5','6','7','8','9','A','B','C'})
      t.eq(r.template.eventCtr, 12)
  end },

  { name = 'allocVuid: preserves existing template.events', run = function()
      local r = { id = 1, parts = {},
        template = { events = { ['1'] = { pitch = 60 } }, eventCtr = 1 } }
      local v = R.allocVuid(r)
      t.eq(v, '2')
      t.eq(r.template.events['1'].pitch, 60)
  end },

  ----- composeOp

  { name = 'composeOp: lazy-inits region.xform and slot', run = function()
      local r = { id = 1, parts = {} }
      R.composeOp(r, '*', 'ppqL', { 'add', 10 })
      t.deepEq(r.xform, { ['*'] = { ppqL = { { 'add', 10 } } } })
  end },

  { name = 'composeOp: appends within a slot', run = function()
      local r = { id = 1, parts = {} }
      R.composeOp(r, '*', 'ppqL', { 'add', 10 })
      R.composeOp(r, '*', 'durL', { 'mul', 2 })
      t.deepEq(r.xform['*'], {
        ppqL = { { 'add', 10 } },
        durL = { { 'mul', 2 } },
      })
  end },

  { name = 'composeOp: coalesces same-opcode literal ops (via aliases.appendOp)', run = function()
      local r = { id = 1, parts = {} }
      R.composeOp(r, '*', 'ppqL', { 'add', 10 })
      R.composeOp(r, '*', 'ppqL', { 'add', 5 })
      t.deepEq(r.xform['*'].ppqL, { { 'add', 15 } })
  end },

  { name = 'composeOp: separate slots stay isolated', run = function()
      local r = { id = 1, parts = {} }
      R.composeOp(r, '*',                 'ppqL',  { 'add', 10 })
      R.composeOp(r, 'note:1:1:pitch',    'pitch', { 'add',  1 })
      t.deepEq(r.xform['*'].ppqL,                 { { 'add', 10 } })
      t.deepEq(r.xform['note:1:1:pitch'].pitch,   { { 'add',  1 } })
  end },

  ----- refuseStarVal

  { name = 'refuseStarVal: only star+val is refused', run = function()
      t.eq(R.refuseStarVal('*', 'val'),               true)
      t.eq(R.refuseStarVal('*', 'ppqL'),              false)
      t.eq(R.refuseStarVal('*', 'pitch'),             false)
      t.eq(R.refuseStarVal('cc:1:74', 'val'),         false)
      t.eq(R.refuseStarVal('note:1:1:pitch', 'val'),  false)
  end },

  ----- resolveEvent

  { name = 'resolveEvent: nil xforms are identity', run = function()
      local out = R.resolveEvent({ pitch = 60, vel = 64, ppqL = 0 }, nil, nil, 'note')
      t.deepEq(out, { pitch = 60, vel = 64, ppqL = 0 })
  end },

  { name = 'resolveEvent: star xform alone', run = function()
      local out = R.resolveEvent(
        { pitch = 60, vel = 64, ppqL = 0 },
        { ppqL = { { 'add', 24 } } },
        nil,
        'note')
      t.eq(out.ppqL, 24)
      t.eq(out.pitch, 60)
  end },

  { name = 'resolveEvent: col xform alone', run = function()
      local out = R.resolveEvent(
        { pitch = 60, vel = 64, ppqL = 0 },
        nil,
        { pitch = { { 'add', 1 } } },
        'note')
      t.eq(out.pitch, 61)
  end },

  { name = 'resolveEvent: star then col compose on the same field — star first', run = function()
      -- vel 64 -> +10 (star) -> 74 -> *2 (col) -> 148
      local out = R.resolveEvent(
        { vel = 64 },
        { vel = { { 'add', 10 } } },
        { vel = { { 'mul',  2 } } },
        'note')
      t.eq(out.vel, 148)
  end },

  { name = 'resolveEvent: cross-type fail-closed (pitch op skipped on cc)', run = function()
      local out = R.resolveEvent(
        { ppqL = 0, val = 64 },
        { val = { { 'add', 1 } } },
        { pitch = { { 'add', 12 } } },
        'cc')
      t.eq(out.val, 65)
      t.eq(out.pitch, nil)
  end },

  { name = 'resolveEvent: inputs untouched (xforms and template event)', run = function()
      local templ = { pitch = 60, vel = 64 }
      local star  = { vel = { { 'add', 10 } } }
      local col   = { pitch = { { 'add', 1 } } }
      local _ = R.resolveEvent(templ, star, col, 'note')
      t.deepEq(templ, { pitch = 60, vel = 64 })
      t.deepEq(star,  { vel = { { 'add', 10 } } })
      t.deepEq(col,   { pitch = { { 'add', 1 } } })
  end },

  ----- cm round-trip on the 'regions' key

  { name = 'cm: regions default is { regions={}, idCtr=0 }',
    run = function(harness)
      local h = harness.mk()
      t.deepEq(h.cm:get('regions'), { regions = {}, idCtr = 0 })
  end },

  { name = 'cm: regions round-trip through take tier',
    run = function(harness)
      local h = harness.mk()
      local blob = {
        regions = {
          { id = 1, colour = 1, ppqLo = 0, ppqHi = 240,
            parts = { ['note:1:1:pitch'] = true } },
          { id = 2, colour = 2, ppqLo = 240, ppqHi = 480,
            parts = { ['cc:1:74'] = true } },
        },
        idCtr = 2,
      }
      h.cm:set('take', 'regions', blob)
      t.deepEq(h.cm:get('regions'), blob)

      -- Reload a fresh cm against the same take.
      local cm2 = util.instantiate('configManager')
      cm2:setContext('take1')
      t.deepEq(cm2:get('regions'), blob)
  end },

  { name = 'cm: regions read returns a deep copy — caller mutation does not leak',
    run = function(harness)
      local h = harness.mk()
      h.cm:set('take', 'regions', {
        regions = { { id = 1, colour = 1, ppqLo = 0, ppqHi = 100,
                      parts = { ['note:1:1:pitch'] = true } } },
        idCtr = 1,
      })
      local a = h.cm:get('regions')
      a.regions[1].ppqHi = 999
      a.regions[2] = { id = 99 }
      a.idCtr = 42
      local b = h.cm:get('regions')
      t.eq(b.regions[1].ppqHi, 100, 'inner field independent across reads')
      t.eq(b.regions[2], nil,       'caller-added entry does not leak')
      t.eq(b.idCtr, 1,              'caller-added field does not leak')
  end },
}
