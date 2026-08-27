-- Stage 1b: the pb view column is carried across the rebuild-entry wipe. A clean
-- channel reuses its column object (no re-clone); a dirtied channel re-derives.
-- The passing suite proves dirty channels stay correct, but nothing else pins the
-- reuse itself -- a regression that re-cloned every rebuild would stay green here
-- without this spec. see design/incremental-pbs.md § Stage 1b
--
-- The last test pins the other side of the gate: pbRange is derivation config, so a
-- change must reach every channel and rescale the wire under the new window.

local t    = require('support')
local util = require('util')

local function centsToRaw(cents, pbRange)
  return util.clamp(util.round(cents * 8192 / (pbRange * 100)), -8192, 8191)
end

local function pbByChan(h)
  local out = {}
  for _, cc in ipairs(h.fm:dump().ccs) do
    if cc.evType == 'pb' then out[cc.chan] = cc end
  end
  return out
end

return {

  {
    name = 'clean rebuild reuses the carried pb column object',
    run = function(harness)
      local h = harness.mk{ seed = { ccs = {
        { ppq = 480, chan = 1, evType = 'pb', val = 0 },
        { ppq = 480, chan = 2, evType = 'pb', val = 0 },
      } } }
      local before1 = h.tm:getChannel(1).columns.pb
      local before2 = h.tm:getChannel(2).columns.pb
      t.truthy(before1 and before2, 'both channels surface a visible pb column')

      h.tm:rebuild(false)   -- no edit: every channel clean

      t.eq(h.tm:getChannel(1).columns.pb, before1, 'clean chan 1 reuses its pb column object')
      t.eq(h.tm:getChannel(2).columns.pb, before2, 'clean chan 2 reuses its pb column object')
    end,
  },

  {
    name = 'a pbRange change rescales every authored pb, holding its cents',
    run = function(harness)
      local h = harness.mk{ seed = { ccs = {
        { ppq = 0,    chan = 1, evType = 'pb', val = centsToRaw(100, 2), cents = 100, shape = 'step' },
        { ppq = 9600, chan = 2, evType = 'pb', val = centsToRaw(-75, 2), cents = -75, shape = 'step' },
      } } }

      h.cm:set('track', 'pbRange', 4)   -- the window doubles: the same cents need half the raw

      local pbs = pbByChan(h)
      t.eq(pbs[1].val, centsToRaw(100, 4), 'chan 1 rescales, so 100c still sounds as 100c')
      t.eq(pbs[2].val, centsToRaw(-75, 4), 'a pb far past every note rescales too')
      t.eq(pbs[1].cents, 100, 'the sidecar is the intent, and does not move')
    end,
  },

  {
    name = 'extraColumns edit dirties pb: carried column replaced',
    run = function(harness)
      local h = harness.mk{ seed = { ccs = {
        { ppq = 480, chan = 2, evType = 'pb', val = 0 },
      } } }
      local before2 = h.tm:getChannel(2).columns.pb
      t.truthy(before2, 'chan 2 surfaces a pb column')

      -- Document-data edit: arrives as dataChanged, now dirtyPb()s all 16 channels.
      h.ds:assign('extraColumns', { [1] = { notes = 1, pb = true } })

      local after2 = h.tm:getChannel(2).columns.pb
      t.truthy(after2, 'chan 2 still surfaces a pb column')
      t.truthy(after2 ~= before2, 'extraColumns edit re-derived chan 2 (fresh column, not carried)')
    end,
  },

}
