-- F1: pb as a first-class gm member. The group frame stores pb INTENT under
-- `val`; toGroup sources it from evt.cents (frame-agnostic), never the um
-- entry's realised val. A member sitting under governing detune must not bake
-- that detune into the shared template -- else every sibling at a different
-- detune projects a stale wire. See design/fx-freeze.md § F1.

local t    = require('support')
local util = require('util')

local function rect() return { ppq = 0, dur = 960, chanLo = 1,
  streams = { [0] = { ['pb:0'] = true } } } end

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
      local rect = { ppq = 0, dur = 960, chanLo = 1,
                     streams = { [0] = { ['pb:0'] = true } } }
      local gid = h.gm:markGroup(h.vm:eventsInRect(rect), rect)
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
}
