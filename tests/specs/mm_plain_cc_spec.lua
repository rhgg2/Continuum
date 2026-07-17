-- Every event mm hands out is uuid-addressable, including ccs REAPER wrote that
-- nothing has ever tagged. Those are `plain`: identity without persistence. The
-- uuid is in-memory only -- no }RDM sidecar rides the take, and every load mints
-- a fresh one -- so nothing may hold a plain cc's uuid across a reload.
--
-- The sidecar is unobservable directly, and it doesn't need to be: a sidecar in
-- the take is exactly what a reload binds. So `plain` surviving a flush+reload IS
-- the assertion that nothing was written, and a promoted cc keeping its uuid
-- across one is the assertion that something was.

local t = require('support')
local realMM = require('realMidiManager')()

local CHANMSG = { pa = 0xA0, cc = 0xB0, pc = 0xC0, at = 0xD0, pb = 0xE0 }

-- One take, seeded with raw ccs and (optionally) their sidecars.
local function freshTake(spec)
  local fakeReaper = require('fakeReaper').new()
  _G.reaper = fakeReaper
  local take = 'take-plain-cc'
  fakeReaper:bindTake(take, take .. '/item', take .. '/track')

  local ccs, texts = {}, {}
  for _, c in ipairs(spec.ccs or {}) do
    ccs[#ccs+1] = { ppq = c.ppq, chanmsg = CHANMSG[c.evType], chan = c.chan - 1,
                    msg2 = c.cc, msg3 = c.val }
  end
  for _, sc in ipairs(spec.sidecars or {}) do
    texts[#texts+1] = { ppq = sc.ppq, eventtype = -1, msg = t.encodeSidecar(sc) }
  end
  fakeReaper:seedMidi(take, { ccs = ccs, texts = texts })
  return take
end

local function ccAt(mm, ppq)
  for _, c in mm:ccs() do if c.ppq == ppq then return c end end
end

return {

  {
    name = 'a cc added with no metadata is plain, and still uuid-addressable',
    run = function(harness)
      local fm = harness.bareMM{ ccs = { { ppq = 0, evType = 'cc', chan = 1, cc = 7, val = 64 } } }
      local cc = ccAt(fm, 0)
      t.truthy(cc.uuid, 'a plain cc still carries a uuid -- identity is not conditional')
      t.eq(cc.plain, true, 'and it is marked plain: nothing persists for it')
    end,
  },

  {
    name = 'a cc added WITH metadata is not plain',
    run = function(harness)
      local fm = harness.bareMM{
        ccs = { { ppq = 0, evType = 'cc', chan = 1, cc = 7, val = 64, foo = 'tag' } },
      }
      local cc = ccAt(fm, 0)
      t.truthy(cc.uuid, 'uuid minted')
      t.eq(cc.plain, nil, 'metadata means a sidecar, which means not plain')
    end,
  },

  {
    name = 'a plain cc writes no sidecar: a reload re-mints its uuid and it stays plain',
    run = function()
      local take = freshTake{ ccs = { { ppq = 100, evType = 'cc', chan = 1, cc = 7, val = 30 } } }

      local first = realMM(nil)
      first:load(take)
      local before = ccAt(first, 100)
      t.truthy(before.uuid, 'load minted an in-memory uuid for the untagged cc')
      t.eq(before.plain, true, 'no sidecar bound, so it is plain')

      -- A structural write dirties the model, so the unwind reprojects the whole take.
      -- If that reprojection emitted a sidecar, the reload below would bind it.
      first:modify(function() first:assign(before.token, { val = 99 }) end)

      local second = realMM(nil)
      second:load(take)
      local after = ccAt(second, 100)
      t.truthy(after, 'the cc survived the reprojection')
      t.eq(after.val, 99, 'and carries the structural edit')
      t.eq(after.plain, true, 'still plain -- the flush wrote no sidecar for it')
    end,
  },

  {
    name = 'the first metadata stamp promotes a plain cc: its uuid then survives a reload',
    run = function()
      local take = freshTake{ ccs = { { ppq = 100, evType = 'cc', chan = 1, cc = 7, val = 30 } } }

      local first = realMM(nil)
      first:load(take)
      local plain = ccAt(first, 100)
      t.eq(plain.plain, true, 'starts plain')

      first:modify(function() first:assign(plain.token, { foo = 'tagged' }) end)
      local promoted = ccAt(first, 100)
      t.eq(promoted.plain, nil, 'the metadata stamp cleared plain')

      local second = realMM(nil)
      second:load(take)
      local after = ccAt(second, 100)
      t.eq(after.plain, nil, 'the sidecar bound on reload, so it is not plain')
      t.eq(after.uuid, promoted.uuid, 'a promoted uuid is durable -- that is what the sidecar is for')
      t.eq(after.foo, 'tagged', 'and its metadata rejoined')
    end,
  },

  {
    name = 'minting plain uuids does not dirty the take',
    run = function()
      -- The whole point of plain: a take full of untagged REAPER ccs is already
      -- converged. If minting their uuids set dirty, every load would rewrite it.
      local take = freshTake{ ccs = {
        { ppq = 100, evType = 'cc', chan = 1, cc = 7, val = 30 },
        { ppq = 200, evType = 'cc', chan = 1, cc = 7, val = 40 },
      } }

      local mm = realMM(nil)
      local flushed = false
      mm:subscribe('flushed', function() flushed = true end)
      mm:load(take)

      t.truthy(ccAt(mm, 100).uuid and ccAt(mm, 200).uuid, 'both minted uuids')
      t.falsy(flushed, 'load wrote nothing back: in-memory identity costs the take nothing')
    end,
  },
}
