-- eventMeta: per-event metadata keyed by POOL guid (not take), so every pooled
-- instance — and a parked survivor — resolves one shared blob. Pins the contract
-- that fixes "parking a take on scratch desyncs its notes from their metadata":
-- pre-fix, ctm_ lived in per-take ext-data while note uuids rode the shared pool,
-- so a sibling/parked instance read its notes' uuids but a stale/empty metadata.

local t    = require('support')
local util = require('util')

local function fresh()
  local reaper = require('fakeReaper').new()
  _G.reaper = reaper
  local ps = util.instantiate('pextStore')
  local em = util.instantiate('eventMeta', { ps = ps })
  return em, reaper, ps
end

return {
  {
    name = 'flush/load round-trips a uuid fields table under a pool guid',
    run = function()
      local em = fresh()
      em:flush('{p1}', { [1] = { detune = -50, delay = 12 } }, {})
      local meta = em:load('{p1}')
      t.eq(meta[1].detune, -50)
      t.eq(meta[1].delay, 12)
    end,
  },

  {
    name = 'distinct pool guids are isolated',
    run = function()
      local em = fresh()
      em:flush('{p1}', { [1] = { detune = -50 } }, {})
      t.eq(em:load('{p2}')[1], nil, 'p2 sees nothing of p1')
    end,
  },

  {
    -- THE REPRO: a pooled sibling is a different take with the SAME pool guid.
    -- Keyed by guid, it sees the metadata authored on the first instance.
    name = 'pooled instances sharing a guid resolve one shared blob',
    run = function()
      local em = fresh()
      em:flush('{pool}', { [7] = { detune = -50 } }, {})  -- authored on instance A
      t.eq(em:load('{pool}')[7].detune, -50, 'a sibling on the same pool sees it')
    end,
  },

  {
    name = 'flush delete removes a uuid and its keys entry, leaving siblings',
    run = function()
      local em = fresh()
      em:flush('{p1}', { [1] = { detune = -50 }, [2] = { detune = 10 } }, {})
      em:flush('{p1}', {}, { [1] = true })
      local meta = em:load('{p1}')
      t.eq(meta[1], nil, 'deleted uuid gone')
      t.eq(meta[2].detune, 10, 'sibling untouched')
    end,
  },

  {
    name = 'saveAll replaces the pool and sweeps stale uuids',
    run = function()
      local em = fresh()
      em:flush('{p1}', { [1] = { detune = -50 }, [2] = { detune = 10 } }, {})
      em:saveAll('{p1}', { [2] = { detune = 99 } })       -- uuid 1 absent → swept
      local meta = em:load('{p1}')
      t.eq(meta[1], nil, 'stale uuid 1 swept')
      t.eq(meta[2].detune, 99, 'survivor rewritten')
    end,
  },

  {
    -- An unpooled clone mints a fresh guid; copyPool forks the metadata onto it,
    -- after which the two pools diverge independently.
    name = 'copyPool forks a pool metadata to a new guid, then they diverge',
    run = function()
      local em = fresh()
      em:flush('{src}', { [1] = { detune = -50 } }, {})
      em:copyPool('{src}', '{dst}')
      t.eq(em:load('{dst}')[1].detune, -50, 'dst inherits src')
      em:flush('{dst}', { [1] = { detune = 0 } }, {})
      t.eq(em:load('{src}')[1].detune, -50, 'src unaffected by the dst edit')
    end,
  },

  {
    -- The keyset is cached in memory to keep flush off an O(N) re-parse; load() must
    -- still re-sync from projext, since REAPER undo/redo rewrites the blob behind us.
    name = 'load re-reads the keyset after an external (undo-style) projext wipe',
    run = function()
      local em, _, ps = fresh()
      em:flush('{p1}', { [1] = { detune = -50 } }, {})
      t.eq(em:load('{p1}')[1].detune, -50)                    -- primes the cache
      ps:assign('project', 'ctm.{p1}.kb', util.REMOVE)        -- undo wipes the pool bucket index
      t.eq(next(em:load('{p1}')), nil, 'load reflects the wipe, not the stale cache')
    end,
  },

  {
    name = 'dropPool forever-deletes a pool metadata',
    run = function()
      local em = fresh()
      em:flush('{p1}', { [1] = { detune = -50 }, [2] = { detune = 10 } }, {})
      em:dropPool('{p1}')
      t.eq(next(em:load('{p1}')), nil, 'nothing left under the guid')
    end,
  },
}
