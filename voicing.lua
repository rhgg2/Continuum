-- See docs/trackerManager.md § Same-pitch onset separation for the model.
-- @noindex

--invariant: pure policy module: no module state; callers stage every mm write
local util = require 'util'

local voicing = {}

----- Verdicts

-- Dedup same-(chan,pitch) raw collision only when one is a regenerable fxNote or they share
-- logical seat and detune; otherwise distinct voices: separate (+1) so each keeps its raw.
local function supersedes(a, b)
  local aDerived, bDerived = a.derived ~= nil, b.derived ~= nil
  if aDerived ~= bDerived then return bDerived end
  return (a.endppqL or a.endppq) > (b.endppqL or b.endppq)
end

local function redundant(a, b)
  if (a.derived ~= nil) ~= (b.derived ~= nil) then return true end
  return a.ppqL == b.ppqL and (a.detune or 0) == (b.detune or 0)
end

----- Separation

--contract: sorts group (ppq, ppqL) in place; returns kills, voiced, onsetOf (separated onsets)
function voicing.resolveGroup(group)
  table.sort(group, function(a, b)
    if a.ppq ~= b.ppq then return a.ppq < b.ppq end
    return (a.ppqL or 0) < (b.ppqL or 0)
  end)
  -- Walk the sorted voice: dedup true duplicates, nudge distinct collisions apart.
  -- onsetOf carries each survivor's post-separation raw onset.
  local kills, voiced, onsetOf = {}, {}, {}
  for _, n in ipairs(group) do
    local prev = voiced[#voiced]
    if prev and n.ppq <= onsetOf[prev] then
      if redundant(n, prev) then
        if supersedes(n, prev) then
          util.add(kills, prev); voiced[#voiced] = n; onsetOf[n] = onsetOf[prev]
        else
          util.add(kills, n)
        end
      else
        onsetOf[n] = onsetOf[prev] + 1
        util.add(voiced, n)
      end
    else
      onsetOf[n] = n.ppq
      util.add(voiced, n)
    end
  end
  return kills, voiced, onsetOf
end

-- Nudge colliding same-(chan,pitch) onsets to prev.ppq+1 (cascades; fixed externals frozen).
-- Pure geometry on evt.ppq; callers stage mm writes. Input sorted (raw, ppqL).
function voicing.nudgeOnsets(records)
  local moved, lastByVoice = {}, {}
  for _, n in ipairs(records) do
    local e   = n.evt
    local key = util.key(e.chan, e.pitch)
    local prev = lastByVoice[key]
    if prev and not e.fixed and e.ppq <= prev.evt.ppq then
      e.ppq = prev.evt.ppq + 1
      util.add(moved, n)
    end
    lastByVoice[key] = n
  end
  return moved
end

return voicing
