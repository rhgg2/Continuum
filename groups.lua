-- Pure groups core. No REAPER, no anchor arithmetic. Two frames: the
-- `group` (shared, relative -- the identity all mirrors agree on) and the
-- `instance` (a concrete placement of that group in the take). Every group
-- event is expressed relative to the group origin -- chanDelta = chan minus
-- the instance anchor's chan, key = the stream's identity within that
-- channel (lane for notes, cc-number for cc), ppq relative to the anchor.
-- The stateful groupManager owns the anchor maths between the two frames.
--
-- A `group` is a region plus its contents: `rect` and `events` (vuid ->
-- flat group-space event). The region is the identity, not an enumerated
-- event set -- an event is a member iff it falls inside the region, so
-- creation needs no opt-in -- and it is shared, never per-instance: local
-- variation is event-level only.
--
-- The region is NOT a column rectangle: tracker columns are an unstable
-- view artifact (inserting a cc reindexes neighbours). It is a logical
-- time span x a per-channel stream-selector set:
--   ppq in [rect.ppq, rect.ppq+rect.dur)
--   AND rect.streams[chanOffset] exists  (chanOffset = chan - anchor)
--   AND streamId(event) in rect.streams[chanOffset]
-- streamId is evType+key (note->lane, cc->cc-number, pb, pc) -- an
-- identity, not an index, so it survives column insert/reorder. Per
-- channel because "ch1: notes+cc74, ch2: cc1 only" must be expressible.
--
-- An instance's divergence from the group is expressed in the same op
-- vocabulary as the tracker stack: `assigns` (sticky local field values,
-- each carrying the group value captured at fork time), `adds` (events
-- that exist only in this instance) and `deletes` (group events this
-- instance has locally deleted). `vuid` is the virtual uuid -- an event's
-- shared identity across instances; the stateful layer maps it to the
-- concrete per-take `uuid`.
--
-- project() resolves a group + instance state into the events that
-- instance should contain, local-wins, flagging a conflict wherever an
-- assign's captured base has drifted from the live group (never
-- auto-resolved). reconcile() diffs the desired set against what the
-- instance holds, keyed by vuid, into minimal ops -- a move/resize is one
-- `set`, never del+add.

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

local util   = require 'util'
local legato = require 'legato'

local groups = {}

--contract: group event + sticky local assign -> resolved event. Local
--           always wins; a drifted base is NOT a conflict (the only
--           conflict is two events at one onset, decided in project).
--           State is 'synced' with no assign, else 'overridden'.
function groups.resolve(groupEvt, assign)
  local out = util.clone(groupEvt) or {}
  if not assign then return out, 'synced' end
  for field, rec in pairs(assign) do out[field] = rec.value end
  return out, 'overridden'
end
local resolve = groups.resolve

--contract: returns (desired, conflicts, states). desired[vuid] is a
--           clean group-space event with no provenance keys; states[vuid]
--           is synced|overridden|conflicted. Recomputed from scratch
--           every call -- a terminal set, never a diff. `patternLen` is
--           the take length (tm:length, caller-supplied -- the core is
--           pure); a tailless note runs to it when nothing follows.
function groups.project(group, instance, patternLen)
  instance = instance or {}
  patternLen = patternLen or math.huge
  local assigns = instance.assigns or {}
  local adds    = instance.adds    or {}
  local deletes = instance.deletes or {}
  local desired, conflicts, states = {}, {}, {}
  -- An assign whose group event vanished is simply dropped (the group
  -- is the authority): it never enters `desired`, raises no conflict.
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

  -- The sole conflict: two events at one (lane, onset). The group event
  -- holds the slot (then lower vuid); a colliding override is dropped
  -- and conflicted. Sorting makes the outcome order-independent.
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

  -- Geometry is tv's legato, replayed on the desired set via the
  -- shared primitive -- nothing re-derived here. `src` carries the
  -- chain geometry; `.e` is the desired entry the pass mutates.
  local function noteLanes(src)
    local lanes = {}
    for vuid, e in pairs(src) do
      if e.evType == 'note' then
        e.ppq = e.ppq or 0
        util.bucket(lanes, groups.laneId(e),
          { vuid = vuid, e = desired[vuid],
            ppq = e.ppq, endppq = e.ppq + (e.dur or 0) })
      end
    end
    for _, list in pairs(lanes) do
      table.sort(list, function(a, b) return a.ppq < b.ppq end)
    end
    return lanes
  end

  -- (1) Instance-local deletes grow the surviving legato owner over the
  --     hole, walked on the *group* chain (tv's queueDeleteNotes rule).
  --     The only place a tail is *extended*.
  for _, list in pairs(noteLanes(group.events)) do
    local del = {}
    for _, n in ipairs(list) do if deletes[n.vuid] then del[n] = true end end
    for _, f in ipairs(legato.deleteFixups(list, del, patternLen)) do
      if f.evt.e then f.evt.e.dur = f.endppq - (f.evt.e.ppq or 0) end
    end
  end

  -- (2) Every note's tail then runs to the next onset in its desired
  --     lane, else patternLen for the last in lane. This is a hard
  --     bound, not the realised clip: it keeps a note-off from running
  --     past the take (REAPER would extend it). The cross-instance
  --     realised clip is conform's job -- reproject marks the
  --     last-in-lane note and tm:rebuild's conform-tail pass caps it
  --     to the next *realised* onset. A bare add (no dur) takes the
  --     tail outright; a stored note is only clipped, never grown.
  for _, list in pairs(noteLanes(desired)) do
    for _, n in ipairs(list) do
      local _, _, tail = legato.place(list, n.ppq, patternLen)
      n.e.dur = n.e.dur == nil and tail - n.ppq
                or math.min(n.ppq + n.e.dur, tail) - n.ppq
    end
  end

  return desired, conflicts, states
end

--contract: current[vuid] = { uuid, groupEvt }. Returns an op list; a moved
--           or resized event is a single `set`, never del+add.
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

--contract: captures the live group value as the merge base at fork time;
--           nil groupEvt (local-only edit) captures nil base.
function groups.deriveAssign(groupEvt, field, value)
  return { base = groupEvt and groupEvt[field] or nil, value = value }
end

--contract: the region's stable per-stream identity -- evType plus `key`
--           (note->lane, cc->cc-number). Index-free: survives column
--           insert/reorder, unlike a view-column position.
function groups.streamId(evt)
  return evt.evType .. ':' .. tostring(evt.key or 0)
end

--contract: group-frame lane identity -- streamId plus chanDelta. Geometry
--           (slot dedup, legato chains, conform) resolves per lane within
--           one channel; two channels at the same lane and onset are
--           distinct slots. rect.streams keeps streamId channel-free
--           because chanOffset is already its own dimension there.
function groups.laneId(evt)
  return tostring(evt.chanDelta or 0) .. '/' .. groups.streamId(evt)
end

--contract: region membership predicate. Both coords are anchor-relative:
--           ppq = concrete ppq minus the instance anchor ppq, chanOffset =
--           concrete chan minus the instance anchor chan (caller does the
--           anchor maths). True iff ppq is within the span [0, rect.dur)
--           AND that channel offset participates AND the event's streamId
--           is selected for it. rect.ppq is the absolute placement origin
--           (cascade/render); it is NOT the membership time origin -- that
--           is the anchor, already subtracted out, mirroring chanOffset.
function groups.inRect(rect, ppq, chanOffset, evt)
  if ppq < 0 or ppq >= rect.dur then return false end
  local sel = rect.streams[chanOffset]
  return sel ~= nil and sel[groups.streamId(evt)] == true
end

-- View mapping: projection state -> chrome colour name. Colocated with
-- the state vocabulary so the two never drift. A per-group hue
-- (`region.<colour>`) carries group identity as the membership wash;
-- tintKey is only the per-cell deviation overlay painted on top, so
-- synced (the common case) has none. conflicted forces a loud outline
-- regardless of which group it belongs to.
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
