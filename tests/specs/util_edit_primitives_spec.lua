-- Pin-tests for the numeric-edit primitives hoisted from viewManager into
-- util.lua (setDigit, snapTo, nudgedScalar) and the cmgr:noteChars lookup
-- (absorbed from the former noteInput module).
-- Each case encodes an invariant that the refactor must preserve; if any
-- fails, the hoist has changed observable behaviour.

local t = require('support')
local util = require('util')

local function newCommandManager(cm)
  return util.instantiate('commandManager', { cm = cm })
end

local function byte(c) return string.byte(c) end

-- Minimal cm stub: cmgr only calls cm:get('noteLayout').
local function stubCm(layout)
  return { get = function(_, _) return layout end }
end

return {
  --------------------------------------------------------------------
  -- util.setDigit
  --------------------------------------------------------------------
  {
    name = 'setDigit: places ones digit in decimal, zeroing below',
    run = function()
      -- pos=0 (ones), base=10: any existing ones are overwritten.
      t.eq(util.setDigit(47, 3, 0, 10, false), 43)
      t.eq(util.setDigit(9,  7, 0, 10, false), 7)
    end,
  },
  {
    name = 'setDigit: places tens digit in decimal, zeroing ones',
    run = function()
      -- pos=1 (tens) zeroes the ones place.
      t.eq(util.setDigit(47, 8, 1, 10, false), 80)
    end,
  },
  {
    name = 'setDigit: hex base, keeps places above the target',
    run = function()
      -- 0x7F = 127. pos=1 sets nibble 1 (high); low nibble cleared.
      t.eq(util.setDigit(0x7F, 0x3, 1, 16, false), 0x30)
      -- pos=0 sets nibble 0 (low); high nibble kept.
      t.eq(util.setDigit(0x7F, 0x3, 0, 16, false), 0x73)
    end,
  },
  {
    name = 'setDigit: keepBelow preserves the places below the target',
    run = function()
      -- keepBelow=false zeroes below the written place; true keeps them.
      t.eq(util.setDigit(347, 5, 2, 10, false), 500)
      t.eq(util.setDigit(347, 5, 2, 10, true),  547)
      -- hex: overwrite the high nibble, keep the low.
      t.eq(util.setDigit(0x73, 0x5, 1, 16, true), 0x53)
    end,
  },

  --------------------------------------------------------------------
  -- util.snapTo
  --------------------------------------------------------------------
  {
    name = 'snapTo: positive dir snaps up; on-boundary values move a full step',
    run = function()
      t.eq(util.snapTo(13, 1, 8), 16)  -- between 8 and 16, snaps to 16
      t.eq(util.snapTo(16, 1, 8), 24)  -- on boundary, moves a full interval
      t.eq(util.snapTo(0,  1, 8), 8)
    end,
  },
  {
    name = 'snapTo: negative dir snaps down; on-boundary values move a full step',
    run = function()
      t.eq(util.snapTo(13, -1, 8), 8)
      t.eq(util.snapTo(16, -1, 8), 8)  -- on boundary, still moves down
      t.eq(util.snapTo(0,  -1, 8), -8)
    end,
  },

  --------------------------------------------------------------------
  -- util.nudgedScalar
  --------------------------------------------------------------------
  {
    name = 'nudgedScalar: no interval → unit step, clamped to bounds',
    run = function()
      t.eq(util.nudgedScalar(100, 1, 127,  1, nil), 101)
      t.eq(util.nudgedScalar(127, 1, 127,  1, nil), 127)  -- clamped
      t.eq(util.nudgedScalar(1,   1, 127, -1, nil), 1)    -- clamped
    end,
  },
  {
    name = 'nudgedScalar: with interval, snaps and then clamps',
    run = function()
      -- velocity-like: coarse=8
      t.eq(util.nudgedScalar(100, 1, 127,  1, 8), 104)  -- 13*8=104
      t.eq(util.nudgedScalar(120, 1, 127,  1, 8), 127)  -- snap 128 clamped
      t.eq(util.nudgedScalar(5,   1, 127, -1, 8), 1)    -- snap 0 clamped to 1
    end,
  },

  --------------------------------------------------------------------
  -- util.insertSorted
  --------------------------------------------------------------------
  {
    name = 'insertSorted: keeps a numeric list ordered, returns the index',
    run = function()
      local less = function(a, b) return a < b end
      local l = { 1, 3, 5 }
      t.eq(util.insertSorted(l, 4, less), 3)   -- between 3 and 5
      t.deepEq(l, { 1, 3, 4, 5 })
      t.eq(util.insertSorted(l, 0, less), 1)   -- front
      t.eq(util.insertSorted(l, 9, less), 6)   -- end
      t.deepEq(l, { 0, 1, 3, 4, 5, 9 })
    end,
  },
  {
    name = 'insertSorted: empty list places at index 1',
    run = function()
      local l = {}
      t.eq(util.insertSorted(l, 7, function(a, b) return a < b end), 1)
      t.deepEq(l, { 7 })
    end,
  },
  {
    name = 'insertSorted: lower bound -- new item precedes existing equals',
    run = function()
      -- comparator on .k only; .tag distinguishes identity. A fresh item seats before equal .k.
      local less = function(a, b) return a.k < b.k end
      local l = { { k = 1, tag = 'a' }, { k = 2, tag = 'b' }, { k = 2, tag = 'c' } }
      t.eq(util.insertSorted(l, { k = 2, tag = 'new' }, less), 2)
      t.eq(l[2].tag, 'new')
      t.eq(l[3].tag, 'b')
    end,
  },
  {
    name = 'insertSorted: multi-key comparator seats a pa after a note at the same onset',
    run = function()
      local less = function(a, b)
        if a.ppq ~= b.ppq then return a.ppq < b.ppq end
        return b.evType == 'pa' and a.evType ~= 'pa'
      end
      local l = { { ppq = 0, evType = 'note' }, { ppq = 10, evType = 'note' } }
      util.insertSorted(l, { ppq = 0, evType = 'pa' }, less)
      t.eq(l[2].evType, 'pa')
      t.eq(l[2].ppq, 0)
      t.eq(l[3].ppq, 10)
    end,
  },

  --------------------------------------------------------------------
  -- cmgr:noteChars (absorbed noteInput)
  --------------------------------------------------------------------
  {
    name = 'cmgr:noteChars colemak: Z-row maps base octave, semi 0',
    run = function()
      local cmgr = newCommandManager(stubCm('colemak'))
      t.deepEq(cmgr:noteChars(byte('z')), { 0, 0 })
    end,
  },
  {
    name = 'cmgr:noteChars colemak: Q-row maps +1 octave',
    run = function()
      local cmgr = newCommandManager(stubCm('colemak'))
      t.deepEq(cmgr:noteChars(byte('q')), { 0, 1 })
    end,
  },
  {
    name = 'cmgr:noteChars colemak: semi increments along the row',
    run = function()
      -- colemak Z-row: z,r,x,s,c,v,... → x is index 3, so semi=2.
      local cmgr = newCommandManager(stubCm('colemak'))
      t.deepEq(cmgr:noteChars(byte('x')), { 2, 0 })
    end,
  },
  {
    name = 'cmgr:noteChars azerty: accepts Unicode codepoints as keys',
    run = function()
      -- azerty row 2 has 233 ('é') at index 2 → {semi=1, octOff=1}.
      local cmgr = newCommandManager(stubCm('azerty'))
      t.deepEq(cmgr:noteChars(233), { 1, 1 })
    end,
  },
  {
    name = 'cmgr.layouts: all four layouts present',
    run = function()
      local cmgr = newCommandManager(stubCm('colemak'))
      for _, name in ipairs{ 'qwerty', 'colemak', 'dvorak', 'azerty' } do
        t.truthy(cmgr.layouts[name], name .. ' layout present')
      end
    end,
  },
  {
    name = 'cmgr:noteChars: unbound char returns nil',
    run = function()
      local cmgr = newCommandManager(stubCm('qwerty'))
      t.eq(cmgr:noteChars(byte('`')), nil)
    end,
  },
}
