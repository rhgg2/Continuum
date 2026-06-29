-- See docs/groupManager.md for the model.

--shape: group = { rect, events = { [vuid] = groupEvt } }
--shape: rect = { ppq, dur, chanLo, streams = { [chanOffset] = { [streamId]=true } } }  -- chanHi derived from max chanOffset
--shape: groupEvt = { evType, <scalar fields: chanDelta,key,ppq,dur,pitch,vel,detune,delay,val,shape,tension,muted...> }
--shape: instanceState = { assigns={[vuid]={[field]={base,value}}}, adds={[vuid]=groupEvt}, deletes={[vuid]=true} }
--shape: conflict = { [vuid] = { [field] = { base, group, value } } }
--shape: op = { op='add'|'del'|'set', vuid, [uuid], [groupEvt] }
--invariant: evType is identity, never merged or overridden; changing type is delete+create upstream
--invariant: the core is field-agnostic -- it merges every event key except evType and never interprets one
--invariant: an assign is sticky -- local value always wins; a drifted base only raises a conflict flag, it does not change the resolved value
--invariant: the region is the identity, not an event set; membership is the rect predicate (time span x per-channel streamId set), so streamId must be index-free (evType+key) and survive column insert/reorder

local util = require 'util'

local groups = {}

--contract: (groupEvt, assign?) -> resolved event, 'synced'|'overridden'. Local value wins; per the sticky-assign invariant a drifted base raises no conflict here.
function groups.resolve(groupEvt, assign)
  local out = util.clone(groupEvt) or {}
  if not assign then return out, 'synced' end
  for field, rec in pairs(assign) do out[field] = rec.value end
  return out, 'overridden'
end
local resolve = groups.resolve

--contract: (group, instance?) -> desired, conflicts, states. desired[vuid] is provenance-free intent (dur is the authored ceiling; nil dur = open); states[vuid] is synced|overridden|conflicted. Recomputed from scratch each call (terminal set, never a diff). Carries intent only -- tm's universal tail pass derives every realised note-off, so project never clips or grows a dur.
function groups.project(group, instance)
  instance = instance or {}
  local assigns = instance.assigns or {}
  local adds    = instance.adds    or {}
  local deletes = instance.deletes or {}
  local desired, conflicts, states = {}, {}, {}
  -- Assign whose group event vanished is dropped (group is authority): no desired entry, no conflict.
  local fromGroup = {}                       -- vuid -> at its unmoved group slot
  for vuid, groupEvt in pairs(group.events) do
    if not deletes[vuid] then
      desired[vuid], states[vuid] = resolve(groupEvt, assigns[vuid])
      fromGroup[vuid] = assigns[vuid] == nil
    end
  end
  for vuid, groupEvt in pairs(adds) do
    desired[vuid] = util.clone(groupEvt)
    states[vuid]  = 'overridden'
  end

  -- Sole conflict: two events at one (lane, onset). Group event (then lower vuid) holds the slot,
  -- the loser is dropped + conflicted; the sort makes that order-independent.
  local ordered = {}
  for vuid in pairs(desired) do ordered[#ordered + 1] = vuid end
  table.sort(ordered, function(a, b)
    if fromGroup[a] ~= fromGroup[b] then return fromGroup[a] == true end
    return a < b
  end)
  local claimed = {}
  for _, vuid in ipairs(ordered) do
    local e = desired[vuid]
    local slot = groups.laneId(e) .. '@' .. tostring(e.ppq or 0)
    if claimed[slot] then
      desired[vuid]   = nil
      states[vuid]    = 'conflicted'
      conflicts[vuid] = true
    else
      claimed[slot] = vuid
    end
  end

  return desired, conflicts, states
end

--contract: (desired, current) where current[vuid]={uuid,groupEvt} -> op list; a move/resize is one `set`, never del+add.
function groups.reconcile(desired, current)
  local ops = {}
  for vuid, groupEvt in pairs(desired) do
    local cur = current[vuid]
    if not cur then
      util.add(ops, { op = 'add', vuid = vuid, groupEvt = groupEvt })
    elseif not util.deepEq(groupEvt, cur.groupEvt) then
      util.add(ops, { op = 'set', vuid = vuid, uuid = cur.uuid, groupEvt = groupEvt })
    end
  end
  for vuid, cur in pairs(current) do
    if desired[vuid] == nil then
      util.add(ops, { op = 'del', vuid = vuid, uuid = cur.uuid })
    end
  end
  return ops
end

--contract: (groupEvt?, field, value) -> assign rec capturing the live group value as the merge base at fork time (nil groupEvt -> nil base).
function groups.deriveAssign(groupEvt, field, value)
  return { base = groupEvt and groupEvt[field] or nil, value = value }
end

--contract: stream identity = evType..':'..(key or 0) (note->lane, cc->cc-number); index-free per the region invariant.
function groups.streamId(evt)
  return evt.evType .. ':' .. tostring(evt.key or 0)
end

--contract: shift a note stream's lane by δ (note:L -> note:L+δ); non-notes pass through.
function groups.shiftStream(sid, delta)
  if delta == 0 then return sid end
  local lane = sid:match('^note:(-?%d+)$')
  if not lane then return sid end
  return 'note:' .. (tonumber(lane) + delta)
end

--contract: group-frame lane identity = (chanDelta or 0)..'/'..streamId; per-channel, so two channels at one lane+onset are distinct slots.
function groups.laneId(evt)
  return tostring(evt.chanDelta or 0) .. '/' .. groups.streamId(evt)
end

--contract: membership predicate; ppq/chanOffset are anchor-relative (caller does the anchor maths). True iff 0<=ppq<rect.dur AND rect.streams[chanOffset][streamId(evt)]. rect.ppq is the placement origin, not the membership origin.
function groups.inRect(rect, ppq, chanOffset, evt)
  if ppq < 0 or ppq >= rect.dur then return false end
  local sel = rect.streams[chanOffset]
  return sel ~= nil and sel[groups.streamId(evt)] == true
end

-- Projection state -> chrome colour. Colocated with the state vocabulary so the two can't drift;
-- tintKey is only the per-cell deviation overlay, so synced (the common case) has none. See docs.
local OVERLAY = { overridden = 'mirror.overridden.tint',
                  conflicted = 'mirror.conflicted.tint' }
function groups.tintKey(state)
  return OVERLAY[state]
end
function groups.regionKey(colour, kind)
  return 'region.' .. colour .. '.' .. kind
end
function groups.outlineKey(state, colour)
  if state == 'conflicted' then return 'mirror.conflicted.outline' end
  return groups.regionKey(colour, 'outline')
end

return groups
