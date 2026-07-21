-- Pin-tests for how midiManager is addressed. Every event mm hands out carries a
-- uuid, and that uuid is the handle: byUuid, assign and delete all take one.
--
-- Content keys (evType, chan, ppq, pitch|cc) stay private to mm, where they serve
-- only the same-pitch collision backstop -- see mm_collision_backstop_spec.
--
-- Identity contract:
--   * Every event has one, minted at add or at load.
--   * Stable under every assign: moving ppq, pitch or chan does not re-key it.
--   * Durable across reload, except a plain cc -- it binds no sidecar, so its uuid
--     is in-memory only and re-minted each load. See mm_plain_cc_spec.

local t = require('support')

return {
  {
    name = 'note: a fetched event round-trips through byUuid',
    run = function(harness)
      local h = harness.mk{
        seed = { notes = { { ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100 } } },
      }
      local _, fetched = h.fm:notes()()
      t.truthy(fetched.uuid, 'the clone carries a handle')
      local loc, byU = h.fm:byUuid(fetched.uuid)
      t.eq(fetched.loc, nil, 'loc stays mm-private -- stripped from the outbound clone')
      t.truthy(loc, 'byUuid still returns mm-internal loc')
      t.eq(byU.pitch, 60)
      t.eq(byU.chan,  1)
      t.eq(byU.ppq,   0)
    end,
  },

  {
    name = 'cc: a plain cc is addressable like any other',
    run = function(harness)
      local fm = harness.bareMM{ ccs = { { ppq = 120, evType = 'cc', chan = 2, cc = 7, val = 64 } } }
      local _, cc = fm:ccs()()
      local loc, c, kind = fm:byUuid(cc.uuid)
      t.eq(loc, 1)
      t.eq(kind, 'cc')
      t.eq(c.val, 64)
      t.eq(c.plain, true, 'plain -- no sidecar, but its in-memory uuid addresses it')
    end,
  },

  {
    name = 'pb / pa / at / pc: every evType yields a working handle',
    run = function(harness)
      local fm = harness.bareMM{ ccs = {
        { ppq = 0,   evType = 'pb', chan = 1,             val = -2048 },
        { ppq = 60,  evType = 'pa', chan = 3, pitch = 64, vel =  90   },
        { ppq = 120, evType = 'at', chan = 5,             val =  77   },
        { ppq = 180, evType = 'pc', chan = 7,             val =  12   },
      } }
      local want = { pb = { field = 'val', value = -2048 }, pa = { field = 'vel', value = 90 },
                     at = { field = 'val', value = 77 },    pc = { field = 'val', value = 12 } }
      local seen = 0
      for _, cc in fm:ccs() do
        local _, evt = fm:byUuid(cc.uuid)
        t.truthy(evt, cc.evType .. ': byUuid returned an event')
        local expected = want[cc.evType]
        t.eq(evt[expected.field], expected.value, cc.evType .. '.' .. expected.field)
        seen = seen + 1
      end
      t.eq(seen, 4, 'all four evTypes present')
    end,
  },

  {
    name = 'a persisted note keeps its handle across reload',
    run = function(harness)
      local h = harness.mk{
        seed = { notes = { { ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100 } } },
      }
      local _, note = h.fm:notes()()
      local uuid = note.uuid

      h.fm:reload()

      local _, n2 = h.fm:byUuid(uuid)
      t.truthy(n2, 'the note kept its uuid across reload')
      t.eq(n2.pitch, 60)
    end,
  },

  {
    name = 'moving an identity field does not re-key: the same handle resolves to the moved note',
    run = function(harness)
      local h = harness.mk{
        seed = { notes = { { ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100 } } },
      }
      local _, note = h.fm:notes()()
      local uuid = note.uuid

      h.fm:modify(function() h.fm:assign(uuid, { ppq = 480, pitch = 64 }) end)

      local _, moved = h.fm:byUuid(uuid)
      t.truthy(moved, 'the handle survives a move of both identity fields')
      t.eq(moved.ppq,   480)
      t.eq(moved.pitch, 64)
      local _, only = h.fm:notes()()
      t.eq(only.uuid, uuid, 'and it is still the one note, not a new one')
    end,
  },

  {
    name = 'distinct events get distinct handles',
    run = function(harness)
      -- A note and a pa at the same (chan, pitch, ppq); a cc#7 vs cc#10
      -- at the same (chan, ppq); a pb at the same (chan, ppq) as an at.
      local fm = harness.bareMM{
        notes = { { ppq = 0, endppq = 120, chan = 1, pitch = 60, vel = 100 } },
        ccs   = {
          { ppq = 0,  evType = 'pa', chan = 1, pitch = 60, vel = 50 },
          { ppq = 60, evType = 'cc', chan = 2, cc = 7,  val = 10 },
          { ppq = 60, evType = 'cc', chan = 2, cc = 10, val = 20 },
          { ppq = 90, evType = 'pb', chan = 3, val = 0 },
          { ppq = 90, evType = 'at', chan = 3, val = 30 },
        },
      }
      local handles = {}
      for _, n in fm:notes() do handles[#handles+1] = n.uuid end
      for _, c in fm:ccs()   do handles[#handles+1] = c.uuid end
      local seen = {}
      for _, uuid in ipairs(handles) do
        t.truthy(uuid, 'every event carries a handle')
        t.falsy(seen[uuid], 'duplicate handle: ' .. tostring(uuid))
        seen[uuid] = true
      end
      t.eq(#handles, 6, 'all six events present')
    end,
  },

  {
    name = 'byUuid returns nil for an unknown handle',
    run = function(harness)
      local h = harness.mk{
        seed = { notes = { { ppq = 0, endppq = 240, chan = 1, pitch = 60, vel = 100 } } },
      }
      t.eq(h.fm:byUuid(99999), nil)
      t.eq(h.fm:byUuid(nil), nil)
    end,
  },
}
