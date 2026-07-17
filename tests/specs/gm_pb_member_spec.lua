-- F1: pb as a first-class gm member. The group frame stores pb INTENT under
-- `val`; toGroup sources it from evt.cents (frame-agnostic), never the um
-- entry's realised val. A member sitting under governing detune must not bake
-- that detune into the shared template -- else every sibling at a different
-- detune projects a stale wire. See design/fx-freeze.md § F1.

local t    = require('support')
local util = require('util')

local function rect() return { ppq = 0, dur = 960, chanLo = 1,
  streams = { [0] = { ['pb:0'] = true } } } end

-- Round-trips the persisted blob through serialise/unserialise, as the take
-- tier does, so a reload assertion proves survival through serialisation too.
local function serialisingDs()
  local store = {}
  return {
    get    = function(_, name) return store[name] end,
    assign = function(_, name, v) store[name] = util.unserialise(util.serialise(v)) end,
    subscribe = function() end,
  }
end

return {
  {
    name = 'pb member: toGroup carries intent (cents), not the realised val',
    run = function()
      local tm, staged = t.fakeTm()
      local gm = util.instantiate('groupManager', { tm = tm, ds = t.fakeDs() })

      -- A pb as the um layer hands it to gm (byUuid entry): val is realised
      -- (rawToCents(wire) = intent + governing detune); cents is the intent.
      local seed = { evType = 'pb', chan = 1, ppq = 0, shape = 'step',
                     val = 70, cents = 50 }

      local gid = gm:markGroup({ seed }, rect())
      t.truthy(gid, 'group seeded from a pb member')
      gm:newInstance(gid, { ppq = 960, chan = 1 })

      local copy = staged.add[1]
      t.truthy(copy, 'newInstance staged the projected pb')
      t.eq(copy.val, 50,
           'projected pb carries the intent (50), not the realised val (70)')
      t.eq(copy.cents, nil,
           'group frame speaks one name: cents does not ride alongside val')
    end,
  },

  {
    name = 'pb member: uuid survives the rebuild so gm can re-anchor it (tm:byUuid)',
    run = function(harness)
      -- A pb authored with cents is minted a uuid by mm (cents sits outside
      -- ccEventFields). Each rebuild gm re-anchors every member via
      -- tm:byUuid(uuid) (groupManager.lua:684); makeEntry's pb branch must carry
      -- that uuid into the um index, or the anchor goes stale and silently
      -- no-ops every later mirror edit.
      local h = harness.mk{ seed = { ccs = {
        { ppq = 0, chan = 1, evType = 'pb', val = 0, cents = 50, shape = 'step' },
      } } }

      local pbUuid
      for _, cc in ipairs(h.fm:dump().ccs) do
        if cc.evType == 'pb' then pbUuid = cc.uuid end
      end
      t.truthy(pbUuid, 'the authored pb was minted a uuid')

      local entry = h.tm:byUuid(pbUuid)
      t.truthy(entry, 'the pb is findable by uuid after the rebuild')
      t.eq(entry.evType, 'pb', 'and it is the pb um entry')
      t.eq(entry.uuid, pbUuid, 'carrying its uuid into the um index')
    end,
  },

  {
    name = 'pb member: a value edit propagates to every instance (updToGroup)',
    run = function(harness)
      -- tv authors the pb column as intent ({ val = intent }); updToGroup carries it
      -- into the shared frame and reproject re-stamps siblings. Pins it isn't dropped.
      local h = harness.mk{
        groups = true,
        seed   = { ccs = {
          { ppq = 0, chan = 1, evType = 'pb', val = 0, cents = 50, shape = 'step' },
        } },
      }
      local pbRect = rect()
      local gid = h.gm:markGroup(h.vm:eventsInRect(pbRect), pbRect)
      t.truthy(gid, 'pb region marked as a group')
      h.gm:newInstance(gid, { ppq = 960, chan = 1 })
      h.tm:flush()

      local function pbByPpq()
        local out = {}
        for _, cc in ipairs(h.fm:dump().ccs) do
          if cc.evType == 'pb' then out[cc.ppq] = cc.val end
        end
        return out
      end

      local before = pbByPpq()
      local pbUuid
      for _, cc in ipairs(h.fm:dump().ccs) do
        if cc.evType == 'pb' and cc.ppq == 0 then pbUuid = cc.uuid end
      end
      t.truthy(pbUuid, 'origin pb member has a uuid')

      h.gm:assignEvent(pbUuid, { val = 300 })
      h.tm:flush()

      local after = pbByPpq()
      t.truthy(after[0] ~= before[0], 'origin pb value changed under the edit')
      t.eq(after[960], after[0],
           'sibling tracked the pb value edit through the shared pattern')
    end,
  },

  {
    name = 'pb member: a fresh in-region pb is adopted and propagates (classifyCreate)',
    run = function(harness)
      -- classifyCreate keys the fresh pb by generic streamId ('pb:0'), no type
      -- arm; gm:addEvent is the member backing's add-target (trackerView.lua:85).
      local h = harness.mk{
        groups = true,
        seed   = { ccs = {
          { ppq = 0, chan = 1, evType = 'pb', val = 0, cents = 50, shape = 'step' },
        } },
      }
      local pbRect = rect()
      local gid = h.gm:markGroup(h.vm:eventsInRect(pbRect), pbRect)
      h.gm:newInstance(gid, { ppq = 960, chan = 1 })
      h.tm:flush()

      local adopted = h.gm:addEvent{ evType = 'pb', ppq = 480, chan = 1,
                                     val = 25, shape = 'step' }
      t.truthy(adopted, 'the in-region pb was adopted (classifyCreate found the group)')
      h.tm:flush()

      local seen = {}
      for _, cc in ipairs(h.fm:dump().ccs) do
        if cc.evType == 'pb' then seen[cc.ppq] = true end
      end
      t.truthy(seen[480],  'the created pb lives at the origin')
      t.truthy(seen[1440], 'and propagated to the sibling (960 + 480)')
    end,
  },

  {
    name = 'pb member: the persisted blob carries intent (not the wire) and rehydrates live',
    run = function()
      -- persist() copies group.events verbatim; the frame holds pb intent under
      -- `val`, so a reload speaks intent, never a baked wire (design/fx-freeze.md § F1).
      local ds = serialisingDs()

      local tmA, stagedA = t.fakeTm()
      local A = util.instantiate('groupManager', { tm = tmA, ds = ds })
      -- val is realised (70 = intent + governing detune); cents is the intent (50).
      local src = { evType = 'pb', chan = 1, ppq = 0, shape = 'step',
                    val = 70, cents = 50, uuid = 900 }
      local gid = A:markGroup({ src }, rect())
      A:newInstance(gid, { ppq = 960, chan = 1 })
      tmA:flush()

      local persisted
      for _, group in pairs(ds:get('groups').groups) do
        for _, evt in pairs(group.events) do
          if evt.evType == 'pb' then persisted = evt end
        end
      end
      t.truthy(persisted, 'the pb group event landed in the persisted blob')
      t.eq(persisted.val, 50, 'blob carries the intent (50), not the realised wire (70)')
      t.eq(persisted.cents, nil, 'and speaks one name: no cents rides alongside val')

      local addEvt = stagedA.add[1]
      local tmB = t.fakeTm{ uuidMap = { [src.uuid] = src, [addEvt.uuid] = addEvt } }
      local B   = util.instantiate('groupManager', { tm = tmB, ds = ds })
      tmB:fireRebuild(true)
      t.eq(#B:eachInstance(), 2, 'the persisted pb group rehydrated live, not inert')
    end,
  },

  {
    name = 'pb member: a sibling under a different detune re-derives its own wire',
    run = function(harness)
      -- Each seat's wire re-derives at flush as cents + that seat's governing
      -- detune -- proof the origin's wire was never baked into the shared template.
      local h = harness.mk{
        config = { take = { pbRange = 2 } },
        groups = true,
        seed   = {
          ccs   = { { ppq = 0, chan = 1, evType = 'pb', val = 0, cents = 50, shape = 'step' } },
          notes = { { ppq = 720, endppq = 960, chan = 1, lane = 1,
                      pitch = 60, vel = 100, detune = 20 } },
        },
      }
      local gid = h.gm:markGroup(h.vm:eventsInRect(rect()), rect())
      h.gm:newInstance(gid, { ppq = 960, chan = 1 })   -- seat governed by the detuned note
      h.tm:flush()

      local originUuid, siblingUuid
      for _, cc in ipairs(h.fm:dump().ccs) do
        if cc.evType == 'pb' and cc.ppq == 0   then originUuid  = cc.uuid end
        if cc.evType == 'pb' and cc.ppq == 960 then siblingUuid = cc.uuid end
      end
      t.truthy(originUuid and siblingUuid, 'origin and sibling pb both present')

      local originVal  = h.tm:byUuid(originUuid).val
      local siblingVal = h.tm:byUuid(siblingUuid).val
      t.eq(originVal, 50,  'origin realises its intent under detune 0')
      t.eq(siblingVal, 70, 'sibling realises the SAME intent under detune 20 (50 + 20)')
      t.eq(siblingVal - originVal, 20,
           'the realised wire tracks the seat detune, not a baked origin value')
    end,
  },
}
