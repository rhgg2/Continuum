-- util.instantiate caches the compiled chunk of each module file, because
-- parsing is the expensive half and the file does not change mid-session. The
-- guarantee callers rely on is about the module *body* running afresh per call,
-- not about the parse — so what needs pinning is that reuse of the compiled
-- chunk never becomes reuse of the instance it builds.
--
-- ccManager is the subject because it is a real dep-free factory whose body
-- opens module-level state (`claims`); sharing an instance would silently pool
-- that state across every caller.

local t = require('support')
local util = require('util')

return {
  {
    name = 'instantiate: repeated calls each build their own instance',
    run = function()
      local first  = util.instantiate('ccManager')
      local second = util.instantiate('ccManager')
      t.falsy(first == second, 'instances must not be shared between calls')
    end,
  },
}
