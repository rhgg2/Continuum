-- The projection between the logical and realisation frames: a pure snapshot built once per
-- rebuild pass, discarded and rebuilt when an input changes. see docs/timing.md § The time context

--invariant: pure: no side effects, no signals, no mutation of args
--invariant: E_c = global ∘ column, resolved over args.length: the composites' ramps run to that end
--shape: args = { length, ppqPerQN, swings = the merged library, assignment = { global = name, [chan] = name } }

local util   = require 'util'
local timing = require 'timing'

local args     = ...
local length   = args.length
local ppqPerQN = args.ppqPerQN
local ctx      = {}

-- One resolved shape per assigned channel, plus the global. A name the library does not hold, an
-- identity body and a lengthless take all resolve to nothing, and that channel projects identically.
local global, column = nil, {}
do
  local function resolve(name)
    local composite = name and args.swings[name]
    if timing.isIdentity(composite) or length <= 0 then return nil end
    return timing.resolveComposite(composite, length, ppqPerQN)
  end
  for chan, name in pairs(args.assignment) do
    if chan == 'global' then global = resolve(name) else column[chan] = resolve(name) end
  end
end

--post: result = the span the composites were resolved over
function ctx:length() return length end

--pre: offset is a realisation-frame nudge (a note's delay), never a logical one
--post: result is integer-valued
function ctx:fromLogical(chan, ppqL, offset)
  local ppqI = ppqL
  local c    = column[chan]
  if c      then ppqI = timing.eval(c, ppqI) end
  if global then ppqI = timing.eval(global, ppqI) end
  return util.round(ppqI + (offset or 0))
end

--post: result = the fromLogical preimage of ppqI, unrounded
function ctx:toLogical(chan, ppqI)
  local ppqL = ppqI
  if global then ppqL = timing.invert(global, ppqL) end
  local c    = column[chan]
  if c      then ppqL = timing.invert(c, ppqL) end
  return ppqL
end

return ctx
