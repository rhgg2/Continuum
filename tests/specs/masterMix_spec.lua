-- masterMix exposes a render-only toolbar segment (peak/loudness meter + master
-- fader). The meter visuals and fader drag are exercised manually in REAPER --
-- the pure-Lua ImGui fake can't drive drawlist or InvisibleButton. This pins the
-- one thing the coordinator depends on: a segment with id 'master' and a render fn.

package.preload['imgui'] = function()
  return function(_)
    return setmetatable({}, { __index = function() return function() end end })
  end
end

local t    = require('support')
local util = require('util')

local function fakeChrome() return { colour = function(name) return name end } end

return {
  {
    name = 'exposes a master toolbar segment with a render fn',
    run = function()
      local mm = util.instantiate('masterMix', { ctx = {}, chrome = fakeChrome() })
      t.eq(mm.segment.id, 'master', 'segment id is master')
      t.eq(type(mm.segment.render), 'function', 'segment carries a render fn')
    end,
  },
}
