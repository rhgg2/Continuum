-- F1: channel aftertouch (`at`) as a first-class gm member. Unlike pb, at has
-- no detune realisation frame -- its `val` IS the intent -- so it rides the
-- fully generic seams (no special makeEntry/toGroup arm) with stream identity
-- `at:0`. These pins would fire if someone grew an at-specific branch that
-- dropped its val or uuid. See design/fx-freeze.md § F1.

local t    = require('support')
local util = require('util')

local function rect() return { ppq = 0, dur = 960, chanLo = 1,
  streams = { [0] = { ['at:0'] = true } } } end

return {
  {
    name = 'at member: toGroup carries val verbatim (no cents rewrite)',
    run = function()
      local tm, staged = t.fakeTm()
      local gm = util.instantiate('groupManager', { tm = tm, ds = t.fakeDs() })

      local seed = { evType = 'at', chan = 1, ppq = 0, shape = 'step', val = 40 }

      local gid = gm:markGroup({ seed }, rect())
      t.truthy(gid, 'group seeded from an at member')
      gm:newInstance(gid, { ppq = 960, chan = 1 })

      local copy = staged.add[1]
      t.truthy(copy, 'newInstance staged the projected at')
      t.eq(copy.val, 40, 'projected at carries its val unchanged')
      t.eq(copy.cents, nil, 'no pb-style cents leaks onto a non-pb member')
    end,
  },

  {
    name = 'at member: uuid survives the rebuild so gm can re-anchor it (tm:byUuid)',
    run = function(harness)
      -- mm mints a uuid for the whole cc family (at included), so the generic
      -- makeEntry else-branch carries it into the um index verbatim and gm's
      -- per-rebuild re-anchor (groupManager.lua:684) finds it -- no at-specific
      -- linkage arm needed, unlike pb's.
      local h = harness.mk{ seed = { ccs = {
        { ppq = 0, chan = 1, evType = 'at', val = 40, shape = 'step' },
      } } }

      local atUuid
      for _, cc in ipairs(h.fm:dump().ccs) do
        if cc.evType == 'at' then atUuid = cc.uuid end
      end
      t.truthy(atUuid, 'the seeded at was minted a uuid')

      local entry = h.tm:byUuid(atUuid)
      t.truthy(entry, 'the at is findable by uuid after the rebuild')
      t.eq(entry.evType, 'at', 'and it is the at um entry')
      t.eq(entry.uuid, atUuid, 'carrying its uuid into the um index')
    end,
  },
}
