-- See docs/groupManager.md for the model.

--shape: group = { rect, events = { [vuid]=groupEvt }, nextVuid, instances = { [instId]=instance } }
--shape: instance = { anchor = { ppq, chan }, assigns, adds, deletes }  -- pure data, persisted verbatim
--shape: proj[groupId][instId][vuid] = { uuid, groupEvt=clone, evt=liveEvt }  -- module-level, runtime; only `uuid` serialised, persisted as `uuids[groupId][instId][vuid]`
--shape: persisted groups = { groups = groups, uuids = { [groupId]={ [instId]={ [vuid]=uuid } } } }
--invariant: localMode is a single global UI flag, not per-instance; default propagate edits the shared group
--invariant: a staged edit is matched to its vuid by evt-table identity (proj evt slot), else by the rect predicate gated on streamIds already present

local util   = require 'util'
local groupsCore = require 'groups'

local deps   = ...
local tm, ds = deps.tm, deps.ds

-- DERIVED is opt-out: an allowlist would silently drop every unlisted key (the rpb-drop bug).
-- see docs/groupManager.md § DERIVED opt-out
local DERIVED = {
  evType=true, chan=true, chanDelta=true, lane=true, key=true, cc=true,
  ppq=true, ppqL=true, endppq=true, endppqL=true, dur=true,
  loc=true, sampleShadowed=true, derived=true, hidden=true, uuid=true,
}

local gm = {}

----- State

local blob        = ds:get('groups') or {}
local groups      = blob.groups or {}
local localMode   = false
local propagating = false
local nextGroupId = 1

-- The active group: a transient pointer (never persisted), dupeClip-idiom.
-- Set on mark / stamp-new; the command layer clears it on any other
-- tracker command, on ec:selClear, and on take rebind.
local activeGroup = nil

-- Runtime projection, kept out of `groups` so instances stay pure
-- serialisable data. locByUuid is the sole O(1) reverse lookup; uuid
-- is the durable key (tm's token is internal and re-keyed).
local proj      = {}
local locByUuid = {}  -- concrete uuid -> { groupId, instId, vuid }
-- newInstance's own projection adds; the preflush adds loop skips them.
local selfStaged = {}
-- moveInstance's own re-place assigns; the preflush assigns loop skips them.
local selfAssigned = {}
-- uuids the user directly touched this flush. Gates userOwned (per
-- event, not per instance) so a create/delete's redundant tm op is
-- skipped while a same-flush edit in two instances still propagates.
local touchedUuids = {}
-- newInstance's adds are selfStaged, so the preflush adds loop skips
-- them and the new group never lands in touchedGroups -- it would stay
-- unreprojected (no conform) until some later edit touched it. Carry it
-- here so the next preflush reprojects it once.
local pendingReproject = {}

local function projOf(groupId, instId)
  local g = proj[groupId]
  if not g then g = {}; proj[groupId] = g end
  local p = g[instId]
  if not p then p = {}; g[instId] = p end
  return p
end

-- Seed proj + locByUuid from the persisted vuid->uuid map.
for groupId in pairs(groups) do
  if groupId >= nextGroupId then nextGroupId = groupId + 1 end
end
for groupId, gi in pairs(blob.uuids or {}) do
  for instId, byVuid in pairs(gi) do
    local p = projOf(groupId, instId)
    for vuid, uuid in pairs(byVuid) do
      p[vuid] = { uuid = uuid }
      locByUuid[uuid] = { groupId = groupId, instId = instId, vuid = vuid }
    end
  end
end

-- Every projected write goes through link/unlink so the reverse lookups
-- stay in step.
local function link(groupId, instId, vuid, p, uuid, groupEvt, evt)
  p[vuid] = { uuid = uuid, groupEvt = groupEvt, evt = evt }
  if uuid then
    locByUuid[uuid] = { groupId = groupId, instId = instId, vuid = vuid }
  end
end

local function unlink(p, vuid)
  local rec = p[vuid]
  if not rec then return end
  if rec.uuid then locByUuid[rec.uuid] = nil end
  p[vuid] = nil
end

-- reconcile() wants current[vuid] = { uuid, groupEvt }.
local function currentOf(p)
  local cur = {}
  for vuid, rec in pairs(p) do
    cur[vuid] = { uuid = rec.uuid, groupEvt = rec.groupEvt }
  end
  return cur
end

----- Anchor maths: four pure duals (group <-> instance)

local function keyOf(evt)
  if evt.evType == 'note' then return evt.lane or 1 end
  if evt.evType == 'cc'   then return evt.cc or 0 end
  return 0
end

--invariant: payload crossing the group<->instance frame is opt-OUT --
--           every src field except DERIVED is carried, so mm's
--           arbitrary per-event metadata (rpb included) survives.
local function copyScalars(src, dst)
  for f, v in pairs(src) do if not DERIVED[f] then dst[f] = v end end
  return dst
end

-- A note's group dur is its INTENT ceiling span (endppqL - onset), never
-- the realised endppq tm re-derives every rebuild. An open note
-- (endppqL == util.OPEN, no ceiling) carries no dur: a nil dur IS open
-- in the group frame.
local function toGroup(evt, anchor)
  -- The group frame is LOGICAL. A concrete's realised ppq carries swing
  -- and delay; ppqL is its logical onset. Rebase off ppqL so neither
  -- leaks into the shared template (ppqL absent only under identity
  -- swing + zero delay, where raw == logical).
  local onset = evt.ppqL or evt.ppq
  local g = copyScalars(evt, { evType    = evt.evType,
                               chanDelta = evt.chan - anchor.chan,
                               key       = keyOf(evt),
                               ppq       = onset - anchor.ppq })
  if evt.evType == 'note' and evt.endppqL ~= util.OPEN
     and evt.endppqL ~= nil then
    g.dur = evt.endppqL - onset
  end
  return g
end

-- A nil group dur is an open note: author endppq = util.OPEN. A finite
-- dur is the intent ceiling: author endppq = onset + dur. tm stamps
-- endppqL and derives the raw tail, so a blocker delete regrows the
-- tail back up to the ceiling rather than merely clipping.
local function toInstance(g, anchor)
  local e = copyScalars(g, { evType = g.evType,
                             chan   = anchor.chan + (g.chanDelta or 0),
                             ppq    = anchor.ppq + (g.ppq or 0) })
  if g.evType == 'note' then
    e.lane = g.key
    if g.dur == nil then
      e.endppq = util.OPEN
    else
      e.endppq = e.ppq + g.dur
    end
  elseif g.evType == 'cc' then
    e.cc = g.key
  end
  return e
end

-- Off-take concretes withheld: writing one pushes REAPER's EOT and grows the take.
-- Group retains the member; concrete revives once an instance brings it on-take.
local function onTake(e)
  return e.ppq < tm:length()
end

-- Instance-frame partial update -> group-frame partial update. `groupEvt`
-- is the event's current group entry, the reference for ceiling<->dur.
-- A note's ceiling is INTENT: endppqL (authored), or open -> dur removed
-- (nil dur IS open). The realised endppq never enters the group frame.
local function updToGroup(update, anchor, groupEvt)
  local u = copyScalars(update, {})
  -- ppqL is the logical onset; tm's realiseNoteUpdate leaves update.ppq
  -- RAW (swing + delay baked in). The group frame is logical, so a pure
  -- delay edit (raw ppq set, no ppqL) must move no group onset — delay
  -- rides as its own scalar via copyScalars.
  if update.ppqL ~= nil then u.ppq = update.ppqL - anchor.ppq end
  if update.chan ~= nil then u.chanDelta = update.chan - anchor.chan end
  if update.lane ~= nil then u.key = update.lane end
  if update.cc   ~= nil then u.key = update.cc end
  if update.endppqL == util.OPEN then
    u.dur = util.REMOVE
  elseif update.endppqL ~= nil then
    local startAbs = update.ppqL or (anchor.ppq + (groupEvt.ppq or 0))
    u.dur = update.endppqL - startAbs
  end
  return u
end

-- Exact inverse: group-frame partial update -> instance-frame update.
-- dur removed (util.REMOVE), OR a move of an already-open note, => the
-- note is open: author endppq = util.OPEN. A finite dur (or a move of
-- a finite note) authors the intent ceiling on endppq; tm stamps
-- endppqL and derives the raw tail.
local function updToInstance(update, anchor, groupEvt)
  local u = copyScalars(update, {})
  if update.ppq ~= nil then u.ppq = anchor.ppq + update.ppq end
  if update.chanDelta ~= nil then u.chan = anchor.chan + update.chanDelta end
  if update.key ~= nil then
    if groupEvt.evType == 'note' then u.lane = update.key else u.cc = update.key end
  end
  if groupEvt.evType == 'note' then
    local startT  = update.ppq ~= nil and update.ppq or (groupEvt.ppq or 0)
    local goeOpen = update.dur == util.REMOVE
                    or (update.dur == nil and groupEvt.dur == nil
                        and update.ppq ~= nil)
    if goeOpen then
      u.endppq = util.OPEN
    elseif update.ppq ~= nil or update.dur ~= nil then
      local dur = update.dur ~= nil and update.dur or (groupEvt.dur or 0)
      u.endppq = anchor.ppq + startT + dur
    end
  end
  return u
end

-- Neutral field diff between two group events (feeds updToInstance).
local function diffGroup(oldG, newG)
  local d = {}
  for k, v in pairs(newG) do
    if k ~= 'evType' and oldG[k] ~= v then d[k] = v end
  end
  for k in pairs(oldG) do
    if k ~= 'evType' and newG[k] == nil then d[k] = util.REMOVE end
  end
  return d
end

----- Persistence

local function persist()
  local uuids = {}
  for groupId, gp in pairs(proj) do
    local gi = {}
    for instId, p in pairs(gp) do
      local byVuid = {}
      for vuid, rec in pairs(p) do byVuid[vuid] = rec.uuid end
      gi[instId] = byVuid
    end
    uuids[groupId] = gi
  end
  ds:assign('groups', { groups = groups, uuids = uuids })
end

-- Construction-time cm read runs before any take binds, so it is empty;
-- live data arrives only on the take-changed rebuild. Without it
-- restored groups are inert and nextGroupId stays 1, clobbering the
-- persisted group on the next markGroup.
local function rehydrate()
  local b = ds:get('groups') or {}
  groups      = b.groups or {}
  proj        = {}
  locByUuid   = {}
  nextGroupId = 1
  local uuids = b.uuids or {}
  for groupId, group in pairs(groups) do
    if groupId >= nextGroupId then nextGroupId = groupId + 1 end
    local gu = uuids[groupId] or {}
    for instId, instance in pairs(group.instances) do
      local desired = groupsCore.project(group, instance)
      local p       = projOf(groupId, instId)
      for vuid, uuid in pairs(gu[instId] or {}) do
        local evt = tm:byUuid(uuid)
        local g   = desired[vuid] or instance.adds[vuid]
        if evt and g then
          link(groupId, instId, vuid, p, uuid, util.clone(g), evt)
        end
      end
    end
  end
end

----- Helpers

local function freshInstance(anchor)
  return { anchor = anchor, assigns = {}, adds = {}, deletes = {} }
end

local function nextKey(map)
  local n = 0
  for k in pairs(map) do if k > n then n = k end end
  return n + 1
end

-- Locate (groupId, instId, vuid) by uuid -- the durable identity; a
-- table gm holds is valid only within one rebuild window.
local function classify(evt)
  local loc = evt.uuid and locByUuid[evt.uuid]
  if not loc then return end
  -- A link is only valid while its vuid still has a home: the shared group
  -- event, or (a local-only add) the instance's own adds. A delete leaves
  -- a dead link -- drop it and let the edit fall through to classifyCreate.
  local group  = groups[loc.groupId]
  local inst   = group and group.instances[loc.instId]
  local backed = group and (group.events[loc.vuid]
                            or (inst and inst.adds[loc.vuid]))
  if not backed then
    unlink(projOf(loc.groupId, loc.instId), loc.vuid)
    return
  end
  -- Keep the projection's live handle on the table the user is actually
  -- editing: covers an edit that lands before this flush's rebuild
  -- refresh (origin-skip and 'set' ops read rec.evt).
  local rec = projOf(loc.groupId, loc.instId)[loc.vuid]
  if rec and rec.evt ~= evt then rec.evt = evt end
  return loc.groupId, loc.instId, loc.vuid
end

-- Two group-frame events occupy the same region slot: same onset, same
-- channel offset, same stream. The identity the override-transition
-- helpers (revive, sibling absorb) match on.
local function sameSlot(a, b)
  return a.ppq == b.ppq and a.chanDelta == b.chanDelta
         and groupsCore.streamId(a) == groupsCore.streamId(b)
end

-- A global-mode create on a slot this instance locally deleted: the group
-- event whose delete is shadowing it, still alive in the shared pattern.
-- Returns its vuid so the create revives it in place instead of
-- allocating a coincident second vuid.
local function revivableVuid(group, instance, evt)
  local g = toGroup(evt, instance.anchor)
  for vuid in pairs(instance.deletes) do
    local ge = group.events[vuid]
    if ge and sameSlot(ge, g) then return vuid end
  end
end

-- A global-mode group-event create/delete flips whether a shared event
-- exists at a slot. A SIBLING instance carrying its own override there
-- must keep its visible event: re-express the override across the flip
-- instead of letting it collide (create) or orphan (delete). create:
-- a colliding add-ov upgrades to an assign-ov on the now-real vuid.
-- delete: an assign-ov demotes to a materialised add-ov -- resolve
-- needs the live base, so this runs before the group event is cleared.
-- The acting instance is the on-ov-local path's job; skip it. A sibling
-- that locally hides the slot has no visible event -- nothing to keep.
local function absorbSiblingOverrides(group, vuid, actingInstId, created)
  local g = group.events[vuid]
  if not g then return end
  for instId, instance in pairs(group.instances) do
    if instId ~= actingInstId then
      if created then
        for addVuid, addG in pairs(instance.adds) do
          if not instance.deletes[addVuid] and sameSlot(addG, g) then
            local a = instance.assigns
            a[vuid] = a[vuid] or {}
            for field, val in pairs(addG) do
              if field ~= 'evType' and g[field] ~= val then
                a[vuid][field] = groupsCore.deriveAssign(g, field, val)
              end
            end
            instance.adds[addVuid] = nil   -- reproject del's the stale concrete
          end
        end
      elseif instance.assigns[vuid] and not instance.deletes[vuid] then
        local nv = group.nextVuid
        group.nextVuid = nv + 1
        instance.adds[nv]      = groupsCore.resolve(g, instance.assigns[vuid])
        instance.assigns[vuid] = nil
      end
    end
  end
end

-- A create with no projected ref: does it fall inside some instance's
-- region, on a stream the region already selects? inRect enforces the gate.
local function classifyCreate(evt)
  for groupId, group in pairs(groups) do
    for instId, instance in pairs(group.instances) do
      if groupsCore.inRect(group.rect,
                       evt.ppq  - instance.anchor.ppq,
                       evt.chan - instance.anchor.chan,
                       { evType = evt.evType, key = keyOf(evt) }) then
        return groupId, instId
      end
    end
  end
end


-- Overlapping mirror groups have no defined semantics: classifyCreate
-- adopts a fresh event into whichever group pairs() yields first, and
-- two groups projecting the same slot collide with no cross-group
-- dedup. Regions are kept disjoint instead. Disjoint is per
-- (channel, streamId, time): same bars on a different lane or channel
-- do not conflict, and an adjacent stack (next = ppq+dur, half-open)
-- does not either.
local function rectCells(rect, anchor)
  local cells = {}                       -- cells[chan][streamId] = true
  for chanOff, streams in pairs(rect.streams) do
    local chan = anchor.chan + chanOff
    local row  = cells[chan] or {}
    cells[chan] = row
    for sid in pairs(streams) do row[sid] = true end
  end
  return cells
end

local function spansOverlap(aPpq, aDur, bPpq, bDur)
  return aPpq < bPpq + bDur and bPpq < aPpq + aDur
end

-- groupId of an existing group an instance of `rect` at `anchor` would
-- collide with -- shared time span AND a shared (channel, streamId)
-- cell -- or nil.
local function regionConflict(rect, anchor, exclude)
  local cells = rectCells(rect, anchor)
  for groupId, group in pairs(groups) do
    for instId, inst in pairs(group.instances) do
      local skip = exclude and exclude.groupId == groupId
                   and (exclude.instId == nil or exclude.instId == instId)
      if not skip and spansOverlap(anchor.ppq, rect.dur,
                       inst.anchor.ppq, group.rect.dur) then
        for chanOff, streams in pairs(group.rect.streams) do
          local row = cells[inst.anchor.chan + chanOff]
          if row then
            for sid in pairs(streams) do
              if row[sid] then return groupId end
            end
          end
        end
      end
    end
  end
end

----------- PUBLIC

--contract: seeds a new group from clipboard-sourced concrete `events` and a
--          resolved region `rect`. Instance 1's anchor is the region origin
--          { rect.ppq, rect.chanLo }; proj points at the passed events.
--          Returns the new groupId, or (nil, reason) if the region
--          collides with a live group (disjoint-region invariant).
function gm:markGroup(events, rect)
  if regionConflict(rect, { ppq = rect.ppq, chan = rect.chanLo }) then
    return nil, 'overlaps an existing mirror group'
  end
  local groupId = nextGroupId
  nextGroupId = groupId + 1
  local anchor = { ppq = rect.ppq, chan = rect.chanLo }

  local evs, p, vuid = {}, projOf(groupId, 1), 0
  for _, e in ipairs(events) do
    vuid = vuid + 1
    local g = toGroup(e, anchor)
    evs[vuid] = g
    link(groupId, 1, vuid, p, e.uuid, util.clone(g), e)
  end

  groups[groupId] = { rect = rect, events = evs, nextVuid = vuid + 1,
                      instances = { [1] = freshInstance(anchor) } }
  return groupId
end

-- Caller (clipboard) has bounds-checked and cleared the target region; off-take withheld, see onTake.
--contract: validates projection (chan 1..16); returns instId or nil,reason on invalid/collision.
function gm:newInstance(groupId, anchor)
  local group = groups[groupId]
  for _, g in pairs(group.events) do
    local e = toInstance(g, anchor)
    if e.chan < 1 or e.chan > 16 then return nil, 'channel out of range' end
  end
  if regionConflict(group.rect, anchor) then
    return nil, 'overlaps an existing mirror group'
  end

  propagating = true
  local instId   = nextKey(group.instances)
  local instance = freshInstance(anchor)
  group.instances[instId] = instance
  local p       = projOf(groupId, instId)
  local desired = groupsCore.project(group, instance)
  for vuid, g in pairs(desired) do
    local e = toInstance(g, anchor)
    if onTake(e) then
      tm:addEvent(e)
      selfStaged[e] = true
      link(groupId, instId, vuid, p, nil, util.clone(g), e)
    end
  end
  propagating = false
  pendingReproject[groupId] = true
  return instId
end

----- Active group (dupeClip-idiom selector; the command layer owns the
-----  clear-on-other-command lifetime, gm only the pointer)

function gm:activeGroup() return activeGroup end
function gm:clearActive() activeGroup = nil end

-- The group's projection rect, for the caller's pre-stage clear of the
-- destination zone (gm:newInstance contract). nil if the group is gone.
function gm:groupRect(groupId)
  local g = groups[groupId]
  return g and g.rect
end

--contract: case 1 -- seed a group from the selection, no copy. The new
--          group becomes active.
function gm:mark(events, rect)
  local groupId, why = self:markGroup(events, rect)
  if not groupId then return nil, why end
  activeGroup = groupId
  return activeGroup
end

--contract: active live -> case 3, drop one more copy at `anchor` (returns
--          instId). No active -> case 2, seed the group AND its first copy
--          (returns groupId, instId); the group becomes active.
function gm:stamp(events, rect, anchor)
  if activeGroup then
    return self:newInstance(activeGroup, anchor)
  end
  local groupId = self:markGroup(events, rect)
  if not groupId then return end
  activeGroup = groupId
  return activeGroup, self:newInstance(activeGroup, anchor)
end

--contract: explicit-group duplicate, used by the groupDuplicate
--          cascade. `groupId` live -> drop one more copy at `anchor`
--          into it; nil or stale -> seed group + first copy. Returns
--          the groupId either way. Sets it active for render parity,
--          but NEVER reads the shared active pointer -- the caller's
--          token is the sole continuation state (stamp's activeGroup
--          fallback belongs to mark/paste, not the cascade).
function gm:duplicateInto(groupId, events, rect, anchor)
  if not (groupId and groups[groupId]) then
    groupId = self:markGroup(events, rect)
    if not groupId then return end
  end
  activeGroup = groupId
  self:newInstance(groupId, anchor)
  return groupId
end

function gm:setLocalMode(on) localMode = not not on end
function gm:localMode()     return localMode end

function gm:stateOf(uuid)
  local loc = locByUuid[uuid]
  if not loc then return end
  local group = groups[loc.groupId]
  local _, _, states = groupsCore.project(group, group.instances[loc.instId])
  return states[loc.vuid]
end

-- Read accessor for the render pass: every live instance with the group
-- rect it projects, its anchor, and whether its group is active. No new
-- mutable state; rect/anchor are by reference (render reads, never
-- mutates).
function gm:eachInstance()
  local out = {}
  for groupId, group in pairs(groups) do
    for instId, inst in pairs(group.instances) do
      out[#out + 1] = { groupId = groupId, instId = instId,
                        rect = group.rect, anchor = inst.anchor,
                        colour = (groupId - 1) % 8 + 1,
                        active = groupId == activeGroup }
    end
  end
  return out
end

----------- SEAM

local function reproject(groupId)
  local group = groups[groupId]
  propagating = true
  for instId, instance in pairs(group.instances) do
    local desired = groupsCore.project(group, instance)
    local instProj = projOf(groupId, instId)
    -- tv is mirror-unaware: a user edit mutates a projected concrete's
    -- intent (ppq / endppqL / open) directly, with no group-geometry
    -- change, so the projection shadow goes stale and reconcile would
    -- see no drift. Refresh the shadow from the live concrete for every
    -- user-touched record, so reconcile both detects the drift and
    -- writes the corrective edit back to the siblings.
    for _, rec in pairs(instProj) do
      if rec.evt and rec.evt.uuid and touchedUuids[rec.evt.uuid] then
        rec.groupEvt = toGroup(rec.evt, instance.anchor)
      end
    end
    for _, op in ipairs(groupsCore.reconcile(desired, currentOf(instProj))) do
      local vuidProj = instProj[op.vuid]
      -- userOwned suppresses only the redundant tm op a user
      -- create/delete already staged (carrier reuse / no second
      -- delete); `set` still re-drives the origin. Keyed per uuid so a
      -- sibling's copy of the same vuid still propagates.
      local userOwned = vuidProj and vuidProj.evt
                        and touchedUuids[vuidProj.evt.uuid]
      if op.op == 'add' then
        local instEvt
        if userOwned then
          instEvt = vuidProj.evt
        else
          instEvt = toInstance(op.groupEvt, instance.anchor)
          -- off-take: withhold so the take never grows; left unlinked,
          -- reconcile re-offers it if it later comes on-take.
          if onTake(instEvt) then tm:addEvent(instEvt) else instEvt = nil end
        end
        if instEvt then
          link(groupId, instId, op.vuid, instProj,
               vuidProj and vuidProj.uuid, util.clone(op.groupEvt), instEvt)
        end
      elseif op.op == 'set' then
        tm:assignEvent(vuidProj.evt,
          updToInstance(diffGroup(vuidProj.groupEvt, op.groupEvt),
                        instance.anchor, op.groupEvt))
        vuidProj.groupEvt = util.clone(op.groupEvt)
      elseif op.op == 'del' then
        if not userOwned and vuidProj and vuidProj.evt then
          tm:deleteEvent(vuidProj.evt)
        end
        unlink(instProj, op.vuid)
      end
    end
  end
  propagating = false
end


-- Local edit of an existing override -- shared by localMode and the
-- on-ov-in-global path. An assign'd / synced group event accrues a
-- sticky per-instance assign; a local-only add is edited in place.
-- Never touches group.events, so no sibling sees it.
local function localAmend(instance, vuid, group, update)
  local groupEvt = group.events[vuid]
  if groupEvt then
    instance.assigns[vuid] = instance.assigns[vuid] or {}
    for field, val in pairs(updToGroup(update, instance.anchor, groupEvt)) do
      instance.assigns[vuid][field] = groupsCore.deriveAssign(groupEvt, field, val)
    end
  else
    local addEvt = instance.adds[vuid]
    util.assign(addEvt, updToGroup(update, instance.anchor, addEvt))
  end
end

do
  local touchedGroups = {}

  local function applyEdit(evt, update)
    local groupId, instId, vuid = classify(evt)
    local isCreate = false
    if not groupId and update ~= nil then          -- a brand-new event (create)
      groupId, instId = classifyCreate(evt)
      if not groupId then return end
      local group, instance = groups[groupId], groups[groupId].instances[instId]
      local revive = not localMode and revivableVuid(group, instance, evt)
      if revive then
        vuid = revive
        instance.deletes[vuid] = nil          -- type-over clears the local delete
      else
        vuid = group.nextVuid
        group.nextVuid = vuid + 1
      end
      isCreate = true
    elseif not groupId then
      return
    end

    local group    = groups[groupId]
    local instance = group.instances[instId]

    -- Same-instance "on-ov => local": once this instance carries its own
    -- override at vuid, a further edit there stays local and never
    -- propagates -- in localMode by definition, in global mode because a
    -- declared divergence is an intent to differ (clear it to rejoin the
    -- group). See docs/groupManager.md "Override transitions".
    local onOv = not isCreate and (instance.adds[vuid] ~= nil
                  or instance.assigns[vuid] ~= nil
                  or instance.deletes[vuid] == true)

    if localMode then
      if update == nil then
        if instance.adds[vuid] ~= nil then
          instance.adds[vuid] = nil       -- a local add deleted is just gone
        else
          instance.deletes[vuid] = true
        end
      elseif isCreate then
        local g = toGroup(evt, instance.anchor)
        instance.adds[vuid] = g
        link(groupId, instId, vuid, projOf(groupId, instId), evt.uuid, util.clone(g), evt)
      else
        localAmend(instance, vuid, group, update)
      end
    elseif onOv then
      if update == nil then
        if instance.adds[vuid] ~= nil then
          instance.adds[vuid] = nil       -- local add: just gone
        elseif instance.assigns[vuid] ~= nil then
          instance.assigns[vuid] = nil    -- drop the divergence, rejoin the group
          -- The user's delete removed this instance's concrete, but the
          -- group event survives, so the link still reads vuid-alive and
          -- reconcile would emit `set` against the dead event. Unlink so
          -- it emits `add` and re-materialises the group projection here.
          unlink(projOf(groupId, instId), vuid)
        end
        -- delete-ov + delete: the slot is already hidden here. No-op --
        -- and crucially never the propagating group delete below.
      else
        localAmend(instance, vuid, group, update)
      end
    else
      if update == nil then
        absorbSiblingOverrides(group, vuid, instId, false)
        group.events[vuid] = nil
      elseif isCreate then
        -- A fresh create is open like tv's placeNewNote: no birth
        -- ceiling (nil dur). tm derives its raw tail; an explicit
        -- duration arrives later as a non-create assign -> finite dur.
        local g = toGroup(evt, instance.anchor)
        g.dur = nil
        group.events[vuid] = g
        link(groupId, instId, vuid, projOf(groupId, instId), evt.uuid,
             util.clone(g), evt)
        absorbSiblingOverrides(group, vuid, instId, true)
      else
        local groupEvt = group.events[vuid]
        util.assign(groupEvt, updToGroup(update, instance.anchor, groupEvt))
      end
    end

    if evt.uuid then touchedUuids[evt.uuid] = true end
    touchedGroups[groupId] = true
  end

  tm:subscribe('preflush', function(adds, assigns, deletes)
    if propagating then return end
    touchedGroups, touchedUuids = {}, {}
    -- An assign tm delivers may be gm's own re-place echo (moveInstance):
    -- skip & clear so it never re-enters applyEdit and pollutes an
    -- override instance's assigns.
    for _, o in ipairs(assigns) do
      if selfAssigned[o.evt] then selfAssigned[o.evt] = nil
      else applyEdit(o.evt, o.update) end
    end
    for _, o in ipairs(deletes) do applyEdit(o.evt, nil)      end
    -- newInstance stages its projection adds; the commit flush fires
    -- later, so they reappear as gm's echo -- skip them.
    for _, o in ipairs(adds) do
      if selfStaged[o.evt] then selfStaged[o.evt] = nil
      else applyEdit(o.evt, o.evt) end
    end
    for groupId in pairs(touchedGroups) do reproject(groupId) end
    for groupId in pairs(pendingReproject) do
      if not touchedGroups[groupId] and groups[groupId] then reproject(groupId) end
      pendingReproject[groupId] = nil
    end
  end)
end

tm:subscribe('postflush', function()
  for groupId, gp in pairs(proj) do
    for instId, p in pairs(gp) do
      for vuid, rec in pairs(p) do
        if rec.uuid == nil and rec.evt and rec.evt.uuid then
          link(groupId, instId, vuid, p, rec.evt.uuid, rec.groupEvt, rec.evt)
        end
      end
    end
  end
  persist()
end)

-- Re-anchor every projection record to the freshly rebuilt event by
-- uuid each window: a sibling's cached evt is never reclassified (the
-- user never edits it) and would otherwise go stale, silently
-- no-oping all later assigns/deletes.
tm:subscribe('rebuild', function(takeChanged)
  if takeChanged then return rehydrate() end
  for _, gp in pairs(proj) do
    for _, p in pairs(gp) do
      for _, rec in pairs(p) do
        local uuid = rec.uuid or (rec.evt and rec.evt.uuid)
        local live = uuid and tm:byUuid(uuid)
        if live then rec.evt = live end
      end
    end
  end
end)

--contract: rehydrate on a groups invalidate (undo rewind); own assign echoes lack it, ignored
ds:subscribe('dataChanged', function(change)
  if change.name == 'groups' and change.invalidate then rehydrate() end
end)

----------- INSTANCE / GROUP LIFECYCLE

-- Stage a tm delete for every projected concrete of one instance, drop
-- the instance, and -- if it was the group's last -- drop the group,
-- clearing the active pointer if it named it. Unknown id -> nil, reason.
--contract: (groupId, instId) -> true | nil,reason; stages tm deletes for the instance's concretes, last instance drops the group + clears active. Unknown id -> nil,reason.
function gm:deleteInstance(groupId, instId)
  local group = groups[groupId]
  if not group then return nil, 'no such group' end
  if not group.instances[instId] then return nil, 'no such instance' end

  local p = projOf(groupId, instId)
  propagating = true
  for _, rec in pairs(p) do
    if rec.evt  then tm:deleteEvent(rec.evt) end
    if rec.uuid then locByUuid[rec.uuid] = nil end
  end
  propagating = false

  proj[groupId][instId]   = nil
  group.instances[instId] = nil
  if next(group.instances) == nil then
    groups[groupId], proj[groupId] = nil, nil
    if activeGroup == groupId then activeGroup = nil end
  end
  persist()
  return true
end

-- Re-anchor an instance. The group frame is anchor-invariant, so a pure
-- move is zero group-frame drift and reproject (drift-driven) cannot see
-- it: re-place every projected concrete through the group->instance dual
-- at the new anchor directly, gated selfStaged so the echo never
-- re-enters applyEdit. Rejected (instance untouched) on channel range or
-- a collision with another group or a sibling -- the moving instance
-- itself excluded so it cannot self-collide.
--contract: (groupId, instId, anchor) -> true | nil,reason. Precondition: caller has cleared the destination cells -- gm only re-places its own concretes, never clears foreign ones (as gm:newInstance, take/region bounds are the caller's). gm validates channel range + cross-group/sibling disjointness only.
function gm:moveInstance(groupId, instId, anchor)
  local group = groups[groupId]
  if not group then return nil, 'no such group' end
  local instance = group.instances[instId]
  if not instance then return nil, 'no such instance' end
  for _, g in pairs(group.events) do
    local e = toInstance(g, anchor)
    if e.chan < 1 or e.chan > 16 then return nil, 'channel out of range' end
  end
  if regionConflict(group.rect, anchor, { groupId = groupId, instId = instId }) then
    return nil, 'overlaps an existing mirror group'
  end

  propagating = true
  for _, rec in pairs(projOf(groupId, instId)) do
    if rec.evt and rec.groupEvt then
      local placed = toInstance(rec.groupEvt, anchor)
      selfAssigned[rec.evt] = true
      tm:assignEvent(rec.evt,
        { ppq = placed.ppq, chan = placed.chan, endppq = placed.endppq })
    end
  end
  propagating = false
  instance.anchor = anchor
  persist()
  return true
end

-- Resize the SHARED rect from edge instance `instId`'s drag. startDelta
-- re-origins (Model A: every anchor += startDelta, every group event
-- ppq -= startDelta) so realised positions hold while the boundary
-- slides; endDelta moves the end edge; streams swaps the per-channel
-- stream-set. A member the new rect no longer covers leaves the group --
-- unlinked from every instance BEFORE reproject so reconcile emits no
-- del: its concrete survives as an ordinary event. `gained` concretes
-- (from the acting instance, caller-supplied -- gm has no tm-enumeration
-- surface) fold in at that instance's anchor. Whole op rejected, nothing
-- mutated, if any instance's new placement collides with another group
-- or a sibling instance of the same group, or the region would vanish.
--contract: (groupId, instId, {startDelta?,endDelta?,streams?,gained?}) -> true|nil,reason.
function gm:resizeGroup(groupId, instId, edits)
  local group = groups[groupId]
  if not group then return nil, 'no such group' end
  local instance = group.instances[instId]
  if not instance then return nil, 'no such instance' end

  local rect       = group.rect
  local startDelta = edits.startDelta or 0
  local endDelta   = edits.endDelta   or 0
  local newDur     = rect.dur - startDelta + endDelta
  if newDur <= 0 then return nil, 'region would vanish' end
  local newRect = { ppq     = rect.ppq + startDelta,
                    dur     = newDur,
                    chanLo  = rect.chanLo,
                    streams = edits.streams or rect.streams }

  -- exclude only this instance: a grown shared rect must still refuse
  -- two siblings of the same group overlapping each other.
  for thisId, inst in pairs(group.instances) do
    local at = { ppq = inst.anchor.ppq + startDelta, chan = inst.anchor.chan }
    if regionConflict(newRect, at, { groupId = groupId, instId = thisId }) then
      return nil, 'overlaps an existing mirror group'
    end
  end

  for _, inst in pairs(group.instances) do
    inst.anchor.ppq = inst.anchor.ppq + startDelta
  end
  local leaving = {}
  for vuid, g in pairs(group.events) do
    g.ppq = (g.ppq or 0) - startDelta
    if not groupsCore.inRect(newRect, g.ppq, g.chanDelta or 0, g) then
      leaving[#leaving + 1] = vuid
    end
  end
  for _, vuid in ipairs(leaving) do
    group.events[vuid] = nil
    for siblingId in pairs(group.instances) do
      unlink(projOf(groupId, siblingId), vuid)
    end
  end
  group.rect = newRect
  for _, evt in ipairs(edits.gained or {}) do
    local g    = toGroup(evt, instance.anchor)
    local vuid = group.nextVuid
    group.nextVuid = vuid + 1
    group.events[vuid] = g
    link(groupId, instId, vuid, projOf(groupId, instId),
         evt.uuid, util.clone(g), evt)
  end

  reproject(groupId)
  persist()
  return true
end

return gm
