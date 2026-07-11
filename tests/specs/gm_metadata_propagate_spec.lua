-- The group<->instance duals copy the event's full payload, not a
-- closed allowlist: any persisted metadata field (rpb, and arbitrary
-- unknown keys mm round-trips) survives a duplicate. The mirror image:
-- regenerated/derived keys (loc, sampleShadowed, fake) must NOT enter
-- the shared group template, or they leak into every sibling.

local t    = require('support')
local util = require('util')

local function fakeTm()
  local hooks, staged, seq = {}, { add = {} }, 0
  local tm = {}
  function tm:length()         return math.huge end   -- off-take clip irrelevant here
  function tm:subscribe(s, fn) hooks[s] = fn end
  function tm:requestRebuild() end
  function tm:addEvent(e)      staged.add[#staged.add + 1] = e end
  function tm:assignEvent()    end
  function tm:deleteEvent()    end
  function tm:flush()
    if hooks.preflush then hooks.preflush({}, {}, {}) end
    for _, e in ipairs(staged.add) do
      if e.uuid == nil then seq = seq + 1; e.uuid = 1000 + seq end
    end
    if hooks.postflush then hooks.postflush() end
  end
  return tm, staged
end

local function rect() return { ppq = 0, dur = 960, chanLo = 1,
  streams = { [0] = { ['note:1'] = true } } } end

return {
  {
    name = 'a duplicated note carries rpb and arbitrary metadata; derived keys do not leak',
    run = function()
      local tm, staged = fakeTm()
      local ds = t.fakeDs()
      local gm = util.instantiate('groupManager', { tm = tm, ds = ds })

      local seed = { evType = 'note', chan = 1, lane = 1, ppq = 0,
                     endppq = 240, endppqL = 240, pitch = 60, vel = 100,
                     rpb = 8, foo = 'bar',
                     loc = 99, sampleShadowed = true, derived = 'absorber' }

      local gid = gm:markGroup({ seed }, rect())
      t.truthy(gid, 'group seeded')
      gm:newInstance(gid, { ppq = 960, chan = 1 })

      local copy = staged.add[1]
      t.truthy(copy, 'newInstance staged one concrete')

      -- The instance is projected from the shared group template, so
      -- these assertions pin BOTH duals: toGroup kept the payload and
      -- denied the derived keys; toInstance carried it back.
      t.eq(copy.rpb, 8, 'rpb survives the duplicate')
      t.eq(copy.foo, 'bar', 'an arbitrary metadata key survives')
      t.eq(copy.loc, nil, 'loc (rebuild-regenerated) did not leak')
      t.eq(copy.sampleShadowed, nil,
           'sampleShadowed (rebuild-only) did not leak')
      t.eq(copy.derived, nil, 'fake (absorber synth) did not leak')
    end,
  },
}
