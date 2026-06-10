-- pa.computeDesired: pure bindings -> per-track trackSpecs. Pins the
-- pooled-duplicate collapse, the same-track no-send rule, and the sorted
-- slot order the mirror diff depends on for a stable REAPER image.

local t    = require('support')
local util = require('util')

local pa = util.instantiate('paramAutomation', {})

local function binding(over)
  local b = { srcTrackGuid = 'SRC', chan = 1, lane = 119, busCode = 0,
              trackGuid = 'DST', fxGuid = '{FX-1}', param = 2,
              scale = 1, offset = 0, label = 'Cutoff' }
  for k, v in pairs(over or {}) do b[k] = v end
  return b
end

return {

  {
    name = 'same-track binding: filter + listen on one spec, no send',
    run = function()
      local specs = pa.computeDesired{ binding{ trackGuid = 'SRC' } }
      local s = specs.SRC
      t.truthy(s, 'source track spec present')
      t.deepEq(s.filter, { { src = 119, dst = 0 } }, 'srcCode = (chan-1)*128 + lane')
      t.deepEq(s.listen,
        { { code = 0, fxGuid = '{FX-1}', param = 2, scale = 1, offset = 0 } })
      t.deepEq(s.sends, {}, 'no send to self')
    end,
  },

  {
    name = 'cross-track binding fans out by send; pooled duplicates collapse',
    run = function()
      -- The same binding gathered twice (pooled takes) must not double up.
      local specs = pa.computeDesired{ binding{}, binding{} }
      t.deepEq(specs.SRC.filter, { { src = 119, dst = 0 } }, 'one filter entry')
      t.deepEq(specs.SRC.sends,  { 'DST' },                  'one send')
      t.deepEq(specs.SRC.listen, {},                         'listening happens on DST')
      t.eq(#specs.DST.listen, 1,     'one listen entry')
      t.deepEq(specs.DST.filter, {}, 'DST authors nothing')
    end,
  },

  {
    name = 'slots sort by src code / bus code for a stable image',
    run = function()
      local specs = pa.computeDesired{
        binding{ chan = 2, lane = 10, busCode = 7, param = 3 },
        binding{ chan = 1, lane = 50, busCode = 3 },
      }
      t.deepEq(specs.SRC.filter, { { src = 50, dst = 3 }, { src = 138, dst = 7 } })
      t.eq(specs.DST.listen[1].code, 3)
      t.eq(specs.DST.listen[2].code, 7)
    end,
  },

}
