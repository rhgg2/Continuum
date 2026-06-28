-- Pin-tests for the cc-side of the per-event metadata contract — uuid
-- allocation on first stamp, lockless carve-out for subsequent metadata,
-- and clean-up on delete.

local t = require('support')
local util = require('util')

-- Plain-cc tests: tm's rebuild rule (Phase 2 two-frame) writes ppqL onto
-- any non-frame cc passing through, which allocates a uuid via the
-- metadata path. To pin mm's lock-on-plain-cc contract we need a cc that
-- never went through tm — so a couple of tests below build a bare fakeMM.

local function ccAt(mm, i)
  local n = 0
  for _, c in mm:ccs() do
    n = n + 1
    if n == i then return c end
  end
end

return {
  {
    name = 'metadata-only assign on a plain (un-uuid\'d) cc requires the lock',
    run = function()
      local fm = newMidiManager{ length = 3840, resolution = 240, take = 't' }
      fm:seed{ ccs = { { ppq = 0, evType = 'cc', chan = 1, cc = 7, val = 64 } } }
      local ok, err = pcall(function() fm:assign(ccAt(fm, 1).token, { foo = 1 }) end)
      t.falsy(ok, 'expected an assertion')
      t.truthy(tostring(err):find('modify'), 'error mentions modify lock')
    end,
  },

  {
    name = 'first metadata stamp allocates a uuid and persists the field',
    run = function(harness)
      local h = harness.mk{
        seed = { ccs = { { ppq = 0, evType = 'cc', chan = 1, cc = 7, val = 64 } } },
      }
      h.fm:modify(function() h.fm:assign(ccAt(h.fm, 1).token, { foo = 'hello' }) end)
      local cc = ccAt(h.fm, 1)
      t.truthy(cc.uuid, 'uuid allocated')
      t.eq(cc.foo, 'hello')
    end,
  },

  {
    name = 'subsequent metadata writes on a stamped cc are lockless',
    run = function(harness)
      local h = harness.mk{
        seed = { ccs = { { ppq = 0, evType = 'cc', chan = 1, cc = 7, val = 64 } } },
      }
      h.fm:modify(function() h.fm:assign(ccAt(h.fm, 1).token, { foo = 1 }) end)
      -- No modify wrapper this time — must not raise.
      h.fm:assign(ccAt(h.fm, 1).token, { foo = 2 })
      t.eq(ccAt(h.fm, 1).foo, 2)
    end,
  },

  {
    name = 'mixed structural+metadata write under modify stamps in one go',
    run = function(harness)
      local h = harness.mk{
        seed = { ccs = { { ppq = 0, evType = 'cc', chan = 1, cc = 7, val = 64 } } },
      }
      h.fm:modify(function() h.fm:assign(ccAt(h.fm, 1).token, { val = 100, label = 'tag' }) end)
      local cc = ccAt(h.fm, 1)
      t.eq(cc.val, 100)
      t.eq(cc.label, 'tag')
      t.truthy(cc.uuid, 'uuid stamped on the same write')
    end,
  },

  {
    name = 'pure-structural writes leave plain ccs un-uuid\'d',
    run = function()
      -- Bare mm (no tm), to keep the cc plain — see header note.
      local fm = newMidiManager{ length = 3840, resolution = 240, take = 't' }
      fm:seed{ ccs = { { ppq = 0, evType = 'cc', chan = 1, cc = 7, val = 64 } } }
      fm:modify(function() fm:assign(ccAt(fm, 1).token, { val = 100 }) end)
      t.eq(ccAt(fm, 1).uuid, nil, 'no metadata, no uuid (sidecar-on-touch)')
    end,
  },

  {
    name = 'distinct first stamps get distinct uuids',
    run = function(harness)
      local h = harness.mk{
        seed = {
          ccs = {
            { ppq =  0, evType = 'cc', chan = 1, cc = 7, val = 0   },
            { ppq = 10, evType = 'cc', chan = 1, cc = 7, val = 64  },
          },
        },
      }
      h.fm:modify(function()
        h.fm:assign(ccAt(h.fm, 1).token, { foo = 1 })
        h.fm:assign(ccAt(h.fm, 2).token, { foo = 2 })
      end)
      local u1, u2 = ccAt(h.fm, 1).uuid, ccAt(h.fm, 2).uuid
      t.truthy(u1 and u2, 'both got uuids')
      t.truthy(u1 ~= u2, 'and they differ')
    end,
  },

  {
    name = 'a stamped cc keeps its uuid across a lockless metadata assign',
    run = function(harness)
      local h = harness.mk{
        seed = {
          ccs = { { ppq = 0, evType = 'cc', chan = 1, cc = 7, val = 64, foo = 'old' } },
        },
      }
      -- Seeding with metadata stamps a uuid; capture it, then take the lockless
      -- carve-out (uuid present, metadata-only) and confirm it isn't re-issued.
      local uuid = ccAt(h.fm, 1).uuid
      t.truthy(uuid, 'stamped cc carries a uuid')
      h.fm:assign(ccAt(h.fm, 1).token, { foo = 'new' })
      local cc = ccAt(h.fm, 1)
      t.eq(cc.uuid, uuid, 'uuid retained across the metadata-only assign')
      t.eq(cc.foo, 'new')
    end,
  },

  {
    name = 'delete removes both event and uuid identity',
    run = function(harness)
      local h = harness.mk{
        seed = { ccs = { { ppq = 0, evType = 'cc', chan = 1, cc = 7, val = 64 } } },
      }
      h.fm:modify(function() h.fm:assign(ccAt(h.fm, 1).token, { foo = 'x' }) end)
      t.truthy(ccAt(h.fm, 1).uuid)
      local tk = ccAt(h.fm, 1).token
      h.fm:modify(function() h.fm:delete(tk) end)
      t.eq(ccAt(h.fm, 1), nil, 'cc gone')
    end,
  },

  {
    name = 'util.REMOVE clears a metadata field on a stamped cc (no lock)',
    run = function(harness)
      local h = harness.mk{
        seed = { ccs = { { ppq = 0, evType = 'cc', chan = 1, cc = 7, val = 64,
                           uuid = 7, foo = 'present' } } },
      }
      h.fm:assign(ccAt(h.fm, 1).token, { foo = util.REMOVE })
      t.eq(ccAt(h.fm, 1).foo, nil)
    end,
  },
}
